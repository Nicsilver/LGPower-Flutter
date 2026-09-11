import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import 'ssap_messages.dart';

const String _pointerSocketUri =
    'ssap://com.webos.service.networkinput/getPointerInputSocket';

/// Separate persistent connection for pointer/navigation input -- a
/// different WebSocket URL obtained at runtime via [_pointerSocketUri], not
/// the SSAP command socket. Handshake: register on a control socket, ask
/// for the pointer socket path, close the control socket, then open a
/// second plain (unregistered) socket to that path.
class PointerSession {
  PointerSession(this._ip, this._prefs) {
    _connect();
  }

  final String _ip;
  final Prefs _prefs;

  WebSocket? _controlWs;
  WebSocket? _pointerWs;
  bool _alive = false;
  final _readyCompleter = Completer<void>();

  // Closing the control socket ourselves (once we have the pointer socket
  // path) fires the same onDone as an unexpected drop would. Without this
  // flag that self-inflicted close raced the still-connecting pointer
  // socket and won, marking the session dead a few ms after it actually
  // became ready.
  bool _controlClosingIntentionally = false;

  bool get isAlive => _alive && _pointerWs != null;

  HttpClient _trustAllClient() =>
      HttpClient()..badCertificateCallback = (cert, host, port) => true;

  Future<void> _connect() async {
    try {
      final ws = await WebSocket.connect(
        'wss://$_ip:3001',
        customClient: _trustAllClient(),
      ).timeout(const Duration(seconds: 3));
      _controlWs = ws;
      ws.listen(
        _onControlMessage,
        onDone: _onControlDropped,
        onError: (_) => _onControlDropped(),
        cancelOnError: true,
      );
      ws.add(encodeSsapMessage(buildRegistration(_prefs.clientKey)));
    } catch (_) {
      _finishNotReady();
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
        _finishNotReady();
        return;
      }
      await _openPointerSocket(socketPath);
      return;
    }

    if (type == 'error') {
      _closeControl();
      _finishNotReady();
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
      final ws = await WebSocket.connect(
        url,
        customClient: _trustAllClient(),
      ).timeout(const Duration(seconds: 3));
      _pointerWs = ws;
      _alive = true;
      ws.listen(
        (_) {},
        onDone: _onPointerClosed,
        onError: (_) => _onPointerClosed(),
        cancelOnError: true,
      );
      _finishReady();
    } catch (_) {
      _alive = false;
      _pointerWs = null;
      _finishNotReady();
    }
  }

  void _onPointerClosed() {
    _alive = false;
    _pointerWs = null;
  }

  void _onControlDropped() {
    _controlWs = null;
    // Our own close() on handshake progression (or on error) already deals
    // with readiness explicitly; only an unexpected drop counts as failure.
    if (!_controlClosingIntentionally && !_readyCompleter.isCompleted) {
      _finishNotReady();
    }
  }

  void _finishReady() {
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  void _finishNotReady() {
    _alive = false;
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  Future<bool> waitUntilReady({int timeoutSecs = 6}) async {
    try {
      await _readyCompleter.future.timeout(Duration(seconds: timeoutSecs));
    } on TimeoutException {
      return false;
    }
    return _alive;
  }

  // No `down:` field, no drag, no left/right button field -- this app never
  // sends them (spec §1.5).
  void sendKey(String keyCode) => _send('type:button\nname:$keyCode\n\n');

  void move(double dx, double dy) =>
      _send('type:move\ndx:${dx.toInt()}\ndy:${dy.toInt()}\n\n');

  void scroll(double dx, double dy) =>
      _send('type:scroll\ndx:${dx.toInt()}\ndy:${dy.toInt()}\n\n');

  void click() => _send('type:click\n\n');

  void _send(String frame) {
    if (!isAlive) return;
    try {
      _pointerWs!.add(frame);
    } catch (_) {
      _alive = false;
    }
  }

  void close() {
    _alive = false;
    try {
      _pointerWs?.close(1000);
    } catch (_) {}
    _pointerWs = null;
    _closeControl();
  }
}
