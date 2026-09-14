import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Haptics for every control. Android goes through the framework's
/// [HapticFeedback]; iOS goes through our own channel (`AppDelegate.swift`)
/// because the framework's iOS path creates a UIFeedbackGenerator per call
/// and drops it straight after `impactOccurred`, which UIKit frequently
/// swallows (flutter/flutter#157442). The native side keeps prepared
/// generators alive so every tick lands.
class Haptics {
  Haptics._();

  static const MethodChannel _channel = MethodChannel('com.nic.lgpower/haptics');

  static bool get _useChannel => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void light() => _fire('light', HapticFeedback.lightImpact);

  static void medium() => _fire('medium', HapticFeedback.mediumImpact);

  static void heavy() => _fire('heavy', HapticFeedback.heavyImpact);

  static void selection() => _fire('selection', HapticFeedback.selectionClick);

  static void _fire(String kind, Future<void> Function() fallback) {
    if (!_useChannel) {
      unawaited(fallback());
      return;
    }
    unawaited(
      _channel.invokeMethod<void>('play', kind).catchError((Object _) {
        // No handler (tests, or a stale native build): fall back to the
        // framework rather than losing the tick entirely.
        return fallback();
      }),
    );
  }
}
