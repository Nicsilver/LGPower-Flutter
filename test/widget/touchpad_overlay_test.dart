// The locked touchpad against a recording pointer session: what each overlay
// control sends to the TV, and how drag movement is batched.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/pointer_session.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/main/widgets/touchpad_overlay.dart';

class _RecordingSession extends PointerSession {
  _RecordingSession(super.ip, super.prefs, this.frames) : super.blocked();

  final List<String> frames;

  @override
  bool get isUsable => true;

  @override
  bool sendKey(String keyCode, {Object? hold}) {
    frames.add('key:$keyCode');
    return true;
  }

  @override
  void click() => frames.add('click');

  @override
  void move(double dx, double dy) => frames.add('move:${dx.toInt()},${dy.toInt()}');

  @override
  void scroll(double dx, double dy) => frames.add('scroll:${dx.toInt()},${dy.toInt()}');
}

class _Harness {
  _Harness(this.controller, this.frames);
  final TouchpadController controller;
  final List<String> frames;

  List<(int, int)> get moves => [
        for (final f in frames)
          if (f.startsWith('move:'))
            (
              int.parse(f.substring(5).split(',')[0]),
              int.parse(f.substring(5).split(',')[1]),
            ),
      ];
}

Future<_Harness> _pumpLockedPad(WidgetTester tester) => _pumpPad(tester, lock: true);

Future<_Harness> _pumpPad(WidgetTester tester, {required bool lock}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp('fake-tv');
  final frames = <String>[];
  final client = WebOsClient(
    prefs,
    pointerSessionFactory: (ip, p) => _RecordingSession(ip, p, frames),
  );
  final controller = TouchpadController(
    client: client,
    vsync: const TestVSync(),
    rootKey: GlobalKey(),
  );
  addTearDown(controller.dispose);

  await tester.runAsync(() async {
    final themeController = AppThemeController(await ThemeManager.loadTheme('dark'));
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          controller: themeController,
          child: Scaffold(body: Stack(children: [TouchpadOverlayLayer(controller: controller)])),
        ),
      ),
    );
  });

  if (!lock) return _Harness(controller, frames);
  controller.onButtonDown(const Offset(200, 2000), const Offset(200, 2000));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  expect(controller.isLocked, isTrue);
  controller.onButtonUp();
  await tester.pump();
  frames.clear();
  return _Harness(controller, frames);
}

Finder _control(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('locked pad controls', () {
    testWidgets('Click sends exactly one click', (tester) async {
      final h = await _pumpLockedPad(tester);
      await tester.tap(_control('Click'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.frames, ['click']);
    });

    testWidgets('Back sends one BACK and no click', (tester) async {
      final h = await _pumpLockedPad(tester);
      await tester.tap(_control('Back'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.frames, ['key:BACK']);
    });

    testWidgets('Exit sends nothing and closes the pad', (tester) async {
      final h = await _pumpLockedPad(tester);
      await tester.tap(_control('Exit'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.frames, isEmpty);
      expect(h.controller.active, isFalse);
    });

    testWidgets('a tap on the bare pad clicks once', (tester) async {
      final h = await _pumpLockedPad(tester);
      await tester.tapAt(const Offset(200, 600));
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.frames, ['click']);
    });
  });

  group('move batching', () {
    // The view is 3 logical px per physical px; the TV gets physical px, as the
    // Kotlin app sends Android's rawX/rawY deltas.
    testWidgets('travel goes out in physical pixels', (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(20, 0), timeStamp: _ms(0));
      await g.moveBy(const Offset(10, 5), timeStamp: _ms(4));
      await g.up();
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), 90);
      expect(h.moves.fold<int>(0, (a, m) => a + m.$2), 15);
    });

    testWidgets('sends are paced by touch time, not frames: none are pumped here',
        (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(20, 0), timeStamp: _ms(0));
      // The first touch event is sent at once, not on the next frame.
      expect(h.moves, [(60, 0)]);
      var expectedDx = 60.0;
      // 1 s of 8 ms touch samples on a 60 Hz display.
      for (var t = 8; t <= 1000; t += 8) {
        await g.moveBy(const Offset(1, 0.5), timeStamp: _ms(t));
        expectedDx += 3;
      }
      final beforeUp = h.moves.length;
      await g.up();

      // One send per refresh (~60), not one per touch event (126).
      expect(beforeUp, inInclusiveRange(58, 64));
      expect(h.frames.where((f) => !f.startsWith('move:')), isEmpty);
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), expectedDx.round());
      expect(h.moves.fold<int>(0, (a, m) => a + m.$2), 125 * 3 ~/ 2);
    });

    testWidgets('travel left when the finger stops goes out without a frame', (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(20, 0), timeStamp: _ms(0));
      await g.moveBy(const Offset(2, 1), timeStamp: _ms(4));
      expect(h.moves, [(60, 0)]);
      await tester.binding.delayed(const Duration(milliseconds: 20));
      expect(h.moves, [(60, 0), (6, 3)]);
      await g.up();
    });

    testWidgets('a slow drag keeps its fraction across sends', (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(13, 0), timeStamp: _ms(0));
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(0.25, 0), timeStamp: _ms(17 * i));
      }
      await g.up();
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), 46);
      expect(h.moves.length, greaterThan(5));
    });
  });

  group('drag ticks', () {
    // A tick every 32 physical px of drag travel, none for the movement that
    // only decides tap versus drag, as the Kotlin pad does.
    late List<String> haptics;

    setUp(() {
      haptics = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    int selectionTicks() => haptics.where((h) => h == 'HapticFeedbackType.selectionClick').length;

    testWidgets('dragging inside the locked pad ticks every 32 physical px', (tester) async {
      await _pumpLockedPad(tester);
      haptics.clear();
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(20, 0), timeStamp: _ms(0));
      expect(selectionTicks(), 0);
      // 5 logical px = 15 physical: the third move passes 32.
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(5, 0), timeStamp: _ms(17 * i));
      }
      await g.up();
      expect(selectionTicks(), 3);
    });

    testWidgets('a tap-sized wobble and a two-finger scroll do not tick', (tester) async {
      await _pumpLockedPad(tester);
      haptics.clear();
      final tap = await tester.startGesture(const Offset(200, 600));
      await tap.moveBy(const Offset(4, 0), timeStamp: _ms(0));
      await tap.moveBy(const Offset(0, 4), timeStamp: _ms(17));
      await tap.up();
      expect(selectionTicks(), 0);

      final a = await tester.startGesture(const Offset(200, 600), pointer: 1);
      final b = await tester.startGesture(const Offset(260, 600), pointer: 2);
      for (var i = 1; i <= 5; i++) {
        await a.moveBy(const Offset(0, 20), timeStamp: _ms(17 * i));
        await b.moveBy(const Offset(0, 20), timeStamp: _ms(17 * i));
      }
      await a.up();
      await b.up();
      expect(selectionTicks(), 0);
    });
  });

  group('drag from the Touchpad button', () {
    // Each touch event moves 2 logical px, under the 12 px threshold on its
    // own; per refresh (4 events, 24 physical px) it is a drag, as the Kotlin
    // app sees it. A per-event check locked the pad 600 ms in and the cursor
    // stopped dead under the still-moving finger.
    testWidgets('a steady drag of small touch events never locks and keeps moving',
        (tester) async {
      final h = await _pumpPad(tester, lock: false);
      final c = h.controller;
      var p = const Offset(200, 2000);
      c.onButtonDown(p, p);
      await tester.pump();
      var t = 0;
      var sentBefore = 0;
      for (var w = 0; w < 60; w++) {
        for (var i = 0; i < 4; i++) {
          p += const Offset(2, 0);
          t += 4;
          c.onButtonMove(p, _ms(t));
        }
        await tester.pump(const Duration(milliseconds: 16));
        if (w == 45) sentBefore = h.moves.length;
      }
      expect(c.isLocked, isFalse);
      expect(h.moves.length, greaterThan(sentBefore));
      c.onButtonUp();
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), 60 * 4 * 2 * 3);
      expect(c.active, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('after locking under a still finger, moving it still drives the cursor',
        (tester) async {
      final h = await _pumpPad(tester, lock: false);
      final c = h.controller;
      const p = Offset(200, 2000);
      c.onButtonDown(p, p);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(c.isLocked, isTrue);
      c.onButtonMove(p + const Offset(5, 0), _ms(700));
      c.onButtonMove(p + const Offset(10, 2), _ms(717));
      c.onButtonUp();
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), 30);
      expect(h.moves.fold<int>(0, (a, m) => a + m.$2), 6);
      expect(c.isLocked, isTrue);
      expect(h.frames.where((f) => !f.startsWith('move:')), isEmpty);
    });
  });
}

Duration _ms(int ms) => Duration(milliseconds: ms);
