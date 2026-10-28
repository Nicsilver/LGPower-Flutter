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
import 'package:lgpower/net/typing_support.dart';
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
  final replies = <String, Map<String, dynamic> Function(Object? id)>{};
  final _subs = <(WebSocket, Object?)>[];
  // Sent to every keyboard subscriber when closeAlert arrives, like the TV
  // running the alert's luna call.
  Map<String, dynamic>? pushOnCloseAlert;

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
            _subs.add((ws, id));
            for (final push in keyboardPushes) {
              ws.add(jsonEncode({...push, 'id': id}));
            }
          case 'unsubscribe':
            unsubscribed.add(id);
          case 'request':
            seenRequests.add(msg);
            final uri = msg['uri'] as String?;
            final reply = uri == 'ssap://com.webos.service.ime/insertText'
                ? insertTextReply?.call(id)
                : replies[uri]?.call(id);
            if (uri == 'ssap://system.notifications/closeAlert' && pushOnCloseAlert != null) {
              for (final (sub, subId) in _subs) {
                sub.add(jsonEncode({...pushOnCloseAlert!, 'id': subId}));
              }
            }
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

  WebOsClient client(Prefs prefs) => WebOsClient(prefs, commandSessionFactory: sessions);

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
      'appName': 'Tiny TV Remote',
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
      // Only an explicit focus:false may raise the hint.
      expect(parseKeyboardFocus({'subscribed': true}), KeyboardFocus.unknown);
      expect(parseKeyboardFocus({'currentWidget': {}}), KeyboardFocus.unknown);
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

    test('a top-level error next to returnValue true is still a success', () async {
      tv.insertTextReply = (id) => {
            'type': 'response',
            'id': id,
            'error': 'harmless note',
            'payload': <String, dynamic>{'returnValue': true},
          };
      final session = tv.sessions('127.0.0.1', await _prefs());
      addTearDown(session.close);
      final reply = await session.send('ssap://com.webos.service.ime/insertText');
      expect(reply, isA<CmdReplyOk>());
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
      final prefs = await _prefs();
      final report = await KeyboardProbe(
        session,
        header: 'Keyboard test report',
        prefs: prefs,
        notificationInsert: (text) async => (const CmdReplyErr('401 insufficient permissions'), null),
        listenFor: const Duration(milliseconds: 400),
      ).run();
      expect(report, contains('Typing verdict: the TV refused text'));
      expect(TypingSupport.isRefused(prefs), isTrue);
      expect(report, contains('through the notification route: alert ERROR 401'));

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

    test('TV identifiers are redacted', () {
      final text = trimFrame({
        'payload': {
          'client-key': 'secret-key',
          'device_id': 'aa:bb:cc:dd:ee:ff',
          'serialNumber': '123ABC',
          'macAddress': '11-22-33-44-55-66',
          'ip': '192.168.1.157',
          'note': 'wired 0a:1b:2c:3d:4e:5f up',
          'model_name': 'HE_DTV_W24O_AFABATAA',
          'major_ver': '33',
        },
      }, max: 2000);
      for (final secret in [
        'secret-key',
        'aa:bb:cc:dd:ee:ff',
        '123ABC',
        '11-22-33-44-55-66',
        '192.168.1.157',
        '0a:1b:2c:3d:4e:5f',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('HE_DTV_W24O_AFABATAA'));
      expect(text, contains('"major_ver":"33"'));
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
      await tester.longPress(find.text('Tiny TV Remote'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(KeyboardTestScreen), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('without a pairing the long-press does nothing', (tester) async {
      await openSettings(tester, paired: false);
      await tester.longPress(find.text('Tiny TV Remote'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(KeyboardTestScreen), findsNothing);
    });
  });

  group('typing support', () {
    test('a refusal lasts three days, then the keyboard tries again', () async {
      final prefs = await _prefs();
      final t0 = DateTime(2026, 10, 26);
      expect(TypingSupport.isRefused(prefs, now: t0), isFalse);
      await TypingSupport.markRefused(prefs, now: t0);
      expect(TypingSupport.isRefused(prefs, now: t0.add(const Duration(days: 2))), isTrue);
      expect(TypingSupport.isRefused(prefs, now: t0.add(const Duration(days: 4))), isFalse);
    });

    test('a different software version lifts the refusal, the same one does not', () async {
      final prefs = await _prefs();
      await TypingSupport.noteVersion(prefs, 'webOS 04 40.43');
      await TypingSupport.markRefused(prefs);
      await TypingSupport.noteVersion(prefs, 'webOS 04 40.43');
      expect(TypingSupport.isRefused(prefs), isTrue);
      await TypingSupport.noteVersion(prefs, 'webOS 04 41.00');
      expect(TypingSupport.isRefused(prefs), isFalse);
      expect(TypingSupport.softwareVersion(prefs), 'webOS 04 41.00');
    });

    test('the first version ever seen does not clear a mark', () async {
      final prefs = await _prefs();
      await TypingSupport.markRefused(prefs);
      await TypingSupport.noteVersion(prefs, 'webOS 04 40.43');
      expect(TypingSupport.isRefused(prefs), isTrue);
    });

    test('links open as typed, everything else is a search', () {
      expect(TypingSupport.browserTarget('https://example.com/a'), 'https://example.com/a');
      expect(TypingSupport.browserTarget('example.com'), 'https://example.com');
      expect(TypingSupport.browserTarget('cat videos'), 'https://www.google.com/search?q=cat+videos');
      expect(TypingSupport.browserTarget(' planet '), 'https://www.google.com/search?q=planet');
      expect(TypingSupport.browserTarget('3.14'), 'https://www.google.com/search?q=3.14');
      expect(TypingSupport.browserTarget('javascript:alert(1)'), 'https://www.google.com/search?q=javascript%3Aalert%281%29');
    });

    test('the version comes from whatever the TV reports', () {
      expect(
        TypingSupport.versionOf({'product_name': 'webOSTV 24', 'major_ver': '4', 'minor_ver': '30'}),
        'webOSTV 24 4 30',
      );
      expect(TypingSupport.versionOf({'firmwareVersion': '43.21.59'}), '43.21.59');
      expect(TypingSupport.versionOf({'returnValue': true}), isNull);
      expect(TypingSupport.versionOf(null), isNull);
    });

    test('text length is read only from a widget that reports it', () {
      expect(keyboardTextLengthOf({'currentWidget': {'focus': true, 'surroundingTextLength': 3}}), 3);
      expect(keyboardTextLengthOf({'currentWidget': {'focus': true, 'hiddenText': true}}), isNull);
      expect(keyboardTextLengthOf(null), isNull);
    });
  });

  group('typeText', () {
    late _Tv tv;
    setUp(() async {
      tv = _Tv();
      await tv.start();
    });
    tearDown(() => tv.stop());

    const focusedPush = {
      'type': 'response',
      'payload': {
        'returnValue': true,
        'subscribed': true,
        'currentWidget': {'focus': true, 'surroundingTextLength': 0},
      },
    };

    void scriptAlert() {
      tv.replies['ssap://system.notifications/createAlert'] =
          (id) => {'type': 'response', 'id': id, 'payload': {'returnValue': true, 'alertId': 'a1'}};
    }

    test('plain typing is one insertText with a boolean replace and no fallback', () async {
      final client = tv.client(await _prefs());
      expect(await client.typeText('hi'), isA<Typed>());
      final uris = [for (final r in tv.seenRequests) r['uri']];
      expect(uris, isNot(contains('ssap://system.notifications/createAlert')));
      final insert = tv.seenRequests.firstWhere((r) => r['uri'] == 'ssap://com.webos.service.ime/insertText');
      expect(insert['payload'], {'text': 'hi', 'replace': false});
    });

    test('a refusal with no visible keyboard state is refused and tries nothing else', () async {
      tv.insertTextReply = (id) => {..._frame401, 'id': id};
      final client = tv.client(await _prefs());
      expect(await client.typeText('hi'), isA<TypeRefused>());
      expect([for (final r in tv.seenRequests) r['uri']], isNot(contains('ssap://system.notifications/createAlert')));
    });

    test('a refusal is retried through the notification route and counts when the text length grows', () async {
      tv.insertTextReply = (id) => {..._frame401, 'id': id};
      tv.keyboardPushes = [focusedPush];
      scriptAlert();
      tv.pushOnCloseAlert = {
        'type': 'response',
        'payload': {
          'returnValue': true,
          'currentWidget': {'focus': true, 'surroundingTextLength': 2},
        },
      };
      final client = tv.client(await _prefs());
      final cancel = await client.watchKeyboard((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await client.typeText('hi'), isA<Typed>());
      cancel();
      final alert = tv.seenRequests.firstWhere((r) => r['uri'] == 'ssap://system.notifications/createAlert');
      expect((alert['payload'] as Map)['onclose'], {
        'uri': 'luna://com.webos.service.ime/insertText',
        'params': {'text': 'hi', 'replace': false},
      });
    });

    test('the notification route does not count when nothing grows', () async {
      tv.insertTextReply = (id) => {..._frame401, 'id': id};
      tv.keyboardPushes = [focusedPush];
      scriptAlert();
      final client = tv.client(await _prefs());
      final cancel = await client.watchKeyboard((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await client.typeText('hi'), isA<TypeRefused>());
      cancel();
    });

    test('another error is a plain failure, not a refusal', () async {
      tv.insertTextReply = (id) => {
            'type': 'response',
            'id': id,
            'payload': {'returnValue': false, 'errorText': 'Invalid parameters'},
          };
      final result = await tv.client(await _prefs()).typeText('hi');
      expect(result, isA<TypeFailed>());
      expect((result as TypeFailed).message, 'Invalid parameters');
    });

    test('the software version is stored when the keyboard asks for it, and a new one lifts a refusal', () async {
      tv.replies['ssap://com.webos.service.update/getCurrentSWInformation'] = (id) => {
            'type': 'response',
            'id': id,
            'payload': {'returnValue': true, 'product_name': 'webOS', 'major_ver': '04', 'minor_ver': '40.43'},
          };
      final prefs = await _prefs();
      await TypingSupport.noteVersion(prefs, 'webOS 04 40.00');
      await TypingSupport.markRefused(prefs);
      await tv.client(prefs).refreshSoftwareVersion();
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (TypingSupport.softwareVersion(prefs) != 'webOS 04 40.43' && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(TypingSupport.softwareVersion(prefs), 'webOS 04 40.43');
      expect(TypingSupport.isRefused(prefs), isFalse);
    });
  });

  group('keyboard sheet', () {
    Future<_SheetClient> pump(WidgetTester tester, _SheetClient Function(Prefs) make, {bool mark = false, String? versionBefore, Future<void> Function(Prefs)? onRefresh}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late _SheetClient client;
      await tester.runAsync(() async {
        final prefs = await _prefs();
        if (versionBefore != null) await TypingSupport.noteVersion(prefs, versionBefore);
        if (mark) await TypingSupport.markRefused(prefs);
        client = make(prefs);
        if (onRefresh != null) client.onRefresh = () => onRefresh(prefs);
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

    testWidgets('a refusal marks the TV, keeps the text and switches Send to a web search', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const CmdError('401 insufficient permissions')));
      expect(find.byKey(const Key('keyboard_note')), findsNothing);
      await typeAndSend(tester);
      expect(find.text(keyboardSearchOnlyLine), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(TypingSupport.isRefused(client.prefs), isTrue);
      expect(client.opened, isEmpty);
      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.opened, ['hello']);
      expect(client.sent, ['hello']);
      expect(find.byType(KeyboardSheet), findsNothing);
    });

    testWidgets('a TV already marked as refusing opens in search mode and never tries to type', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const Success()), mark: true);
      expect(find.text(keyboardSearchOnlyLine), findsOneWidget);
      await typeAndSend(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.sent, isEmpty);
      expect(client.opened, ['hello']);
    });

    testWidgets('a new software version on a marked TV takes the sheet back to typing', (tester) async {
      late Prefs prefs;
      final client = await pump(tester, (p) {
        prefs = p;
        return _SheetClient(p, const Success());
      }, mark: true, versionBefore: 'webOS 04 40.00', onRefresh: (p) => TypingSupport.noteVersion(p, 'webOS 04 41.00'));
      await tester.pump();
      expect(find.text(keyboardSearchOnlyLine), findsNothing);
      await typeAndSend(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.sent, ['hello']);
      expect(client.opened, isEmpty);
      expect(TypingSupport.isRefused(prefs), isFalse);
    });

    testWidgets('a TV that will not open the link says so', (tester) async {
      final client = await pump(tester, (p) => _SheetClient(p, const Success()), mark: true);
      client.openResult = const CmdError('401 insufficient permissions');
      await typeAndSend(tester);
      expect(find.text(keyboardLinkLine), findsOneWidget);
      expect(find.byType(KeyboardSheet), findsOneWidget);
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
  final opened = <String>[];
  Result openResult = const Success();
  Future<void> Function()? onRefresh;
  void Function(KeyboardFocus)? focus;
  int watching = 0;

  @override
  Future<void> refreshSoftwareVersion() async => onRefresh?.call();

  @override
  Future<Result> openInBrowser(String text) async {
    opened.add(text);
    return openResult;
  }

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
