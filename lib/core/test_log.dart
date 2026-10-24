import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/main/widgets/touchpad_overlay.dart' show TouchpadOverlayLayer;

/// One LgpTest line: `app`, `t`, `ev`, then the fields in order, nulls left out.
String formatTestLine(String app, int t, String ev, Map<String, Object?> fields) {
  final m = <String, Object?>{'app': app, 't': t, 'ev': ev};
  fields.forEach((k, v) {
    if (v != null) m[k] = v;
  });
  return jsonEncode(m);
}

String? _short(String? s, [int max = 80]) {
  if (s == null) return null;
  final flat = s.replaceAll('\n', ' ');
  return flat.length > max ? flat.substring(0, max) : flat;
}

/// Structured test log for the phone lab (contract:
/// LGPowerWidget/.plans/phonelab-app-log-schema.md). Every entry point returns
/// at once outside debug builds; [kDebugMode] is a compile-time constant, so a
/// release build drops the bodies and this file's FFI with them.
abstract final class TestLog {
  static const _app = 'f';
  static const _channel = MethodChannel('com.nic.lgpower/test');

  static bool _enabled = true;
  static final _sids = <String, int>{};
  static final _active = <int>{};
  static _Native? _native;

  static void init() {
    if (!kDebugMode) return;
    _native = _Native.tryOpen();
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'widgets':
          return _widgetsJson();
        case 'enabled':
          _enabled = call.arguments as bool? ?? true;
          return null;
      }
      return null;
    });
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    WidgetsBinding.instance.addObserver(_Life());
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) life('resume');
  }

  /// Ids are per process, in creation order: `cmd1`, `ptr1`, ...
  static String nextSid(String prefix) {
    if (!kDebugMode) return '';
    return '$prefix${_sids.update(prefix, (n) => n + 1, ifAbsent: () => 1)}';
  }

  static void _emit(String ev, Map<String, Object?> fields) {
    final native = _native;
    if (native == null) return;
    native.write(formatTestLine(_app, native.uptimeMs(), ev, fields));
  }

  static void _onPointer(PointerEvent e) {
    if (!_enabled) return;
    final String a;
    if (e is PointerDownEvent) {
      _active.add(e.pointer);
      if (_active.length != 1) return;
      a = 'down';
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (!_active.remove(e.pointer) || _active.isNotEmpty) return;
      a = e is PointerUpEvent ? 'up' : 'cancel';
    } else {
      return;
    }
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    _emit('touch', {
      'a': a,
      'x': (e.position.dx * dpr).round(),
      'y': (e.position.dy * dpr).round(),
      'et': e.timeStamp.inMilliseconds,
    });
  }

  static void key(String sid, int n, String st, String name, {bool repeat = false}) {
    if (!kDebugMode || !_enabled) return;
    _emit('key', {'sid': sid, 'n': n, 'st': st, 'name': name, 'rep': repeat ? true : null});
  }

  static void move(String kind, String sid, int n, String st, int dx, int dy) {
    if (!kDebugMode || !_enabled) return;
    _emit(kind, {'sid': sid, 'n': n, 'st': st, 'dx': dx, 'dy': dy});
  }

  static void click(String sid, int n, String st) {
    if (!kDebugMode || !_enabled) return;
    _emit('click', {'sid': sid, 'n': n, 'st': st});
  }

  static void flush(String sid, int queued, int written) {
    if (!kDebugMode || !_enabled) return;
    _emit('flush', {'sid': sid, 'q': queued, 'w': written});
  }

  static void req(String sid, String id, String uri) {
    if (!kDebugMode || !_enabled) return;
    _emit('req', {'sid': sid, 'id': id, 'uri': uri});
  }

  static void res(String sid, String id, bool ok, String? err) {
    if (!kDebugMode || !_enabled) return;
    _emit('res', {'sid': sid, 'id': id, 'ok': ok, 'err': _short(err)});
  }

  static void sock(String role, String sid, String st,
      {int? code, String? reason, bool? deliberate}) {
    if (!kDebugMode || !_enabled) return;
    _emit('sock', {
      'role': role,
      'sid': sid,
      'st': st,
      'code': code,
      'reason': _short(reason),
      'deliberate': deliberate,
    });
  }

  static void life(String st) {
    if (!kDebugMode || !_enabled) return;
    _emit('life', {'st': st});
  }

  // Walks the on-stage element tree instead of enabling semantics: the tree
  // costs nothing between queries, while an active semantics tree would add
  // per-frame work to the very runs being measured.
  static String _widgetsJson() {
    final native = _native;
    final out = <String, Object?>{
      'app': _app,
      't': native?.uptimeMs() ?? 0,
      'ev': 'widgets',
    };
    final root = WidgetsBinding.instance.rootElement;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (root == null || views.isEmpty) {
      out['ok'] = false;
      out['err'] = 'no activity';
      return jsonEncode(out);
    }
    final view = views.first;
    final screen = view.physicalSize;
    final dpr = view.devicePixelRatio;
    final main = <String, Map<String, int>>{};
    final pad = <String, Map<String, int>>{};

    void add(Map<String, Map<String, int>> into, String name, Element e) {
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
      final tl = ro.localToGlobal(Offset.zero) * dpr;
      final br = ro.localToGlobal(ro.size.bottomRight(Offset.zero)) * dpr;
      final w = br.dx - tl.dx, h = br.dy - tl.dy;
      if (w <= 0 || h <= 0) return;
      final cx = (tl.dx + br.dx) / 2, cy = (tl.dy + br.dy) / 2;
      if (cx < 0 || cy < 0 || cx > screen.width || cy > screen.height) return;
      into[name] = {
        'x': cx.round(),
        'y': cy.round(),
        'l': tl.dx.round(),
        't': tl.dy.round(),
        'r': br.dx.round(),
        'b': br.dy.round(),
      };
    }

    void walk(Element e, bool inOverlay) {
      final w = e.widget;
      var overlay = inOverlay;
      if (w is TouchpadOverlayLayer) {
        overlay = true;
        add(pad, 'pad', e);
      } else if (w is Semantics) {
        final name = _labelNames[w.properties.label];
        if (name != null) {
          if (overlay) {
            final padName = _padNames[w.properties.label];
            if (padName != null) add(pad, padName, e);
          } else {
            add(main, name, e);
          }
        }
      }
      e.debugVisitOnstageChildren((c) => walk(c, overlay));
    }

    walk(root, false);
    out['ok'] = true;
    out['screen'] = [screen.width.round(), screen.height.round()];
    out['w'] = pad.containsKey('pad') ? pad : main;
    return jsonEncode(out);
  }

  static const _labelNames = {
    'Up': 'up',
    'Down': 'down',
    'Left': 'left',
    'Right': 'right',
    'OK': 'ok',
    'Back': 'back',
    'Home': 'home',
    'Mute': 'mute',
    'Input': 'input',
    'Power': 'power',
    'Keyboard': 'keyboard',
    'Settings': 'settings',
    'App Settings': 'app_settings',
    'Touchpad': 'touchpad',
    'Volume Up': 'vol_up',
    'Volume Down': 'vol_down',
    'Channel Up': 'ch_up',
    'Channel Down': 'ch_down',
    'Screen Off': 'screen_off',
    'Numpad': 'numpad',
    'Exit': 'pad_exit',
    'Click': 'pad_click',
  };

  static const _padNames = {
    'Back': 'pad_back',
    'Exit': 'pad_exit',
    'Click': 'pad_click',
  };
}

class _Life with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) TestLog.life('resume');
    if (state == AppLifecycleState.paused) TestLog.life('pause');
  }
}

typedef _ClockGettimeC = Int32 Function(Int32, Pointer<IntPtr>);
typedef _ClockGettime = int Function(int, Pointer<IntPtr>);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);
typedef _LogWriteC = Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint8>);
typedef _LogWrite = int Function(int, Pointer<Uint8>, Pointer<Uint8>);

/// libc / liblog through dart:ffi. `clock_gettime(CLOCK_MONOTONIC)` is the
/// clock behind `SystemClock.uptimeMillis()`, so Dart and Kotlin lines share
/// one time base with no calibration. Logging goes straight to logcat from the
/// calling isolate: a platform channel would add a thread hop per touch frame.
class _Native {
  _Native._(this._clock, this._logWrite, this._ts, this._tag, this._buf);

  static const _bufSize = 4096;
  static const _clockMonotonic = 1;
  static const _logInfo = 4;

  final _ClockGettime _clock;
  final _LogWrite _logWrite;
  final Pointer<IntPtr> _ts;
  final Pointer<Uint8> _tag;
  final Pointer<Uint8> _buf;

  static _Native? tryOpen() {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final libc = DynamicLibrary.process();
      final malloc = libc.lookupFunction<_MallocC, _Malloc>('malloc');
      final clock = libc.lookupFunction<_ClockGettimeC, _ClockGettime>('clock_gettime');
      final logWrite = DynamicLibrary.open('liblog.so')
          .lookupFunction<_LogWriteC, _LogWrite>('__android_log_write');
      final tag = malloc(16).cast<Uint8>();
      final bytes = utf8.encode('LgpTest');
      tag.asTypedList(16).setAll(0, [...bytes, 0]);
      return _Native._(clock, logWrite, malloc(2 * sizeOf<IntPtr>()).cast<IntPtr>(), tag,
          malloc(_bufSize).cast<Uint8>());
    } catch (_) {
      return null;
    }
  }

  int uptimeMs() {
    _clock(_clockMonotonic, _ts);
    return _ts[0] * 1000 + _ts[1] ~/ 1000000;
  }

  void write(String line) {
    final bytes = utf8.encode(line);
    final n = bytes.length < _bufSize - 1 ? bytes.length : _bufSize - 1;
    final view = _buf.asTypedList(_bufSize);
    view.setRange(0, n, bytes);
    view[n] = 0;
    _logWrite(_logInfo, _tag, _buf);
  }
}
