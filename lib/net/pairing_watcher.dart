import 'dart:async';
import 'dart:io';

import '../core/prefs.dart';
import 'ssap_messages.dart';
import 'ws_connect.dart';

typedef StopPairing = void Function();

/// [PairingWatcher.watch]'s signature, factored out as a typedef so
/// `SetupScreen` can accept an injectable fake in tests.
typedef PairingWatch = StopPairing Function(
  String ip, {
  required void Function() onPromptShown,
  required void Function(String clientKey) onPaired,
});

/// Watches `wss://<ip>:3001` for pairing completion, used by Setup only
/// (protocol spec §2.5). Pairs against the candidate IP directly rather than
/// the saved `tv_ip` -- abandoning setup must never lock in the wrong TV.
class PairingWatcher {
  PairingWatcher(this.prefs, {SocketConnector? connector})
      : _connector = connector ?? connectTrustAll;

  final Prefs prefs;
  final SocketConnector _connector;

  static const _retryDelay = Duration(seconds: 2);
  static const _attemptTimeout = Duration(seconds: 30);

  bool _stopped = false;

  // The attempt in flight, so stopping can end it instead of leaving its
  // socket and listener up for the rest of the 30 s.
  Completer<bool>? _attemptDone;

  /// Starts the retry loop. Returns a stop function; call it to cancel (UI
  /// timeout, Retry/Search-again buttons, screen disposal).
  StopPairing watch(
    String ip, {
    required void Function() onPromptShown,
    required void Function(String clientKey) onPaired,
  }) {
    _stopped = false;
    var promptFired = false;
    void firePromptOnce() {
      if (!promptFired) {
        promptFired = true;
        onPromptShown();
      }
    }

    unawaited(_loop(ip, firePromptOnce, onPaired));
    return () {
      _stopped = true;
      final done = _attemptDone;
      if (done != null && !done.isCompleted) done.complete(false);
    };
  }

  Future<void> _loop(
    String ip,
    void Function() firePromptOnce,
    void Function(String) onPaired,
  ) async {
    while (!_stopped) {
      final paired = await _attempt(ip, firePromptOnce, onPaired);
      if (paired || _stopped) return;
      await Future.delayed(_retryDelay);
    }
  }

  /// One connection attempt, bounded to 30 s total regardless of whether the
  /// prompt has been shown -- a stalled attempt is abandoned and retried with
  /// a fresh socket rather than waited on forever.
  Future<bool> _attempt(
    String ip,
    void Function() firePromptOnce,
    void Function(String) onPaired,
  ) async {
    WebSocket ws;
    try {
      ws = await connectWithTimeout(_connector, 'wss://$ip:3001', const Duration(seconds: 5));
    } catch (_) {
      return false;
    }
    if (_stopped) {
      closeQuietly(ws);
      return false;
    }

    final completer = Completer<bool>();
    _attemptDone = completer;
    ws.add(encodeSsapMessage(buildRegistration(prefs.clientKey)));

    final sub = ws.listen(
      (raw) {
        Map<String, dynamic> msg;
        try {
          msg = decodeSsapMessage(raw as String);
        } catch (_) {
          return;
        }
        final type = msg['type'] as String?;
        final id = msg['id'] as String?;
        // A stopped watch belongs to a screen the user left; its TV must not
        // leave a key behind in the prefs of whichever TV is active now.
        if (_stopped) return;
        if (type == 'registered') {
          // "registered" means paired regardless of whether this reply
          // carries a fresh key -- a reused, still-valid saved key can come
          // back without one (mirrors CommandSession's handling).
          final key =
              (msg['payload'] as Map<String, dynamic>?)?['client-key'] as String?;
          if (key != null && key.isNotEmpty) {
            prefs.setClientKey(key);
          }
          onPaired(key != null && key.isNotEmpty ? key : (prefs.clientKey ?? ''));
          if (!completer.isCompleted) completer.complete(true);
        } else if (type == 'response' && id == regMessageId) {
          // TV is showing its accept prompt -- stay on this socket, webOS
          // sends "registered" here once the user taps Accept.
          firePromptOnce();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(false);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(false);
      },
      cancelOnError: true,
    );

    bool result;
    try {
      result = await completer.future.timeout(_attemptTimeout, onTimeout: () => false);
    } finally {
      _attemptDone = null;
      await sub.cancel();
      closeQuietly(ws);
    }
    return result;
  }
}
