import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/prefs.dart';
import '../../core/right_pill.dart';
import '../../core/tv_store.dart';
import '../../net/ir.dart';
import '../../net/webos_client.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../settings/settings_screen.dart';
import '../setup/setup_screen.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/spotlight_tour.dart';
import '../widgets/warning_sheet.dart';
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

/// Which row is sliding in over the bottom row right now: colours or media
/// keys.
enum _SlideRow { none, colors, media }

/// The main remote screen (port spec `port-spec-main-ui.md`): scaffold, main
/// column, header overlay, numpad page swap and colour/media-row swap.
/// Everything else (connection/volume/brightness state, the wake sequence,
/// the pointer gesture machine) lives in [RemoteController] /
/// [TouchpadController].
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
  final GlobalKey _slideRowKey = GlobalKey();

  // Tour targets, ordered top to bottom so the ring only ever travels one way
  final GlobalKey _titleKey = GlobalKey();
  final GlobalKey _gearKey = GlobalKey();
  final GlobalKey _shortcutsKey = GlobalKey();
  final GlobalKey _powerKey = GlobalKey();
  final GlobalKey _statusDotKey = GlobalKey();
  final GlobalKey _touchpadKey = GlobalKey();
  final GlobalKey _keyboardKey = GlobalKey();
  final GlobalKey _volumePillKey = GlobalKey();
  final GlobalKey _mediaKey = GlobalKey();
  final GlobalKey _numpadKey = GlobalKey();

  RemoteController? _controllerOrNull;
  TouchpadController? _touchpadOrNull;
  RemoteController get _controller => _controllerOrNull!;
  TouchpadController get _touchpad => _touchpadOrNull!;
  bool get _ready => _controllerOrNull != null;

  StreamSubscription<ToastMessage>? _toastSub;
  bool _numpadOpen = false;
  _SlideRow _slideRow = _SlideRow.none;
  bool _slideRowJustDismissed = false;
  bool _hardwareKeysHooked = false;
  bool _tourRunning = false;

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
    final touchpad = TouchpadController(
      client: client,
      vsync: this,
      rootKey: _rootKey,
    );
    _toastSub = controller.toasts.listen((m) {
      if (mounted) showToast(context, m.text, long: m.long);
    });
    setState(() {
      _controllerOrNull = controller;
      _touchpadOrNull = touchpad;
    });
    unawaited(controller.onResume());
    unawaited(_syncWakelock());
    // Android only -- iOS has no way to intercept the hardware volume keys.
    if (!kIsWeb && Platform.isAndroid) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      _hardwareKeysHooked = true;
    }
    // Fire-and-forget, same as onCreate's non-blocking dialog on Android --
    // the rest of setup (already done above) doesn't wait on it. A pending
    // tour takes precedence: two overlays on top of each other on first
    // launch is one too many.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (prefs.tourPending) {
        unawaited(_maybeStartTour());
      } else {
        unawaited(maybeShowWhatsNew(context, prefs));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ready) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.onResume());
      unawaited(_syncWakelock());
    } else if (state == AppLifecycleState.paused) {
      _controller.onPause();
      // Unconditional -- a backgrounded remote has no screen to keep on, and
      // the wakelock would otherwise outlive the app going to the background.
      unawaited(WakelockPlus.disable());
    }
  }

  // Keep-screen-on only matters while this screen is actually the one on
  // top (spec 05): enabled at bootstrap/resume when the pref is on, disabled
  // wherever it's read as off.
  Future<void> _syncWakelock() async {
    if (!_ready) return;
    if (_controller.prefs.keepScreenOn) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
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
    if (_hardwareKeysHooked) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _toastSub?.cancel();
    _controllerOrNull?.dispose();
    _touchpadOrNull?.dispose();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Tour
  // ---------------------------------------------------------------------

  List<TourStep> get _tourSteps => [
    TourStep(
      [_titleKey],
      'Your TVs',
      'The current TV. Tap it to switch to another saved TV or to add one.',
    ),
    TourStep(
      [_gearKey],
      'Settings',
      'Shortcuts, themes and the rest live behind the gear. The tour ends in there.',
    ),
    TourStep(
      [_shortcutsKey],
      'App shortcuts',
      'These launch apps on the TV. You pick them in Settings, up to eight.',
    ),
    TourStep(
      [_powerKey, _statusDotKey],
      'Power',
      "Turns the TV on from standby over the network, or with the phone's IR blaster if it has one. "
          'The dot in the corner shows whether the TV is on.',
    ),
    TourStep(
      [_touchpadKey],
      'Touchpad',
      'Tap and drag straight from this button to move the pointer. Hold it for a moment to lock the '
          'touchpad open; Back closes it.',
    ),
    TourStep(
      [_keyboardKey],
      'Keyboard',
      "Type on the phone, send to the TV. Works in the TV's search and browser; YouTube and Netflix "
          'only accept their own on-screen keyboard.',
    ),
    TourStep(
      [_volumePillKey],
      'Volume',
      "Tap the ends to step, or drag anywhere on the pill to slide. The phone's volume keys work here too.",
    ),
    TourStep(
      [_mediaKey],
      'Media keys',
      'Rewind, play, pause and forward slide in at the bottom. Colors next to the numpad does the same '
          'for the colour keys.',
    ),
    TourStep(
      [_numpadKey],
      'Numpad and more keys',
      'Channel numbers, Guide, Info, subtitles and an OK key. Next opens Settings.',
    ),
  ];

  /// Runs the remote's leg of the tour when setup or Settings asked for it;
  /// finishing it hands over to the Settings leg.
  Future<void> _maybeStartTour() async {
    if (!_ready || _tourRunning || !_controller.prefs.tourPending) return;
    _tourRunning = true;
    await _controller.prefs.setTourPending(false);
    // Let the enter transition settle so the highlight lands on laid-out
    // widgets
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) {
      _tourRunning = false;
      return;
    }
    if (_numpadOpen) setState(() => _numpadOpen = false);
    final completed = await showSpotlightTour(
      context,
      _tourSteps,
      lastLabel: 'Open Settings',
    );
    _tourRunning = false;
    if (!mounted || !completed) return;
    await _controller.prefs.setTourSettingsPending(true);
    await _openSettings();
  }

  // ---------------------------------------------------------------------
  // Settings / slide rows / pickers
  // ---------------------------------------------------------------------

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(client: _controller.client),
      ),
    );
    await _afterReturn();
  }

  /// Everything a screen pushed over the remote may have changed: the active
  /// TV, its shortcuts, the right pill, the theme, keep-screen-on, a queued
  /// tour, or (after the last TV was removed) the connection itself.
  Future<void> _afterReturn() async {
    if (!mounted) return;
    if (_controller.client.tvIp.isEmpty) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SetupScreen(client: _controller.client),
        ),
      );
      return;
    }
    await _controller.onResume();
    if (!mounted) return;
    await _syncWakelock();
    if (!mounted) return;
    await _maybeStartTour();
  }

  void _openSlideRow(_SlideRow row) {
    HapticFeedback.lightImpact();
    if (!_slideRowJustDismissed) {
      setState(() => _slideRow = row);
    }
  }

  void _onRootPointerDown(PointerDownEvent event) {
    _slideRowJustDismissed = false;
    if (_slideRow == _SlideRow.none) return;
    final box = _slideRowKey.currentContext?.findRenderObject();
    var inside = false;
    if (box is RenderBox && box.attached) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      inside = rect.contains(event.position);
    }
    if (!inside) {
      setState(() {
        _slideRow = _SlideRow.none;
        _slideRowJustDismissed = true;
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
      onSelect: (id) => unawaited(
        _controller.sendCommand(() => _controller.client.switchInput(id)),
      ),
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
        for (final mode in WebOsClient.pictureModes)
          (mode.$1, mode.$2, mode.$1 == current),
      ],
      onSelect: (id) => unawaited(
        _controller.sendCommand(() => _controller.client.setPictureMode(id)),
      ),
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
        for (final mode in WebOsClient.soundModes)
          (mode.$1, mode.$2, mode.$1 == current),
      ],
      onSelect: (id) => unawaited(
        _controller.sendCommand(() => _controller.client.setSoundMode(id)),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Saved TVs (title picker)
  // ---------------------------------------------------------------------

  static const _addTvId = '__add';

  Future<void> _openTvPicker() async {
    HapticFeedback.lightImpact();
    final prefs = _controller.prefs;
    final tvs = TvStore.list(prefs);
    final activeId = TvStore.activeId(prefs);
    await showPickerSheet(
      context,
      title: 'TVs',
      rows: [
        for (final tv in tvs) (tv.id, tv.name, tv.id == activeId),
        (_addTvId, 'Add another TV…', false),
      ],
      onLongPress: (id) {
        if (id != _addTvId) unawaited(_showTvActions(id));
      },
      onSelect: (id) {
        if (id == _addTvId) {
          unawaited(_addTv());
        } else if (id != activeId) {
          unawaited(_controller.switchTv(id));
        }
      },
    );
  }

  Future<void> _addTv() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SetupScreen(client: _controller.client, addMode: true),
      ),
    );
    await _afterReturn();
  }

  Future<void> _showTvActions(String id) async {
    final tv = TvStore.list(
      _controller.prefs,
    ).where((t) => t.id == id).firstOrNull;
    if (tv == null || !mounted) return;
    await showPickerSheet(
      context,
      title: tv.name,
      rows: const [('rename', 'Rename', false), ('remove', 'Remove', false)],
      onSelect: (action) {
        switch (action) {
          case 'rename':
            unawaited(_showRenameDialog(tv));
          case 'remove':
            unawaited(
              showWarningSheet(
                context,
                chip: 'REMOVE TV',
                title: 'Remove ${tv.name}?',
                body:
                    'The pairing with this TV is forgotten. You can add it again from the TV picker, '
                    'which asks the TV to pair once more.',
                button: 'Remove',
                onAccept: () {
                  TvStore.remove(_controller.prefs, id);
                  unawaited(_afterReturn());
                },
              ),
            );
        }
      },
    );
  }

  Future<void> _showRenameDialog(Tv tv) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: tv.name),
    );
    if (name == null || !mounted) return;
    _controller.renameTv(tv.id, name);
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
      return Scaffold(
        backgroundColor: theme.windowBg,
        body: const SizedBox.shrink(),
      );
    }
    return ListenableBuilder(
      listenable: _touchpad,
      builder: (context, _) {
        // Spec §12 onBackPressed: locked touchpad takes priority over the
        // numpad page, otherwise fall through to the default (app exit).
        final interceptBack = _touchpad.isLocked || _numpadOpen;
        return PopScope(
          canPop: !interceptBack,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (_touchpad.isLocked) {
              _touchpad.exitTapped();
            } else if (_numpadOpen) {
              setState(() => _numpadOpen = false);
            }
          },
          child: Scaffold(
            backgroundColor: theme.windowBg,
            body: SafeArea(
              bottom: false,
              child: Listener(
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
                                      onClose: () =>
                                          setState(() => _numpadOpen = false),
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
            ),
          ),
        );
      },
    );
  }

  Widget _header(ThemeConfig theme) {
    return Positioned(
      top: 12,
      right: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            key: _statusDotKey,
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: _statusColor(_controller.status),
              shape: BoxShape.circle,
            ),
          ),
          GestureDetector(
            key: _gearKey,
            onTap: () => unawaited(_openSettings()),
            child: Semantics(
              button: true,
              label: 'App Settings',
              child: Opacity(
                opacity: 0.35,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AppIcon(
                      'ic_settings',
                      size: 24,
                      color: theme.primaryText,
                    ),
                  ),
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
        _title(theme),
        const Spacer(),
        ShortcutsRow(key: _shortcutsKey, controller: _controller),
        const Spacer(),
        _powerRow(theme),
        const Spacer(),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(
              offset: const Offset(0, 8),
              child: _homeMuteInputRow(theme, dims),
            ),
            _pillsAndDpadRow(theme, dims),
            Transform.translate(
              offset: const Offset(0, -8),
              child: _backMenuRow(theme, dims),
            ),
          ],
        ),
        const Spacer(),
        _bottomArea(theme),
      ],
    );
  }

  /// The title is the active TV's name and opens the saved-TV picker. The
  /// pressed state hugs the text as a rounded pill.
  Widget _title(ThemeConfig theme) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: _titleKey,
          borderRadius: BorderRadius.circular(12),
          splashColor: theme.primaryText.withAlpha(0x22),
          highlightColor: theme.primaryText.withAlpha(0x22),
          onTap: () => unawaited(_openTvPicker()),
          child: Semantics(
            button: true,
            label: 'TVs',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      _controller.tvName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.primaryText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AppIcon(
                    'ic_chevron_down',
                    size: 18,
                    color: theme.secondaryText,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _powerRow(ThemeConfig theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleButton(
          circleKey: _powerKey,
          size: 72,
          color: const Color(0xFFE53935),
          label: 'Power',
          labelColor: theme.secondaryText,
          labelFontSize: 11,
          labelTopMargin: 5,
          semanticLabel: 'Power',
          onTap: () => unawaited(_controller.tapPower()),
          onLongPress: _onPowerLongPress,
          child: const AppIcon('ic_power', size: 24),
        ),
        const SizedBox(width: 28),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TouchpadButton(key: _touchpadKey, controller: _touchpad),
            const SizedBox(height: 5),
            Text(
              'Touchpad',
              style: TextStyle(fontSize: 11, color: theme.secondaryText),
            ),
          ],
        ),
        const SizedBox(width: 28),
        CircleButton(
          circleKey: _keyboardKey,
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
          child: AppIcon(
            'ic_keyboard',
            size: 28,
            color: theme.circleBtnIconTint,
          ),
        ),
      ],
    );
  }

  // The haptic always fires (matches the platform's own long-press feedback
  // on Android); only the actual IR send is conditional on hardware.
  void _onPowerLongPress() {
    HapticFeedback.heavyImpact();
    unawaited(_transmitPowerIr());
  }

  Future<void> _transmitPowerIr() async {
    if (await Ir.hasEmitter()) {
      await Ir.transmit(38000, Ir.necPattern(Ir.lgPowerCode));
    }
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
    Key? circleKey,
  }) {
    return CircleButton(
      circleKey: circleKey,
      size: size,
      color: background ?? theme.circleBtnBg,
      label: label,
      labelColor: theme.secondaryText,
      labelTopMargin: labelTopMargin,
      semanticLabel: semanticLabel,
      onTap: onTap,
      onLongPress: onLongPress,
      child: AppIcon(
        icon,
        size: iconSize,
        color: iconColor ?? theme.circleBtnIconTint,
      ),
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
        // The Media button sits in the gap under the d-pad
        SizedBox(
          width: dims.dpadBottomGap,
          child: Center(
            child: _iconCell(
              theme: theme,
              circleKey: _mediaKey,
              size: 52,
              icon: 'ic_media',
              iconSize: 28,
              label: 'Media',
              semanticLabel: 'Media keys',
              labelTopMargin: 4,
              onTap: () => _openSlideRow(_SlideRow.media),
            ),
          ),
        ),
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
          pillKey: _volumePillKey,
          width: dims.pillWidth,
          height: dims.dpadSize,
          label: _controller.currentVolume?.toString() ?? '',
          level: _controller.currentVolume,
          fillColor: _controller.currentMuted
              ? const Color(0x66888888)
              : const Color(0x664FC3F7),
          topIcon: 'ic_volume_up',
          bottomIcon: 'ic_volume_down',
          topSemanticLabel: 'Volume Up',
          bottomSemanticLabel: 'Volume Down',
          onTapUp: _controller.volumeTapUp,
          onTapDown: _controller.volumeTapDown,
          onDragMove: _controller.volumeDragMove,
          onDragEnd: _controller.volumeDragEnd,
        ),
        SizedBox(width: dims.pillGap),
        Dpad(controller: _controller, size: dims.dpadSize, okSize: dims.okSize),
        SizedBox(width: dims.pillGap),
        _controller.rightPill == RightPill.channel
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
                onTapUp: _controller.brightnessTapUp,
                onTapDown: _controller.brightnessTapDown,
                onDragMove: _controller.brightnessDragMove,
                onDragEnd: _controller.brightnessDragEnd,
              ),
      ],
    );
  }

  Widget _bottomArea(ThemeConfig theme) {
    switch (_slideRow) {
      case _SlideRow.colors:
        return Row(
          key: _slideRowKey,
          children: [
            Expanded(child: _colorCell(theme, const Color(0xFFE53935), 'Red')),
            Expanded(
              child: _colorCell(theme, const Color(0xFF2E7D32), 'Green'),
            ),
            Expanded(
              child: _colorCell(theme, const Color(0xFFF9A825), 'Yellow'),
            ),
            Expanded(child: _colorCell(theme, const Color(0xFF1565C0), 'Blue')),
          ],
        );
      case _SlideRow.media:
        return Row(
          key: _slideRowKey,
          children: [
            Expanded(child: _mediaCell(theme, 'ic_rewind', 'Rewind', 'REWIND')),
            Expanded(child: _mediaCell(theme, 'ic_play', 'Play', 'PLAY')),
            Expanded(child: _mediaCell(theme, 'ic_pause', 'Pause', 'PAUSE')),
            Expanded(
              child: _mediaCell(
                theme,
                'ic_fast_forward',
                'Forward',
                'FASTFORWARD',
                semantic: 'Fast forward',
              ),
            ),
          ],
        );
      case _SlideRow.none:
        break;
    }
    return Row(
      key: _slideRowKey,
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
            onTap: () => _openSlideRow(_SlideRow.colors),
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
    final iconColor = !tint
        ? null
        : (active ? theme.btnAccentText : theme.circleBtnIconTint);
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
      circleKey: _numpadKey,
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
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: theme.primaryText,
        ),
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

  Widget _mediaCell(
    ThemeConfig theme,
    String icon,
    String label,
    String keyCode, {
    String? semantic,
  }) {
    return _bottomCell(
      theme: theme,
      icon: icon,
      iconSize: 24,
      label: label,
      semanticLabel: semantic ?? label,
      onTap: () => unawaited(_controller.pressSimple(keyCode)),
    );
  }
}

/// Owns its controller so it outlives the dialog's closing transition (see
/// the same note on Setup's manual-IP dialog).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return AlertDialog(
      backgroundColor: theme.surfaceBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Rename TV', style: TextStyle(color: theme.primaryText)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        style: TextStyle(fontSize: 15, color: theme.primaryText),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: theme.windowBg,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.btnGhostBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.btnGhostBorderPressed),
          ),
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: theme.secondaryText)),
        ),
        TextButton(
          onPressed: _save,
          child: Text('Save', style: TextStyle(color: theme.btnAccentBg)),
        ),
      ],
    );
  }
}
