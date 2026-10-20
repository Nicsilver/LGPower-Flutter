// Error parsing for typing failures (a 401 frame carries its text in the
// top-level `error`, not in the payload) and what the keyboard sheet shows for
// it, plus the keyboard test's report.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/keyboard.dart';
import 'package:lgpower/net/keyboard_probe.dart';
import 'package:lgpower/net/ssap_messages.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/net/ws_connect.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/main/remote_controller.dart';
import 'package:lgpower/ui/main/widgets/keyboard_sheet.dart';
import 'package:lgpower/ui/settings/keyboard_test_screen.dart';
import 'package:lgpower/ui/settings/settings_screen.dart';

import 'widget/fake_path_provider.dart';

const _frame401 = {
  'type': 'error',
  'error': '401 insufficient permissions',
  'payload': <String, dynamic>{},
};

/// A plain ws:// TV whose insertText answer and keyboard pushes are scripted.
class _Tv {
  late HttpServer _server;
  Map<String, dynamic> Function(Object? id)? insertTextReply;
  final seenRequests = <Map<String, dynamic>>[];
  final unsubscribed = <Object?>[];
  List<Map<String, dynamic>> keyboardPushes = [];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        switch (msg['type']) {
          case 'register':
            ws.add(jsonEncode({
              'type': 'registered',
              'id': id,
              'payload': {'client-key': 'secret-key'},
            }));
          case 'subscribe':
            for (final push in keyboardPushes) {
              ws.add(jsonEncode({...push, 'id': id}));
            }
          case 'unsubscribe':
            unsubscribed.add(id);
          case 'request':
            seenRequests.add(msg);
            final reply = msg['uri'] == 'ssap://com.webos.service.ime/insertText'
                ? insertTextReply?.call(id)
                : null;
            ws.add(jsonEncode(reply ??
                {
                  'type': 'response',
                  'id': id,
                  'payload': {'returnValue': true},
                }));
        }
      });
    });
  }

  Future<void> stop() => _server.close(force: true);

  SocketConnector get connector => (url) => WebSocket.connect('ws://127.0.0.1:${_server.port}');

  CommandSession Function(String, Prefs) get sessions =>
      (ip, p) => CommandSession(ip, p, connector: connector);
}

Future<Prefs> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp('127.0.0.1');
  await prefs.setClientKey('secret-key');
  return prefs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installFakePathProvider();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/package_info'),
    (call) async => <String, dynamic>{
      'appName': 'Power Remote',
      'packageName': 'com.nic.lgpower',
      'version': '1.0.0',
      'buildNumber': '1',
      'buildSignature': '',
    },
  );

  group('error text', () {
    test('a 401 frame reads its text from the top-level error', () {
      expect(ssapErrorText(_frame401), '401 insufficient permissions');
    });

    test('payload.errorText still wins when present', () {
      expect(
        ssapErrorText({
          'type': 'response',
          'error': 'ignored',
          'payload': {'returnValue': false, 'errorText': 'No such method'},
        }),
        'No such method',
      );
    });

    test('a frame with neither gives an empty string', () {
      expect(ssapErrorText({'type': 'error', 'payload': {}}), '');
      expect(ssapErrorText({'type': 'error'}), '');
    });

    test('permission errors are told apart from other failures', () {
      expect(isSsapPermissionError('401 insufficient permissions'), isTrue);
      expect(isSsapPermissionError('Insufficient permissions'), isTrue);
      expect(isSsapPermissionError('404 no such service'), isFalse);
      expect(isSsapPermissionError('Timeout. Is the TV on and reachable?'), isFalse);
    });

    test('the sheet line is plain for a 401 and the TV text otherwise', () {
      expect(keyboardErrorLine('401 insufficient permissions'), keyboardPermissionLine);
      expect(keyboardErrorLine('500 Application error'), '500 Application error');
      expect(keyboardPermissionLine.contains('—'), isFalse);
    });

    test('keyboard focus is read from currentWidget', () {
      expect(parseKeyboardFocus(null), KeyboardFocus.unknown);
      expect(parseKeyboardFocus({'subscribed': true}), KeyboardFocus.none);
      expect(
        parseKeyboardFocus({
          'currentWidget': {'focus': true, 'contentType': 'text'},
        }),
        KeyboardFocus.focused,
      );
      expect(
        parseKeyboardFocus({
          'currentWidget': {'focus': false},
        }),
        KeyboardFocus.none,
      );
    });
  });

  group('command session', () {
    late _Tv tv;
    setUp(() async {
      tv = _Tv();
      await tv.start();
    });
    tearDown(() => tv.stop());

    test('a top-level error frame becomes the reply text, not "Unknown error"', () async {
      tv.insertTextReply = (id) => {..._frame401, 'id': id};
      final session = tv.sessions('127.0.0.1', await _prefs());
      addTearDown(session.close);
      final reply = await session.send(
        'ssap://com.webos.service.ime/insertText',
        payload: {'text': 'a', 'replace': false},
      );
      expect(reply, isA<CmdReplyErr>());
      expect((reply as CmdReplyErr).message, '401 insufficient permissions');
      expect(reply.raw?['error'], '401 insufficient permissions');
    });

    test('a response frame carrying a top-level error is a failure too', () async {
      tv.insertTextReply = (id) => {
            'type': 'response',
            'id': id,
            'error': '401 insufficient permissions',
            'payload': <String, dynamic>{},
          };
      final session = tv.sessions('127.0.0.1', await _prefs());
      addTearDown(session.close);
      final reply = await session.send('ssap://com.webos.service.ime/insertText');
      expect((reply as CmdReplyErr).message, '401 insufficient permissions');
    });

    test('subscribe hands the whole frame to onFrame, errors included', () async {
      tv.keyboardPushes = [_frame401];
      final session = tv.sessions('127.0.0.1', await _prefs());
      addTearDown(session.close);
      await session.awaitReady();
      final frames = <Map<String, dynamic>>[];
      final payloads = <Map<String, dynamic>?>[];
      session.subscribe(
        'ssap://com.webos.service.ime/registerRemoteKeyboard',
        payloads.add,
        onFrame: frames.add,
      );
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (frames.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(frames.single['error'], '401 insufficient permissions');
      expect(payloads, [null]);
    });

    test('the keyboard test report covers every call and hides the client key', () async {
      tv.insertTextReply = (id) => {..._frame401, 'id': id};
      tv.keyboardPushes = [
        {
          'type': 'response',
          'payload': {
            'returnValue': true,
            'subscribed': true,
            'currentWidget': {'focus': true},
          },
        },
      ];
      final session = tv.sessions('127.0.0.1', await _prefs());
      addTearDown(session.close);
      await session.awaitReady();
      final report = await KeyboardProbe(
        session,
        header: 'Keyboard test report',
        listenFor: const Duration(milliseconds: 400),
      ).run();

      for (final label in [
        'getSystemInfo: OK',
        'getSoftwareInformation: OK',
        'control: getVolume: OK',
        'control: getForegroundAppInfo: OK',
        'insertText "A" replace=false: ERROR 401 insufficient permissions',
        'insertText "B" replace=0: ERROR 401 insufficient permissions',
        'deleteCharacters count=1: OK',
        'sendEnterKey: OK',
        'registerRemoteKeyboard: 1 frame(s)',
      ]) {
        expect(report, contains(label));
      }
      expect(report, contains('"currentWidget":{"focus":true}'));
      expect(report, contains('<redacted>'));
      expect(report, isNot(contains('secret-key')));

      final inserts = [
        for (final r in tv.seenRequests)
          if (r['uri'] == 'ssap://com.webos.service.ime/insertText') r['payload'],
      ];
      expect(inserts, [
        {'text': 'A', 'replace': false},
        {'text': 'B', 'replace': 0},
        {'text': 'C', 'replace': false},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.unsubscribed, hasLength(1));
    });

    test('long frames are cut', () {
      final text = trimFrame({'blob': 'x' * 2000});
      expect(text.length, lessThan(600));
      expect(text, contains('more characters'));
    });
  });

  group('hidden entry', () {
    Future<void> openSettings(WidgetTester tester, {required bool paired}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await Prefs.load();
        if (paired) {
          await prefs.setTvIp('127.0.0.1');
          await prefs.setClientKey('key');
        }
        final theme = AppThemeController(await ThemeManager.loadTheme('dark'));
        await tester.pumpWidget(
          AppTheme(
            controller: theme,
            child: MaterialApp(home: SettingsScreen(client: WebOsClient(prefs), limited: true)),
          ),
        );
      });
      await tester.pump();
    }

    testWidgets('long-pressing the About card opens the test when a TV is paired', (tester) async {
      await openSettings(tester, paired: true);
      await tester.longPress(find.text('Power Remote'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(KeyboardTestScreen), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('without a pairing the long-press does nothing', (tester) async {
      await openSettings(tester, paired: false);
      await tester.longPress(find.text('Power Remote'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(KeyboardTestScreen), findsNothing);
    });
  });

  group('keyboard sheet', () {
    Future<_SheetClient> pump(WidgetTester tester, _SheetClient Function(Prefs) make) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late _SheetClient client;
      await tester.runAsync(() async {
        final prefs = await _prefs();
        client = make(prefs);
        final theme = AppThemeController(await ThemeManager.loadTheme('dark'));
        await tester.pumpWidget(
          AppTheme(
            controller: theme,
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showKeyboardSheet(
                      context,
                      RemoteController(client: client, prefs: prefs),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
      });
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return client;
    }

    Future<void> typeAndSend(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a 401 shows the plain permission line and keeps the text', (tester) async {
      await pump(tester, (p) => _SheetClient(p, const CmdError('401 insufficient permissions')));
      expect(find.byKey(const Key('keyboard_note')), findsNothing);
      await typeAndSend(tester);
      expect(find.text(keyboardPermissionLine), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('another error shows the TV text', (tester) async {
      await pump(tester, (p) => _SheetClient(p, const CmdError('500 Application error')));
      await typeAndSend(tester);
      expect(find.text('500 Application error'), findsOneWidget);
      expect(find.text(keyboardPermissionLine), findsNothing);
    });

    testWidgets('no focused text field on the TV shows the hint, a focus clears it', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const Success()));
      expect(find.text(keyboardNoFocusHint), findsNothing);
      client.focus!(KeyboardFocus.none);
      await tester.pump();
      expect(find.text(keyboardNoFocusHint), findsOneWidget);
      client.focus!(KeyboardFocus.focused);
      await tester.pump();
      expect(find.text(keyboardNoFocusHint), findsNothing);
    });

    testWidgets('the keyboard subscription is held while open and cancelled on dismiss', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const Success()));
      expect(client.watching, 1);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(KeyboardSheet), findsNothing);
      expect(client.watching, 0);
    });

    testWidgets('success sends the text and closes the sheet', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const Success()));
      await typeAndSend(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.sent, ['hello']);
      expect(find.byType(KeyboardSheet), findsNothing);
    });
  });
}

class _SheetClient extends WebOsClient {
  _SheetClient(super.prefs, this.result);

  final Result result;
  final sent = <String>[];
  void Function(KeyboardFocus)? focus;
  int watching = 0;

  @override
  Future<Result> sendText(String text) async {
    sent.add(text);
    return result;
  }

  @override
  Future<void Function()> watchKeyboard(void Function(KeyboardFocus) listener) async {
    focus = listener;
    watching++;
    return () => watching--;
  }
}
