import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import '../core/test_log.dart';
import 'ssap_messages.dart';
import 'ws_connect.dart';
import 'wol.dart' show macList;

enum CmdState { connecting, ready, needsPairing, dead }

/// Result of one SSAP round trip, kept separate from the public [Result]
/// type (in webos_client.dart) so the session layer never has to know about
/// UI-facing error text conventions.
sealed class CmdReply {
  const CmdReply();
}

class CmdReplyOk extends CmdReply {
  const CmdReplyOk(this.payload, {this.raw});
  final Map<String, dynamic> payload;

  /// The whole frame as the TV sent it; only the keyboard test reads it.
  final Map<String, dynamic>? raw;
}

class CmdReplyNeedsPairing extends CmdReply {
  const CmdReplyNeedsPairing();
}

class CmdReplyErr extends CmdReply {
  const CmdReplyErr(this.message, {this.raw});
  final String message;
  final Map<String, dynamic>? raw;
}

const String _getInfoUri = 'ssap://com.webos.service.connectionmanager/getinfo';

/// getinfo reports the Wi-Fi and the wired MAC whichever interface is plugged
/// in, and only the live one wakes the TV, so both are kept and both get a
/// magic packet.
List<String> extractMacAddresses(Map<String, dynamic>? payload) => [
      for (final key in ['wifiInfo', 'wiredInfo'])
        if ((payload?[key] as Map<String, dynamic>?)?['macAddress']
            case final String mac when mac.isNotEmpty)
          mac,
    ];

/// Adds what the TV reports to the saved MACs without dropping one typed in
/// by hand.
String mergeMacs(String saved, List<String> found) {
  final seen = <String>{};
  return [...macList(saved), ...found]
      .where((m) => seen.add(m.toUpperCase()))
      .join(', ');
}

/// One shared, multiplexed SSAP socket. Requests are matched to replies by
/// id so concurrent callers (slider send loops, the power watcher, value
/// refreshes) share a single TLS connection instead of racing to open their
/// own — the original bug this avoids: each caller opening a fresh socket
/// and killing the previous one meant nothing ever finished connecting
/// under load.
class CommandSession {
  CommandSession(
    this.ip,
    this._prefs, {
    SocketConnector? connector,
    this.connectGrace = const Duration(seconds: 10),
  })  : _connector = connector ?? connectTrustAll,
        createdAt = DateTime.now(),
        sid = TestLog.nextSid('cmd') {
    _connect();
  }

  final String ip;
  final Prefs _prefs;
  final SocketConnector _connector;
  final DateTime createdAt;
  final String sid;
  final Duration connectGrace;

  static const _readyWait = Duration(seconds: 8);

  CmdState _state = CmdState.connecting;
  CmdState get state => _state;

  /// When the TV last accepted this session's registration.
  DateTime? registeredAt;

  /// The TV's `registered` frame. Holds the client key, so it is for
  /// diagnostics that redact it.
  Map<String, dynamic>? registeredFrame;

  WebSocket? _ws;
  String? deadReason;

  /// The TV answered the registration with an error (prompt denied or timed
  /// out), as opposed to the socket just dropping.
  bool pairingRejected = false;

  /// The socket completed its upgrade. A session that died without getting
  /// this far stalled in connect/TLS, which says nothing about the TV being
  /// in standby.
  bool opened = false;

  final _idSeq = SsapIdSequence();
  final _pending = <String, Completer<CmdReply>>{};
  final _subscriptions = <String, void Function(Map<String, dynamic>?)>{};
  final _subscriptionFrameTaps = <String, void Function(Map<String, dynamic> frame)>{};
  final _stateSettled = Completer<void>();
  final _deathCompleter = Completer<void>();

  /// A session mid-handshake is shared rather than replaced: concurrent
  /// callers used to each open a new socket and kill the previous one, so
  /// nothing ever finished connecting under load (spec §1.4 `isUsable`).
  bool get isUsable {
    switch (_state) {
      case CmdState.ready:
      case CmdState.needsPairing:
        return _ws != null;
      case CmdState.connecting:
        return DateTime.now().difference(createdAt) < connectGrace;
      case CmdState.dead:
        return false;
    }
  }

  Future<void> _connect() async {
    TestLog.sock('cmd', sid, 'connect');
    try {
      final ws = await connectWithTimeout(_connector, 'wss://$ip:3001', const Duration(seconds: 3));
      if (_state == CmdState.dead) {
        // close() ran while the connect was in flight; nothing owns this socket.
        closeQuietly(ws);
        return;
      }
      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      opened = true;
      TestLog.sock('cmd', sid, 'open');
      ws.listen(_onMessage, onDone: _onDone, onError: _onError, cancelOnError: true);
      ws.add(encodeSsapMessage(buildRegistration(_prefs.clientKey)));
    } catch (e) {
      deadReason = e.toString();
      TestLog.sock('cmd', sid, 'fail', reason: deadReason);
      _die(CmdReplyErr(deadReason ?? 'Connection failed'));
    }
  }

  void _onDone() {
    TestLog.sock('cmd', sid, 'close', code: _ws?.closeCode, reason: _ws?.closeReason);
    if (_state == CmdState.dead) return;
    // A TV in standby accepts the upgrade and then closes with "Try Again
    // Later (EWS)" -- record the reason so the next send() surfaces it
    // instead of a bare "Connection closed".
    final reason = _ws?.closeReason;
    deadReason = (reason == null || reason.isEmpty) ? null : reason;
    _die(const CmdReplyErr('Connection closed'));
  }

  void _onError(Object error) {
    TestLog.sock('cmd', sid, 'fail', reason: error.toString());
    if (_state == CmdState.dead) return;
    deadReason = error.toString();
    _die(CmdReplyErr(deadReason ?? 'Connection failed'));
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = decodeSsapMessage(raw as String);
    } catch (_) {
      return;
    }
    final type = msg['type'] as String?;
    final id = msg['id'] as String?;
    final payload = msg['payload'] as Map<String, dynamic>?;

    if (type == 'registered') {
      registeredAt = DateTime.now();
      registeredFrame = msg;
      // A reply that outlives a TV switch belongs to the old TV and must not
      // overwrite the new one's key or MACs.
      final current = ip == _prefs.tvIp;
      final key = payload?['client-key'] as String?;
      if (current && key != null && key.isNotEmpty) {
        _prefs.setClientKey(key);
      }
      // Fewer than two means a pairing from before both MACs were kept.
      if (current && macList(_prefs.tvMac).length < 2) {
        _ws?.add(encodeSsapMessage({
          'id': macLookupMessageId,
          'type': 'request',
          'uri': _getInfoUri,
          'payload': {},
        }));
      }
      TestLog.sock('cmd', sid, 'registered');
      _state = CmdState.ready;
      _settle();
      return;
    }

    if (type == 'response' && id == regMessageId) {
      // TV challenged registration -- user must accept the pairing prompt.
      // "registered" arrives on this same socket once they do.
      TestLog.sock('cmd', sid, 'prompt');
      _state = CmdState.needsPairing;
      _settle();
      _failAll(const CmdReplyNeedsPairing());
      return;
    }

    if (type == 'response' && id == macLookupMessageId) {
      if (ip != _prefs.tvIp) return;
      final merged = mergeMacs(_prefs.tvMac, extractMacAddresses(payload));
      if (merged != _prefs.tvMac) _prefs.setTvMac(merged);
      return;
    }

    if (id != null &&
        (type == 'response' || type == 'error') &&
        _subscriptions.containsKey(id)) {
      _subscriptionFrameTaps[id]?.call(msg);
      _subscriptions[id]!(type == 'response' ? payload : null);
      return;
    }

    if (type == 'response' && id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final returnValue = payload?['returnValue'] as bool? ?? true;
      // A top-level error only counts when the payload does not itself say
      // the call succeeded, so a TV that adds a stray `error` to a good reply
      // does not break pairing, power or volume calls.
      final payloadOk = payload?['returnValue'] == true;
      if (returnValue == false || (msg['error'] is String && !payloadOk)) {
        final errorText = ssapErrorText(msg);
        TestLog.res(sid, id, false, errorText);
        completer.complete(CmdReplyErr(
          errorText.isEmpty ? 'Command rejected by TV' : errorText,
          raw: msg,
        ));
      } else {
        TestLog.res(sid, id, true, null);
        completer.complete(CmdReplyOk(payload ?? const {}, raw: msg));
      }
      return;
    }

    // Denied or timed-out pairing prompt. Left alone the session would sit in
    // needsPairing for good, with nothing on the TV left to accept.
    if (type == 'error' && id == regMessageId) {
      final errorText = ssapErrorText(msg);
      deadReason = errorText.isEmpty ? 'Pairing was not accepted' : errorText;
      pairingRejected = true;
      final ws = _ws;
      _die(CmdReplyErr(deadReason!));
      closeQuietly(ws);
      return;
    }

    if (type == 'error' && id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final errorText = ssapErrorText(msg);
      TestLog.res(sid, id, false, errorText);
      completer.complete(CmdReplyErr(errorText.isEmpty ? 'Unknown error' : errorText, raw: msg));
      return;
    }
  }

  void _settle() {
    if (!_stateSettled.isCompleted) _stateSettled.complete();
  }

  void _failAll(CmdReply reply) {
    final pendingCopy = Map.of(_pending);
    _pending.clear();
    for (final completer in pendingCopy.values) {
      if (!completer.isCompleted) completer.complete(reply);
    }
  }

  void _die(CmdReply reply) {
    if (_state == CmdState.dead) return;
    _state = CmdState.dead;
    _ws = null;
    _settle();
    if (!_deathCompleter.isCompleted) _deathCompleter.complete();
    _failAll(reply);
  }

  /// Waits (up to 8 s) for the socket to leave CONNECTING, then sends the
  /// request and waits (up to [timeoutSecs]) for its reply. Worst case a
  /// single call blocks ~14 s.
  Future<CmdReply> send(
    String uri, {
    Map<String, dynamic> payload = const {},
    int timeoutSecs = 6,
  }) async {
    await _awaitSettled(_readyWait);

    if (_state != CmdState.ready) {
      switch (_state) {
        case CmdState.needsPairing:
          return const CmdReplyNeedsPairing();
        case CmdState.dead:
          final suffix = deadReason != null ? ' ($deadReason)' : '';
          return CmdReplyErr("Can't connect to TV$suffix");
        case CmdState.connecting:
        case CmdState.ready:
          return const CmdReplyErr('Timeout. Is the TV on and reachable?');
      }
    }

    final id = _idSeq.nextRequestId();
    final completer = Completer<CmdReply>();
    _pending[id] = completer;

    final ws = _ws;
    var sent = true;
    if (ws == null || _state != CmdState.ready) {
      sent = false;
    } else {
      try {
        ws.add(encodeSsapMessage({
          'id': id,
          'type': 'request',
          'uri': uri,
          'payload': payload,
        }));
      } catch (_) {
        sent = false;
      }
    }
    if (!sent) {
      _pending.remove(id);
      return const CmdReplyErr('Not connected');
    }
    TestLog.req(sid, id, uri);

    try {
      return await completer.future.timeout(Duration(seconds: timeoutSecs));
    } on TimeoutException {
      _pending.remove(id);
      return const CmdReplyErr('Timeout. Is the TV on and reachable?');
    }
  }

  /// Returns the subscription id, or null if not READY or the send failed
  /// (in which case the listener is not registered).
  ///
  /// [onFrame] also sees the whole frame, error frames included, which the
  /// plain listener (payload, or null on error) cannot tell apart.
  String? subscribe(
    String uri,
    void Function(Map<String, dynamic>?) listener, {
    void Function(Map<String, dynamic> frame)? onFrame,
  }) {
    if (_state != CmdState.ready || _ws == null) return null;
    final id = _idSeq.nextSubscriptionId();
    _subscriptions[id] = listener;
    if (onFrame != null) _subscriptionFrameTaps[id] = onFrame;
    try {
      _ws!.add(encodeSsapMessage({
        'id': id,
        'type': 'subscribe',
        'uri': uri,
        'payload': {},
      }));
    } catch (_) {
      _subscriptions.remove(id);
      _subscriptionFrameTaps.remove(id);
      return null;
    }
    return id;
  }

  void unsubscribe(String id) {
    _subscriptions.remove(id);
    _subscriptionFrameTaps.remove(id);
    try {
      _ws?.add(encodeSsapMessage({'id': id, 'type': 'unsubscribe'}));
    } catch (_) {
      // Session is already dead; nothing to unsubscribe from.
    }
  }

  Future<void> awaitReady({Duration timeout = const Duration(seconds: 5)}) =>
      _awaitSettled(timeout);

  Future<void> awaitDeath() => _deathCompleter.future;

  Future<void> _awaitSettled(Duration timeout) async {
    if (_stateSettled.isCompleted) return;
    try {
      await _stateSettled.future.timeout(timeout);
    } on TimeoutException {
      // Still CONNECTING -- send()/awaitReady() callers handle that state.
    }
  }

  void close() {
    // _die clears _ws, so the socket has to be taken first or it stays open
    // (and keeps pinging the TV) after every reset.
    final ws = _ws;
    _die(const CmdReplyErr('Session closed'));
    closeQuietly(ws);
  }
}
