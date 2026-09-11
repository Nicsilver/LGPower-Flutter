import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/prefs.dart';
import '../../net/tv_discovery.dart';
import '../../net/webos_client.dart';

/// Connection/power status shown by the header dot (spec §4).
enum TvStatus { checking, connected, searching, pairing, disconnected }

/// One toast the screen should show -- mirrors `sendCommand`'s two failure
/// cases (spec §12): `NeedsPairing` is always the long-form pairing prompt,
/// `error` carries the client's own message.
class ToastMessage {
  const ToastMessage(this.text, {this.long = false});
  final String text;
  final bool long;
}

/// Owns every piece of state the remote screen reacts to but doesn't itself
/// arrange on screen: connection status, presence watching, the 5s level
/// poll, volume/brightness state (+ `last_*` prefs), the 50ms drag send
/// loops, refresh debounces, the power/shortcut wake sequence and the
/// `sendCommand` toast wrapper. Layout, the numpad/colour-row page swap and
/// pickers stay in `main_screen.dart`.
class RemoteController extends ChangeNotifier {
  RemoteController({required this.client, required this.prefs});

  final WebOsClient client;
  final Prefs prefs;

  TvStatus status = TvStatus.checking;
  bool get tvConnected => status == TvStatus.connected;

  bool currentScreenOff = false;
  int? currentVolume;
  bool currentMuted = false;
  int? currentBrightness;
  bool rightPillChannel = false;
  List<TvApp> shortcuts = const [];

  int _wakeGen = 0;
  bool _discovering = false;
  bool _watching = false;
  void Function()? _stopWatching;

  bool _levelsPollActive = false;
  Timer? _levelsPollTimer;
  Timer? _volumeRefreshTimer;
  Timer? _brightnessRefreshTimer;

  Timer? _volumeSendTimer;
  int _volumeDragLevel = -1;
  int _volumeSentLevel = -1;
  bool _volumeSending = false;

  Timer? _brightnessSendTimer;
  int _brightnessDragLevel = -1;
  int _brightnessSentLevel = -1;
  bool _brightnessSending = false;

  final _toastController = StreamController<ToastMessage>.broadcast();
  Stream<ToastMessage> get toasts => _toastController.stream;

  bool _disposed = false;

  // Several state changes land via unawaited network callbacks (refresh
  // timers, drag-loop ticks) that can still be in flight when the screen is
  // torn down; notifying a disposed ChangeNotifier throws, so every call
  // site routes through this guard instead of calling notifyListeners()
  // directly.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Lifecycle (spec §12)
  // ---------------------------------------------------------------------

  /// onResume: rebuild the shared session, re-read the right-pill pref,
  /// rebuild shortcuts, restore cached levels, start watching.
  Future<void> onResume() async {
    client.resetConnection();
    rightPillChannel = prefs.rightPillChannel;
    shortcuts = client.loadShortcuts();
    if (prefs.lastVolume >= 0) {
      setVolumeState(prefs.lastVolume, prefs.lastMuted);
    }
    if (prefs.lastBrightness >= 0) {
      setBrightnessBar(prefs.lastBrightness);
    }
    _notify();
    startWatching();
  }

  /// onPause: stop the presence watch and the level poll. The drag send
  /// loops are left alone -- they stop themselves on drag end, same as the
  /// Kotlin source.
  void onPause() {
    _watching = false;
    _stopWatching?.call();
    _stopWatching = null;
    _stopLevelsPoll();
  }

  @override
  void dispose() {
    _disposed = true;
    onPause();
    _volumeRefreshTimer?.cancel();
    _brightnessRefreshTimer?.cancel();
    _volumeSendTimer?.cancel();
    _brightnessSendTimer?.cancel();
    _toastController.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Status / presence (spec §4)
  // ---------------------------------------------------------------------

  void startWatching() {
    if (client.tvIp.isEmpty) {
      status = TvStatus.searching;
      _notify();
      unawaited(_autoDiscover());
      return;
    }
    _watching = true;
    _stopWatching = client.watchPower(_applyPresence);
  }

  Future<void> _autoDiscover() async {
    if (_discovering) return;
    _discovering = true;
    try {
      final found = await discoverTvs();
      if (found.isNotEmpty) {
        await client.saveTvIp(found.first);
        startWatching();
      } else {
        status = TvStatus.disconnected;
        _notify();
      }
    } finally {
      _discovering = false;
    }
  }

  void _applyPresence(Presence p) {
    if (!_watching) return; // drop callbacks that arrive after onPause
    final wasConnected = tvConnected;
    switch (p) {
      case PresenceUnknown():
        status = TvStatus.checking;
      case PresenceUnreachable():
        status = TvStatus.disconnected;
      case PresenceNeedsPairing():
        status = TvStatus.pairing;
      case PresenceReported(:final isOn, :final screenOff):
        status = isOn ? TvStatus.connected : TvStatus.disconnected;
        // "Screen Off" still counts as on; the button only lights up then.
        currentScreenOff = isOn && screenOff;
    }
    final nowConnected = tvConnected;
    if (nowConnected && !wasConnected) _startLevelsPoll();
    if (!nowConnected && wasConnected) _stopLevelsPoll();
    _notify();
  }

  void _startLevelsPoll() {
    if (_levelsPollActive) return;
    _levelsPollActive = true;
    unawaited(_levelsPollTick());
  }

  void _stopLevelsPoll() {
    _levelsPollActive = false;
    _levelsPollTimer?.cancel();
    _levelsPollTimer = null;
  }

  Future<void> _levelsPollTick() async {
    if (!_levelsPollActive || !tvConnected) {
      _levelsPollActive = false;
      return;
    }
    final state = await client.getTvState();
    if (state != null) {
      if (state.brightness != null) setBrightnessBar(state.brightness!);
      if (state.volume != null) setVolumeState(state.volume!, state.muted);
    }
    if (!_levelsPollActive) return;
    // A plain `Future.delayed` here can't be interrupted -- onPause()/dispose()
    // need to cancel this wait immediately, not just stop the recursion once
    // it eventually fires (spec §12: `statusHandler.removeCallbacks`).
    _levelsPollTimer?.cancel();
    _levelsPollTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_levelsPollTick());
    });
  }

  // ---------------------------------------------------------------------
  // sendCommand wrapper (spec §12) -- haptic, run, toast on failure only.
  // ---------------------------------------------------------------------

  Future<void> sendCommand(Future<Result> Function() block) async {
    HapticFeedback.lightImpact();
    final result = await block();
    _handleResult(result);
  }

  void _handleResult(Result result) {
    if (_disposed) return; // the toast stream is closed by then
    switch (result) {
      case NeedsPairing():
        _toastController.add(
          const ToastMessage('Accept pairing on your TV, then try again', long: true),
        );
      case CmdError(:final message):
        _toastController.add(ToastMessage(message));
      case Success():
        break;
    }
  }

  /// Every plain pointer-socket key press (spec §3.2 of the protocol spec):
  /// d-pad, OK, Home, Back/Exit, Menu, colours, numpad tiles, CH rocker.
  Future<void> pressSimple(String key) => sendCommand(() => client.pressKey(key));

  // ---------------------------------------------------------------------
  // Power (spec §4, protocol spec §5)
  // ---------------------------------------------------------------------

  Future<void> tapPower() async {
    HapticFeedback.lightImpact();
    final gen = ++_wakeGen;
    final presence = await client.awaitPresence(3000);
    final isOn = presence is PresenceReported && presence.isOn;
    if (isOn) {
      await client.turnOff();
    } else {
      await _wakeTv(gen, () => client.goHome());
    }
  }

  Future<void> launchShortcut(TvApp app) async {
    HapticFeedback.lightImpact();
    final gen = ++_wakeGen;
    final presence = await client.awaitPresence(3000);
    final isOn = presence is PresenceReported && presence.isOn;
    if (isOn) {
      await client.launchApp(app.id);
    } else {
      await _wakeTv(gen, () => client.launchApp(app.id));
    }
  }

  /// WoL once, then up to 25 one-second-apart attempts of [action], each
  /// fired on its own (unawaited) future; the first `Success` bumps the
  /// generation (which halts the loop) and forces the screen on.
  Future<void> _wakeTv(int gen, Future<Result> Function() action) async {
    await client.sendWakeOnLan();
    for (var i = 0; i < 25; i++) {
      if (_wakeGen != gen) return;
      unawaited(_attemptWake(gen, action));
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _attemptWake(int gen, Future<Result> Function() action) async {
    if (_wakeGen != gen) return;
    final result = await action();
    if (result is Success) {
      _wakeGen++;
      await client.turnOnScreen();
    }
  }

  // ---------------------------------------------------------------------
  // Mute / screen off (spec §5)
  // ---------------------------------------------------------------------

  Future<void> toggleMute() async {
    HapticFeedback.lightImpact();
    setVolumeState(currentVolume ?? 0, !currentMuted);
    final result = await client.pressKey('MUTE');
    _handleResult(result);
    _scheduleVolumeRefresh(const Duration(milliseconds: 1500));
  }

  Future<void> tapScreenOff() async {
    if (currentScreenOff) return;
    HapticFeedback.lightImpact();
    currentScreenOff = true;
    _notify();
    final result = await client.turnOffScreen();
    _handleResult(result);
  }

  // ---------------------------------------------------------------------
  // Volume pill (spec §6)
  // ---------------------------------------------------------------------

  void setVolumeState(int level, bool muted) {
    currentVolume = level;
    currentMuted = muted;
    unawaited(prefs.setLastVolume(level));
    unawaited(prefs.setLastMuted(muted));
    _notify();
  }

  /// Phone hardware volume keys (Android only, spec §6): unlike the pill's
  /// own tap-up/down these go through [sendCommand] so a failure toasts.
  Future<void> hardwareVolumeUp() async {
    setVolumeState(((currentVolume ?? 0) + 1).clamp(0, 100), currentMuted);
    await sendCommand(() => client.pressKey('VOLUMEUP'));
    _scheduleVolumeRefresh(const Duration(milliseconds: 200));
  }

  Future<void> hardwareVolumeDown() async {
    setVolumeState(((currentVolume ?? 0) - 1).clamp(0, 100), currentMuted);
    await sendCommand(() => client.pressKey('VOLUMEDOWN'));
    _scheduleVolumeRefresh(const Duration(milliseconds: 200));
  }

  void volumeTapUp() {
    final next = ((currentVolume ?? 0) + 1).clamp(0, 100);
    setVolumeState(next, currentMuted);
    unawaited(() async {
      await client.pressKey('VOLUMEUP');
      _scheduleVolumeRefresh(const Duration(milliseconds: 200));
    }());
  }

  void volumeTapDown() {
    final next = ((currentVolume ?? 0) - 1).clamp(0, 100);
    setVolumeState(next, currentMuted);
    unawaited(() async {
      await client.pressKey('VOLUMEDOWN');
      _scheduleVolumeRefresh(const Duration(milliseconds: 200));
    }());
  }

  void volumeDragMove(int level) {
    _volumeDragLevel = level;
    _volumeSendTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_volumeSendTick());
    });
  }

  Future<void> _volumeSendTick() async {
    if (_volumeDragLevel == _volumeSentLevel || _volumeSending) return;
    _volumeSending = true;
    final level = _volumeDragLevel;
    _volumeSentLevel = level;
    try {
      await client.setVolume(level);
    } finally {
      _volumeSending = false;
    }
  }

  void volumeDragEnd(int level) {
    _volumeSendTimer?.cancel();
    _volumeSendTimer = null;
    setVolumeState(level, currentMuted);
    unawaited(() async {
      await client.setVolume(level);
      _scheduleVolumeRefresh(const Duration(milliseconds: 200));
    }());
  }

  void _scheduleVolumeRefresh(Duration delay) {
    _volumeRefreshTimer?.cancel();
    _volumeRefreshTimer = Timer(delay, () {
      unawaited(() async {
        final v = await client.getVolume();
        if (v != null) setVolumeState(v.volume, v.muted);
      }());
    });
  }

  // ---------------------------------------------------------------------
  // Brightness pill (spec §6) -- steps of 5, same drag-loop shape.
  // ---------------------------------------------------------------------

  void setBrightnessBar(int level) {
    currentBrightness = level;
    unawaited(prefs.setLastBrightness(level));
    _notify();
  }

  void brightnessTapUp() {
    final next = ((currentBrightness ?? 50) + 5).clamp(0, 100);
    setBrightnessBar(next);
    unawaited(() async {
      await client.setBrightness(next);
      _scheduleBrightnessRefresh(const Duration(milliseconds: 200));
    }());
  }

  void brightnessTapDown() {
    final next = ((currentBrightness ?? 50) - 5).clamp(0, 100);
    setBrightnessBar(next);
    unawaited(() async {
      await client.setBrightness(next);
      _scheduleBrightnessRefresh(const Duration(milliseconds: 200));
    }());
  }

  void brightnessDragMove(int level) {
    _brightnessDragLevel = level;
    _brightnessSendTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_brightnessSendTick());
    });
  }

  Future<void> _brightnessSendTick() async {
    if (_brightnessDragLevel == _brightnessSentLevel || _brightnessSending) return;
    _brightnessSending = true;
    final level = _brightnessDragLevel;
    _brightnessSentLevel = level;
    try {
      await client.setBrightness(level);
    } finally {
      _brightnessSending = false;
    }
  }

  void brightnessDragEnd(int level) {
    _brightnessSendTimer?.cancel();
    _brightnessSendTimer = null;
    setBrightnessBar(level);
    unawaited(() async {
      await client.setBrightness(level);
      _scheduleBrightnessRefresh(const Duration(milliseconds: 200));
    }());
  }

  void _scheduleBrightnessRefresh(Duration delay) {
    _brightnessRefreshTimer?.cancel();
    _brightnessRefreshTimer = Timer(delay, () {
      unawaited(() async {
        final b = await client.getBrightness();
        if (b != null) setBrightnessBar(b);
      }());
    });
  }

  // ---------------------------------------------------------------------
  // Right pill in channel mode (spec §6) -- no drag, no repeat.
  // ---------------------------------------------------------------------

  Future<void> channelUp() => pressSimple('CHANNELUP');
  Future<void> channelDown() => pressSimple('CHANNELDOWN');
}
