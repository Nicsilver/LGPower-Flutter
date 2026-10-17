import 'dart:io';

/// Opens a WebSocket to [url]. Injectable into the sessions so tests can
/// serve plain `ws://` from a local fake TV.
typedef SocketConnector = Future<WebSocket> Function(String url);

// dart:io's HttpClient already sets TCP_NODELAY on every socket it opens, and
// WebSocket.connect upgrades one of those, so small frames are not held back
// by Nagle.
Future<WebSocket> connectTrustAll(String url) => WebSocket.connect(
      url,
      customClient: HttpClient()..badCertificateCallback = (cert, host, port) => true,
    );
