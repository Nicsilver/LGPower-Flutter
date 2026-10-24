import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import 'ssap_messages.dart';
import 'ws_connect.dart';

const String _pointerSocketUri =
    'ssap://com.webos.service.networkinput/getPointerInputSocket';

enum PointerState { connecting, ready, dead }

/// What [PointerSession.registerGate] decided about registering.
enum RegisterGate { register, needsPairing, fail }

class _Frame {
  _Frame.raw(this.kind, this.raw, {this.hold})
      : dx = 0,
        dy = 0,
        queuedAt = DateTime.now();
  _Frame.delta(this.kind, this.dx, this.dy)
      : raw = null,
        hold = null,
        queuedAt = DateTime.now();

  final String kind;
  final String? raw;

  /// Set on the auto-repeat presses of a held key; null for everything else.
  final Object? hold;
  DateTime queuedAt;
  int dx;
  int dy;

  bool get isMotion => kind == 'move' || kind == 'scroll';

  /// A deliberate single press: never dropped as stale, because its caller is
  /// waiting for the result.
  bool get isOneShotKey => kind == 'button' && hold == null;

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
    this.firstOpenWindow = defaultFirstOpenWindow,
    this.keepAfterInput = defaultKeepAfterInput,
  })  : createdAt = DateTime.now(),
        _lastActiveAt = DateTime.now(),
        _connector = connector ?? connectTrustAll,
        _handshakeTimeout = handshakeTimeout {
    _handshakeTimer = Timer(handshakeTimeout, _fail);
    _keyUsed = _prefs.clientKey;
    if (_keyUsed == null || _keyUsed!.isEmpty) {
      _needsPairing = true;
      _fail();
      return;
    }
    _connect();
  }

  /// A session that is dead from the start: the TV is already showing a
  /// pairing prompt on the command socket, and registering here with the same
  /// key could dismiss or replace it.
  PointerSession.blocked(this.ip, this._prefs)
      : createdAt = DateTime.now(),
        _lastActiveAt = DateTime.now(),
        keepAfterInput = defaultKeepAfterInput,
        connectGrace = const Duration(seconds: 10),
        staleAfter = const Duration(milliseconds: 1500),
        firstOpenWindow = defaultFirstOpenWindow,
        _handshakeTimeout = defaultHandshakeTimeout,
        _connector = connectTrustAll {
    _keyUsed = _prefs.clientKey;
    _needsPairing = true;
    _fail();
  }

  final String ip;
  final Prefs _prefs;
  final SocketConnector _connector;
  final DateTime createdAt;
  final Duration connectGrace;
  final Duration _handshakeTimeout;

  /// How long the pointer's own handshake may take once it is allowed to
  /// register. The wait for the command session to register before that is
  /// not part of it, so two slow registrations in a row both fit; the whole
  /// session is still over after [connectGrace], which is also how long a
  /// key press waits for it, so a press that has reported a timeout never
  /// has its key sent by a session that opens afterwards.
  static const Duration defaultHandshakeTimeout = Duration(seconds: 6);

  /// How long the first attempt to open the control socket may take before it
  /// is abandoned for a fresh one. It normally opens in 70-220 ms; a C4 that
  /// leaves a connection without any TLS or upgrade reply would otherwise cost
  /// the full 3 s connect timeout and fail the press with most of its
  /// deadline unused.
  static const Duration defaultFirstOpenWindow = Duration(seconds: 1);
  final Duration firstOpenWindow;

  /// How long after its last delivered frame (or after it opened) a session
  /// still counts as in use, see [inUse].
  static const Duration defaultKeepAfterInput = Duration(seconds: 5);
  final Duration keepAfterInput;
  DateTime _lastActiveAt;

  /// Queued cursor movement, clicks and held-key repeats older than this are
  /// dropped on flush: replayed late they would land at the wrong spot or
  /// fire as a burst and overshoot. Single key presses are exempt.
  final Duration staleAfter;

  static const int _maxQueued = 200;

  PointerState _state = PointerState.connecting;
  PointerState get state => _state;

  /// Asked once the control socket is open, before registering on it. Set by
  /// [WebOsClient] right after constructing the session, which is before
  /// [_connect] gets past its first await.
  Future<RegisterGate> Function()? registerGate;

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

  bool _closedByCaller = false;

  // Set when a queued move or scroll is discarded, so a click queued behind
  // it is not delivered at a cursor position the user never saw.
  bool _motionDropped = false;

  /// Closed by [close] while still alive (a reset or a replacement), as
  /// opposed to failing on its own.
  bool get retired => _closedByCaller;

  /// The socket opened at some point, so every one-shot key handed to this
  /// session was written to it.
  bool get wasReady => _wasReady;
  bool _wasReady = false;

  bool get isAlive => _state == PointerState.ready && _pointerWs != null;

  // Registering without a valid key makes the TV show a pairing prompt, so
  // this session never retries that: it stays dead until the command session
  // has stored a new key.
  bool _needsPairing = false;
  String? _keyUsed;

  /// True while a retry would only ask the TV for pairing again.
  bool get pairingStillMissing =>
      _needsPairing && (_prefs.clientKey ?? '') == (_keyUsed ?? '');

  bool get isConnecting =>
      _state == PointerState.connecting &&
      DateTime.now().difference(createdAt) < connectGrace;

  /// Carried input moments ago: replacing it now would abort live work.
  bool get inUse =>
      _state != PointerState.dead &&
      ip == _prefs.tvIp &&
      DateTime.now().difference(_lastActiveAt) < keepAfterInput;

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
      final ws = await _openControlSocket();
      if (_state == PointerState.dead) {
        closeQuietly(ws);
        return;
      }
      _controlWs = ws;
      ws.listen(
        _onControlMessage,
        onDone: _onControlDropped,
        onError: (_) => _onControlDropped(),
        cancelOnError: true,
      );
      final gate = registerGate;
      if (gate != null) {
        _restartHandshakeTimer(_graceLeft());
        final verdict = await gate();
        // Closed, timed out, or dropped by a TV in standby while waiting.
        if (_state != PointerState.connecting) return;
        switch (verdict) {
          case RegisterGate.register:
            // Registering without a key is a pairing request.
            if ((_prefs.clientKey ?? '').isEmpty) {
              _fail();
              return;
            }
            _keyUsed = _prefs.clientKey;
            final left = _graceLeft();
            _restartHandshakeTimer(left < _handshakeTimeout ? left : _handshakeTimeout);
          case RegisterGate.needsPairing:
            _needsPairing = true;
            _fail();
            return;
          case RegisterGate.fail:
            _fail();
            return;
        }
      }
      ws.add(encodeSsapMessage(buildRegistration(_prefs.clientKey)));
    } catch (_) {
      _fail();
    }
  }

  /// Nothing has been registered on a socket that never opened, so replacing
  /// it cannot show a second pairing prompt or send a key twice. The abandoned
  /// attempt is closed by [connectWithTimeout] if it opens late and is never
  /// listened to, so it cannot flush the queue or become the session.
  Future<WebSocket> _openControlSocket() async {
    final url = 'wss://$ip:3001';
    final started = DateTime.now();
    try {
      return await connectWithTimeout(_connector, url, firstOpenWindow);
    } on TimeoutException {
      // No reply at all: go straight to the second attempt.
    } on SocketException {
      await _waitOutFirstWindow(started);
    } on HandshakeException {
      await _waitOutFirstWindow(started);
    }
    if (_state != PointerState.connecting) throw StateError('closed');
    return connectWithTimeout(_connector, url, const Duration(seconds: 3));
  }

  // A refused or reset connect is retried too, but not in a tight loop against
  // a TV that is off.
  Future<void> _waitOutFirstWindow(DateTime started) async {
    final left = firstOpenWindow - DateTime.now().difference(started);
    if (left > Duration.zero) await Future<void>.delayed(left);
  }

  Duration _graceLeft() => connectGrace - DateTime.now().difference(createdAt);

  void _restartHandshakeTimer(Duration after) {
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(after, _fail);
  }

  Future<void> _onControlMessage(dynamic raw) async {
    // A reply that outlives the session must not open a pointer socket for it.
    if (_state == PointerState.dead) return;
    String? type;
    String? id;
    Map<String, dynamic>? payload;
    try {
      final msg = decodeSsapMessage(raw as String);
      type = msg['type'] as String?;
      id = msg['id'] as String?;
      payload = msg['payload'] as Map<String, dynamic>?;
    } catch (_) {
      return;
    }

    if (type == 'registered') {
      final key = payload?['client-key'] as String?;
      if (ip == _prefs.tvIp && key != null && key.isNotEmpty) {
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

    // The TV is asking the user to accept a pairing prompt.
    if (type == 'response' && id == regMessageId) {
      _needsPairing = true;
      _fail();
      return;
    }

    // An error for the registration (a denied or timed-out prompt, or a TV
    // hiccup) is an ordinary failure with the usual cooldown: only the prompt
    // challenge above means the user has something to accept.
    if (type == 'error') _fail();
  }

  void _closeControl() {
    _controlClosingIntentionally = true;
    closeQuietly(_controlWs);
    _controlWs = null;
  }

  Future<void> _openPointerSocket(String url) async {
    try {
      final ws = await connectWithTimeout(_connector, url, const Duration(seconds: 3));
      if (_state == PointerState.dead) {
        closeQuietly(ws);
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
      _wasReady = true;
      _lastActiveAt = DateTime.now();
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
    if (byCaller) _closedByCaller = true;
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
    closeQuietly(ws);
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

  /// False means no live socket took the key (dead session, or the write
  /// failed), so the caller must not report it as delivered. A [hold] marks
  /// an auto-repeat press of a held key.
  // No `down:` field, no drag, no left/right button field -- this app never
  // sends them (spec §1.5).
  bool sendKey(String keyCode, {Object? hold}) =>
      _submit(_Frame.raw('button', 'type:button\nname:$keyCode\n\n', hold: hold));

  /// Discards the queued repeats of a hold: once the finger is up they must
  /// not fire as a burst when the socket opens.
  void dropRepeats(Object hold) => _queue.removeWhere((f) => f.hold == hold);

  void move(double dx, double dy) {
    final x = dx.toInt(), y = dy.toInt();
    // Sub-pixel drags truncate to 0,0; the TV gets nothing from those frames.
    if (x == 0 && y == 0) return;
    _submitDelta('move', x, y);
  }

  void scroll(double dx, double dy) => _submitDelta('scroll', dx.toInt(), dy.toInt());

  void click() => _submit(_Frame.raw('click', 'type:click\n\n'));

  void _submitDelta(String kind, int dx, int dy) {
    if (_state == PointerState.connecting && _queue.isNotEmpty && _queue.last.kind == kind) {
      // Folding consecutive queued moves keeps the cursor travel but turns a
      // burst of tiny frames into one when the socket opens. The frame is as
      // fresh as its newest part: keeping the first fragment's age would drop
      // the new movement together with a stale start.
      _queue.last
        ..dx += dx
        ..dy += dy
        ..queuedAt = DateTime.now();
      return;
    }
    _submit(_Frame.delta(kind, dx, dy));
  }

  bool _submit(_Frame frame) {
    switch (_state) {
      case PointerState.ready:
        return _write(frame);
      case PointerState.connecting:
        if (_queue.length >= _maxQueued) _evictOldest();
        _queue.add(frame);
        return true;
      case PointerState.dead:
        return false;
    }
  }

  // Key presses outlive the cap so a flood of moves cannot push one out.
  void _evictOldest() {
    var i = _queue.indexWhere((f) => !f.isOneShotKey);
    if (i < 0) i = 0;
    final dropped = _queue.removeAt(i);
    if (dropped.isMotion) _motionDropped = true;
  }

  void _flushQueue() {
    final frames = List.of(_queue);
    _queue.clear();
    final cutoff = DateTime.now().subtract(staleAfter);
    // Only the newest repeat of each hold is still of any use.
    final latestRepeat = <Object, _Frame>{
      for (final f in frames)
        if (f.hold != null) f.hold!: f,
    };
    var motionDropped = _motionDropped;
    _motionDropped = false;
    for (final f in frames) {
      if (f.isOneShotKey) {
        _write(f);
        continue;
      }
      final stale = f.queuedAt.isBefore(cutoff);
      if (f.hold != null) {
        if (!stale && identical(latestRepeat[f.hold], f)) _write(f);
      } else if (f.kind == 'click') {
        if (!stale && !motionDropped) _write(f);
      } else if (stale) {
        motionDropped = true;
      } else {
        _write(f);
      }
    }
  }

  bool _write(_Frame frame) {
    final ws = _pointerWs;
    if (ws == null) return false;
    try {
      ws.add(frame.encode());
      _lastActiveAt = DateTime.now();
      return true;
    } catch (_) {
      _fail();
      return false;
    }
  }

  void close() => _fail(byCaller: true);
}
