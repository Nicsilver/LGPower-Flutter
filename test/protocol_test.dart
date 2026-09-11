// Exercises the protocol layer against the fake webOS TV (tools/faketv in
// LGPowerWidget) already listening on 127.0.0.1:3001 (wss, self-signed) and
// 127.0.0.1:3002 (icons). Never starts a second copy.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/tv_discovery.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/net/wol.dart';

const _tvIp = '127.0.0.1';

/// Fresh mock-backed Prefs pointed at the fake TV. Each test gets its own
/// client_key/registration -- the fake accepts any key unconditionally, so
/// re-registering per test costs nothing and keeps tests independent.
Future<Prefs> _freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  await prefs.setTvIp(_tvIp);
  return prefs;
}

void main() {
  // Deliberately no TestWidgetsFlutterBinding.ensureInitialized() -- it
  // installs HttpOverrides that fake every HttpClient response with a 400,
  // which would also break the real wss:// sockets under test here (dart:io
  // WebSocket.connect goes through HttpClient for the upgrade handshake).
  // shared_preferences' mock store doesn't need the binding.

  group('registration and pairing', () {
    test('registers with the fake TV, reaches READY, saves client_key', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      expect(prefs.clientKey, isNull);
      final volume = await client.getVolume();
      expect(volume, isNotNull);
      expect(prefs.clientKey, isNotNull);
      expect(prefs.clientKey, isNotEmpty);
    });
  });

  group('volume', () {
    test('getVolume returns a value; setVolume(37) round-trips', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final before = await client.getVolume();
      expect(before, isNotNull);

      final result = await client.setVolume(37);
      expect(result, isA<Success>());

      final after = await client.getVolume();
      expect(after, isNotNull);
      expect(after!.volume, 37);
    });
  });

  group('brightness', () {
    test('getBrightness / setBrightness round-trip through the Luna alert path', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final before = await client.getBrightness();
      expect(before, isNotNull);

      final target = before == 55 ? 60 : 55;
      final result = await client.setBrightness(target);
      expect(result, isA<Success>());

      final after = await client.getBrightness();
      expect(after, target);
    });
  });

  group('inputs and apps', () {
    test('getInputs returns a non-empty list', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final (inputs, error) = await client.getInputs();
      expect(error, isNull);
      expect(inputs, isNotEmpty);
    });

    test('listApps returns 12 apps sorted by title', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final (apps, error) = await client.listApps();
      expect(error, isNull);
      expect(apps.length, 12);
      final titles = apps.map((a) => a.title).toList();
      final sorted = [...titles]
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(titles, sorted);
    });
  });

  group('pointer socket', () {
    test('pressKey succeeds (pointer socket handshake works)', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final result = await client.pressKey('UP');
      expect(result, isA<Success>());
    });
  });

  group('power watcher', () {
    test(
      'watchPower reports on within 5s, then off after turnOff()',
      () async {
        final prefs = await _freshPrefs();
        final client = WebOsClient(prefs);
        addTearDown(client.resetConnection);

        // faketv is a long-lived process shared across test runs -- start
        // from a known "on" state regardless of what a previous run (or the
        // turnOff() below, on a re-run) left it in.
        await client.turnOnScreen();

        final offCompleter = Completer<void>();
        final stop = client.watchPower((p) {
          if (p is PresenceReported && !p.isOn && !offCompleter.isCompleted) {
            offCompleter.complete();
          }
        });
        addTearDown(stop);

        final onPresence = await client.awaitPresence(5000);
        expect(onPresence, isA<PresenceReported>());
        expect((onPresence as PresenceReported).isOn, isTrue);

        final result = await client.turnOff();
        expect(result, isA<Success>());

        // isOn flips almost immediately: the fake's first pushed state
        // already carries processing "Request Power Off", which the
        // OFF_TRANSITIONS substring rule reads as off before `state` itself
        // reaches "Active Standby" a few seconds later.
        await offCompleter.future.timeout(const Duration(seconds: 5));
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('discovery (no network)', () {
    test('M-SEARCH text is byte-exact, CRLF, sent as one request', () {
      const expected = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:lge-com:service:webos-second-screen:1\r\n'
          '\r\n';
      expect(mSearchMessage, expected);
      expect(utf8.encode(mSearchMessage).length, utf8.encode(expected).length);
    });

    test('LOCATION parsing quirk: substring after the FIRST colon', () {
      // "LOCATION: http://192.168.1.50:1815/desc.xml" cut at the first ':'
      // yields " http://192.168.1.50:1815/desc.xml" -- still a valid URI
      // once trimmed, which is the whole point of the quirk.
      final ip = extractIpFromSsdpResponse(
        'HTTP/1.1 200 OK\r\n'
        'LOCATION: http://192.168.1.50:1815/desc.xml\r\n'
        'ST: urn:lge-com:service:webos-second-screen:1\r\n'
        '\r\n',
      );
      expect(ip, '192.168.1.50');
    });

    test('missing LOCATION header yields null', () {
      final ip = extractIpFromSsdpResponse('HTTP/1.1 200 OK\r\nST: foo\r\n\r\n');
      expect(ip, isNull);
    });
  });

  group('wake-on-lan', () {
    test('builds a 102-byte magic packet: 6xFF header + MAC repeated 16x', () {
      final packet = buildMagicPacket('AA:BB:CC:DD:EE:FF');
      expect(packet, isNotNull);
      expect(packet!.length, 102);
      expect(packet.sublist(0, 6), List.filled(6, 0xFF));
      const mac = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];
      for (var i = 0; i < 16; i++) {
        expect(packet.sublist(6 + i * 6, 6 + i * 6 + 6), mac);
      }
    });

    test('rejects an empty or malformed MAC', () {
      expect(buildMagicPacket(''), isNull);
      expect(buildMagicPacket('not-a-mac'), isNull);
      expect(buildMagicPacket('AA:BB:CC:DD:EE'), isNull);
    });
  });

  group('icons', () {
    test('fetches an icon from the fake TV icon server', () async {
      final prefs = await _freshPrefs();
      final client = WebOsClient(prefs);
      addTearDown(client.resetConnection);

      final (apps, error) = await client.listApps();
      expect(error, isNull);
      expect(apps, isNotEmpty);
      final rawUrl = apps.first.iconUrl;
      expect(rawUrl, isNotNull);

      // faketv bakes in whatever --host it was started with (10.0.2.2, for
      // the Android emulator); rewrite to 127.0.0.1 to reach it from here.
      final url = Uri.parse(rawUrl!).replace(host: '127.0.0.1').toString();
      final bytes = await client.fetchIcon(url);
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(0));
    });
  });
}
