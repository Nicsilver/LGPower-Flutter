import 'dart:async';

enum ResumeStep { probe, reset }

/// What the remote does with the shared connections when it comes back to the
/// front.
///
/// Resetting every time cost a full handshake on the first key (one to five
/// seconds on a slow Wi-Fi). The command socket is the only one the TV answers
/// on, so one request has to come back on it before it and the pointer beside
/// it are trusted; traffic seen a moment ago proves nothing, since frames
/// buffered while the app was frozen look like fresh ones. A socket that is not
/// registered and open has nothing worth keeping.
ResumeStep resumeStep({required bool commandReady}) =>
    commandReady ? ResumeStep.probe : ResumeStep.reset;

/// Holds key presses and taps while a resume check decides whether the old
/// sockets still work. A key sent on a half-open pointer is lost without any
/// error, so it waits for the verdict instead; on a live link that is one round
/// trip, usually over before the first tap.
class ResumeGate {
  _Check? _current;

  // Taps handed to [runAfter] that have not been sent yet.
  int _held = 0;
  Future<void> _tail = Future.value();

  bool get isOpen => _current == null;

  /// Closes the gate until [end] is called with the returned check.
  Object begin() => _current = _Check();

  void end(Object check) {
    final c = check as _Check;
    if (!c.done.isCompleted) c.done.complete();
    if (identical(_current, c)) _current = null;
  }

  /// Completes when the running check ends, if any, but never later than [max]
  /// so a stuck one can't hold keys. Already complete on an open gate.
  Future<void> wait(Duration max) {
    final check = _current;
    if (check == null) return Future.value();
    final timedOut = Completer<void>();
    final timer = Timer(max, () {
      if (!timedOut.isCompleted) timedOut.complete();
    });
    return Future.any([check.done.future, timedOut.future]).whenComplete(timer.cancel);
  }

  /// Runs [send] now on an open gate with nothing queued ahead of it, else
  /// once the verdict is in. Held sends leave one after another in the order
  /// they were made, so a BACK and a click queued together never swap. The
  /// caller never waits.
  void runAfter(Duration max, void Function() send) {
    if (isOpen && _held == 0) {
      send();
      return;
    }
    _held++;
    final verdict = wait(max);
    _tail = _tail.then((_) async {
      try {
        await verdict;
      } finally {
        _held--;
      }
      try {
        send();
      } catch (e, s) {
        // One failing send must not stop the taps queued behind it.
        Zone.current.handleUncaughtError(e, s);
      }
    });
  }
}

class _Check {
  final done = Completer<void>();
}

/// True when [answered] completes within [max]. A socket that dies meanwhile
/// ([died]) ends the wait early instead of at the budget. Both are only
/// listened to, never cancelled.
Future<bool> awaitReply({
  required Future<void> answered,
  required Future<void> died,
  required Duration max,
}) {
  final timedOut = Completer<bool>();
  final timer = Timer(max, () => timedOut.complete(false));
  return Future.any<bool>([
    answered.then((_) => true),
    died.then((_) => false),
    timedOut.future,
  ]).whenComplete(timer.cancel);
}

/// Runs the resume probe with the stale mark already set: a TV that resets the
/// socket kills it before the verdict, and the power watcher must read that as a
/// replaced socket, not standby. Only a reply clears the mark.
Future<bool> probeCommand({
  required void Function(bool) markStale,
  required Future<bool> Function() probe,
}) async {
  markStale(true);
  final answered = await probe();
  if (answered) markStale(false);
  return answered;
}

/// The pointer has no ping and the TV never writes on it, so a close sent while
/// the phone dozed is never heard; the only sign is how long nothing went over
/// it. A dead one stays put because it carries the retry pause.
bool shouldReplaceIdlePointer({
  required bool dead,
  required Duration idle,
  required Duration maxIdle,
}) =>
    !dead && idle > maxIdle;

/// A pointer opened since the check began is not the one it looked at and is
/// left alone.
bool sameSession<T extends Object>(T shared, T? seen) => seen != null && identical(shared, seen);
