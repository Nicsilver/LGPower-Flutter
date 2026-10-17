// Connection reuse and grace logic of the pointer and command sessions,
// against an in-process fake TV that speaks plain ws:// (no TLS, no python
// rig). The sessions take a connector so the wss:// URLs map onto it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/pairing_watcher.dart';
import 'package:lgpower/net/pointer_session.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/net/ws_connect.dart';

class _FakeTv {
  late HttpServer _server;
  int controlConnections = 0;
  int openControlSockets = 0;
  int pointerConnections = 0;
  int registerCount = 0;

  /// Answers registration with the pairing prompt challenge instead of
  /// accepting it, like a TV that does not know the client key.
  bool challengePairing = false;

  /// Answers registration with an error, like a TV whose prompt was denied.
  bool rejectRegistration = false;

  /// With [challengePairing]: follows the challenge with the denial error.
  bool denyAfterChallenge = false;

  /// Replaces the registration reply wholesale (malformed-message tests).
  String Function(Object? id)? registerReply;

  /// What a getPowerState subscription is answered with.
  Map<String, dynamic> subscribeReply = {
    'type': 'response',
    'payload': {'returnValue': true, 'state': 'Active'},
  };
  final pointerFrames = <String>[];
  final _pointerSockets = <WebSocket>[];
  final _controlSockets = <WebSocket>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      if (req.uri.path == '/pointer') {
        pointerConnections++;
        _pointerSockets.add(ws);
        ws.listen((m) => pointerFrames.add(m as String));
        return;
      }
      controlConnections++;
      openControlSockets++;
      _controlSockets.add(ws);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        switch (msg['type']) {
          case 'register':
            registerCount++;
            final custom = registerReply;
            if (custom != null) {
              ws.add(custom(id));
              return;
            }
            if (rejectRegistration) {
              ws.add(jsonEncode({
                'type': 'error',
                'id': id,
                'payload': {'errorText': '403 User denied access'},
              }));
              return;
            }
            if (challengePairing && denyAfterChallenge) {
              Timer(const Duration(milliseconds: 40), () {
                ws.add(jsonEncode({
                  'type': 'error',
                  'id': id,
                  'payload': {'errorText': '403 User denied access'},
                }));
              });
            }
            ws.add(jsonEncode(challengePairing
                ? {
                    'type': 'response',
                    'id': id,
                    'payload': {'pairingType': 'PROMPT', 'returnValue': true},
                  }
                : {
                    'type': 'registered',
                    'id': id,
                    'payload': {'client-key': 'key'},
                  }));
          case 'subscribe':
            ws.add(jsonEncode({...subscribeReply, 'id': id}));
          case 'request':
            final uri = msg['uri'];
            final payload =
                uri == 'ssap://com.webos.service.networkinput/getPointerInputSocket'
                    ? {'returnValue': true, 'socketPath': 'wss://127.0.0.1:3001/pointer'}
                    : uri == 'ssap://com.webos.service.connectionmanager/getinfo'
                        ? {
                            'returnValue': true,
                            'wifiInfo': {'macAddress': 'AA:BB:CC:DD:EE:FF'},
                          }
                        : {
                            'returnValue': true,
                            'volumeStatus': {'volume': 12, 'muteStatus': false},
                          };
            ws.add(jsonEncode({'type': 'response', 'id': id, 'payload': payload}));
        }
      }, onDone: () => openControlSockets--);
    });
  }

  /// Tells every open control socket the pairing prompt was accepted.
  void pushRegistered() {
    for (final s in _controlSockets) {
      s.add(jsonEncode({
        'type': 'registered',
        'id': 'reg_0',
        'payload': {'client-key': 'late-key'},
      }));
    }
  }

  void dropPointerSockets() {
    for (final s in _pointerSockets) {
      s.close();
    }
    _pointerSockets.clear();
  }

  Future<void> stop() => _server.close(force: true);

  /// Maps the app's wss://ip:3001[/path] URLs onto this server, optionally
  /// stalling the connect to model a slow TLS handshake.
  SocketConnector connector({Duration delay = Duration.zero}) => (url) async {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        final path = Uri.parse(url).path;
        return WebSocket.connect('ws://127.0.0.1:$port$path');
      };
}

// Paired by default: a pointer session never registers without a key.
Future<Prefs> _prefs({String? clientKey = 'key'}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp('127.0.0.1');
  if (clientKey != null) await prefs.setClientKey(clientKey);
  return prefs;
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue, reason: 'condition not met within 3 s');
}

List<String> _buttons(_FakeTv tv) =>
    tv.pointerFrames.where((f) => f.startsWith('type:button')).toList();

void main() {
  // No TestWidgetsFlutterBinding: its HttpOverrides would turn the fake
  // TV's WebSocket upgrade into a 400.
  late _FakeTv tv;

  setUp(() async {
    tv = _FakeTv();
    await tv.start();
  });
  tearDown(() => tv.stop());

  group('PointerSession', () {
    test('frames sent while connecting are flushed in call order, moves folded', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 150)));
      addTearDown(session.close);

      session.sendKey('UP');
      session.move(3, 1);
      session.move(4, 2);
      session.sendKey('DOWN');
      session.click();
      expect(session.state, PointerState.connecting);

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 4);
      expect(tv.pointerFrames, [
        'type:button\nname:UP\n\n',
        'type:move\ndx:7\ndy:3\n\n',
        'type:button\nname:DOWN\n\n',
        'type:click\n\n',
      ]);
    });

    test('a connecting session is usable until its grace runs out', () async {
      final never = Completer<WebSocket>();
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: (_) => never.future, connectGrace: const Duration(milliseconds: 120));
      addTearDown(session.close);

      expect(session.isUsable, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(session.isUsable, isFalse);
    });

    test('a failed connect leaves a dead session that drops frames', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: (_) => Future<WebSocket>.error(const SocketException('refused')));
      session.sendKey('UP');
      expect(await session.waitUntilReady(), isFalse);
      expect(session.state, PointerState.dead);
      expect(session.isUsable, isFalse);
    });

    test('closing mid-connect leaves no socket open on the TV', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 100)));
      session.close();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(tv.pointerConnections, 0);
    });
  });

  group('WebOsClient pointer sharing', () {
    test('presses and touchpad calls during a connect share one session, keys in order', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 200)));
      });
      addTearDown(client.resetConnection);

      final presses = <Future<Result>>[];
      for (final key in ['UP', 'DOWN', 'LEFT', 'RIGHT']) {
        presses.add(client.pressKey(key));
        client.pointerSession().move(1, 0);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      client.warmPointer();

      expect(await Future.wait(presses), everyElement(isA<Success>()));
      expect(created, 1);
      await _until(() => _buttons(tv).length == 4);
      expect(tv.pointerConnections, 1);
      expect(tv.controlConnections, 1);
      expect(_buttons(tv), [
        'type:button\nname:UP\n\n',
        'type:button\nname:DOWN\n\n',
        'type:button\nname:LEFT\n\n',
        'type:button\nname:RIGHT\n\n',
      ]);
    });

    test('a live session is reused; a dropped one is replaced on the next press', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      expect(await client.pressKey('UP'), isA<Success>());
      expect(await client.pressKey('UP'), isA<Success>());
      expect(created, 1);

      final first = client.pointerSession();
      await _until(() => tv.pointerConnections == 1);
      tv.dropPointerSockets();
      await _until(() => !first.isAlive);
      expect(await client.pressKey('OK'), isA<Success>());
      expect(created, 2);
    });

    test('a connecting session past its grace is replaced', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        return PointerSession(ip, p,
            connector: (_) => Completer<WebSocket>().future,
            connectGrace: const Duration(milliseconds: 100));
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      expect(client.pointerSession(), same(first));
      await Future<void>.delayed(const Duration(milliseconds: 140));
      final second = client.pointerSession();
      expect(second, isNot(same(first)));
      expect(first.state, PointerState.dead);
    });

    test('a changed TV address does not reuse the old TV session', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await prefs.setTvIp('127.0.0.2');
      final second = client.pointerSession();
      expect(second, isNot(same(first)));
      expect(second.ip, '127.0.0.2');
      expect(first.state, PointerState.dead);
    });
  });

  group('reset and close', () {
    test('a reset mid-connect hands waiting presses to a fresh session, once each', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 150)));
      });
      addTearDown(client.resetConnection);

      final presses = [client.pressKey('VOLUMEUP'), client.pressKey('VOLUMEDOWN')];
      client.resetConnection();

      expect(await Future.wait(presses), everyElement(isA<Success>()));
      await _until(() => _buttons(tv).length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(created, 2);
      expect(tv.pointerConnections, 1);
      expect(_buttons(tv), ['type:button\nname:VOLUMEUP\n\n', 'type:button\nname:VOLUMEDOWN\n\n']);
    });

    test('a press whose replacement session is reset too gives up instead of looping', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 150)));
      });
      addTearDown(client.resetConnection);

      final press = client.pressKey('UP');
      client.resetConnection();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      client.resetConnection();

      expect(await press, isA<CmdError>());
      expect(created, 2);
    });

    test('closing a ready command session closes its socket on the TV', () async {
      final session = CommandSession('127.0.0.1', await _prefs(), connector: tv.connector());
      await session.awaitReady();
      expect(session.state, CmdState.ready);
      await _until(() => tv.openControlSockets == 1);

      session.close();
      await _until(() => tv.openControlSockets == 0);
    });

    test('closing a command session mid-connect leaves no socket open', () async {
      final session = CommandSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 100)));
      session.close();
      await _until(() => tv.controlConnections == 1);
      await _until(() => tv.openControlSockets == 0);
    });
  });

  group('WebOsClient command sharing', () {
    test('concurrent requests during the handshake share one connection', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs, commandSessionFactory: (ip, p) {
        created++;
        return CommandSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 150)));
      });
      addTearDown(client.resetConnection);

      final results = await Future.wait([
        client.getVolume(),
        client.getVolume(),
        client.getTvState(),
      ]);
      expect((results.first as VolumeState?)?.volume, 12);
      expect(created, 1);
      expect(tv.controlConnections, 1);

      expect((await client.getVolume())?.volume, 12);
      expect(created, 1);
    });

    test('a changed TV address starts a new command session', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, commandSessionFactory: (ip, p) {
        return CommandSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      expect(await client.getVolume(), isNotNull);
      await prefs.setTvIp('127.0.0.2');
      expect(await client.getVolume(), isNotNull);
      expect(tv.controlConnections, 2);
    });
  });

  group('pointer session timing', () {
    test('queued moves and clicks older than staleAfter are dropped, key presses never are', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 250)),
          staleAfter: const Duration(milliseconds: 100));
      addTearDown(session.close);

      session.sendKey('UP');
      session.move(5, 5);
      session.click();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      session.sendKey('DOWN');

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames, ['type:button\nname:UP\n\n', 'type:button\nname:DOWN\n\n']);
    });

    test('a fresh click behind a dropped move is dropped too, it would land at the wrong spot', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 250)),
          staleAfter: const Duration(milliseconds: 100));
      addTearDown(session.close);

      session.move(5, 5);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      session.click();

      expect(await session.waitUntilReady(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(tv.pointerFrames, isEmpty);
    });

    test('a click with no stale move before it is kept', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 100)),
          staleAfter: const Duration(milliseconds: 500));
      addTearDown(session.close);

      session.move(2, 2);
      session.click();
      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 2);
      expect(tv.pointerFrames, ['type:move\ndx:2\ndy:2\n\n', 'type:click\n\n']);
    });

    test('a click behind a move the queue cap evicted is dropped', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 200)));
      addTearDown(session.close);

      // Alternating kinds so nothing folds; 200 fills the queue.
      for (var i = 0; i < 100; i++) {
        session.move(1, 0);
        session.scroll(0, 1);
      }
      session.click();

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 199);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames.where((f) => f.startsWith('type:click')), isEmpty);
    });

    test('the queue cap never evicts a key press while other input is queued', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 200)));
      addTearDown(session.close);

      session.sendKey('UP');
      for (var i = 0; i < 250; i++) {
        session.click();
      }

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 200);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames.first, 'type:button\nname:UP\n\n');
      expect(tv.pointerFrames.length, 200);
    });

    test('a folded move is as fresh as its newest part', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 200)),
          staleAfter: const Duration(milliseconds: 300));
      addTearDown(session.close);

      session.move(1, 0);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      session.move(1, 0);

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.isNotEmpty);
      expect(tv.pointerFrames, ['type:move\ndx:2\ndy:0\n\n']);
    });

    test('only the newest queued repeat of a hold is sent, and none after the hold ended', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 200)));
      addTearDown(session.close);

      final held = Object();
      final released = Object();
      session.sendKey('UP');
      for (var i = 0; i < 6; i++) {
        session.sendKey('UP', hold: held);
        session.sendKey('DOWN', hold: released);
      }
      session.dropRepeats(released);

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames, ['type:button\nname:UP\n\n', 'type:button\nname:UP\n\n']);
    });

    test('a stale queued repeat is dropped', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 250)),
          staleAfter: const Duration(milliseconds: 100));
      addTearDown(session.close);

      session.sendKey('UP', hold: Object());
      expect(await session.waitUntilReady(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames, isEmpty);
    });

    test('sendKey reports whether a session can still take the key', () async {
      final live = PointerSession('127.0.0.1', await _prefs(), connector: tv.connector());
      addTearDown(live.close);
      expect(live.sendKey('UP'), isTrue);
      expect(await live.waitUntilReady(), isTrue);
      expect(live.sendKey('UP'), isTrue);

      final dead = PointerSession('127.0.0.1', await _prefs(),
          connector: (_) => Future<WebSocket>.error(const SocketException('refused')));
      expect(await dead.waitUntilReady(), isFalse);
      expect(dead.sendKey('UP'), isFalse);
      expect(dead.retired, isFalse);

      live.close();
      expect(live.sendKey('UP'), isFalse);
      expect(live.retired, isTrue);
    });

    test('a key press queued through a handshake slower than staleAfter is still delivered', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        return PointerSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 250)),
            staleAfter: const Duration(milliseconds: 100));
      });
      addTearDown(client.resetConnection);

      expect(await client.pressKey('ENTER'), isA<Success>());
      await _until(() => _buttons(tv).length == 1);
      expect(_buttons(tv), ['type:button\nname:ENTER\n\n']);
    });

    test('the repeats of a released hold are discarded by the client', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        return PointerSession(ip, p, connector: tv.connector(delay: const Duration(milliseconds: 200)));
      });
      addTearDown(client.resetConnection);

      final hold = Object();
      final first = client.pressKey('LEFT');
      final repeats = [for (var i = 0; i < 5; i++) client.pressKey('LEFT', hold: hold)];
      client.endHold(hold);

      expect(await first, isA<Success>());
      await Future.wait(repeats);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(_buttons(tv), ['type:button\nname:LEFT\n\n']);
    });

    test('a session that opens after its handshake timeout never sends the queued key', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 200)),
          handshakeTimeout: const Duration(milliseconds: 150));
      addTearDown(session.close);

      session.sendKey('UP');
      expect(await session.waitUntilReady(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(tv.pointerFrames, isEmpty);
      expect(tv.pointerConnections, 0);
    });

    test('the default handshake timeout matches the press timeout', () {
      expect(PointerSession.defaultHandshakeTimeout, const Duration(seconds: 6));
    });

    test('after a failed handshake the client hands back the dead session until the backoff ends', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: const Duration(milliseconds: 250),
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: (_) => Future<WebSocket>.error(const SocketException('refused')));
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);
      for (var i = 0; i < 5; i++) {
        final s = client.pointerSession();
        expect(s, same(first));
        s.move(1, 1);
      }
      expect(created, 1);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.pointerSession(), isNot(same(first)));
      expect(created, 2);
    });

    test('a key pressed inside the cooldown waits it out and connects once', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: const Duration(milliseconds: 250),
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: created == 1
                ? (_) => Future<WebSocket>.error(const SocketException('refused'))
                : tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);

      final watch = Stopwatch()..start();
      expect(await client.pressKey('UP'), isA<Success>());
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(150));
      expect(created, 2);
      await _until(() => _buttons(tv).length == 1);
    });

    test('a key pressed inside the cooldown of a TV that stays down times out after one retry', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: const Duration(milliseconds: 100),
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p,
            connector: (_) => Future<WebSocket>.error(const SocketException('refused')));
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);
      expect(await client.pressKey('UP'), isA<CmdError>());
      expect(created, 2);
    });

    test('an established pointer session that dropped is replaced without waiting', () async {
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: const Duration(seconds: 30),
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      expect(await first.waitUntilReady(), isTrue);
      await _until(() => tv.pointerConnections == 1);
      tv.dropPointerSockets();
      await _until(() => !first.isAlive);
      expect(client.pointerSession(), isNot(same(first)));
      expect(created, 2);
    });

    test('the command session dying drops the shared pointer session', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs,
          pointerSessionFactory: (ip, p) => PointerSession(ip, p, connector: tv.connector()),
          commandSessionFactory: (ip, p) => CommandSession(ip, p,
              connector: (_) => Future<WebSocket>.error(const SocketException('gone'))));
      addTearDown(client.resetConnection);

      final pointer = client.pointerSession();
      expect(await pointer.waitUntilReady(), isTrue);
      expect(pointer.isUsable, isTrue);

      expect(await client.getVolume(), isNull);
      await _until(() => pointer.state == PointerState.dead);
      expect(client.pointerSession(), isNot(same(pointer)));
    });
  });

  group('late replies after a TV switch', () {
    test('a command session registering after the address changed leaves key and MACs alone', () async {
      final prefs = await _prefs(clientKey: null);
      final session = CommandSession('127.0.0.1', prefs,
          connector: tv.connector(delay: const Duration(milliseconds: 150)));
      addTearDown(session.close);

      await prefs.setTvIp('10.0.0.9');
      await session.awaitReady(timeout: const Duration(seconds: 3));
      expect(session.state, CmdState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(prefs.clientKey, isNull);
      expect(prefs.tvMac, isEmpty);
    });

    test('the same session stores key and MAC while the address still matches', () async {
      final prefs = await _prefs(clientKey: null);
      final session = CommandSession('127.0.0.1', prefs, connector: tv.connector());
      addTearDown(session.close);

      await session.awaitReady(timeout: const Duration(seconds: 3));
      await _until(() => prefs.tvMac.isNotEmpty);
      expect(prefs.clientKey, 'key');
      expect(prefs.tvMac, 'AA:BB:CC:DD:EE:FF');
    });

    test('a pointer session registering after the address changed keeps the new TV key', () async {
      final prefs = await _prefs(clientKey: 'old');
      final session = PointerSession('127.0.0.1', prefs,
          connector: tv.connector(delay: const Duration(milliseconds: 150)));
      addTearDown(session.close);

      await prefs.setTvIp('10.0.0.9');
      await session.waitUntilReady();
      await _until(() => tv.registerCount == 1);
      expect(prefs.clientKey, 'old');
    });
  });

  group('pairing prompts', () {
    test('without a client key the pointer never connects and the client stops retrying', () async {
      final prefs = await _prefs(clientKey: null);
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      expect(first.state, PointerState.dead);
      expect(first.pairingStillMissing, isTrue);
      for (var i = 0; i < 5; i++) {
        expect(client.pointerSession(), same(first));
      }
      expect(await client.pressKey('UP'), isA<NeedsPairing>());
      expect(created, 1);
      expect(tv.controlConnections, 0);

      await prefs.setClientKey('paired');
      final next = client.pointerSession();
      expect(next, isNot(same(first)));
      expect(created, 2);
      expect(await next.waitUntilReady(), isTrue);
    });

    test('a pairing challenge fails the pointer once and is not retried until the key changes', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'stale');
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);
      expect(first.pairingStillMissing, isTrue);
      for (var i = 0; i < 5; i++) {
        expect(client.pointerSession(), same(first));
      }
      expect(await client.pressKey('UP'), isA<NeedsPairing>());
      expect(created, 1);
      expect(tv.registerCount, 1);

      await prefs.setClientKey('fresh');
      expect(client.pointerSession(), isNot(same(first)));
      expect(created, 2);
    });

    test('a command session that registered after the failure lifts the backoff', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'stale');
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pointerSessionFactory: (ip, p) => PointerSession(ip, p, connector: tv.connector()),
          commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);

      tv.challengePairing = false;
      expect(await client.getVolume(), isNotNull);
      expect(client.pointerSession(), isNot(same(first)));
    });
  });

  group('command session churn', () {
    test('a pointer still connecting survives the command session being replaced', () async {
      final prefs = await _prefs();
      var commands = 0;
      final client = WebOsClient(prefs,
          pointerSessionFactory: (ip, p) => PointerSession(ip, p,
              connector: tv.connector(delay: const Duration(milliseconds: 300))),
          commandSessionFactory: (ip, p) => commands++ == 0
              ? CommandSession(ip, p,
                  connector: (_) => Completer<WebSocket>().future,
                  connectGrace: const Duration(milliseconds: 50))
              : CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final stuck = client.getVolume();
      final pointer = client.pointerSession();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(await client.getVolume(), isNotNull);
      await stuck;
      expect(client.pointerSession(), same(pointer));
      expect(await pointer.waitUntilReady(), isTrue);
    });

    test('a pointer still connecting survives the command session dying', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs,
          pointerSessionFactory: (ip, p) => PointerSession(ip, p,
              connector: tv.connector(delay: const Duration(milliseconds: 300))),
          commandSessionFactory: (ip, p) => CommandSession(ip, p,
              connector: (_) => Future<WebSocket>.error(const SocketException('gone'))));
      addTearDown(client.resetConnection);

      final pointer = client.pointerSession();
      expect(await client.getVolume(), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(pointer.state, PointerState.connecting);
      expect(client.pointerSession(), same(pointer));
      expect(await pointer.waitUntilReady(), isTrue);
    });

    test('a pointer past its connect grace is replaced when the command session is', () async {
      final prefs = await _prefs();
      var commands = 0;
      var pointers = 0;
      final client = WebOsClient(prefs,
          pointerSessionFactory: (ip, p) {
            pointers++;
            return PointerSession(ip, p,
                connector: (_) => Completer<WebSocket>().future,
                connectGrace: const Duration(milliseconds: 50));
          },
          commandSessionFactory: (ip, p) => commands++ == 0
              ? CommandSession(ip, p,
                  connector: (_) => Completer<WebSocket>().future,
                  connectGrace: const Duration(milliseconds: 50))
              : CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final stuck = client.getVolume();
      final pointer = client.pointerSession();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pointer.isUsable, isFalse);

      expect(await client.getVolume(), isNotNull);
      await stuck;
      expect(pointer.state, PointerState.dead);
      expect(client.pointerSession(), isNot(same(pointer)));
      expect(pointers, 2);
    });

    test('a replaced command session dying later does not drop the new pointer session', () async {
      final prefs = await _prefs();
      var commands = 0;
      final client = WebOsClient(prefs,
          pointerSessionFactory: (ip, p) => PointerSession(ip, p, connector: tv.connector()),
          commandSessionFactory: (ip, p) => commands++ == 0
              ? CommandSession(ip, p,
                  connector: (_) => Completer<WebSocket>().future,
                  connectGrace: const Duration(milliseconds: 50))
              : CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final stuck = client.getVolume();
      final pointer = client.pointerSession();
      expect(await pointer.waitUntilReady(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Replacing the stuck session closes it; its death notification runs
      // afterwards and must not count as the live command session dying.
      expect(await client.getVolume(), isNotNull);
      await stuck;
      await Future<void>.delayed(Duration.zero);

      expect(pointer.isAlive, isTrue);
      expect(client.pointerSession(), same(pointer));
    });
  });

  group('pairing errors and expiry', () {
    test('an error for the registration is an ordinary failure, not a pairing block', () async {
      tv.rejectRegistration = true;
      final prefs = await _prefs();
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);
      expect(first.pairingStillMissing, isFalse);
      expect(client.pointerSession(), isNot(same(first)));
      expect(created, 2);

      expect(await client.pressKey('UP'), isA<CmdError>());
      expect(tv.registerCount, greaterThanOrEqualTo(2));
    });

    test('a pairing block lifts by itself after pairingBlockExpiry', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'stale');
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pairingBlockExpiry: const Duration(milliseconds: 150),
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      });
      addTearDown(client.resetConnection);

      final first = client.pointerSession();
      await _until(() => first.state == PointerState.dead);
      expect(client.pointerSession(), same(first));

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(client.pointerSession(), isNot(same(first)));
      expect(created, 2);
    });

    test('while the command socket shows the prompt the pointer never registers', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'stale');
      var created = 0;
      final client = WebOsClient(prefs,
          pointerRetryBackoff: Duration.zero,
          pointerSessionFactory: (ip, p) {
        created++;
        return PointerSession(ip, p, connector: tv.connector());
      },
          commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      expect(await client.getVolume(), isNull);
      expect(tv.registerCount, 1);

      final blocked = client.pointerSession();
      expect(blocked.state, PointerState.dead);
      expect(blocked.pairingStillMissing, isTrue);
      expect(await client.pressKey('UP'), isA<NeedsPairing>());
      expect(client.pointerSession(), same(blocked));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(created, 0);
      expect(tv.registerCount, 1);

      // The user accepts: the command session registers and stores the key.
      tv.challengePairing = false;
      tv.pushRegistered();
      await _until(() => prefs.clientKey == 'late-key');
      final next = client.pointerSession();
      expect(next, isNot(same(blocked)));
      expect(created, 1);
      expect(await next.waitUntilReady(), isTrue);
    });
  });

  group('command session pairing denial', () {
    test('a denied prompt ends the session instead of leaving it waiting for the prompt', () async {
      tv.challengePairing = true;
      tv.denyAfterChallenge = true;
      final session = CommandSession('127.0.0.1', await _prefs(clientKey: 'stale'),
          connector: tv.connector());
      addTearDown(session.close);

      await _until(() => session.state == CmdState.dead);
      expect(session.pairingRejected, isTrue);
      expect(session.deadReason, contains('denied'));
      expect(session.isUsable, isFalse);
      expect(await session.send('ssap://audio/getVolume'), isA<CmdReplyErr>());
      await _until(() => tv.openControlSockets == 0);
    });

    test('the power watcher shows pairing and does not ask again straight away', () async {
      tv.challengePairing = true;
      tv.denyAfterChallenge = true;
      final prefs = await _prefs(clientKey: 'stale');
      final client = WebOsClient(prefs,
          commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final events = <Presence>[];
      final stop = client.watchPower(events.add);
      addTearDown(stop);

      await _until(() => events.any((e) => e is PresenceNeedsPairing));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(tv.registerCount, 1);
      expect(events.whereType<PresenceUnreachable>(), isEmpty);
    });
  });

  group('power watching', () {
    test('a slow command connect within its grace is not reported unreachable', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs,
          watchReadyWait: const Duration(milliseconds: 80),
          commandSessionFactory: (ip, p) => CommandSession(ip, p,
              connector: tv.connector(delay: const Duration(milliseconds: 400))));
      addTearDown(client.resetConnection);

      final events = <Presence>[];
      final stop = client.watchPower(events.add);
      addTearDown(stop);

      await _until(() => events.any((e) => e is PresenceReported));
      expect(events.whereType<PresenceUnreachable>(), isEmpty);
    });

    test('a connect that outlives its grace is reported unreachable', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs,
          watchReadyWait: const Duration(milliseconds: 80),
          commandSessionFactory: (ip, p) => CommandSession(ip, p,
              connector: (_) => Completer<WebSocket>().future,
              connectGrace: const Duration(milliseconds: 200)));
      addTearDown(client.resetConnection);

      final events = <Presence>[];
      final stop = client.watchPower(events.add);
      addTearDown(stop);

      await _until(() => events.any((e) => e is PresenceUnreachable));
    });

    test('a power update with a state is reported as that state', () async {
      final client = WebOsClient(await _prefs(),
          commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()));
      addTearDown(client.resetConnection);

      final events = <Presence>[];
      final stop = client.watchPower(events.add);
      addTearDown(stop);

      await _until(() => events.isNotEmpty);
      expect(events.first, isA<PresenceReported>());
      expect((events.first as PresenceReported).isOn, isTrue);
    });

    test('a failed or empty power update is unknown, never "on"', () async {
      for (final reply in [
        {'type': 'error', 'payload': {'errorText': 'nope'}},
        {'type': 'response', 'payload': {'returnValue': false}},
        {'type': 'response', 'payload': {'returnValue': true, 'state': ''}},
      ]) {
        tv.subscribeReply = reply;
        final client = WebOsClient(await _prefs(),
            commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()));

        final events = <Presence>[];
        final stop = client.watchPower(events.add);
        await _until(() => events.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        stop();
        client.resetConnection();

        expect(events, everyElement(isA<PresenceUnknown>()), reason: '$reply');
      }
    });
  });

  group('socket helpers', () {
    test('a connect that finishes after its timeout is closed instead of left open', () async {
      final attempt = connectWithTimeout(
        tv.connector(delay: const Duration(milliseconds: 200)),
        'wss://127.0.0.1:3001',
        const Duration(milliseconds: 50),
      );
      await expectLater(attempt, throwsA(isA<TimeoutException>()));

      await _until(() => tv.controlConnections == 1);
      await _until(() => tv.openControlSockets == 0);
    });

    test('a malformed reply during the pointer handshake is ignored without an unhandled error', () async {
      tv.registerReply = (id) => jsonEncode({'type': 'response', 'id': id, 'payload': 'oops'});
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(), handshakeTimeout: const Duration(milliseconds: 250));
      addTearDown(session.close);

      expect(await session.waitUntilReady(), isFalse);
      expect(session.state, PointerState.dead);
    });
  });

  group('PairingWatcher', () {
    test('stopping ends the attempt in flight and nothing is saved afterwards', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'old');
      var prompts = 0;
      var paired = 0;
      final stop = PairingWatcher(prefs, connector: tv.connector()).watch(
        '127.0.0.1',
        onPromptShown: () => prompts++,
        onPaired: (_) => paired++,
      );

      await _until(() => prompts == 1);
      expect(tv.openControlSockets, 1);
      stop();
      await _until(() => tv.openControlSockets == 0);

      tv.pushRegistered();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(paired, 0);
      expect(prefs.clientKey, 'old');
      expect(tv.controlConnections, 1);
    });

    test('a pairing that completes while watching still saves the key', () async {
      tv.challengePairing = true;
      final prefs = await _prefs(clientKey: 'old');
      var prompts = 0;
      String? pairedKey;
      final stop = PairingWatcher(prefs, connector: tv.connector()).watch(
        '127.0.0.1',
        onPromptShown: () => prompts++,
        onPaired: (k) => pairedKey = k,
      );
      addTearDown(stop);

      await _until(() => prompts == 1);
      tv.pushRegistered();
      await _until(() => pairedKey != null);
      expect(pairedKey, 'late-key');
      expect(prefs.clientKey, 'late-key');
    });
  });
}
