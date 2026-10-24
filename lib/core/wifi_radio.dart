import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../net/conn_report.dart';

/// Android's Wi-Fi radio, seen from the remote screen. A low-latency Wi-Fi lock
/// keeps the radio out of power save while the app is in front: power save
/// batches small frames for up to a beacon interval, which shows up as
/// touchpad stutter and slow key presses. Everything here is a no-op off
/// Android and never throws, since the remote works fine without it.
class WifiRadio {
  WifiRadio._();

  static const MethodChannel _channel = MethodChannel('com.nic.lgpower/wifi');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<T?> _call<T>(String method) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } catch (_) {
      return null;
    }
  }

  static void holdLowLatency() => unawaited(_call<bool>('acquire'));

  static void releaseLowLatency() => unawaited(_call<bool>('release'));

  static Future<bool> get lowLatencyHeld async => await _call<bool>('isHeld') ?? false;

  /// Requests the lock and reports whether it is held afterwards.
  static Future<bool> acquireLowLatency() async => await _call<bool>('acquire') ?? false;

  /// Band, signal and link speed of the current Wi-Fi; null off Wi-Fi or off Android.
  static Future<WifiSnapshot?> snapshot() async {
    final info = await _call<Map<Object?, Object?>>('wifiInfo');
    if (info == null) return null;
    final frequency = info['frequencyMhz'];
    final rssi = info['rssiDbm'];
    final link = info['linkMbps'];
    if (frequency is! int || rssi is! int || link is! int) return null;
    return WifiSnapshot(frequency, rssi, link);
  }
}
