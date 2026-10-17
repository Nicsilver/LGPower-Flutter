import 'dart:async';
import 'dart:io';

/// Opens a WebSocket to [url]. Injectable into the sessions so tests can
/// serve plain `ws://` from a local fake TV.
typedef SocketConnector = Future<WebSocket> Function(String url);

// dart:io's HttpClient already sets TCP_NODELAY on every socket it opens, and
// WebSocket.connect upgrades one of those, so small frames are not held back
// by Nagle.
Future<WebSocket> connectTrustAll(String url) {
  final client = HttpClient();
  client.badCertificateCallback = (cert, host, port) => true;
  // Without it a dead address holds the connect for the OS timeout (minutes),
  // long after the caller gave up on it.
  client.connectionTimeout = const Duration(seconds: 3);
  return WebSocket.connect(url, customClient: client);
}

/// Connects through [connector] but gives up after [timeout]. A connect that
/// completes after that is closed instead of being left open with no owner.
Future<WebSocket> connectWithTimeout(
  SocketConnector connector,
  String url,
  Duration timeout,
) async {
  final pending = connector(url);
  try {
    return await pending.timeout(timeout);
  } on TimeoutException {
    unawaited(pending.then<void>((ws) => ws.close(1000)).catchError((_) {}));
    rethrow;
  }
}

/// Closes [ws] without letting a socket error surface as an unhandled async
/// exception: nothing is left to react to it once the session is done.
void closeQuietly(WebSocket? ws) {
  if (ws == null) return;
  try {
    unawaited(ws.close(1000).catchError((_) {}));
  } catch (_) {}
}
