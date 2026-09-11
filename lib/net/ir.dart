import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Facade over the Android-only `com.nic.lgpower/ir` platform channel
/// (`MainActivity.kt`). No iPhone has an IR emitter and iOS exposes no
/// equivalent API, so every call here degrades to "no emitter" off Android
/// instead of throwing.
class Ir {
  Ir._();

  static const MethodChannel _channel = MethodChannel('com.nic.lgpower/ir');

  static bool? _hasEmitterCache;

  /// Resolved once and cached -- IR hardware can't appear or disappear while
  /// the app is running, so callers can await this from `initState` without
  /// re-querying the channel on every rebuild.
  static Future<bool> hasEmitter() async {
    final cached = _hasEmitterCache;
    if (cached != null) return cached;
    var result = false;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        result = await _channel.invokeMethod<bool>('hasIrEmitter') ?? false;
      } on PlatformException {
        result = false;
      } on MissingPluginException {
        result = false;
      }
    }
    _hasEmitterCache = result;
    return result;
  }

  /// Throws `PlatformException('no_emitter', ...)` if the phone has none --
  /// callers that already show a "no emitter" sheet/toast should check
  /// [hasEmitter] first rather than relying on this to fail.
  static Future<void> transmit(int carrierHz, List<int> pattern) {
    return _channel.invokeMethod<void>('transmit', {
      'carrierHz': carrierHz,
      'pattern': pattern,
    });
  }

  /// NEC address 0x04 (LG) pre-encoded as the 0x20DF prefix.
  static const int lgPowerCode = 0x20DF10EF;

  /// `code = (0x20DF << 16) | (rev(cmd) << 8) | rev(~cmd & 0xFF)` -- the
  /// address bytes are baked into the 0x20DF prefix, only the command byte
  /// and its complement vary per key.
  static int lgCode(int cmd) {
    return (0x20DF << 16) | (_reverseByte(cmd) << 8) | _reverseByte(~cmd & 0xFF);
  }

  // NEC transmits each byte LSB-first, so the receiver expects it sent
  // pre-reversed.
  static int _reverseByte(int b) {
    var v = b & 0xFF;
    var r = 0;
    for (var i = 0; i < 8; i++) {
      r = (r << 1) | (v & 1);
      v >>= 1;
    }
    return r;
  }

  /// Standard NEC pulse train in microseconds: leader (9000, 4500), 32 data
  /// bits from byte 3 down to byte 0 each sent MSB-first (mark 562, space
  /// 1687 for a 1 / 562 for a 0), then a stop bit (562, 562) -- 68 entries.
  static List<int> necPattern(int code) {
    final pattern = <int>[9000, 4500];
    for (var byteIndex = 3; byteIndex >= 0; byteIndex--) {
      final b = (code >> (byteIndex * 8)) & 0xFF;
      for (var bit = 7; bit >= 0; bit--) {
        pattern.add(562);
        pattern.add(((b >> bit) & 1) == 1 ? 1687 : 562);
      }
    }
    pattern.add(562);
    pattern.add(562);
    return pattern;
  }
}
