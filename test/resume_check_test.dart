// The resume check: pure decision pieces on a fake clock, then the client
// against an in-process fake TV that speaks plain ws:// (no TLS) and can go
// silent on the sockets it already has open.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/pointer_session.dart';
import 'package:lgpower/net/resume_check.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/net/ws_connect.dart';

const _powerState = 'ssap://com.webos.service.tvpower/power/getPowerState';

void main() {
  group('decision', () {
    test('a socket that is not registered is reset', () {
      expect(resumeStep(commandReady: false), ResumeStep.reset);
    });

    // Frames buffered while the app was frozen can look like fresh traffic, so
    // only a reply counts.
    test('a registered socket is always asked first', () {
      expect(resumeStep(commandReady: true), ResumeStep.probe);
    });

    test('an idle pointer is replaced but a dead or busy one is not', () {
      const max = Duration(seconds: 30);
      bool replace(bool dead, int idleMs) => shouldReplaceIdlePointer(
          dead: dead, idle: Duration(milliseconds: idleMs), maxIdle: max);
      expect(replace(false, 30001), isTrue);
      expect(replace(false, 30000), isFalse);
      expect(replace(false, 5000), isFalse);
      expect(replace(true, 600000), isFalse);
    });

    test('only the pointer the check saw is dropped', () {
      final seen = Object();
      final openedMeanwhile = Object();
      expect(sameSession(seen, seen), isTrue);
      expect(sameSession(openedMeanwhile, seen), isFalse);
      expect(sameSession(openedMeanwhile, null), isFalse);
    });
  });

  group('awaitReply', () {
    test('a reply before the budget counts', () {
      fakeAsync((async) {
        final answered = Completer<void>();
        final died = Completer<void>();
        bool? result;
        awaitReply(answered: answered.future, died: died.future, max: const Duration(seconds: 1))
            .then((v) => result = v);
        async.elapse(const Duration(milliseconds: 400));
        answered.complete();
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });

    test('a reply after the budget does not', () {
      fakeAsync((async) {
        final answered = Completer<void>();
        bool? result;
        awaitReply(
                answered: answered.future,
                died: Completer<void>().future,
                max: const Duration(seconds: 1))
            .then((v) => result = v);
        async.elapse(const Duration(milliseconds: 1001));
        expect(result, isFalse);
        answered.complete();
        async.flushMicrotasks();
        expect(result, isFalse);
      });
    });

    test('a socket that dies mid-probe ends the wait at the death, not the budget', () {
      fakeAsync((async) {
        final died = Completer<void>();
        bool? result;
        awaitReply(
                answered: Completer<void>().future,
                died: died.future,
                max: const Duration(seconds: 10))
            .then((v) => result = v);
        async.elapse(const Duration(milliseconds: 300));
        expect(result, isNull);
        died.complete();
        async.flushMicrotasks();
        expect(result, isFalse);
        expect(async.elapsed, const Duration(milliseconds: 300));
      });
    });

    test('a reply that landed just before the death still counts', () {
      fakeAsync((async) {
        final answered = Completer<void>();
        final died = Completer<void>();
        bool? result;
        awaitReply(answered: answered.future, died: died.future, max: const Duration(seconds: 1))
            .then((v) => result = v);
        answered.complete();
        died.complete();
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });
  });

  group('probeCommand', () {
    test('the stale mark is set before the probe runs', () async {
      var mark = false;
      var markedWhileProbing = false;
      await probeCommand(markStale: (v) => mark = v, probe: () async {
        markedWhileProbing = mark;
        return false;
      });
      expect(markedWhileProbing, isTrue);
      expect(mark, isTrue, reason: 'a silent socket stays marked');
    });

    test('only a reply clears the mark', () async {
      var mark = false;
      expect(await probeCommand(markStale: (v) => mark = v, probe: () async => true), isTrue);
      expect(mark, isFalse);
    });

    test('a socket that resets mid-probe keeps the mark for the watcher', () async {
      final marks = <bool>[];
      var seenByWatcher = false;
      var mark = false;
      await probeCommand(
        markStale: (v) {
          mark = v;
          marks.add(v);
        },
        probe: () async {
          seenByWatcher = mark;
          return false;
        },
      );
      expect(seenByWatcher, isTrue);
      expect(marks, [true]);
    });
  });

  group('ResumeGate', () {
    test('an open gate does not hold anyone', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        var done = false;
        gate.wait(const Duration(seconds: 60)).then((_) => done = true);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(gate.isOpen, isTrue);
      });
    });

    test('a key waits for the verdict and goes on right after it', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        final check = gate.begin();
        expect(gate.isOpen, isFalse);
        var released = false;
        gate.wait(const Duration(seconds: 5)).then((_) => released = true);
        async.elapse(const Duration(seconds: 1));
        expect(released, isFalse);
        gate.end(check);
        async.flushMicrotasks();
        expect(released, isTrue);
        expect(gate.isOpen, isTrue);
      });
    });

    test('a stuck check holds a key only for its budget', () {
      fakeAsync((async) {
        final gate = ResumeGate()..begin();
        var released = false;
        gate.wait(const Duration(milliseconds: 1500)).then((_) => released = true);
        async.elapse(const Duration(milliseconds: 1499));
        expect(released, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(released, isTrue);
      });
    });

    test('an older check ending leaves a newer one closed', () {
      final gate = ResumeGate();
      final first = gate.begin();
      final second = gate.begin();
      gate.end(first);
      expect(gate.isOpen, isFalse);
      gate.end(second);
      expect(gate.isOpen, isTrue);
    });

    test('a held tap goes out once after the verdict and never before', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        final check = gate.begin();
        var sent = 0;
        gate.runAfter(const Duration(seconds: 60), () => sent++);
        async.elapse(const Duration(seconds: 5));
        expect(sent, 0);
        gate.end(check);
        async.flushMicrotasks();
        expect(sent, 1);
        async.elapse(const Duration(seconds: 120));
        expect(sent, 1);
      });
    });

    test('a tap on an open gate goes out at once, inside the call', () {
      var sent = 0;
      ResumeGate().runAfter(const Duration(seconds: 1), () => sent++);
      expect(sent, 1);
    });

    test('a tap on a stuck gate goes out when its budget runs out', () {
      fakeAsync((async) {
        final gate = ResumeGate()..begin();
        var sent = 0;
        gate.runAfter(const Duration(milliseconds: 1500), () => sent++);
        async.elapse(const Duration(milliseconds: 1499));
        expect(sent, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(sent, 1);
      });
    });

    test('taps held on the gate leave in the order they were made', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        final check = gate.begin();
        final order = <int>[];
        for (var i = 1; i <= 20; i++) {
          gate.runAfter(const Duration(seconds: 60), () => order.add(i));
        }
        gate.end(check);
        async.flushMicrotasks();
        expect(order, List.generate(20, (i) => i + 1));
      });
    });

    test('a tap made as the gate opens does not overtake the ones still queued', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        final check = gate.begin();
        final order = <String>[];
        gate.runAfter(const Duration(seconds: 60), () => order.add('back'));
        gate.end(check);
        gate.runAfter(const Duration(seconds: 60), () => order.add('click'));
        async.flushMicrotasks();
        expect(order, ['back', 'click']);
      });
    });

    test('a send that throws does not stop the taps behind it', () {
      fakeAsync((async) {
        final gate = ResumeGate();
        final check = gate.begin();
        var second = 0;
        final errors = <Object>[];
        runZonedGuarded(() {
          gate.runAfter(const Duration(seconds: 60), () => throw StateError('boom'));
          gate.runAfter(const Duration(seconds: 60), () => second++);
          gate.end(check);
          async.flushMicrotasks();
        }, (e, _) => errors.add(e));
        expect(second, 1);
        expect(errors, hasLength(1));
      });
    });
  });

  group('client', () {
    late _Tv tv;
    setUp(() async {
      tv = _Tv();
      await tv.start();
    });
    tearDown(() => tv.stop());

    Future<_Rig> rig({
      Duration pointerIdle = const Duration(seconds: 30),
      Duration probe = const Duration(milliseconds: 300),
      Duration keepAfterInput = PointerSession.defaultKeepAfterInput,
    }) async {
      final prefs = await _prefs();
      final r = _Rig(tv, prefs, pointerIdle, probe, keepAfterInput);
      addTearDown(r.client.resetConnection);
      return r;
    }

    test('a command socket that is still connecting is reset, not probed', () async {
      tv.registerDelay = const Duration(seconds: 3);
      final r = await rig();
      final first = r.client.diagnosticSession();
      expect(first.state, CmdState.connecting);
      await r.client.resumeConnection();
      expect(first.state, CmdState.dead);
      expect(tv.requests.where((q) => q.uri == _powerState), isEmpty);
    });

    test('a session for another TV is reset, not probed', () async {
      final r = await rig();
      final first = r.client.diagnosticSession();
      await first.awaitReady();
      await r.prefs.setTvIp('127.0.0.2');
      await r.client.resumeConnection();
      expect(first.state, CmdState.dead);
      expect(tv.requests.where((q) => q.uri == _powerState), isEmpty);
    });

    test('a socket that answers is kept, with the pointer beside it', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      final registers = tv.registerCount;

      final check = r.client.resumeConnection();
      expect(cmd.replacedAsStale, isTrue, reason: 'marked before the probe');
      await check;

      expect(tv.requests.where((q) => q.uri == _powerState), hasLength(1));
      expect(cmd.replacedAsStale, isFalse);
      expect(identical(r.client.diagnosticSession(), cmd), isTrue);
      expect(identical(r.client.pointerSession(), ptr), isTrue);
      expect(tv.registerCount, registers);
    });

    test('a pointer idle past the limit is replaced while the command socket stays', () async {
      final r = await rig(pointerIdle: const Duration(milliseconds: 40), keepAfterInput: const Duration(milliseconds: 10));
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final check = r.client.resumeConnection();
      final fresh = r.client.pointerSession();
      expect(identical(fresh, ptr), isFalse, reason: 'swapped before the probe even ran');
      expect(ptr.retired, isTrue);
      await check;
      expect(identical(r.client.diagnosticSession(), cmd), isTrue);
      expect(identical(r.client.pointerSession(), fresh), isTrue);
    });

    test('a dead pointer stays put, it carries the retry pause', () async {
      final r = await rig(pointerIdle: const Duration(milliseconds: 40), keepAfterInput: const Duration(milliseconds: 10));
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      await _until(() => tv.hasPointerSocket);
      tv.dropPointerSockets();
      await _until(() => ptr.isDead);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final created = r.pointers.length;

      await r.client.resumeConnection();
      expect(r.pointers.length, created);
    });

    test('a silent socket is closed and both sessions are warmed fresh', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      expect(cmd.replacedAsStale, isTrue);
      await check;

      expect(cmd.state, CmdState.dead);
      expect(cmd.replacedAsStale, isTrue);
      expect(ptr.retired, isTrue);
      final freshCmd = r.client.diagnosticSession();
      expect(identical(freshCmd, cmd), isFalse);
      await freshCmd.awaitReady();
      expect(freshCmd.state, CmdState.ready);
      expect(identical(r.client.pointerSession(), ptr), isFalse);
    });

    test('a reply after the budget is too late', () async {
      tv.powerStateDelay = const Duration(milliseconds: 700);
      final r = await rig(probe: const Duration(milliseconds: 150));
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      await r.client.resumeConnection();
      expect(cmd.state, CmdState.dead);
      expect(cmd.replacedAsStale, isTrue);
    });

    test('a socket that dies mid-probe ends the check at the death', () async {
      final r = await rig(probe: const Duration(seconds: 8));
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      tv.goSilent();
      Timer(const Duration(milliseconds: 60), tv.dropControlSockets);
      final watch = Stopwatch()..start();
      await r.client.resumeConnection();
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(cmd.replacedAsStale, isTrue, reason: 'the watcher must not read the reset as standby');
      expect(identical(r.client.diagnosticSession(), cmd), isFalse);
    });

    test('replacing a silent socket drops only the pointer the check saw', () async {
      final r = await rig(pointerIdle: const Duration(milliseconds: 40), keepAfterInput: const Duration(milliseconds: 10));
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final seen = r.client.pointerSession();
      expect(await seen.waitUntilReady(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      tv.goSilent();

      final check = r.client.resumeConnection();
      final openedMeanwhile = r.client.pointerSession();
      expect(identical(openedMeanwhile, seen), isFalse);
      await check;

      expect(seen.retired, isTrue);
      expect(openedMeanwhile.retired, isFalse);
      expect(identical(r.client.pointerSession(), openedMeanwhile), isTrue);
    });

    test('a pointer that carried input a moment ago is still dropped with a silent socket', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      expect(ptr.inUse, isTrue);
      tv.goSilent();
      await r.client.resumeConnection();
      expect(ptr.retired, isTrue);
    });

    test('a key waits for the verdict and goes out on the replacement pointer', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      final press = r.client.pressKey('ENTER');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tv.buttons, isEmpty, reason: 'held while the probe is out');
      await check;
      expect(await press, isA<Success>());
      await _until(() => tv.buttons.isNotEmpty);
      expect(tv.buttons, ['ENTER']);
      expect(ptr.retired, isTrue);
    });

    test('keys pressed during the check keep their order', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      final presses = [for (final k in ['UP', 'DOWN', 'LEFT', 'RIGHT']) r.client.pressKey(k)];
      await check;
      await Future.wait(presses);
      await _until(() => tv.buttons.length == 4);
      expect(tv.buttons, ['UP', 'DOWN', 'LEFT', 'RIGHT']);
    });

    test('a held repeat does not overtake earlier one-shot presses at the gate', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      final h = Object();
      final presses = [
        r.client.pressKey('UP'),
        r.client.pressKey('RIGHT', hold: h),
        r.client.pressKey('RIGHT', hold: h),
      ];
      await check;
      await Future.wait(presses);
      await _until(() => tv.buttons.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Only the newest repeat of a hold is written
      expect(tv.buttons, ['UP', 'RIGHT']);
    });

    test('a repeat whose key was released while it waited never fires', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      final hold = Object();
      final repeat = r.client.pressKey('DOWN', hold: hold);
      r.client.endHold(hold);
      await check;
      expect(await repeat, isA<CmdError>());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.buttons, isEmpty);
    });

    test('a command request waits for the verdict and goes out on the replacement socket', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      tv.goSilent();

      final check = r.client.resumeConnection();
      final off = r.client.turnOff();
      await check;
      expect(await off, isA<Success>());
      final turnOff = tv.requests.singleWhere((q) => q.uri == 'ssap://system/turnOff');
      expect(turnOff.silent, isFalse, reason: 'it must not have been written to the dead socket');
    });

    test('a luna request waits for the verdict too', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      tv.goSilent();

      final check = r.client.resumeConnection();
      final luna = r.client.setLunaForTest();
      await check;
      await luna;
      final alerts =
          tv.requests.where((q) => q.uri == 'ssap://system.notifications/createAlert').toList();
      expect(alerts, isNotEmpty);
      expect(alerts.any((q) => q.silent), isFalse);
    });

    test('a pointer click and a BACK held on the gate go out in order on the new pointer', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      tv.goSilent();

      final check = r.client.resumeConnection();
      r.client.pointerKey('BACK');
      r.client.pointerClick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tv.pointerFrames, isEmpty);
      await check;
      await _until(() => tv.pointerFrames.length >= 2);
      expect(tv.pointerFrames.map((f) => f.contains('name:BACK') ? 'BACK' : 'click').toList(),
          ['BACK', 'click']);
      expect(ptr.retired, isTrue);
    });

    test('a click on an open gate is sent without waiting', () async {
      final r = await rig();
      final cmd = r.client.diagnosticSession();
      await cmd.awaitReady();
      final ptr = r.client.pointerSession();
      expect(await ptr.waitUntilReady(), isTrue);
      await r.client.resumeConnection();
      r.client.pointerClick();
      await _until(() => tv.pointerFrames.isNotEmpty);
      expect(tv.pointerFrames.single, contains('type:click'));
    });
  });
}

class _Rig {
  _Rig(this.tv, this.prefs, Duration pointerIdle, Duration probe, Duration keepAfterInput) {
    client = WebOsClient(
      prefs,
      resumeProbe: probe,
      resumePointerIdle: pointerIdle,
      commandSessionFactory: (ip, p) => CommandSession(ip, p, connector: tv.connector()),
      pointerSessionFactory: (ip, p) {
        final s = PointerSession(ip, p, connector: tv.connector(), keepAfterInput: keepAfterInput);
        pointers.add(s);
        return s;
      },
    );
  }

  final _Tv tv;
  final Prefs prefs;
  late final WebOsClient client;
  final pointers = <PointerSession>[];
}

class _Request {
  _Request(this.uri, this.silent);
  final String uri;

  /// Written to a socket the TV had gone silent on.
  final bool silent;
}

class _Tv {
  late HttpServer _server;
  int registerCount = 0;
  Duration registerDelay = Duration.zero;
  Duration powerStateDelay = Duration.zero;
  final requests = <_Request>[];
  final pointerFrames = <String>[];
  final _controlSockets = <WebSocket>[];
  final _pointerSockets = <WebSocket>[];
  final _silent = <WebSocket>{};

  List<String> get buttons => [
        for (final f in pointerFrames)
          if (f.startsWith('type:button')) f.split('\n')[1].substring('name:'.length),
      ];

  bool get hasPointerSocket => _pointerSockets.isNotEmpty;

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      if (req.uri.path == '/pointer') {
        _pointerSockets.add(ws);
        ws.listen((m) => pointerFrames.add(m as String));
        return;
      }
      _controlSockets.add(ws);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        void reply(Map<String, dynamic> m, [Duration delay = Duration.zero]) {
          void send() {
            try {
              ws.add(jsonEncode({...m, 'id': id}));
            } catch (_) {}
          }

          delay > Duration.zero ? Timer(delay, send) : send();
        }

        switch (msg['type']) {
          case 'register':
            registerCount++;
            reply({
              'type': 'registered',
              'payload': {'client-key': 'key'},
            }, registerDelay);
          case 'subscribe':
            reply({
              'type': 'response',
              'payload': {'returnValue': true, 'state': 'Active'},
            });
          case 'request':
            final uri = msg['uri'] as String;
            final silent = _silent.contains(ws);
            requests.add(_Request(uri, silent));
            if (silent) return;
            final payload = uri == 'ssap://com.webos.service.networkinput/getPointerInputSocket'
                ? {'returnValue': true, 'socketPath': 'wss://127.0.0.1:3001/pointer'}
                : {'returnValue': true};
            reply({'type': 'response', 'payload': payload},
                uri == _powerState ? powerStateDelay : Duration.zero);
        }
      });
    });
  }

  /// Every control socket open now stops answering requests.
  void goSilent() => _silent.addAll(_controlSockets);

  void dropControlSockets() {
    for (final s in _controlSockets) {
      s.close();
    }
    _controlSockets.clear();
  }

  void dropPointerSockets() {
    for (final s in _pointerSockets) {
      s.close();
    }
    _pointerSockets.clear();
  }

  Future<void> stop() => _server.close(force: true);

  SocketConnector connector() => (url) async {
        final path = Uri.parse(url).path;
        return WebSocket.connect('ws://127.0.0.1:$port$path');
      };
}

extension on WebOsClient {
  // The luna path is private; this goes through the public brightness setter.
  Future<Result> setLunaForTest() => setBrightness(30);
}

Future<Prefs> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp('127.0.0.1');
  await prefs.setClientKey('key');
  return prefs;
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue, reason: 'condition not met within 3 s');
}
