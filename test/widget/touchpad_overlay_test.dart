// The locked touchpad against a recording pointer session: what each overlay
// control sends to the TV, and how drag movement is batched.
import 'package:flutter/material.dart';
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

Future<_Harness> _pumpLockedPad(WidgetTester tester) async {
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
    testWidgets('many touch events per frame go out as one frame, total preserved',
        (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      // Past the tap threshold in one step, then fine-grained travel.
      await g.moveBy(const Offset(20, 0));
      var expectedDx = 20.0, expectedDy = 0.0;
      const frameCount = 6;
      for (var frame = 0; frame < frameCount; frame++) {
        for (var i = 0; i < 20; i++) {
          await g.moveBy(const Offset(0.7, 0.3));
          expectedDx += 0.7;
          expectedDy += 0.3;
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 16));

      // 121 touch events; the old per-event forwarding sent one frame each.
      expect(h.moves.length, lessThanOrEqualTo(frameCount));
      expect(h.frames.where((f) => !f.startsWith('move:')), isEmpty);
      final sentDx = h.moves.fold<int>(0, (a, m) => a + m.$1);
      final sentDy = h.moves.fold<int>(0, (a, m) => a + m.$2);
      // Only the sub-unit remainder (plus float drift) may still sit in the carry.
      expect(expectedDx - sentDx, inInclusiveRange(0, 1.001));
      expect(expectedDy - sentDy, inInclusiveRange(0, 1.001));
    });

    testWidgets('travel still queued when the finger lifts is not lost', (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(const Offset(10, 5));
      await g.up();
      expect(h.moves.fold<int>(0, (a, m) => a + m.$1), 30);
      expect(h.moves.fold<int>(0, (a, m) => a + m.$2), 5);
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.moves.length, 1);
    });

    testWidgets('a slow drag keeps its fraction across frames', (tester) async {
      final h = await _pumpLockedPad(tester);
      final g = await tester.startGesture(const Offset(200, 600));
      await g.moveBy(const Offset(13, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0.4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      final sentDx = h.moves.fold<int>(0, (a, m) => a + m.$1);
      expect(sentDx, 17);
    });
  });
}
