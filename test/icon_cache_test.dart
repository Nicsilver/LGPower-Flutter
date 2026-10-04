// The TV's icon server (port 3002) drops or 5xx's connections when a whole app
// list is requested at once. These tests run a local server that does the same.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/webos_client.dart';

// 1x1 transparent PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// Mimics the TV: at most [limit] requests in flight, the rest get a 503 or a
/// dropped socket. [failFirst] additionally fails the first hit of every path.
class _FlakyIconServer {
  _FlakyIconServer({required this.limit, this.failFirst = false});

  final int limit;
  final bool failFirst;
  late final HttpServer server;
  int inFlight = 0;
  int peak = 0;
  final hits = <String, int>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final hit = hits[req.uri.path] = (hits[req.uri.path] ?? 0) + 1;
      if (inFlight >= limit) {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      inFlight++;
      if (inFlight > peak) peak = inFlight;
      // Long enough that unthrottled requests overlap.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      inFlight--;
      if (failFirst && hit == 1) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.write('busy');
      } else {
        req.response.add(_png);
      }
      await req.response.close();
    });
  }

  String url(int i) => 'http://127.0.0.1:${server.port}/icon/$i.png';
  Future<void> stop() => server.close(force: true);
}

Future<WebOsClient> _client() async {
  SharedPreferences.setMockInitialValues({});
  final client = WebOsClient(await Prefs.load());
  await Future<void>.delayed(Duration.zero);
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs every HttpClient with a 400; this suite needs real sockets.
  HttpOverrides.global = null;
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('icons_test');
    PathProviderPlatform.instance = _TempDirPathProvider(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a non-200 reply is not taken for an icon', () async {
    final server = _FlakyIconServer(limit: 1, failFirst: true);
    await server.start();
    addTearDown(server.stop);
    final client = await _client();

    expect(await client.fetchIcon(server.url(0)), isNull);
    expect(await client.fetchIcon(server.url(0)), isNotNull);
  });

  test('loading a big app list leaves no tile without an icon', () async {
    // 40 apps against a server that only copes with 4 at a time and fails the
    // first request for each icon: the old all-at-once fetch lost most of them.
    final server = _FlakyIconServer(limit: 4, failFirst: true);
    await server.start();
    addTearDown(server.stop);
    final client = await _client();
    await client.cacheMissingIcons(const []);

    final apps = [
      for (var i = 0; i < 40; i++) TvApp('app.$i', 'App $i', server.url(i)),
    ];
    final cached = <String>[];
    await client.cacheMissingIcons(
      apps,
      onCached: (a) => cached.add(a.id),
      retryDelay: const Duration(milliseconds: 5),
    );

    expect(cached.length, apps.length);
    for (final app in apps) {
      expect(client.cachedIconFile(app.id), isNotNull, reason: app.id);
    }
    expect(server.peak, lessThanOrEqualTo(4));
  });

  test('a failed download is not cached and is retried on the next load', () async {
    final server = _FlakyIconServer(limit: 0);
    await server.start();
    addTearDown(server.stop);
    final client = await _client();
    final apps = [TvApp('app.x', 'X', server.url(1))];

    await client.cacheMissingIcons(
      apps,
      retryDelay: const Duration(milliseconds: 5),
    );
    expect(client.cachedIconFile('app.x'), isNull);

    final working = _FlakyIconServer(limit: 4);
    await working.start();
    addTearDown(working.stop);
    await client.cacheMissingIcons(
      [TvApp('app.x', 'X', working.url(1))],
      retryDelay: const Duration(milliseconds: 5),
    );
    expect(client.cachedIconFile('app.x'), isNotNull);
  });
  test('a failed write does not block later downloads of the same icons', () async {
    final server = _FlakyIconServer(limit: 4);
    await server.start();
    addTearDown(server.stop);
    final client = await _client();
    final apps = [
      for (var i = 0; i < 10; i++) TvApp('app.$i', 'App $i', server.url(i)),
    ];

    PathProviderPlatform.instance =
        _TempDirPathProvider('${dir.path}/missing');
    await client.cacheMissingIcons(apps);

    PathProviderPlatform.instance = _TempDirPathProvider(dir.path);
    await client.cacheMissingIcons(apps);
    for (final app in apps) {
      expect(client.cachedIconFile(app.id), isNotNull, reason: app.id);
    }
  });
}
