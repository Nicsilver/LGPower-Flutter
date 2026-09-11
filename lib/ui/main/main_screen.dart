import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/prefs.dart';
import '../../net/webos_client.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/picker_sheet.dart';
import '../settings/settings_screen.dart';
import 'dims.dart';
import 'remote_controller.dart';
import 'widgets/circle_button.dart';
import 'widgets/dpad.dart';
import 'widgets/fill_viewport_page.dart';
import 'widgets/keyboard_sheet.dart';
import 'widgets/level_pill.dart';
import 'widgets/numpad_page.dart';
import 'widgets/shortcuts_row.dart';
import 'widgets/touchpad_overlay.dart';
import 'whats_new.dart';

/// The main remote screen (port spec `port-spec-main-ui.md`): scaffold, main
/// column, header overlay, numpad page swap and colour-row swap. Everything
/// else (connection/volume/brightness state, the wake sequence, the pointer
/// gesture machine) lives in [RemoteController] / [TouchpadController].
///
/// [client]/[prefs] are optional so tests can inject a fake client directly;
/// production call sites construct this with no arguments (after Setup, and
/// from `lib/main.dart`'s initial route), so a missing pair is resolved by
/// loading them the same way `main()` does before the first frame that needs
/// them.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.client, this.prefs});

  final WebOsClient? client;
  final Prefs? prefs;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _colorRowKey = GlobalKey();

  RemoteController? _controllerOrNull;
  TouchpadController? _touchpadOrNull;
  RemoteController get _controller => _controllerOrNull!;
  TouchpadController get _touchpad => _touchpadOrNull!;
  bool get _ready => _controllerOrNull != null;

  StreamSubscription<ToastMessage>? _toastSub;
  bool _numpadOpen = false;
  bool _colorRowOpen = false;
  bool _colorRowJustDismissed = false;
  bool _hardwareKeysHooked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    // Guarantee at least one microtask of delay before the first setState
    // below, even when client/prefs are both supplied (as tests do) and
    // Prefs.load() is never actually awaited -- calling setState from the
    // same synchronous stack as initState would hit "setState called during
    // build".
    await Future<void>.value();
    final prefs = widget.prefs ?? await Prefs.load();
    final client = widget.client ?? WebOsClient(prefs);
    if (!mounted) return;
    final controller = RemoteController(client: client, prefs: prefs);
    final touchpad = TouchpadController(client: client, vsync: this, rootKey: _rootKey);
    _toastSub = controller.toasts.listen((m) {
      if (mounted) showToast(context, m.text, long: m.long);
    });
    setState(() {
      _controllerOrNull = controller;
      _touchpadOrNull = touchpad;
    });
    unawaited(controller.onResume());
    // Android only -- iOS has no way to intercept the hardware volume keys.
    if (!kIsWeb && Platform.isAndroid) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      _hardwareKeysHooked = true;
    }
    // Fire-and-forget, same as onCreate's non-blocking dialog on Android --
    // the rest of setup (already done above) doesn't wait on it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(maybeShowWhatsNew(context, prefs));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ready) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.onResume());
    } else if (state == AppLifecycleState.paused) {
      _controller.onPause();
    }
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!_ready) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      unawaited(_controller.hardwareVolumeUp());
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      unawaited(_controller.hardwareVolumeDown());
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_hardwareKeysHooked) HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _toastSub?.cancel();
    _controllerOrNull?.dispose();
    _touchpadOrNull?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Settings / colour row / pickers
  // ---------------------------------------------------------------------

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsScreen(client: _controller.client)),
    );
    // Spec §12: re-read right_pill_channel/shortcuts/theme on return.
    if (mounted) await _controller.onResume();
  }

  void _onColorsTap() {
    HapticFeedback.lightImpact();
    if (!_colorRowJustDismissed) {
      setState(() => _colorRowOpen = true);
    }
  }

  void _onRootPointerDown(PointerDownEvent event) {
    _colorRowJustDismissed = false;
    if (!_colorRowOpen) return;
    final box = _colorRowKey.currentContext?.findRenderObject();
    var inside = false;
    if (box is RenderBox && box.attached) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      inside = rect.contains(event.position);
    }
    if (!inside) {
      setState(() {
        _colorRowOpen = false;
        _colorRowJustDismissed = true;
      });
    }
  }

  Future<void> _openInputPicker() async {
    HapticFeedback.lightImpact();
    final (inputs, error) = await _controller.client.getInputs();
    if (!mounted) return;
    if (error != null || inputs.isEmpty) {
      showToast(context, error ?? 'No inputs found');
      return;
    }
    await showPickerSheet(
      context,
      title: 'Input Source',
      rows: [for (final i in inputs) (i.id, i.label, false)],
      onSelect: (id) => unawaited(_controller.sendCommand(() => _controller.client.switchInput(id))),
    );
  }

  Future<void> _openPicturePicker() async {
    HapticFeedback.lightImpact();
    final current = await _controller.client.getCurrentPictureMode();
    if (!mounted) return;
    await showPickerSheet(
      context,
      title: 'Picture Mode',
      rows: [
        for (final mode in WebOsClient.pictureModes) (mode.$1, mode.$2, mode.$1 == current),
      ],
      onSelect: (id) =>
          unawaited(_controller.sendCommand(() => _controller.client.setPictureMode(id))),
    );
  }

  Future<void> _openSoundPicker() async {
    HapticFeedback.lightImpact();
    final current = await _controller.client.getSoundMode();
    if (!mounted) return;
    await showPickerSheet(
      context,
      title: 'Sound Mode',
      rows: [
        for (final mode in WebOsClient.soundModes) (mode.$1, mode.$2, mode.$1 == current),
      ],
      onSelect: (id) => unawaited(_controller.sendCommand(() => _controller.client.setSoundMode(id))),
    );
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  Color _statusColor(TvStatus status) => switch (status) {
        TvStatus.checking => const Color(0xFF888888),
        TvStatus.connected => const Color(0xFF4CAF50),
        TvStatus.searching => const Color(0xFFFF9800),
        TvStatus.pairing => const Color(0xFFFF9800),
        TvStatus.disconnected => const Color(0xFFF44336),
      };

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    if (!_ready) {
      // Bootstrapping client/prefs (only when constructed with neither) --
      // brief enough (SharedPreferences is already warm by the time Setup or
      // main.dart gets here) that a themed blank frame reads better than a
      // spinner.
      return Scaffold(backgroundColor: theme.windowBg, body: const SizedBox.shrink());
    }
    return Scaffold(
      backgroundColor: theme.windowBg,
      body: Listener(
        onPointerDown: _onRootPointerDown,
        behavior: HitTestBehavior.translucent,
        child: Stack(
          key: _rootKey,
          children: [
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final dims = MainDims.of(context);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: _numpadOpen
                          ? NumpadPage(
                              controller: _controller,
                              onClose: () => setState(() => _numpadOpen = false),
                            )
                          : _buildMainColumn(theme, dims),
                    ),
                    _header(theme),
                  ],
                );
              },
            ),
            TouchpadOverlayLayer(controller: _touchpad),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeConfig theme) {
    return Positioned(
      top: 8,
      right: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(color: _statusColor(_controller.status), shape: BoxShape.circle),
          ),
          GestureDetector(
            onTap: () => unawaited(_openSettings()),
            child: Semantics(
              button: true,
              label: 'App Settings',
              child: Opacity(
                opacity: 0.35,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(child: AppIcon('ic_settings', size: 24, color: theme.primaryText)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainColumn(ThemeConfig theme, MainDims dims) {
    return FillViewportPage(
      padding: EdgeInsets.fromLTRB(dims.mainPadH, 16, dims.mainPadH, 48),
      children: [
        SizedBox(
          width: double.infinity,
          child: Text(
            'LG TV Remote',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primaryText),
          ),
        ),
        const Spacer(),
        ShortcutsRow(controller: _controller),
        const Spacer(),
        _powerRow(theme),
        const Spacer(),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(offset: const Offset(0, 8), child: _homeMuteInputRow(theme, dims)),
            _pillsAndDpadRow(theme, dims),
            Transform.translate(offset: const Offset(0, -8), child: _backMenuRow(theme, dims)),
          ],
        ),
        const Spacer(),
        _bottomArea(theme),
      ],
    );
  }

  Widget _powerRow(ThemeConfig theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleButton(
          size: 72,
          color: const Color(0xFFE53935),
          label: 'Power',
          labelColor: theme.secondaryText,
          labelFontSize: 11,
          labelTopMargin: 5,
          semanticLabel: 'Power',
          onTap: () => unawaited(_controller.tapPower()),
          child: const AppIcon('ic_power', size: 24),
        ),
        const SizedBox(width: 28),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TouchpadButton(controller: _touchpad),
            const SizedBox(height: 5),
            Text('Touchpad', style: TextStyle(fontSize: 11, color: theme.secondaryText)),
          ],
        ),
        const SizedBox(width: 28),
        CircleButton(
          size: 72,
          color: theme.circleBtnBg,
          label: 'Keyboard',
          labelColor: theme.secondaryText,
          labelTopMargin: 5,
          semanticLabel: 'Keyboard',
          onTap: () {
            HapticFeedback.lightImpact();
            unawaited(showKeyboardSheet(context, _controller));
          },
          child: AppIcon('ic_keyboard', size: 28, color: theme.circleBtnIconTint),
        ),
      ],
    );
  }

  Widget _iconCell({
    required ThemeConfig theme,
    required double size,
    required String icon,
    required double iconSize,
    required String label,
    required String semanticLabel,
    required double labelTopMargin,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    Color? background,
    Color? iconColor,
  }) {
    return CircleButton(
      size: size,
      color: background ?? theme.circleBtnBg,
      label: label,
      labelColor: theme.secondaryText,
      labelTopMargin: labelTopMargin,
      semanticLabel: semanticLabel,
      onTap: onTap,
      onLongPress: onLongPress,
      child: AppIcon(icon, size: iconSize, color: iconColor ?? theme.circleBtnIconTint),
    );
  }

  Widget _homeMuteInputRow(ThemeConfig theme, MainDims dims) {
    final muted = _controller.currentMuted;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(width: dims.pillMirror),
        _iconCell(
          theme: theme,
          size: 52,
          icon: 'ic_home',
          iconSize: 24,
          label: 'Home',
          semanticLabel: 'Home',
          labelTopMargin: 4,
          onTap: () => unawaited(_controller.pressSimple('HOME')),
        ),
        SizedBox(width: dims.dpadTopGap),
        _iconCell(
          theme: theme,
          size: 52,
          icon: 'ic_mute',
          iconSize: 28,
          label: 'Mute',
          semanticLabel: 'Mute',
          labelTopMargin: 4,
          background: muted ? theme.btnAccentBg : theme.circleBtnBg,
          iconColor: muted ? theme.btnAccentText : theme.circleBtnIconTint,
          onTap: () => unawaited(_controller.toggleMute()),
        ),
        SizedBox(width: dims.dpadTopGap),
        _iconCell(
          theme: theme,
          size: 52,
          icon: 'ic_input',
          iconSize: 24,
          label: 'Input',
          semanticLabel: 'Input Source',
          labelTopMargin: 4,
          onTap: () => unawaited(_openInputPicker()),
        ),
        SizedBox(width: dims.pillMirror),
      ],
    );
  }

  Widget _backMenuRow(ThemeConfig theme, MainDims dims) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(width: dims.pillMirror),
        _iconCell(
          theme: theme,
          size: 52,
          icon: 'ic_back',
          iconSize: 24,
          label: 'Back',
          semanticLabel: 'Back',
          labelTopMargin: 4,
          onTap: () => unawaited(_controller.pressSimple('BACK')),
          onLongPress: () => unawaited(_controller.pressSimple('EXIT')),
        ),
        SizedBox(width: dims.dpadBottomGap),
        _iconCell(
          theme: theme,
          size: 52,
          icon: 'ic_settings',
          iconSize: 24,
          label: 'Menu',
          semanticLabel: 'Settings',
          labelTopMargin: 4,
          onTap: () => unawaited(_controller.pressSimple('MENU')),
          onLongPress: () => unawaited(_controller.pressSimple('HOME')),
        ),
        SizedBox(width: dims.pillMirror),
      ],
    );
  }

  Widget _pillsAndDpadRow(ThemeConfig theme, MainDims dims) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        LevelPill(
          width: dims.pillWidth,
          height: dims.dpadSize,
          label: _controller.currentVolume?.toString() ?? '',
          level: _controller.currentVolume,
          fillColor: _controller.currentMuted ? const Color(0x66888888) : const Color(0x664FC3F7),
          topIcon: 'ic_volume_up',
          bottomIcon: 'ic_volume_down',
          topSemanticLabel: 'Volume Up',
          bottomSemanticLabel: 'Volume Down',
          sliderEnabled: _controller.prefs.volSlider,
          onTapUp: _controller.volumeTapUp,
          onTapDown: _controller.volumeTapDown,
          onDragMove: _controller.volumeDragMove,
          onDragEnd: _controller.volumeDragEnd,
        ),
        SizedBox(width: dims.pillGap),
        Dpad(controller: _controller, size: dims.dpadSize, okSize: dims.okSize),
        SizedBox(width: dims.pillGap),
        _controller.rightPillChannel
            ? LevelPill(
                width: dims.pillWidth,
                height: dims.dpadSize,
                label: '',
                level: null,
                fillColor: null,
                topIcon: 'ic_channel_up',
                bottomIcon: 'ic_channel_down',
                topSemanticLabel: 'Channel Up',
                bottomSemanticLabel: 'Channel Down',
                channelMode: true,
                onTapUp: () => unawaited(_controller.channelUp()),
                onTapDown: () => unawaited(_controller.channelDown()),
              )
            : LevelPill(
                width: dims.pillWidth,
                height: dims.dpadSize,
                label: _controller.currentBrightness?.toString() ?? '',
                level: _controller.currentBrightness,
                fillColor: const Color(0x44FFB74D),
                topIcon: 'ic_brightness_up',
                bottomIcon: 'ic_brightness_down',
                topSemanticLabel: 'Brightness Up',
                bottomSemanticLabel: 'Brightness Down',
                sliderEnabled: _controller.prefs.brightnessSlider,
                onTapUp: _controller.brightnessTapUp,
                onTapDown: _controller.brightnessTapDown,
                onDragMove: _controller.brightnessDragMove,
                onDragEnd: _controller.brightnessDragEnd,
              ),
      ],
    );
  }

  Widget _bottomArea(ThemeConfig theme) {
    if (_colorRowOpen) {
      return Row(
        key: _colorRowKey,
        children: [
          Expanded(child: _colorCell(theme, const Color(0xFFE53935), 'Red')),
          Expanded(child: _colorCell(theme, const Color(0xFF2E7D32), 'Green')),
          Expanded(child: _colorCell(theme, const Color(0xFFF9A825), 'Yellow')),
          Expanded(child: _colorCell(theme, const Color(0xFF1565C0), 'Blue')),
        ],
      );
    }
    return Row(
      key: _colorRowKey,
      children: [
        Expanded(
          child: _bottomCell(
            theme: theme,
            icon: 'ic_screen_off',
            iconSize: 24,
            label: 'Screen Off',
            semanticLabel: 'Screen Off',
            active: _controller.currentScreenOff,
            onTap: () => unawaited(_controller.tapScreenOff()),
          ),
        ),
        Expanded(
          child: _bottomCell(
            theme: theme,
            icon: 'ic_picture',
            iconSize: 24,
            label: 'Picture',
            semanticLabel: 'Picture Mode',
            onTap: () => unawaited(_openPicturePicker()),
          ),
        ),
        Expanded(child: _numpadCell(theme)),
        Expanded(
          child: _bottomCell(
            theme: theme,
            icon: 'ic_colors',
            iconSize: 28,
            label: 'Colors',
            semanticLabel: 'Color Buttons',
            tint: false,
            onTap: _onColorsTap,
          ),
        ),
        Expanded(
          child: _bottomCell(
            theme: theme,
            icon: 'ic_sound',
            iconSize: 28,
            label: 'Sound',
            semanticLabel: 'Sound Mode',
            onTap: () => unawaited(_openSoundPicker()),
          ),
        ),
      ],
    );
  }

  Widget _bottomCell({
    required ThemeConfig theme,
    required String icon,
    required double iconSize,
    required String label,
    required String semanticLabel,
    VoidCallback? onTap,
    bool active = false,
    bool tint = true,
  }) {
    final bg = active ? theme.btnAccentBg : theme.circleBtnBg;
    final iconColor = !tint ? null : (active ? theme.btnAccentText : theme.circleBtnIconTint);
    return CircleButton(
      size: 56,
      color: bg,
      label: label,
      labelColor: theme.secondaryText,
      labelTopMargin: 5,
      semanticLabel: semanticLabel,
      onTap: onTap,
      child: AppIcon(icon, size: iconSize, color: iconColor),
    );
  }

  Widget _numpadCell(ThemeConfig theme) {
    return CircleButton(
      size: 56,
      color: theme.circleBtnBg,
      label: 'Numpad',
      labelColor: theme.secondaryText,
      labelTopMargin: 5,
      semanticLabel: 'Numpad',
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _numpadOpen = true);
      },
      child: Text(
        '123',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: theme.primaryText),
      ),
    );
  }

  Widget _colorCell(ThemeConfig theme, Color color, String label) {
    return CircleButton(
      size: 56,
      color: color,
      label: label,
      labelColor: theme.secondaryText,
      labelTopMargin: 5,
      semanticLabel: label,
      onTap: () => unawaited(_controller.pressSimple(label.toUpperCase())),
      child: const SizedBox.shrink(),
    );
  }
}
