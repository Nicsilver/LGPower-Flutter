import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import 'ssap_messages.dart';
import 'wol.dart' show macList;

enum CmdState { connecting, ready, needsPairing, dead }

/// Result of one SSAP round trip, kept separate from the public [Result]
/// type (in webos_client.dart) so the session layer never has to know about
/// UI-facing error text conventions.
sealed class CmdReply {
  const CmdReply();
}

class CmdReplyOk extends CmdReply {
  const CmdReplyOk(this.payload);
  final Map<String, dynamic> payload;
}

class CmdReplyNeedsPairing extends CmdReply {
  const CmdReplyNeedsPairing();
}

class CmdReplyErr extends CmdReply {
  const CmdReplyErr(this.message);
  final String message;
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
  CommandSession(this._ip, this._prefs) : createdAt = DateTime.now() {
    _connect();
  }

  final String _ip;
  final Prefs _prefs;
  final DateTime createdAt;

  static const _connectGrace = Duration(seconds: 10);
  static const _readyWait = Duration(seconds: 8);

  CmdState _state = CmdState.connecting;
  CmdState get state => _state;

  WebSocket? _ws;
  String? deadReason;

  final _idSeq = SsapIdSequence();
  final _pending = <String, Completer<CmdReply>>{};
  final _subscriptions = <String, void Function(Map<String, dynamic>?)>{};
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
        return DateTime.now().difference(createdAt) < _connectGrace;
      case CmdState.dead:
        return false;
    }
  }

  Future<void> _connect() async {
    try {
      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final ws = await WebSocket.connect(
        'wss://$_ip:3001',
        customClient: client,
      ).timeout(const Duration(seconds: 3));
      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      ws.listen(_onMessage, onDone: _onDone, onError: _onError, cancelOnError: true);
      ws.add(encodeSsapMessage(buildRegistration(_prefs.clientKey)));
    } catch (e) {
      deadReason = e.toString();
      _die(CmdReplyErr(deadReason ?? 'Connection failed'));
    }
  }

  void _onDone() {
    // A TV in standby accepts the upgrade and then closes with "Try Again
    // Later (EWS)" -- record the reason so the next send() surfaces it
    // instead of a bare "Connection closed".
    final reason = _ws?.closeReason;
    deadReason = (reason == null || reason.isEmpty) ? null : reason;
    _die(const CmdReplyErr('Connection closed'));
  }

  void _onError(Object error) {
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
      final key = payload?['client-key'] as String?;
      if (key != null && key.isNotEmpty) {
        _prefs.setClientKey(key);
      }
      // Fewer than two means a pairing from before both MACs were kept.
      if (macList(_prefs.tvMac).length < 2) {
        _ws?.add(encodeSsapMessage({
          'id': macLookupMessageId,
          'type': 'request',
          'uri': _getInfoUri,
          'payload': {},
        }));
      }
      _state = CmdState.ready;
      _settle();
      return;
    }

    if (type == 'response' && id == regMessageId) {
      // TV challenged registration -- user must accept the pairing prompt.
      // "registered" arrives on this same socket once they do.
      _state = CmdState.needsPairing;
      _settle();
      _failAll(const CmdReplyNeedsPairing());
      return;
    }

    if (type == 'response' && id == macLookupMessageId) {
      final merged = mergeMacs(_prefs.tvMac, extractMacAddresses(payload));
      if (merged != _prefs.tvMac) _prefs.setTvMac(merged);
      return;
    }

    if (id != null &&
        (type == 'response' || type == 'error') &&
        _subscriptions.containsKey(id)) {
      _subscriptions[id]!(type == 'response' ? payload : null);
      return;
    }

    if (type == 'response' && id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final returnValue = payload?['returnValue'] as bool? ?? true;
      if (returnValue == false) {
        final errorText = (payload?['errorText'] as String?) ?? '';
        completer.complete(CmdReplyErr(
          errorText.isEmpty ? 'Command rejected by TV' : errorText,
        ));
      } else {
        completer.complete(CmdReplyOk(payload ?? const {}));
      }
      return;
    }

    if (type == 'error' && id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final errorText = (payload?['errorText'] as String?) ?? '';
      completer.complete(CmdReplyErr(errorText.isEmpty ? 'Unknown error' : errorText));
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

    try {
      return await completer.future.timeout(Duration(seconds: timeoutSecs));
    } on TimeoutException {
      _pending.remove(id);
      return const CmdReplyErr('Timeout. Is the TV on and reachable?');
    }
  }

  /// Returns the subscription id, or null if not READY or the send failed
  /// (in which case the listener is not registered).
  String? subscribe(String uri, void Function(Map<String, dynamic>?) listener) {
    if (_state != CmdState.ready || _ws == null) return null;
    final id = _idSeq.nextSubscriptionId();
    _subscriptions[id] = listener;
    try {
      _ws!.add(encodeSsapMessage({
        'id': id,
        'type': 'subscribe',
        'uri': uri,
        'payload': {},
      }));
    } catch (_) {
      _subscriptions.remove(id);
      return null;
    }
    return id;
  }

  void unsubscribe(String id) {
    _subscriptions.remove(id);
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
    _die(const CmdReplyErr('Session closed'));
    try {
      _ws?.close(1000);
    } catch (_) {}
  }
}
