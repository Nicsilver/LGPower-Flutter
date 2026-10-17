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
  final pointerFrames = <String>[];
  final _pointerSockets = <WebSocket>[];

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
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        switch (msg['type']) {
          case 'register':
            registerCount++;
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
    test('a reset mid-connect drops queued keys instead of flushing them late', () async {
      final prefs = await _prefs();
      final client = WebOsClient(prefs, pointerSessionFactory: (ip, p) {
        return PointerSession(ip, p,
            connector: tv.connector(delay: const Duration(milliseconds: 150)));
      });
      addTearDown(client.resetConnection);

      final presses = [client.pressKey('VOLUMEUP'), client.pressKey('VOLUMEUP')];
      client.resetConnection();

      expect(await Future.wait(presses), everyElement(isA<CmdError>()));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(tv.pointerConnections, 0);
      expect(_buttons(tv), isEmpty);
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
    test('input queued longer than staleAfter is not flushed, fresh input and clicks are', () async {
      final session = PointerSession('127.0.0.1', await _prefs(),
          connector: tv.connector(delay: const Duration(milliseconds: 250)),
          staleAfter: const Duration(milliseconds: 300));
      addTearDown(session.close);

      session.sendKey('UP');
      session.move(5, 5);
      session.click();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      session.sendKey('DOWN');

      expect(await session.waitUntilReady(), isTrue);
      await _until(() => tv.pointerFrames.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.pointerFrames, ['type:click\n\n', 'type:button\nname:DOWN\n\n']);
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
      expect(await client.pressKey('UP'), isA<CmdError>());
      expect(created, 1);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.pointerSession(), isNot(same(first)));
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
}
