import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';

import '../core/prefs.dart';
import 'command_session.dart';
import 'pointer_session.dart';
import 'wol.dart' as wol;

const String _powerStateUri =
    'ssap://com.webos.service.tvpower/power/getPowerState';

/// Outcome of a fire-and-forget SSAP command. Named `CmdError` rather than
/// `Error` to avoid shadowing `dart:core`'s `Error`.
sealed class Result {
  const Result();
}

class Success extends Result {
  const Success();
}

class NeedsPairing extends Result {
  const NeedsPairing();
}

class CmdError extends Result {
  const CmdError(this.message);
  final String message;
}

// Observed on a C4: turnOff pushes state "Active" with processing "Request
// Power Off" within 50 ms, then "Request/Prepare Active Standby", and lands
// on "Active Standby" ~3 s later.
const Set<String> _offStates = {'Active Standby', 'Suspend', 'Power Off'};
const List<String> _offTransitions = ['Power Off', 'Standby', 'Suspend'];

/// TV reachability/power as reported by the `getPowerState` subscription --
/// never by a TCP probe (a TV in standby keeps port 3001 open and closes
/// every new session with "Try Again Later (EWS)"). Variants are prefixed
/// with `Presence` because `NeedsPairing` already names a [Result] variant.
sealed class Presence {
  const Presence();
}

class PresenceUnknown extends Presence {
  const PresenceUnknown();
}

class PresenceUnreachable extends Presence {
  const PresenceUnreachable();
}

class PresenceNeedsPairing extends Presence {
  const PresenceNeedsPairing();
}

class PresenceReported extends Presence {
  const PresenceReported(this.state, this.processing);
  final String state;
  final String? processing;

  // "Screen Off" still counts as on: webOS runs and takes commands, only
  // the panel is dark.
  bool get isOn =>
      !_offStates.contains(state) &&
      !_offTransitions.any((t) => processing?.contains(t) ?? false);

  bool get screenOff => state == 'Screen Off';
}

class VolumeState {
  const VolumeState(this.volume, this.muted);
  final int volume;
  final bool muted;
}

class TvState {
  const TvState(this.brightness, this.volume, this.muted);
  final int? brightness;
  final int? volume;
  final bool muted;
}

class InputSource {
  const InputSource(this.id, this.label);
  final String id;
  final String label;
}

class TvApp {
  const TvApp(this.id, this.title, [this.iconUrl]);
  final String id;
  final String title;
  final String? iconUrl;
}

/// Hardcoded appId -> ARGB pill colour, copied verbatim from
/// `WebOsClient.kt`'s `BRAND_COLORS` companion object (33 entries). The API
/// exposes no per-app branding, so these are guessed/measured once and
/// reused for every install.
const Map<String, int> brandColors = {
  'youtube.leanback.v4': 0xFFCC0000,
  'youtubemusic.leanback.v4': 0xFF9C0A28,
  'youtube.kids': 0xFFCC0000,
  'netflix': 0xFFAA0A12,
  'amazon': 0xFF0073AA,
  'com.spotify.tvv2': 0xFF157A3C,
  'com.spotify.tv': 0xFF157A3C,
  'com.disney.disneyplus-prod': 0xFF0D2D9E,
  'com.disney.disneyplus': 0xFF0D2D9E,
  'com.apple.appletv': 0xFF2A2A2A,
  'com.hbo.hbonow': 0xFF3D1580,
  'com.wbd.stream': 0xFF3D1580,
  'com.hulu.livingroomplus': 0xFF0D7A3E,
  'tv.twitch': 0xFF5B2DAD,
  'com.plexapp.plex': 0xFF7A5600,
  'io.strem.tv': 0xFF7B2FBE,
  'crunchyroll.leanback.v4': 0xFFA34D16,
  'com.crunchyroll.crunchyroid': 0xFFA34D16,
  'com.tubitv': 0xFFA33200,
  'com.peacocktv.peacockandroid': 0xFF00407A,
  'com.paramount.plus': 0xFF003399,
  'com.cbs.paramount': 0xFF003399,
  'com.discoveryplus.tv': 0xFF0047B2,
  'com.skyshowtime.skyshowtime': 0xFF001F6E,
  'com.viaplay.tvapp': 0xFF7A003C,
  'viaplay.tvapp': 0xFF7A003C,
  'com.mb.jellyfin': 0xFF005580,
  'org.jellyfin.androidtv': 0xFF005580,
  'drtv.webos': 0xFFAA0000,
  'com.drtv.smart': 0xFFAA0000,
  'com.espn.score_center': 0xFF8C0000,
  'com.limelight': 0xFF1A4D80,
  'org.xbmc.kodi': 0xFF1A3A6B,
};

class WebOsClient {
  WebOsClient(this.prefs) {
    // Fire-and-forget: primes the synchronous cachedIconFile() lookup.
    // Until this resolves, cachedIconFile() returns null (see its doc).
    unawaited(_primeIconDir());
  }

  final Prefs prefs;

  CommandSession? _sharedCommandSession;
  PointerSession? _sharedPointerSession;
  Directory? _iconDir;
  Presence _presence = const PresenceUnknown();
  final _presenceController = StreamController<Presence>.broadcast();

  String get tvIp => prefs.tvIp;
  String get tvMac => prefs.tvMac;
  Future<void> saveTvIp(String ip) => prefs.setTvIp(ip);
  Future<void> saveTvMac(String mac) => prefs.setTvMac(mac);

  CommandSession _commandSession() {
    final existing = _sharedCommandSession;
    if (existing != null && existing.isUsable) return existing;
    existing?.close();
    final session = CommandSession(tvIp, prefs);
    _sharedCommandSession = session;
    return session;
  }

  void resetConnection() {
    _sharedPointerSession?.close();
    _sharedPointerSession = null;
    _sharedCommandSession?.close();
    _sharedCommandSession = null;
  }

  Future<Result> _execute(
    String uri, {
    Map<String, dynamic> payload = const {},
    int timeoutSecs = 6,
  }) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    final reply = await _commandSession().send(uri, payload: payload, timeoutSecs: timeoutSecs);
    return switch (reply) {
      CmdReplyOk() => const Success(),
      CmdReplyNeedsPairing() => const NeedsPairing(),
      CmdReplyErr(:final message) => CmdError(message),
    };
  }

  /// Shared session with strict `isAlive` (unlike CommandSession's grace
  /// window) -- a mid-handshake pointer session is not reused.
  Future<Result> pressKey(String keyCode) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    final existing = _sharedPointerSession;
    PointerSession session;
    if (existing != null && existing.isAlive) {
      session = existing;
    } else {
      existing?.close();
      session = PointerSession(tvIp, prefs);
      _sharedPointerSession = session;
    }
    final ready = await session.waitUntilReady();
    if (ready) {
      session.sendKey(keyCode);
      return const Success();
    }
    if (identical(_sharedPointerSession, session)) {
      _sharedPointerSession = null;
    }
    return const CmdError('Timeout. Is the TV on and reachable?');
  }

  /// A brand-new dedicated session per touch gesture; the caller closes it.
  Future<PointerSession> openPointerSession() async {
    final session = PointerSession(tvIp, prefs);
    await session.waitUntilReady();
    return session;
  }

  Future<Result> turnOff() => _execute('ssap://system/turnOff');

  Future<Result> turnOffScreen() =>
      _execute('ssap://com.webos.service.tvpower/power/turnOffScreen');

  Future<Result> turnOnScreen() =>
      _execute('ssap://com.webos.service.tvpower/power/turnOnScreen');

  // Doubles as the "is webOS awake yet?" probe in the wake retry loop
  // (short 3 s timeout so a dead TV fails fast).
  Future<Result> goHome() => _execute(
        'ssap://system.launcher/launch',
        payload: {'id': 'com.webos.app.home'},
        timeoutSecs: 3,
      );

  Future<VolumeState?> getVolume() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession().send('ssap://audio/getVolume');
    if (reply is! CmdReplyOk) return null;
    return _parseVolume(reply.payload);
  }

  // Firmware answers with either shape; a volume below 0 (or absent) means
  // "no reading" so the caller can keep the previous value.
  VolumeState? _parseVolume(Map<String, dynamic> payload) {
    final nested = payload['volumeStatus'] as Map<String, dynamic>?;
    final src = nested ?? payload;
    final rawVol = src['volume'];
    final vol = rawVol is int ? rawVol : int.tryParse('$rawVol') ?? -1;
    if (vol < 0) return null;
    final muted = nested != null
        ? (nested['muteStatus'] as bool? ?? false)
        : (payload['muted'] as bool? ?? false);
    return VolumeState(vol, muted);
  }

  Future<Result> setVolume(int level) =>
      _execute('ssap://audio/setVolume', payload: {'volume': level});

  Future<int?> getBrightness() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession().send(
      'ssap://settings/getSystemSettings',
      payload: {
        'category': 'picture',
        'keys': ['backlight'],
      },
    );
    if (reply is! CmdReplyOk) return null;
    final settings = reply.payload['settings'] as Map<String, dynamic>?;
    final raw = settings?['backlight'];
    return raw == null ? null : int.tryParse('$raw');
  }

  // WRITE_SETTINGS isn't granted to the flat (unsigned) manifest, so writes
  // go through the notifications-alert trampoline instead (spec §3.9).
  Future<Result> setBrightness(int level) => _lunaRequest(
        'com.webos.settingsservice/setSystemSettings',
        {
          'category': 'picture',
          'settings': {'energySaving': 'off', 'backlight': '$level'},
        },
      );

  Future<Result> brightnessUp() => _adjustBrightness(5);
  Future<Result> brightnessDown() => _adjustBrightness(-5);

  Future<Result> _adjustBrightness(int delta) async {
    final current = await getBrightness();
    if (current == null) return const CmdError('Could not read backlight');
    return setBrightness((current + delta).clamp(0, 100));
  }

  // Both reads run concurrently on the shared session; null only if both
  // came back null.
  Future<TvState?> getTvState() async {
    final results = await Future.wait([getBrightness(), getVolume()]);
    final brightness = results[0] as int?;
    final volume = results[1] as VolumeState?;
    if (brightness == null && volume == null) return null;
    return TvState(brightness, volume?.volume, volume?.muted ?? false);
  }

  Future<String?> getCurrentPictureMode() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession().send(
      'ssap://settings/getSystemSettings',
      payload: {
        'category': 'picture',
        'keys': ['pictureMode'],
      },
    );
    if (reply is! CmdReplyOk) return null;
    final settings = reply.payload['settings'] as Map<String, dynamic>?;
    return settings?['pictureMode'] as String?;
  }

  Future<Result> setPictureMode(String mode) => _lunaRequest(
        'com.webos.settingsservice/setSystemSettings',
        {
          'category': 'picture',
          'settings': {'pictureMode': mode},
        },
      );

  Future<String?> getSoundMode() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession().send(
      'ssap://settings/getSystemSettings',
      payload: {
        'category': 'sound',
        'keys': ['soundMode'],
      },
    );
    if (reply is! CmdReplyOk) return null;
    final settings = reply.payload['settings'] as Map<String, dynamic>?;
    return settings?['soundMode'] as String?;
  }

  Future<Result> setSoundMode(String mode) => _lunaRequest(
        'com.webos.settingsservice/setSystemSettings',
        {
          'category': 'sound',
          'settings': {'soundMode': mode},
        },
      );

  Future<(List<InputSource>, String?)> getInputs() async {
    if (tvIp.isEmpty) return (const <InputSource>[], 'No TV IP configured');
    final reply = await _commandSession()
        .send('ssap://tv/getExternalInputList', timeoutSecs: 8);
    return switch (reply) {
      CmdReplyNeedsPairing() => (const <InputSource>[], 'Pairing required'),
      CmdReplyErr(:final message) => (const <InputSource>[], message),
      CmdReplyOk(:final payload) => _parseInputs(payload),
    };
  }

  (List<InputSource>, String?) _parseInputs(Map<String, dynamic> payload) {
    final devices = payload['devices'] as List<dynamic>?;
    if (devices == null) return (const <InputSource>[], 'No inputs found');
    final list = <InputSource>[];
    for (final entry in devices) {
      final device = entry as Map<String, dynamic>;
      final id = device['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final label = device['label'] as String?;
      list.add(InputSource(id, (label == null || label.isEmpty) ? id : label));
    }
    return (list, list.isEmpty ? 'No inputs found' : null);
  }

  Future<Result> switchInput(String id) =>
      _execute('ssap://tv/switchInput', payload: {'inputId': id});

  Future<(List<TvApp>, String?)> listApps() async {
    if (tvIp.isEmpty) return (const <TvApp>[], 'No TV IP configured');
    final reply = await _commandSession().send(
      'ssap://com.webos.applicationManager/listLaunchPoints',
      timeoutSecs: 10,
    );
    return switch (reply) {
      CmdReplyNeedsPairing() => (const <TvApp>[], 'Needs pairing'),
      CmdReplyErr(:final message) => (const <TvApp>[], message),
      CmdReplyOk(:final payload) => _parseLaunchPoints(payload),
    };
  }

  (List<TvApp>, String?) _parseLaunchPoints(Map<String, dynamic> payload) {
    final points = payload['launchPoints'] as List<dynamic>?;
    if (points == null) {
      final raw = jsonEncode(payload);
      final truncated = raw.length > 200 ? raw.substring(0, 200) : raw;
      return (const <TvApp>[], 'Unexpected response: $truncated');
    }
    final seen = <String>{};
    final list = <TvApp>[];
    for (final entry in points) {
      final obj = entry as Map<String, dynamic>;
      final visible = obj['visible'] as bool? ?? true;
      if (!visible) continue;
      final appId = obj['appId'] as String?;
      final id = (appId != null && appId.isNotEmpty) ? appId : (obj['id'] as String? ?? '');
      final title = obj['title'] as String? ?? '';
      final largeIcon = obj['largeIcon'] as String?;
      final icon = (largeIcon != null && largeIcon.isNotEmpty)
          ? largeIcon
          : (obj['icon'] as String?);
      if (id.isNotEmpty && title.isNotEmpty && seen.add(id)) {
        list.add(TvApp(id, title, icon));
      }
    }
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return (list, null);
  }

  Future<Result> launchApp(String id) =>
      _execute('ssap://system.launcher/launch', payload: {'id': id});

  // No focus detection, no character-by-character sending, no enter key --
  // fire-and-forget insertText is all the TV API offers for this app.
  Future<Result> sendText(String text) => _execute(
        'ssap://com.webos.service.ime/insertText',
        payload: {'text': text, 'replace': 0},
      );

  Future<String?> getMacFromDevice() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession()
        .send('ssap://com.webos.service.connectionmanager/getinfo', timeoutSecs: 8);
    if (reply is! CmdReplyOk) return null;
    return extractMacAddress(reply.payload);
  }

  Future<void> sendWakeOnLan() => wol.sendWakeOnLan(tvMac);

  Presence get presence => _presence;

  void _publish(Presence value, void Function(Presence) listener) {
    _presence = value;
    _presenceController.add(value);
    listener(value);
  }

  /// Keeps the shared command session open and subscribed to the TV's power
  /// state. A socket that drops quickly (<2 s) is treated as broken and
  /// retried after a 5 s backoff; one that lived a while is a Wi-Fi blip and
  /// is retried immediately. Returns a stop function.
  void Function() watchPower(void Function(Presence) listener) {
    _presence = const PresenceUnknown();
    final cancelCompleter = Completer<void>();

    Future<void> raceCancel(Future<void> future) =>
        Future.any([future, cancelCompleter.future]);

    Future<void> loop() async {
      var delayMs = 0;
      while (!cancelCompleter.isCompleted) {
        if (delayMs > 0) {
          await raceCancel(Future.delayed(Duration(milliseconds: delayMs)));
          if (cancelCompleter.isCompleted) break;
        }
        final session = _commandSession();
        await raceCancel(session.awaitReady());
        if (cancelCompleter.isCompleted) break;

        switch (session.state) {
          case CmdState.ready:
            final subId = session.subscribe(_powerStateUri, (payload) {
              _publish(
                PresenceReported(
                  payload?['state'] as String? ?? '',
                  _nullIfEmpty(payload?['processing'] as String?),
                ),
                listener,
              );
            });
            final since = DateTime.now();
            await raceCancel(session.awaitDeath());
            if (subId != null) session.unsubscribe(subId);
            if (cancelCompleter.isCompleted) break;
            final lifetime = DateTime.now().difference(since);
            delayMs = lifetime < const Duration(seconds: 2) ? 5000 : 0;
          case CmdState.needsPairing:
            _publish(const PresenceNeedsPairing(), listener);
            // The TV answers on this same socket once the prompt is accepted.
            while (!cancelCompleter.isCompleted && session.state == CmdState.needsPairing) {
              await raceCancel(Future.delayed(const Duration(milliseconds: 250)));
            }
            delayMs = session.state == CmdState.ready ? 0 : 5000;
          case CmdState.connecting:
          case CmdState.dead:
            _publish(const PresenceUnreachable(), listener);
            delayMs = 5000;
        }
      }
    }

    unawaited(loop());
    return () {
      if (!cancelCompleter.isCompleted) cancelCompleter.complete();
    };
  }

  Future<Presence> awaitPresence(int timeoutMs) async {
    if (_presence is! PresenceUnknown) return _presence;
    try {
      await _presenceController.stream
          .firstWhere((p) => p is! PresenceUnknown)
          .timeout(Duration(milliseconds: timeoutMs));
    } catch (_) {
      // Timeout (or no event arrived) -- fall through and return whatever
      // the current reading is, per spec §5.5.
    }
    return _presence;
  }

  Future<void> _primeIconDir() async {
    try {
      _iconDir = await getApplicationSupportDirectory();
    } catch (_) {
      _iconDir = null;
    }
  }

  static String _sanitiseAppId(String appId) =>
      appId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  Future<Uint8List?> fetchIcon(String url) async {
    HttpClient? client;
    try {
      // A trailing cascade after a closure-valued assignment binds to the
      // closure's return expression, not the receiver -- split these rather
      // than chain them (https://github.com/dart-lang/sdk/issues/33235-style
      // gotcha: `..connectionTimeout` would otherwise apply to the `bool`).
      client = HttpClient()..badCertificateCallback = (cert, host, port) => true;
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final bytesBuilder = BytesBuilder();
      await for (final chunk in response) {
        bytesBuilder.add(chunk);
      }
      return bytesBuilder.toBytes();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<File?> cacheIcon(String appId, String url) async {
    final bytes = await fetchIcon(url);
    if (bytes == null) return null;
    final dir = await getApplicationSupportDirectory();
    _iconDir = dir;
    final file = File('${dir.path}/icon_${_sanitiseAppId(appId)}.png');
    await file.writeAsBytes(bytes);
    await _extractAndStoreColor(appId, bytes);
    return file;
  }

  Future<void> _extractAndStoreColor(String appId, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final palette = await PaletteGenerator.fromImage(frame.image);
      final raw = palette.vibrantColor?.color ??
          palette.dominantColor?.color ??
          const Color(0xFF333355);
      // Darkened to 60% so the pill text stays legible over any brand hue.
      final darkened = Color.fromARGB(
        0xFF,
        (raw.r * 255 * 0.6).round(),
        (raw.g * 255 * 0.6).round(),
        (raw.b * 255 * 0.6).round(),
      );
      await prefs.setColorFor(appId, darkened.toARGB32());
    } catch (_) {
      // Best-effort -- loadCachedColor() falls back to brand colours or
      // no cached colour at all.
    }
  }

  /// Transiently returns null right after construction, before the async
  /// app-support directory lookup primed in the constructor resolves.
  File? cachedIconFile(String appId) {
    final dir = _iconDir;
    if (dir == null) return null;
    final file = File('${dir.path}/icon_${_sanitiseAppId(appId)}.png');
    return file.existsSync() ? file : null;
  }

  int? loadCachedColor(String appId) =>
      brandColors[appId] ?? prefs.colorFor(appId);

  List<TvApp> loadShortcuts() {
    final raw = prefs.appShortcutsJson;
    if (raw == null) return _defaultShortcuts();
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      final list = <TvApp>[];
      for (final entry in arr) {
        final obj = entry as Map<String, dynamic>;
        final id = obj['id'] as String?;
        final title = obj['title'] as String?;
        if (id == null || title == null) continue;
        list.add(TvApp(id, title, obj['iconUrl'] as String?));
      }
      return list;
    } catch (_) {
      return _defaultShortcuts();
    }
  }

  List<TvApp> _defaultShortcuts() => const [
        TvApp('youtube.leanback.v4', 'YouTube'),
        TvApp('netflix', 'Netflix'),
      ];

  // Mirrors the UI-level cap (AppGridAdapter) so a bad caller can't persist
  // more shortcuts than the app will ever render.
  Future<void> saveShortcuts(List<TvApp> apps) {
    final limited = apps.take(4).toList();
    final json = jsonEncode(limited
        .map((a) => {
              'id': a.id,
              'title': a.title,
              if (a.iconUrl != null) 'iconUrl': a.iconUrl,
            })
        .toList());
    return prefs.setAppShortcutsJson(json);
  }

  Future<Result> _lunaRequest(String uri, Map<String, dynamic> params) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    final lunaUri = 'luna://$uri';
    final session = _commandSession();

    final alertReply = await session.send(
      'ssap://system.notifications/createAlert',
      payload: {
        'message': ' ',
        'buttons': [
          {'label': '', 'onClick': lunaUri, 'params': params},
        ],
        'onclose': {'uri': lunaUri, 'params': params},
        'onfail': {'uri': lunaUri, 'params': params},
      },
    );

    String? alertId;
    if (alertReply is CmdReplyOk) {
      alertId = alertReply.payload['alertId'] as String?;
    }
    if (alertId == null || alertId.isEmpty) {
      return switch (alertReply) {
        CmdReplyNeedsPairing() => const NeedsPairing(),
        CmdReplyErr(:final message) => CmdError(message),
        CmdReplyOk() => const CmdError('No alertId returned'),
      };
    }

    final closeReply = await session.send(
      'ssap://system.notifications/closeAlert',
      payload: {'alertId': alertId},
    );
    return switch (closeReply) {
      CmdReplyOk() => const Success(),
      CmdReplyNeedsPairing() => const NeedsPairing(),
      CmdReplyErr(:final message) => CmdError(message),
    };
  }

  static const List<(String, String)> pictureModes = [
    ('vivid', 'Vivid'),
    ('standard', 'Standard'),
    ('eco', 'Eco'),
    ('cinema', 'Cinema'),
    ('expert1', 'Expert (Bright Room)'),
    ('expert2', 'Expert (Dark Room)'),
    ('game', 'Game Optimizer'),
    ('filmMaker', 'Filmmaker Mode'),
    ('sports', 'Sports'),
  ];

  static const List<(String, String)> soundModes = [
    ('standard', 'Standard'),
    ('movie', 'Movie'),
    ('music', 'Music'),
    ('sports', 'Sports'),
    ('game', 'Game'),
    ('news', 'News'),
    ('aiSoundPlus', 'AI Sound+'),
  ];
}

String? _nullIfEmpty(String? s) => (s == null || s.isEmpty) ? null : s;
