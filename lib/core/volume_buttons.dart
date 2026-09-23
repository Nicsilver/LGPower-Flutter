import 'dart:async';

import 'package:flutter/services.dart';

/// The phone's volume buttons. Android catches the keys in `MainActivity.kt`
/// because Flutter's HardwareKeyboard misses them without keyboard focus
/// (flutter/flutter#95121). iOS has no key events for them at all, so
/// `AppDelegate.swift` watches the media volume, reports each step here and
/// moves the phone volume back.
class VolumeButtons {
  VolumeButtons._();

  static const MethodChannel _channel = MethodChannel('com.nic.lgpower/volume_buttons');

  static void start({required void Function() onUp, required void Function() onDown}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'press') return;
      if (call.arguments == 'up') {
        onUp();
      } else if (call.arguments == 'down') {
        onDown();
      }
    });
    unawaited(_channel.invokeMethod<void>('start').catchError((Object _) {}));
  }

  static void stop() {
    _channel.setMethodCallHandler(null);
    unawaited(_channel.invokeMethod<void>('stop').catchError((Object _) {}));
  }
}
