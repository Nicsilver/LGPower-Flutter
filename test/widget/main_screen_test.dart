// Pumps MainScreen against a fake WebOsClient (no real sockets -- pressKey/
// setVolume/setBrightness/watchPower/awaitPresence are all overridden) so
// these run fast and hermetically, unlike protocol_test.dart which drives
// the real fake TV rig.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/messages.g.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/main/main_screen.dart';
import 'package:lgpower/ui/main/widgets/level_pill.dart';
import 'package:lgpower/ui/main/widgets/numpad_page.dart';

const _packageInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);

// MainScreen calls WakelockPlus on every bootstrap/resume regardless of the
// keep_screen_on pref's value (off just means "disable", still a real
// platform call) -- without a mock reply the pigeon channel has no host-side
// handler in a widget test and every call throws.
const _wakelockToggleChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
  WakelockPlusApi.pigeonChannelCodec,
);

/// Overrides every method that would otherwise touch a real socket. Presence
/// is driven manually via [emit] so status-dot tests are deterministic.
class FakeWebOsClient extends WebOsClient {
  FakeWebOsClient(super.prefs);

  Presence _presence = const PresenceUnknown();
  void Function(Presence)? _listener;
  final List<String> pressedKeys = [];

  void emit(Presence p) {
    _presence = p;
    _listener?.call(p);
  }

  @override
  void Function() watchPower(void Function(Presence) listener) {
    _listener = listener;
    return () => _listener = null;
  }

  @override
  Future<Presence> awaitPresence(int timeoutMs) async => _presence;

  @override
  Future<Result> pressKey(String keyCode) async {
    pressedKeys.add(keyCode);
    return const Success();
  }

  @override
  Future<Result> setVolume(int level) async => const Success();

  @override
  Future<Result> setBrightness(int level) async => const Success();

  @override
  Future<VolumeState?> getVolume() async => null;

  @override
  Future<int?> getBrightness() async => null;

  // Refreshed on every connect for the after-wake picker's cache; a real
  // call would open a socket to the fake address.
  @override
  Future<(List<InputSource>, String?)> getInputs() async =>
      (const <InputSource>[], null);
}

Future<Prefs> _freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp(
    'fake-tv',
  ); // non-empty -- keeps startWatching() off the autoDiscover path
  await prefs.setLastSeenVersion(1 << 30); // suppress the what's-new dialog
  return prefs;
}

Future<void> _pumpMainScreen(
  WidgetTester tester, {
  required Prefs prefs,
  required FakeWebOsClient client,
}) async {
  // The default test surface (800x600, landscape-ish) is shorter than the
  // remote's full column, so the bottom row sits outside the viewport and
  // tap() can't hit it. A phone-shaped canvas matches what this screen is
  // actually designed for and lines dims.dart up with the compact variant.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Loading the theme (path_provider's custom-theme probe) alongside the
  // screen's many flutter_svg icons needs the real event loop -- under the
  // fake-async test zone alone this combination hangs pumpWidget forever;
  // runAsync briefly steps outside that zone so both settle normally.
  await tester.runAsync(() async {
    final themeController = AppThemeController(
      await ThemeManager.loadTheme('dark'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          controller: themeController,
          child: MainScreen(client: client, prefs: prefs),
        ),
      ),
    );
  });
  await tester
      .pump(); // let the bootstrap microtask (client/prefs already supplied) settle
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // main_screen.dart's what's-new hook calls PackageInfo.fromPlatform(); mock
  // its channel so that resolves instead of throwing MissingPluginException.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_packageInfoChannel, (call) async {
        if (call.method == 'getAll') {
          return <String, dynamic>{
            'appName': 'lgpower',
            'packageName': 'com.nic.lgpower.flutter',
            'version': '1.0.0',
            'buildNumber': '1',
            'buildSignature': '',
          };
        }
        return null;
      });

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockDecodedMessageHandler<Object?>(
        _wakelockToggleChannel,
        (message) async => <Object?>[null],
      );

  testWidgets('remote labels are present', (tester) async {
    final prefs = await _freshPrefs();
    final client = FakeWebOsClient(prefs);
    await _pumpMainScreen(tester, prefs: prefs, client: client);

    // A pre-saved-TVs install (flat tv_ip only) migrates into one TV named
    // "LG TV", which is what the title now shows.
    for (final label in [
      'LG TV',
      'Power',
      'Touchpad',
      'Keyboard',
      'Home',
      'Mute',
      'Input',
      'OK',
      'Back',
      'Media',
      'Menu',
      'Screen Off',
      'Picture',
      '123',
      'Colors',
      'Sound',
    ]) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'missing label "$label"',
      );
    }
  });

  group('volume pill maths', () {
    testWidgets('tap top half steps +1', (tester) async {
      final prefs = await _freshPrefs();
      await prefs.setLastVolume(20);
      await prefs.setLastMuted(false);
      final client = FakeWebOsClient(prefs);
      await _pumpMainScreen(tester, prefs: prefs, client: client);

      expect(find.text('20'), findsOneWidget);

      final pillListener = find.descendant(
        of: find.byType(LevelPill).first,
        matching: find.byType(Listener),
      );
      final rect = tester.getRect(pillListener);
      final topHalfPoint = Offset(rect.center.dx, rect.top + rect.height * 0.1);

      await tester.tapAt(topHalfPoint);
      await tester.pump();

      expect(find.text('21'), findsOneWidget);
      expect(client.pressedKeys, contains('VOLUMEUP'));
    });

    testWidgets('drag to the very top sets level 100', (tester) async {
      final prefs = await _freshPrefs();
      await prefs.setLastVolume(20);
      await prefs.setLastMuted(false);
      final client = FakeWebOsClient(prefs);
      await _pumpMainScreen(tester, prefs: prefs, client: client);

      final pillListener = find.descendant(
        of: find.byType(LevelPill).first,
        matching: find.byType(Listener),
      );
      final rect = tester.getRect(pillListener);

      final gesture = await tester.startGesture(rect.center);
      await gesture.moveTo(Offset(rect.center.dx, rect.top));
      await gesture.up();
      await tester.pump();

      expect(find.text('100'), findsOneWidget);
    });
  });

  testWidgets('numpad echoes digits into the readout', (tester) async {
    final prefs = await _freshPrefs();
    final client = FakeWebOsClient(prefs);
    await _pumpMainScreen(tester, prefs: prefs, client: client);

    await tester.tap(find.text('123'));
    await tester.pump();
    expect(find.byType(NumpadPage), findsOneWidget);

    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.tap(find.text('2'));
    await tester.pump();

    // Only the readout ever shows a 2-character run; the dialer keys
    // themselves are single digits, so this is unambiguous.
    expect(find.text('12'), findsOneWidget);
    expect(client.pressedKeys, containsAllInOrder(['1', '2']));
  });

  testWidgets('colour row opens on tap and closes on an outside tap', (
    tester,
  ) async {
    // Disposed explicitly at the end of the test body, not via addTearDown --
    // the global tearDown queue runs after this binding's own end-of-test
    // "handle still active" check, so addTearDown(handle.dispose) is too late.
    final handle = tester.ensureSemantics();
    final prefs = await _freshPrefs();
    final client = FakeWebOsClient(prefs);
    await _pumpMainScreen(tester, prefs: prefs, client: client);

    // The Colors button's caption ("Colors") is a sibling below the circle,
    // not inside its tap target (matches the Android source: the label
    // TextView is never part of the ImageButton) -- find the button itself
    // by its semantic label instead of by the caption text.
    expect(find.text('Red'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Color Buttons'));
    await tester.pump();
    expect(find.text('Red'), findsOneWidget);
    expect(find.text('Colors'), findsNothing);

    // Tap something well outside the bottom row -- the Power caption, which
    // is not itself a tap target -- to dismiss.
    await tester.tap(find.text('Power'));
    await tester.pump();
    expect(find.text('Red'), findsNothing);
    expect(find.text('Colors'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('status dot colour follows Presence', (tester) async {
    final prefs = await _freshPrefs();
    final client = FakeWebOsClient(prefs);
    await _pumpMainScreen(tester, prefs: prefs, client: client);

    Color dotColor() {
      final decorated = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere(
            (c) =>
                c.constraints ==
                const BoxConstraints.tightFor(width: 6, height: 6),
          );
      return (decorated.decoration! as BoxDecoration).color!;
    }

    // CHECKING is the initial state before any presence has been reported.
    expect(dotColor(), const Color(0xFF888888));

    client.emit(const PresenceReported('Active', null));
    await tester.pump();
    expect(dotColor(), const Color(0xFF4CAF50));

    client.emit(const PresenceUnreachable());
    await tester.pump();
    expect(dotColor(), const Color(0xFFF44336));

    client.emit(const PresenceNeedsPairing());
    await tester.pump();
    expect(dotColor(), const Color(0xFFFF9800));
  });
}
