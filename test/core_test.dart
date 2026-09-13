// Pure-prefs logic ported from TvStore.kt / WakeAction.kt / RightPill.kt and
// the shortcut defaults in WebOsClient.kt: no widgets, no sockets.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/core/right_pill.dart';
import 'package:lgpower/core/tv_store.dart';
import 'package:lgpower/core/wake_action.dart';
import 'package:lgpower/net/webos_client.dart';

Future<Prefs> _prefs([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return Prefs.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TvStore migration', () {
    test('a fresh install has no TVs and no active id', () async {
      final prefs = await _prefs();
      expect(TvStore.list(prefs), isEmpty);
      expect(TvStore.activeId(prefs), isNull);
      expect(TvStore.activeName(prefs), 'LG TV Remote');
      expect(TvStore.nextDefaultName(prefs), 'LG TV');
    });

    test(
      'flat prefs become one active TV that owns the old shortcut list',
      () async {
        final shortcuts = jsonEncode([
          {'id': 'netflix', 'title': 'Netflix'},
        ]);
        final prefs = await _prefs({
          'tv_ip': '10.0.0.5',
          'tv_mac': 'AA:AA:AA:AA:AA:AA',
          'client_key': 'k',
          'app_shortcuts': shortcuts,
        });
        final tv = TvStore.list(prefs).single;
        expect(tv.name, 'LG TV');
        expect(tv.ip, '10.0.0.5');
        expect(tv.mac, 'AA:AA:AA:AA:AA:AA');
        expect(tv.clientKey, 'k');
        expect(TvStore.activeId(prefs), tv.id);
        expect(TvStore.shortcutsKey(prefs), 'app_shortcuts_${tv.id}');
        expect(prefs.getString('app_shortcuts_${tv.id}'), shortcuts);
        expect(TvStore.nextDefaultName(prefs), 'LG TV 2');
      },
    );
  });

  group('TvStore switching', () {
    test(
      'switchTo saves the live prefs into the old TV and loads the new one',
      () async {
        final prefs = await _prefs({
          'tv_ip': '10.0.0.5',
          'client_key': 'ka',
          'last_volume': 30,
        });
        final a = TvStore.list(prefs).single;
        // Simulate pairing a second TV: park A, write B's live prefs, add it.
        TvStore.beginAdd(prefs);
        expect(prefs.tvIp, '');
        await prefs.setTvIp('10.0.0.6');
        await prefs.setClientKey('kb');
        final b = TvStore.addFromLive(prefs, 'Bedroom', udn: 'uuid-b');
        expect(TvStore.activeId(prefs), b.id);
        expect(b.udn, 'uuid-b');

        // Something changed A's key while it was live... which it wasn't; but
        // B's edits while active are captured on the way out.
        await prefs.setTvMac('BB:BB:BB:BB:BB:BB');
        TvStore.switchTo(prefs, a.id);
        expect(prefs.tvIp, '10.0.0.5');
        expect(prefs.clientKey, 'ka');
        expect(
          prefs.lastVolume,
          -1,
          reason: 'cached levels belong to the other set',
        );
        expect(
          TvStore.list(prefs).firstWhere((t) => t.id == b.id).mac,
          'BB:BB:BB:BB:BB:BB',
        );
      },
    );

    test('cancelAdd restores the parked live prefs', () async {
      final prefs = await _prefs({
        'tv_ip': '10.0.0.5',
        'tv_mac': 'AA:AA:AA:AA:AA:AA',
        'client_key': 'ka',
      });
      TvStore.beginAdd(prefs);
      expect(prefs.clientKey, isNull);
      TvStore.cancelAdd(prefs);
      expect(prefs.tvIp, '10.0.0.5');
      expect(prefs.tvMac, 'AA:AA:AA:AA:AA:AA');
      expect(prefs.clientKey, 'ka');
    });

    test(
      'removing the active TV hands over to the next one, or clears everything',
      () async {
        final prefs = await _prefs({'tv_ip': '10.0.0.5', 'client_key': 'ka'});
        final a = TvStore.list(prefs).single;
        TvStore.beginAdd(prefs);
        await prefs.setTvIp('10.0.0.6');
        await prefs.setClientKey('kb');
        final b = TvStore.addFromLive(prefs, 'Bedroom');
        await prefs.setString('app_shortcuts_${b.id}', '[]');

        TvStore.remove(prefs, b.id);
        expect(TvStore.list(prefs).map((t) => t.id), [a.id]);
        expect(TvStore.activeId(prefs), a.id);
        expect(prefs.tvIp, '10.0.0.5');
        expect(prefs.getString('app_shortcuts_${b.id}'), isNull);

        TvStore.remove(prefs, a.id);
        expect(TvStore.list(prefs), isEmpty);
        expect(TvStore.activeId(prefs), isNull);
        expect(prefs.tvIp, '');
        expect(prefs.clientKey, isNull);
      },
    );

    test(
      'update edits the entry and the live prefs only for the active TV',
      () async {
        final prefs = await _prefs({'tv_ip': '10.0.0.5'});
        final a = TvStore.list(prefs).single;
        TvStore.update(
          prefs,
          a.id,
          name: '  ',
          ip: '',
          mac: 'CC:CC:CC:CC:CC:CC',
        );
        final after = TvStore.list(prefs).single;
        expect(after.name, 'LG TV', reason: 'blank name keeps the old one');
        expect(after.ip, '10.0.0.5', reason: 'blank ip keeps the old one');
        expect(after.mac, 'CC:CC:CC:CC:CC:CC');
        expect(prefs.tvMac, 'CC:CC:CC:CC:CC:CC');
      },
    );

    test('match prefers the SSDP fingerprint over the address', () async {
      final prefs = await _prefs();
      await prefs.setTvIp('10.0.0.5');
      final a = TvStore.addFromLive(prefs, 'A', udn: 'uuid-a');
      expect(TvStore.match(prefs, '10.0.0.5', 'uuid-a')?.id, a.id);
      expect(
        TvStore.match(prefs, '10.0.0.9', 'uuid-a')?.id,
        a.id,
        reason: 'same set, new address',
      );
      expect(
        TvStore.match(prefs, '10.0.0.5', 'uuid-other'),
        isNull,
        reason: 'another set on the old address',
      );
      expect(
        TvStore.match(prefs, '10.0.0.5', null)?.id,
        a.id,
        reason: 'no fingerprint falls back to ip',
      );
    });
  });

  group('WakeAction', () {
    test('defaults to Home and is stored per TV', () async {
      final prefs = await _prefs({'tv_ip': '10.0.0.5'});
      final a = TvStore.list(prefs).single;
      expect(WakeAction.get(prefs).kind, WakeAction.home);
      expect(WakeAction.get(prefs).display, 'Home screen');

      await WakeAction.set(
        prefs,
        const WakeAction(WakeAction.input, id: 'HDMI_2', label: 'HDMI 2'),
      );
      expect(prefs.getString('wake_action_${a.id}'), isNotNull);
      final got = WakeAction.get(prefs);
      expect(got.kind, WakeAction.input);
      expect(got.id, 'HDMI_2');
      expect(got.display, 'HDMI 2');
      expect(got.key, 'input:HDMI_2');
      expect(const WakeAction(WakeAction.stay).display, 'Leave as is');
    });
  });

  group('RightPill', () {
    test('reads every historical spelling', () async {
      expect(RightPill.get(await _prefs()), RightPill.brightness);
      expect(
        RightPill.get(await _prefs({'right_pill': 'channel'})),
        RightPill.channel,
      );
      expect(
        RightPill.get(await _prefs({'right_pill': 'brightness_buttons'})),
        RightPill.brightness,
      );
      expect(
        RightPill.get(await _prefs({'right_pill_channel': true})),
        RightPill.channel,
      );
      final prefs = await _prefs({'right_pill_channel': true});
      await RightPill.set(prefs, RightPill.brightness);
      expect(
        RightPill.get(prefs),
        RightPill.brightness,
        reason: 'the new key wins over the old switch',
      );
    });
  });

  group('WebOsClient prefs-only helpers', () {
    test(
      'pickDefaultShortcuts takes popular apps in order, then fills from the tail',
      () {
        const apps = [
          TvApp('com.webos.app.browser', 'Web Browser'),
          TvApp('com.webos.app.livetv', 'Live TV'),
          TvApp('io.strem.tv', 'Stremio'),
          TvApp('org.xbmc.kodi', 'Kodi'),
          TvApp('netflix', 'Netflix'),
          TvApp('youtube.leanback.v4', 'YouTube'),
          TvApp('com.disney.disneyplus', 'Disney+'),
        ];
        final picked = WebOsClient.pickDefaultShortcuts(apps);
        expect(picked.map((a) => a.title), [
          'YouTube',
          'Netflix',
          'Disney+',
          'Kodi',
        ]);
        expect(WebOsClient.pickDefaultShortcuts(const []), isEmpty);
      },
    );

    test('shortcuts are saved per TV and capped at 8', () async {
      final prefs = await _prefs({'tv_ip': '10.0.0.5'});
      final client = WebOsClient(prefs);
      final a = TvStore.list(prefs).single;
      await client.saveShortcuts([
        for (var i = 0; i < 10; i++) TvApp('app$i', 'App $i'),
      ]);
      expect(client.loadShortcuts().length, 8);
      expect(prefs.getString('app_shortcuts_${a.id}'), isNotNull);
      expect(prefs.getString('app_shortcuts'), isNull);
    });

    test('cachedInputs reads the per-TV cache the input list writes', () async {
      final prefs = await _prefs({'tv_ip': '10.0.0.5'});
      final client = WebOsClient(prefs);
      expect(client.cachedInputs(), isEmpty);
      final a = TvStore.list(prefs).single;
      await prefs.setString(
        'inputs_cache_${a.id}',
        jsonEncode([
          {'id': 'HDMI_1', 'label': 'HDMI 1'},
        ]),
      );
      expect(client.cachedInputs().single.label, 'HDMI 1');
    });
  });
}
