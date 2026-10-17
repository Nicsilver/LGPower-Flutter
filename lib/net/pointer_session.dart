import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import 'ssap_messages.dart';
import 'ws_connect.dart';

const String _pointerSocketUri =
    'ssap://com.webos.service.networkinput/getPointerInputSocket';

enum PointerState { connecting, ready, dead }

class _Frame {
  _Frame.raw(this.kind, this.raw)
      : dx = 0,
        dy = 0,
        queuedAt = DateTime.now();
  _Frame.delta(this.kind, this.dx, this.dy)
      : raw = null,
        queuedAt = DateTime.now();

  final String kind;
  final DateTime queuedAt;
  final String? raw;
  int dx;
  int dy;

  String encode() => raw ?? 'type:$kind\ndx:$dx\ndy:$dy\n\n';
}

/// Separate persistent connection for pointer/navigation input -- a
/// different WebSocket URL obtained at runtime via [_pointerSocketUri], not
/// the SSAP command socket. Handshake: register on a control socket, ask
/// for the pointer socket path, close the control socket, then open a
/// second plain (unregistered) socket to that path.
///
/// Frames sent while the handshake is still running are queued in call order
/// and flushed once the socket opens, so a caller never has to wait for (or
/// replace) a connecting session.
class PointerSession {
  PointerSession(
    this.ip,
    this._prefs, {
    SocketConnector? connector,
    this.connectGrace = const Duration(seconds: 10),
    Duration handshakeTimeout = defaultHandshakeTimeout,
    this.staleAfter = const Duration(milliseconds: 1500),
  })  : createdAt = DateTime.now(),
        _connector = connector ?? connectTrustAll {
    _handshakeTimer = Timer(handshakeTimeout, _fail);
    _connect();
  }

  final String ip;
  final Prefs _prefs;
  final SocketConnector _connector;
  final DateTime createdAt;
  final Duration connectGrace;

  /// Equal to [waitUntilReady]'s default on purpose: a press that has
  /// reported a timeout must never have its key sent by a session that
  /// opens afterwards.
  static const Duration defaultHandshakeTimeout = Duration(seconds: 6);

  /// Queued input older than this is dropped on flush: a key held through a
  /// slow handshake would otherwise fire as a burst and overshoot.
  final Duration staleAfter;

  static const int _maxQueued = 200;

  PointerState _state = PointerState.connecting;
  PointerState get state => _state;

  /// Set when the handshake itself failed (a standby TV accepts the upgrade
  /// and then closes it), not when an established session dropped or was
  /// closed by us.
  DateTime? handshakeFailedAt;

  WebSocket? _controlWs;
  WebSocket? _pointerWs;
  Timer? _handshakeTimer;
  final _readyCompleter = Completer<void>();
  final _queue = <_Frame>[];

  // Closing the control socket ourselves (once we have the pointer socket
  // path) fires the same onDone as an unexpected drop would. Without this
  // flag that self-inflicted close raced the still-connecting pointer
  // socket and won, marking the session dead a few ms after it actually
  // became ready.
  bool _controlClosingIntentionally = false;

  bool get isAlive => _state == PointerState.ready && _pointerWs != null;

  /// A session mid-handshake is shared rather than replaced: a d-pad held
  /// down fires every 120 ms, and replacing the session on each press would
  /// restart the two TLS handshakes every time so no press ever lands.
  bool get isUsable => switch (_state) {
        PointerState.ready => _pointerWs != null,
        PointerState.connecting =>
          DateTime.now().difference(createdAt) < connectGrace,
        PointerState.dead => false,
      };

  Future<void> _connect() async {
    try {
      final ws = await _connector('wss://$ip:3001').timeout(const Duration(seconds: 3));
      if (_state == PointerState.dead) {
        unawaited(ws.close(1000).catchError((_) {}));
        return;
      }
      _controlWs = ws;
      ws.listen(
        _onControlMessage,
        onDone: _onControlDropped,
        onError: (_) => _onControlDropped(),
        cancelOnError: true,
      );
      ws.add(encodeSsapMessage(buildRegistration(_prefs.clientKey)));
    } catch (_) {
      _fail();
    }
  }

  Future<void> _onControlMessage(dynamic raw) async {
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
      _controlWs?.add(encodeSsapMessage({
        'id': 'ptr_req',
        'type': 'request',
        'uri': _pointerSocketUri,
        'payload': {},
      }));
      return;
    }

    if (type == 'response' && id == 'ptr_req') {
      final socketPath = payload?['socketPath'] as String?;
      _closeControl();
      if (socketPath == null || socketPath.isEmpty) {
        _fail();
        return;
      }
      await _openPointerSocket(socketPath);
      return;
    }

    if (type == 'error') {
      _fail();
    }
  }

  void _closeControl() {
    _controlClosingIntentionally = true;
    try {
      _controlWs?.close(1000);
    } catch (_) {}
    _controlWs = null;
  }

  Future<void> _openPointerSocket(String url) async {
    try {
      final ws = await _connector(url).timeout(const Duration(seconds: 3));
      if (_state == PointerState.dead) {
        unawaited(ws.close(1000).catchError((_) {}));
        return;
      }
      _pointerWs = ws;
      ws.listen(
        (_) {},
        onDone: _onPointerClosed,
        onError: (_) => _onPointerClosed(),
        cancelOnError: true,
      );
      _handshakeTimer?.cancel();
      _state = PointerState.ready;
      _flushQueue();
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    } catch (_) {
      _fail();
    }
  }

  void _onPointerClosed() {
    _pointerWs = null;
    _fail();
  }

  void _onControlDropped() {
    _controlWs = null;
    // Our own close() on handshake progression (or on error) already deals
    // with readiness explicitly; only an unexpected drop counts as failure.
    if (!_controlClosingIntentionally && _state == PointerState.connecting) {
      _fail();
    }
  }

  void _fail({bool byCaller = false}) {
    if (_state == PointerState.dead) return;
    if (_state == PointerState.connecting && !byCaller) {
      handshakeFailedAt = DateTime.now();
    }
    _state = PointerState.dead;
    _handshakeTimer?.cancel();
    _queue.clear();
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    _closeControl();
    final ws = _pointerWs;
    _pointerWs = null;
    try {
      ws?.close(1000);
    } catch (_) {}
  }

  /// Completes once the handshake has finished; true only if the session came
  /// up. Does not extend the connect attempt itself.
  Future<bool> waitUntilReady({Duration timeout = defaultHandshakeTimeout}) async {
    try {
      await _readyCompleter.future.timeout(timeout);
    } on TimeoutException {
      return false;
    }
    return _state == PointerState.ready;
  }

  // No `down:` field, no drag, no left/right button field -- this app never
  // sends them (spec §1.5).
  void sendKey(String keyCode) => _submit(_Frame.raw('button', 'type:button\nname:$keyCode\n\n'));

  void move(double dx, double dy) => _submitDelta('move', dx.toInt(), dy.toInt());

  void scroll(double dx, double dy) => _submitDelta('scroll', dx.toInt(), dy.toInt());

  void click() => _submit(_Frame.raw('click', 'type:click\n\n'));

  void _submitDelta(String kind, int dx, int dy) {
    if (_state == PointerState.connecting && _queue.isNotEmpty && _queue.last.kind == kind) {
      // Folding consecutive queued moves keeps the cursor travel but turns a
      // burst of tiny frames into one when the socket opens.
      _queue.last
        ..dx += dx
        ..dy += dy;
      return;
    }
    _submit(_Frame.delta(kind, dx, dy));
  }

  void _submit(_Frame frame) {
    switch (_state) {
      case PointerState.ready:
        _write(frame);
      case PointerState.connecting:
        if (_queue.length >= _maxQueued) _queue.removeAt(0);
        _queue.add(frame);
      case PointerState.dead:
        break;
    }
  }

  void _flushQueue() {
    final frames = List.of(_queue);
    _queue.clear();
    final cutoff = DateTime.now().subtract(staleAfter);
    for (final f in frames) {
      if (f.kind != 'click' && f.queuedAt.isBefore(cutoff)) continue;
      _write(f);
    }
  }

  void _write(_Frame frame) {
    final ws = _pointerWs;
    if (ws == null) return;
    try {
      ws.add(frame.encode());
    } catch (_) {
      _fail();
    }
  }

  void close() => _fail(byCaller: true);
}
