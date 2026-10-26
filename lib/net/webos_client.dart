import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart' show Color;
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';

import '../core/prefs.dart';
import '../core/test_log.dart';
import '../core/tv_store.dart';
import '../core/wake_action.dart';
import 'command_session.dart';
import 'conn_report.dart';
import 'keyboard.dart';
import 'pointer_session.dart';
import 'resume_check.dart';
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

const String factoryAppId = 'com.webos.app.factorywin';

/// inStop (factory reset) and tilt (locks the remote until a reboot) have no
/// entry here on purpose.
enum ServiceMenu {
  inStart('inStart'),
  ezAdjust('ezAdjust');

  const ServiceMenu(this.irKey);
  final String irKey;
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

const _probeClose = 'connection report';

class WebOsClient {
  WebOsClient(
    this.prefs, {
    CommandSession Function(String ip, Prefs prefs)? commandSessionFactory,
    PointerSession Function(String ip, Prefs prefs)? pointerSessionFactory,
    this.pointerRetryBackoff = const Duration(seconds: 1),
    this.pairingBlockExpiry = const Duration(seconds: 30),
    this.watchReadyWait = const Duration(seconds: 5),
    this.resumeProbe = const Duration(seconds: 1),
    this.resumePointerIdle = const Duration(seconds: 30),
    void Function(String line)? connLog,
  })  : _connLog = connLog ?? ((line) => debugPrint('LgpConn: $line')),
        _commandSessionFactory = commandSessionFactory ?? CommandSession.new,
        _pointerSessionFactory = pointerSessionFactory ?? PointerSession.new {
    // Fire-and-forget: primes the synchronous cachedIconFile() lookup.
    // Until this resolves, cachedIconFile() returns null (see its doc).
    unawaited(_primeIconDir());
  }

  final Prefs prefs;
  final void Function(String line) _connLog;
  final CommandSession Function(String ip, Prefs prefs) _commandSessionFactory;
  final PointerSession Function(String ip, Prefs prefs) _pointerSessionFactory;

  /// After a pointer handshake fails, callers get the dead session back for
  /// this long instead of each touchpad frame starting a new connect against
  /// a TV that is in standby.
  final Duration pointerRetryBackoff;

  /// How long a pairing challenge on the pointer keeps keys answering "accept
  /// pairing". The prompt on the TV times out by itself, and a pairing that
  /// finished on a session older than the failure would otherwise never lift
  /// the block.
  final Duration pairingBlockExpiry;

  /// How long each round of the power watcher waits for the command session to
  /// leave CONNECTING before looking again.
  final Duration watchReadyWait;

  /// How long the resume check waits for the old command socket to answer.
  /// Several round trips even on a jittery Wi-Fi: a false alarm only costs the
  /// handshake every resume used to cost, a socket that really died costs this
  /// much on top of it.
  final Duration resumeProbe;

  /// A pointer idle for longer than this is replaced on resume even when the
  /// command socket answers.
  final Duration resumePointerIdle;

  Duration get _resumeGateMax => resumeProbe + const Duration(milliseconds: 500);

  final _resumeGate = ResumeGate();
  final _endedHolds = Expando<bool>('ended hold');

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
    // The IP check matters while a TV is being added or its address edited:
    // the old TV's live session must not answer for the new one.
    if (existing != null && existing.ip == tvIp && existing.isUsable) return existing;
    if (existing != null) {
      existing.close(why: 'replaced');
      // The power watcher replaces a dying command session every few seconds
      // while the TV wakes; a pointer session still connecting must survive that.
      _dropPointer(where: (p) => p.ip != tvIp || (p.state != PointerState.dead && !p.isUsable));
    }
    final session = _commandSessionFactory(tvIp, prefs);
    _sharedCommandSession = session;
    // The pointer socket has no ping of its own, so the command socket's
    // keepalive is what notices a silent Wi-Fi drop; a pointer session that
    // outlived it can look usable while its frames vanish.
    // A pointer that carried input moments ago is kept too: it is evidently still
    // delivering, and replacing it mid-drag stalls the cursor until a new command
    // session registers, then lands everything moved meanwhile as one jump.
    unawaited(session.awaitDeath().then((_) {
      var pointer = 'unshared';
      if (identical(_sharedCommandSession, session)) {
        if (_sharedPointerSession == null) {
          pointer = 'none';
        } else {
          final dropped = _dropPointer(
              where: (p) => p.state != PointerState.dead && !p.isConnecting && !p.inUse);
          pointer = dropped ? 'dropped' : 'kept';
        }
      }
      final line = sessionDeathLine(session, pointer);
      // The report closes the session itself to time a fresh one; that is not a death worth listing.
      if (session.deathCause != _probeClose) DeathLog.shared.add(line);
      _connLog(line);
    }));
    return session;
  }

  // A pairing that was accepted since the pointer failed lifts the backoff
  // even when the TV hands back the key the pointer already tried.
  bool _pairingBlocked(PointerSession p) {
    if (!p.pairingStillMissing) return false;
    final since = p.handshakeFailedAt ?? p.createdAt;
    if (DateTime.now().difference(since) > pairingBlockExpiry) return false;
    return !(_sharedCommandSession?.registeredAt?.isAfter(since) ?? false);
  }

  /// The one pointer session that d-pad keys and the touchpad share. A live
  /// or still-connecting session is reused (frames sent meanwhile are
  /// queued by the session); a new one starts only when there is none, it
  /// died, it outlived its connect grace, or the TV's address changed.
  PointerSession pointerSession() {
    final existing = _sharedPointerSession;
    if (existing != null && existing.ip == tvIp) {
      if (existing.isUsable) return existing;
      if (_pairingBlocked(existing)) return existing;
      final failedAt = existing.handshakeFailedAt;
      if (failedAt != null && DateTime.now().difference(failedAt) < pointerRetryBackoff) {
        return existing;
      }
    }
    existing?.close();
    // While the command socket is showing the pairing prompt, a second
    // registration from here could dismiss or replace it.
    final command = _sharedCommandSession;
    final promptShowing =
        command != null && command.ip == tvIp && command.state == CmdState.needsPairing;
    final session = promptShowing
        ? PointerSession.blocked(tvIp, prefs)
        : _pointerSessionFactory(tvIp, prefs);
    if (!promptShowing) session.registerGate = () => _awaitCommandRegistered(session);
    _sharedPointerSession = session;
    return session;
  }

  // The pointer registers with the same key as the command session. A key the
  // TV doesn't know turns every registration into a pairing prompt, and two at
  // once can show two prompts or have one replace the other, so the pointer
  // only registers once the command session has and never asks on its own.
  // Its TLS handshake still runs alongside the command session's.
  Future<RegisterGate> _awaitCommandRegistered(PointerSession pointer) async {
    final deadline = pointer.createdAt.add(pointer.connectGrace);
    var connected = false;
    while (pointer.state == PointerState.connecting && pointer.ip == tvIp) {
      final shared = _sharedCommandSession;
      final mine = shared != null && shared.ip == pointer.ip;
      final CommandSession session;
      if (mine && shared.state == CmdState.needsPairing) {
        return RegisterGate.needsPairing;
      } else if (mine &&
          shared.state == CmdState.dead &&
          (shared.opened || shared.pairingRejected)) {
        // A session that opened and then died (a TV in standby accepts the
        // upgrade and closes) is the power watcher's to retry at its own
        // pace: a connect from here would add one per key press. One that
        // never opened stalled in connect/TLS, so it falls through to the
        // single replacement below.
        return RegisterGate.fail;
      } else if (mine && shared.isUsable) {
        session = shared;
      } else if (!connected) {
        // None yet, or one stuck past its connect grace.
        connected = true;
        session = _commandSession();
      } else {
        return RegisterGate.fail;
      }
      switch (session.state) {
        case CmdState.ready:
          return RegisterGate.register;
        case CmdState.needsPairing:
          return RegisterGate.needsPairing;
        case CmdState.dead:
          return RegisterGate.fail;
        case CmdState.connecting:
          final graceEnd = session.createdAt.add(session.connectGrace);
          final until = graceEnd.isBefore(deadline) ? graceEnd : deadline;
          final wait = until.difference(DateTime.now());
          if (wait <= Duration.zero) return RegisterGate.fail;
          // Settles on any outcome, including the session being replaced; the
          // next round looks at whichever one is shared by then.
          await session.awaitReady(timeout: wait);
      }
    }
    return RegisterGate.fail;
  }

  /// Opens the pointer connection ahead of the first key or touch so the
  /// two TLS handshakes are already done when the user reaches for the remote.
  void warmPointer() {
    // Without a key the first registration is the pairing itself, and that
    // belongs to the command session.
    if (tvIp.isEmpty || (prefs.clientKey ?? '').isEmpty) return;
    pointerSession();
  }

  // A dead session stays put when [where] is given: it carries the retry
  // pause and the pairing backoff.
  bool _dropPointer({bool Function(PointerSession)? where}) {
    final p = _sharedPointerSession;
    if (p == null || (where != null && !where(p))) return false;
    p.close();
    _sharedPointerSession = null;
    return true;
  }

  void resetConnection() {
    _dropPointer();
    _sharedCommandSession?.close(why: 'reset');
    _sharedCommandSession = null;
  }

  /// Keeps the shared connections across a return to the foreground when the
  /// TV still answers on them, else drops both as [resetConnection] does.
  /// Completes when the verdict is in; the idle-pointer swap has happened by
  /// the time this returns.
  Future<void> resumeConnection() {
    final command = _sharedCommandSession;
    final step = resumeStep(
        commandReady: command != null && command.state == CmdState.ready && command.ip == tvIp);
    if (step == ResumeStep.reset) {
      resetConnection();
      return Future.value();
    }
    final session = command!;
    final oldPointer = _sharedPointerSession;
    // Before anything can pick the old pointer up
    final check = _resumeGate.begin();
    // The TV never writes on the pointer, so a close it sent while the phone dozed is never heard
    try {
      if (oldPointer != null &&
          shouldReplaceIdlePointer(
              dead: oldPointer.isDead, idle: oldPointer.idleFor, maxIdle: resumePointerIdle) &&
          _dropPointer(where: (p) => sameSession(p, oldPointer) && !p.inUse)) {
        warmPointer();
      }
    } catch (_) {
      // A closed gate would hold every send until the safety timeout
      _resumeGate.end(check);
      rethrow;
    }
    return _resumeProbe(session, oldPointer, check);
  }

  Future<void> _resumeProbe(
      CommandSession session, PointerSession? oldPointer, Object check) async {
    try {
      final answered = await probeCommand(
        markStale: (v) => session.replacedAsStale = v,
        probe: () => session.answersWithin(resumeProbe, _powerStateUri),
      );
      if (answered) {
        TestLog.sock('cmd', session.sid, 'resume-keep');
      } else {
        TestLog.sock('cmd', session.sid, 'resume-stale');
        _replaceStale(session, oldPointer);
      }
    } finally {
      _resumeGate.end(check);
    }
  }

  // Unlike resetConnection this ignores recent traffic: anything sent since
  // the resume went into a socket that has just failed to answer.
  void _replaceStale(CommandSession command, PointerSession? pointer) {
    if (identical(_sharedCommandSession, command)) _sharedCommandSession = null;
    command.replacedAsStale = true;
    // A pointer opened since the resume is fresh and is left to finish its handshake
    _dropPointer(where: (p) => sameSession(p, pointer));
    command.close(why: 'silent on resume');
    warmPointer();
  }

  Future<Result> _execute(
    String uri, {
    Map<String, dynamic> payload = const {},
    int timeoutSecs = 6,
  }) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    await _resumeGate.wait(_resumeGateMax);
    final reply = await _commandSession().send(uri, payload: payload, timeoutSecs: timeoutSecs);
    return switch (reply) {
      CmdReplyOk() => const Success(),
      CmdReplyNeedsPairing() => const NeedsPairing(),
      CmdReplyErr(:final message) => CmdError(message),
    };
  }

  /// Ends a held d-pad key: repeats still queued for it are discarded.
  void endHold(Object hold) {
    _endedHolds[hold] = true;
    _sharedPointerSession?.dropRepeats(hold);
  }

  /// A click on the shared pointer. A tap on a half-open pointer is lost
  /// without any error, so it waits for the resume verdict like a key does.
  /// Moves are streams of frames and stay unheld.
  void pointerClick() => _afterResumeCheck((p) => p.click());

  void pointerKey(String keyCode) => _afterResumeCheck((p) => p.sendKey(keyCode));

  void _afterResumeCheck(void Function(PointerSession) send) {
    if (tvIp.isEmpty) return;
    _resumeGate.runAfter(_resumeGateMax, () => send(pointerSession()));
  }

  /// The key is handed to the shared pointer session before any await, so
  /// presses keep their order even while the session is still connecting; the
  /// result reports whether the key was written to a live socket. A [hold]
  /// marks an auto-repeat of a held key: those are best effort and never wait
  /// for a retry.
  Future<Result> pressKey(String keyCode, {Object? hold}) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    // No await on an open gate: presses must reach the session in call order
    if (!_resumeGate.isOpen) {
      await _resumeGate.wait(_resumeGateMax);
      // A repeat whose key was let go while it waited would fire after the release
      if (hold != null && _endedHolds[hold] == true) return const CmdError('Released');
    }
    final oneShot = hold == null;
    for (var attempt = 0; attempt < 2; attempt++) {
      var session = pointerSession();
      // An await costs a microtask even when it returns at once, which would let
      // held repeats overtake earlier one-shot presses
      if (oneShot && attempt == 0 && _backoffPending(session)) {
        session = await _afterBackoff(session);
      }
      final accepted = session.sendKey(keyCode, hold: hold);
      if (accepted && await session.waitUntilReady(timeout: session.connectGrace)) {
        return const Success();
      }
      if (_pairingBlocked(session)) return const NeedsPairing();
      // A session that was reset or replaced under the press, or whose socket
      // refused the frame after it had been up, never saw a handshake fail;
      // one fresh session is worth a try before reporting a timeout. One that
      // had opened already wrote the key, and a second send would press twice.
      final worthRetry = oneShot &&
          session.handshakeFailedAt == null &&
          (!accepted || (session.retired && !session.wasReady)) &&
          session.ip == tvIp;
      if (!worthRetry) break;
    }
    return const CmdError('Timeout. Is the TV on and reachable?');
  }

  // A key press right after a failed connect would otherwise fail on the spot
  // although the TV may be fine (a warm-up that hit a closing socket); waiting
  // out the cooldown turns it into a real attempt.
  bool _backoffPending(PointerSession session) {
    final failedAt = session.handshakeFailedAt;
    if (session.state != PointerState.dead || failedAt == null || _pairingBlocked(session)) {
      return false;
    }
    return pointerRetryBackoff - DateTime.now().difference(failedAt) > Duration.zero;
  }

  Future<PointerSession> _afterBackoff(PointerSession session) async {
    final failedAt = session.handshakeFailedAt;
    if (session.state != PointerState.dead || failedAt == null || _pairingBlocked(session)) {
      return session;
    }
    final remaining = pointerRetryBackoff - DateTime.now().difference(failedAt);
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining + const Duration(milliseconds: 20));
    }
    return pointerSession();
  }

  Future<Result> turnOff() => _execute('ssap://system/turnOff');

  Future<Result> turnOffScreen() =>
      _execute('ssap://com.webos.service.tvpower/power/turnOffScreen');

  Future<Result> turnOnScreen() =>
      _execute('ssap://com.webos.service.tvpower/power/turnOnScreen');

  // Short 3 s timeout so a dead TV fails fast in the wake retry loop.
  Future<Result> goHome() => _execute(
        'ssap://system.launcher/launch',
        payload: {'id': 'com.webos.app.home'},
        timeoutSecs: 3,
      );

  // Answers as soon as webOS is up without changing what is on screen, so a
  // TV that was woken over the network stays on whatever it boots into.
  Future<Result> probe() => _execute('ssap://system/getSystemInfo', timeoutSecs: 3);

  /// The "is webOS awake yet?" probe of the wake retry loop, doubling as the
  /// user's chosen landing spot (Settings › Controls › After waking the TV).
  Future<Result> afterWake() {
    final a = WakeAction.get(prefs);
    return switch (a.kind) {
      WakeAction.stay => probe(),
      WakeAction.input => _execute('ssap://tv/switchInput', payload: {'inputId': a.id}, timeoutSecs: 3),
      WakeAction.app => _execute('ssap://system.launcher/launch', payload: {'id': a.id}, timeoutSecs: 3),
      _ => goHome(),
    };
  }

  Future<Result> pressEnter() => pressKey('ENTER');
  Future<Result> volumeUp() => pressKey('VOLUMEUP');
  Future<Result> volumeDown() => pressKey('VOLUMEDOWN');

  Future<VolumeState?> getVolume() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession().send('ssap://audio/getVolume');
    if (reply is! CmdReplyOk) return null;
    return _parseVolume(reply.payload);
  }

  // An AV receiver or soundbar on ARC/optical often ignores setVolume (the TV
  // only relays volume keys to it over CEC), so callers step with the keys.
  bool volumeNeedsKeys = false;

  static const Set<String> _tvOwnOutputs = {
    'tv_speaker', 'tv_external_speaker', 'headphone', 'tv_speaker_headphone',
  };

  void _noteSoundOutput(Map<String, dynamic>? status) {
    if (status == null) return;
    final output = status['soundOutput'] as String? ?? '';
    volumeNeedsKeys = status['adjustVolume'] == false ||
        (output.isNotEmpty && !_tvOwnOutputs.contains(output));
  }

  // Firmware answers with either shape; a volume below 0 (or absent) means
  // "no reading" so the caller can keep the previous value.
  VolumeState? _parseVolume(Map<String, dynamic> payload) {
    final nested = payload['volumeStatus'] as Map<String, dynamic>?;
    _noteSoundOutput(nested);
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

  // Some sets ignore setVolume (external speakers over ARC/optical, or a
  // burst of requests during a drag) while the volume keys still work, so
  // read the level back and step the rest of the way.
  Future<void> settleVolume(int target) async {
    final actual = (await getVolume())?.volume;
    if (actual == null) return;
    final delta = target - actual;
    if (delta == 0 || delta.abs() > 40) return;
    for (var i = 0; i < delta.abs(); i++) {
      await (delta > 0 ? volumeUp() : volumeDown());
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

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
    final result = switch (reply) {
      CmdReplyNeedsPairing() => (const <InputSource>[], 'Pairing required'),
      CmdReplyErr(:final message) => (const <InputSource>[], message),
      CmdReplyOk(:final payload) => _parseInputs(payload),
    };
    if (result.$1.isNotEmpty) {
      unawaited(prefs.setString(
        _inputsCacheKey(),
        jsonEncode([for (final i in result.$1) {'id': i.id, 'label': i.label}]),
      ));
    }
    return result;
  }

  String _inputsCacheKey() {
    final id = TvStore.activeId(prefs);
    return id == null ? 'inputs_cache' : 'inputs_cache_$id';
  }

  /// Last list the TV gave us, so the wake picker still offers inputs while
  /// the TV is off.
  List<InputSource> cachedInputs() {
    final json = prefs.getString(_inputsCacheKey());
    if (json == null) return const [];
    try {
      final arr = jsonDecode(json) as List<dynamic>;
      return [
        for (final e in arr)
          InputSource((e as Map<String, dynamic>)['id'] as String, e['label'] as String),
      ];
    } catch (_) {
      return const [];
    }
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

  /// The factory menus are the launcher's `com.webos.app.factorywin` app with
  /// an `irKey`, the same call ColorControl and bscpylgtv make.
  Future<Result> launchServiceMenu(ServiceMenu menu) => _execute(
        'ssap://system.launcher/launch',
        payload: {
          'id': factoryAppId,
          'params': {'id': 'executeFactory', 'irKey': menu.irKey},
        },
      );

  Future<Result> closeServiceMenu() =>
      _execute('ssap://system.launcher/close', payload: {'id': factoryAppId});

  Future<Result> sendText(String text) => _execute(
        'ssap://com.webos.service.ime/insertText',
        payload: {'text': text, 'replace': false},
      );

  /// Holds the TV's remote-keyboard subscription on the shared command
  /// session and reports whether a text field has focus. Returns the cancel
  /// function; a session that is not ready in time just never reports.
  Future<void Function()> watchKeyboard(void Function(KeyboardFocus) listener) async {
    if (tvIp.isEmpty) return () {};
    final session = _commandSession();
    await session.awaitReady(timeout: const Duration(seconds: 4));
    final id = session.subscribe(
      'ssap://com.webos.service.ime/registerRemoteKeyboard',
      (payload) {
        if (payload != null) listener(parseKeyboardFocus(payload));
      },
    );
    return () {
      if (id != null) session.unsubscribe(id);
    };
  }

  /// Timed probes for the connection report. Drops both shared sockets first so
  /// the open times are those of a fresh connection; the next use of the remote
  /// reopens them on demand.
  Future<TvProbe> probeConnection({void Function(String stage)? onStage}) async {
    if (tvIp.isEmpty) return const TvProbe(failure: 'No TV is set up');
    // Registering without a key would raise a pairing prompt on the TV.
    if ((prefs.clientKey ?? '').isEmpty) return const TvProbe(failure: 'The TV is not paired yet');
    const count = 10;
    double ms(Stopwatch w) => w.elapsedMicroseconds / 1000.0;

    onStage?.call('Opening the command connection');
    final oldPointer = _sharedPointerSession;
    final oldCommand = _sharedCommandSession;
    // Closing a pointer mid-gesture would cut the user's own input.
    var pointerBusy = oldPointer?.inUse ?? false;
    if (!pointerBusy) {
      _sharedPointerSession = null;
      oldPointer?.close();
    }
    _sharedCommandSession = null;
    oldCommand?.close(why: _probeClose);

    final opened = Stopwatch()..start();
    final session = _commandSession();
    await session.awaitReady(timeout: const Duration(seconds: 10));
    if (session.state != CmdState.ready) {
      return TvProbe(
        failure: session.state == CmdState.needsPairing
            ? 'The TV is waiting for pairing'
            : "Can't connect to TV",
      );
    }
    final commandOpenMs = ms(opened);

    onStage?.call('Reading TV info');
    final model = ConnReport.tvModel(
        await session.send('ssap://system/getSystemInfo', timeoutSecs: 4));
    final software = ConnReport.tvSoftware(await session.send(
        'ssap://com.webos.service.update/getCurrentSWInformation',
        timeoutSecs: 4));

    onStage?.call('Timing requests');
    final trips = <double>[];
    var failed = 0;
    for (var i = 0; i < count; i++) {
      final w = Stopwatch()..start();
      final reply = await session.send('ssap://system/getSystemInfo', timeoutSecs: 4);
      if (reply is CmdReplyOk) {
        trips.add(ms(w));
      } else {
        failed++;
      }
    }

    onStage?.call('Opening the pointer socket');
    // The remote screen underneath re-warms a pointer as soon as the command session is up.
    final warmed = _sharedPointerSession;
    if (warmed != null && warmed.inUse) pointerBusy = true;
    if (pointerBusy) {
      return TvProbe(
        model: model,
        software: software,
        commandOpenMs: commandOpenMs,
        roundTripsMs: trips,
        roundTripFailures: failed,
        pointerFailure: 'Pointer test skipped, remote in use',
      );
    }
    _sharedPointerSession = null;
    warmed?.close();
    final pointerWatch = Stopwatch()..start();
    final pointer = pointerSession();
    if (!await pointer.waitUntilReady()) {
      return TvProbe(
        model: model,
        software: software,
        commandOpenMs: commandOpenMs,
        roundTripsMs: trips,
        roundTripFailures: failed,
        pointerFailure: 'Pointer socket did not open',
      );
    }
    final pointerOpenMs = ms(pointerWatch);

    return TvProbe(
      model: model,
      software: software,
      commandOpenMs: commandOpenMs,
      roundTripsMs: trips,
      roundTripFailures: failed,
      pointerOpenMs: pointerOpenMs,
    );
  }

  /// The shared command session, for the keyboard test, which has to see raw
  /// frames the typed methods above throw away.
  CommandSession diagnosticSession() => _commandSession();

  Future<String?> getMacFromDevice() async {
    if (tvIp.isEmpty) return null;
    final reply = await _commandSession()
        .send('ssap://com.webos.service.connectionmanager/getinfo', timeoutSecs: 8);
    if (reply is! CmdReplyOk) return null;
    final macs = extractMacAddresses(reply.payload);
    return macs.isEmpty ? null : macs.join(', ');
  }

  Future<void> sendWakeOnLan() => wol.sendWakeOnLan(tvMac, tvIp: tvIp);

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
        await raceCancel(session.awaitReady(timeout: watchReadyWait));
        if (cancelCompleter.isCompleted) break;

        switch (session.state) {
          case CmdState.ready:
            final subId = session.subscribe(_powerStateUri, (payload) {
              // A failed update has no state; read as a state it would count
              // as "on".
              final state = payload?['state'] as String? ?? '';
              _publish(
                state.isEmpty
                    ? const PresenceUnknown()
                    : PresenceReported(state, _nullIfEmpty(payload?['processing'] as String?)),
                listener,
              );
            });
            final since = DateTime.now();
            await raceCancel(session.awaitDeath());
            if (subId != null) session.unsubscribe(subId);
            if (cancelCompleter.isCompleted) break;
            final lifetime = DateTime.now().difference(since);
            delayMs = lifetime < const Duration(seconds: 2) && !session.replacedAsStale ? 5000 : 0;
          case CmdState.needsPairing:
            _publish(const PresenceNeedsPairing(), listener);
            // The TV answers on this same socket once the prompt is accepted.
            while (!cancelCompleter.isCompleted && session.state == CmdState.needsPairing) {
              await raceCancel(Future.delayed(const Duration(milliseconds: 250)));
            }
            // A refused prompt waits longer before asking again, or the TV
            // would be showing a new one every few seconds.
            delayMs = session.state == CmdState.ready
                ? 0
                : session.pairingRejected
                    ? 30000
                    : 5000;
          case CmdState.connecting:
            // Still within its connect grace: the next round waits on the
            // same session instead of calling a slow Wi-Fi connect unreachable.
            if (session.isUsable) {
              delayMs = 0;
            } else {
              _publish(const PresenceUnreachable(), listener);
              delayMs = 5000;
            }
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
      return await _readIcon(client, url).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<Uint8List?> _readIcon(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    // The TV's icon server answers 5xx/404 under load; that body is not an
    // image and must never reach the cache.
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytesBuilder = BytesBuilder();
    await for (final chunk in response) {
      bytesBuilder.add(chunk);
    }
    final bytes = bytesBuilder.toBytes();
    return bytes.isEmpty ? null : bytes;
  }

  static const _iconAttempts = 3;
  final _iconsInFlight = <String>{};

  Future<File?> cacheIcon(
    String appId,
    String url, {
    Duration retryDelay = const Duration(milliseconds: 400),
  }) async {
    Uint8List? bytes;
    for (var attempt = 1; bytes == null && attempt <= _iconAttempts; attempt++) {
      if (attempt > 1) await Future<void>.delayed(retryDelay * (attempt - 1));
      bytes = await fetchIcon(url);
    }
    if (bytes == null) return null;
    final dir = await getApplicationSupportDirectory();
    _iconDir = dir;
    final file = File('${dir.path}/icon_${_sanitiseAppId(appId)}.png');
    // cachedIconFile() only checks that the file exists, so a half-written
    // file would be shown (and kept for good if the app dies mid-write).
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    await _extractAndStoreColor(appId, bytes);
    return file;
  }

  /// Downloads the icons of [apps] that are not cached yet through a small
  /// worker pool: the TV's icon server drops connections when a whole app
  /// list is requested at once, which left random tiles without an icon.
  Future<void> cacheMissingIcons(
    Iterable<TvApp> apps, {
    void Function(TvApp app)? onCached,
    int concurrency = 4,
    Duration retryDelay = const Duration(milliseconds: 400),
  }) async {
    // Saving shortcuts and loading the TV's list both call this; without the
    // in-flight set the same icon would be requested twice at once.
    final queue = [
      for (final app in apps)
        if (app.iconUrl != null &&
            cachedIconFile(app.id) == null &&
            _iconsInFlight.add(app.id))
          app,
    ];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final app = queue.removeLast();
        try {
          final file = await cacheIcon(app.id, app.iconUrl!, retryDelay: retryDelay);
          if (file != null) onCached?.call(app);
        } catch (_) {
          // A throwing write would otherwise end this worker and strand the
          // rest of the queue in _iconsInFlight until the app restarts.
        } finally {
          _iconsInFlight.remove(app.id);
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
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
    if (!file.existsSync()) return null;
    // Builds before the 200-only check could store an error page as the icon;
    // treating it as missing makes "Load apps" refetch it and the UI fall back
    // to the letter tile instead of a broken image.
    return _looksLikeImage(file) ? file : null;
  }

  static bool _looksLikeImage(File file) {
    RandomAccessFile? raf;
    try {
      raf = file.openSync();
      final h = raf.readSync(12);
      bool starts(List<int> magic, [int at = 0]) {
        if (h.length < at + magic.length) return false;
        for (var i = 0; i < magic.length; i++) {
          if (h[at + i] != magic[i]) return false;
        }
        return true;
      }

      return starts(const [0x89, 0x50, 0x4E, 0x47]) ||
          starts(const [0xFF, 0xD8, 0xFF]) ||
          starts(const [0x47, 0x49, 0x46, 0x38]) ||
          (starts(const [0x52, 0x49, 0x46, 0x46]) &&
              starts(const [0x57, 0x45, 0x42, 0x50], 8));
    } catch (_) {
      return false;
    } finally {
      raf?.closeSync();
    }
  }

  int? loadCachedColor(String appId) =>
      brandColors[appId] ?? prefs.colorFor(appId);

  List<TvApp> loadShortcuts() {
    final raw = prefs.getString(TvStore.shortcutsKey(prefs));
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

  static const int maxShortcuts = 8;

  // Mirrors the UI-level cap so a bad caller can't persist more shortcuts
  // than the app will ever render.
  Future<void> saveShortcuts(List<TvApp> apps) {
    final limited = apps.take(maxShortcuts).toList();
    final json = jsonEncode(limited
        .map((a) => {
              'id': a.id,
              'title': a.title,
              if (a.iconUrl != null) 'iconUrl': a.iconUrl,
            })
        .toList());
    return prefs.setString(TvStore.shortcutsKey(prefs), json);
  }

  /// First shortcuts for a freshly paired TV: the well-known streaming apps
  /// it actually has, in a fixed order of popularity, topped up from the
  /// TV's own launcher list. webOS exposes neither usage counts nor the
  /// on-screen ribbon order, so this is the closest thing to "the apps you
  /// use".
  static List<TvApp> pickDefaultShortcuts(List<TvApp> apps, {int count = 4}) {
    const wanted = [
      'youtube', 'netflix', 'amazon', 'prime', 'disney', 'hbo', 'max', 'viaplay',
      'spotify', 'apple', 'plex', 'twitch', 'tv 2', 'dr tv', 'skyshowtime', 'paramount',
    ];
    final picked = <TvApp>[];
    for (final w in wanted) {
      if (picked.length >= count) break;
      for (final a in apps) {
        if (picked.contains(a)) continue;
        final id = a.id.toLowerCase();
        final title = a.title.toLowerCase();
        if (id.contains(w) || title == w || title.startsWith('$w ')) {
          picked.add(a);
          break;
        }
      }
    }
    const system = ['com.webos.', 'com.palm.', 'com.lge.', 'com.lgsmartplatform'];
    final rest = apps
        .where((a) => !picked.contains(a) && !system.any((p) => a.id.startsWith(p)))
        .toList();
    final fill = count - picked.length;
    if (fill > 0) picked.addAll(rest.skip((rest.length - fill).clamp(0, rest.length)));
    return picked.take(count).toList();
  }

  Future<Result> _lunaRequest(String uri, Map<String, dynamic> params) async {
    if (tvIp.isEmpty) return const CmdError('No TV IP configured');
    await _resumeGate.wait(_resumeGateMax);
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
