// The wake loop starts an attempt every second; attempts that overlap all wait
// on the same connecting command session and are released together when it
// registers. The after-wake action and the screen-on must still go out once.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/ui/main/remote_controller.dart';

void main() {
  // The haptic tick on tapPower needs a binding; its HttpOverrides would turn
  // the fake TV's WebSocket upgrade into a 400, so they are lifted again.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('a slow command connect still gives one after-wake action and one screen-on', () async {
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        switch (msg['type']) {
          case 'register':
            ws.add(jsonEncode({
              'type': 'registered',
              'id': id,
              'payload': {'client-key': 'key'},
            }));
          case 'request':
            requests.add(msg['uri'] as String);
            ws.add(jsonEncode({
              'type': 'response',
              'id': id,
              'payload': {'returnValue': true},
            }));
        }
      });
    });

    SharedPreferences.setMockInitialValues({});
    final prefs = await Prefs.load();
    await prefs.setTvIp('127.0.0.1');
    await prefs.setClientKey('key');
    // The TV answers about 2.4 s after the first attempt, so the attempts
    // started at 0, 1 and 2 s are all waiting on the same session.
    final client = WebOsClient(
      prefs,
      commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: (url) async {
        await Future<void>.delayed(const Duration(milliseconds: 2400));
        return WebSocket.connect('ws://127.0.0.1:${server.port}${Uri.parse(url).path}');
      }),
    );
    addTearDown(client.resetConnection);
    final controller = RemoteController(client: client, prefs: prefs);
    addTearDown(controller.dispose);

    await controller.tapPower();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(requests.where((u) => u == 'ssap://system.launcher/launch'), hasLength(1));
    expect(requests.where((u) => u.endsWith('/power/turnOnScreen')), hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
