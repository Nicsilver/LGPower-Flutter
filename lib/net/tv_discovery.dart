import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String ssdpAddr = '239.255.255.250';
const int ssdpPort = 1900;
const int webosPort = 3001;
const Duration _scanDuration = Duration(seconds: 3);
const Duration _hardCap = Duration(seconds: 4);

/// Ask only for the webOS service -- ssdp:all/DIAL make every UPnP device on
/// the network respond (PCs, routers, phones). CRLF line endings, trailing
/// blank line.
const String mSearchMessage =
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: 2\r\n'
    'ST: urn:lge-com:service:webos-second-screen:1\r\n'
    '\r\n';

/// A found TV: address plus, when it answered SSDP, the unique device name
/// from its description.
class FoundTv {
  const FoundTv(this.ip, this.udn);
  final String ip;
  final String? udn;
}

/// Blocking discovery, addresses only (see [discoverTvsDetailed]).
Future<List<String>> discoverTvs() async => [
  for (final f in await discoverTvsDetailed()) f.ip,
];

/// SSDP multicast and the /24 port scan run concurrently and write into one
/// ordered, deduplicated result set -- whichever scanner finds an IP first
/// decides its position. Bounded to a 4 s hard cap regardless of whether
/// either scan finished. A TV joined to the phone's own hotspot lives on a
/// subnet the primary interface does not cover, so every other site-local
/// interface gets the same pair of scans.
///
/// The Android app binds every socket here to the Wi-Fi/Ethernet `Network`
/// (and holds a multicast lock for the SSDP send) so discovery doesn't
/// silently run over mobile data -- Dart has no `Network.bindSocket`
/// equivalent, so this port uses sockets bound to the interface address
/// instead (degraded, not fatal: see spec §1.3/§4).
Future<List<FoundTv>> discoverTvsDetailed() async {
  final results = <String>{};
  final locations = <String, String>{};
  try {
    final primary = await _localIPv4();
    final extra = (await _siteLocalAddresses())
        .where((a) => primary == null || _subnetOf(a) != _subnetOf(primary))
        .toList();
    await Future.wait([
      _ssdpScan(results, locations, bindTo: null),
      if (primary != null) _portScan(primary, results),
      // Only subnets the LAN scan does not already cover; a second sweep of
      // the same range just competes for the 3 s window
      for (final a in extra) ...[
        _ssdpScan(results, locations, bindTo: a),
        _portScan(a, results),
      ],
    ]).timeout(_hardCap);
  } on TimeoutException {
    // Hard cap reached -- return whatever either scan found so far.
  }
  final found = <FoundTv>[];
  for (final ip in results) {
    final location = locations[ip];
    found.add(FoundTv(ip, location == null ? null : await _udnFrom(location)));
  }
  return found;
}

/// Unicast SSDP search straight at one address, for TVs that were typed in
/// by hand. Returns the UDN, or null if nothing answered within a second.
Future<String?> fingerprintTv(String ip) async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.send(utf8.encode(mSearchMessage), InternetAddress(ip), ssdpPort);
    final completer = Completer<String?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dgram = socket?.receive();
      if (dgram == null) return;
      final location = _locationOf(
        utf8.decode(dgram.data, allowMalformed: true),
      );
      if (location != null && !completer.isCompleted) {
        completer.complete(location);
      }
    });
    final location = await completer.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () => null,
    );
    await sub.cancel();
    return location == null ? null : await _udnFrom(location);
  } catch (_) {
    return null;
  } finally {
    socket?.close();
  }
}

Future<String?> _udnFrom(String location) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 800);
    final request = await client.getUrl(Uri.parse(location));
    final response = await request.close().timeout(
      const Duration(milliseconds: 800),
    );
    final xml = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(milliseconds: 800));
    final match = RegExp(
      r'<UDN>\s*(?:uuid:)?([^<]+?)\s*</UDN>',
      caseSensitive: false,
    ).firstMatch(xml);
    return match?.group(1)?.trim();
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

Future<bool> _confirmWebOsTv(String ip) async {
  // A live SSAP port is what separates a webOS TV from any other UPnP
  // responder (or, for the port scan, any other host on the /24).
  try {
    final socket = await Socket.connect(
      ip,
      webosPort,
      timeout: const Duration(milliseconds: 300),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _ssdpScan(
  Set<String> results,
  Map<String, String> locations, {
  required String? bindTo,
}) async {
  RawDatagramSocket? socket;
  final pendingConfirms = <Future<void>>[];
  try {
    socket = await RawDatagramSocket.bind(
      bindTo == null ? InternetAddress.anyIPv4 : InternetAddress(bindTo),
      0,
    );
    socket.broadcastEnabled = true;
    final target = InternetAddress(ssdpAddr);
    final bytes = utf8.encode(mSearchMessage);
    // Sent twice: UDP.
    socket.send(bytes, target, ssdpPort);
    socket.send(bytes, target, ssdpPort);

    final checked = <String>{};
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dgram = socket?.receive();
      if (dgram == null) return;
      final text = utf8.decode(dgram.data, allowMalformed: true);
      final location = _locationOf(text);
      final ip = extractIpFromSsdpResponse(text);
      if (ip == null || !checked.add(ip)) return;
      if (location != null) locations[ip] = location;
      pendingConfirms.add(
        _confirmWebOsTv(ip).then((ok) {
          if (ok) results.add(ip);
        }),
      );
    });

    await Future.delayed(_scanDuration);
    await sub.cancel();
    try {
      await Future.wait(
        pendingConfirms,
      ).timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // Let discoverTvs()'s outer hard cap take over.
    }
  } catch (_) {
    // A hotspot interface that vanished mid-scan, or one that refuses
    // multicast -- the other scanners still run.
  } finally {
    socket?.close();
  }
}

String? _locationOf(String response) {
  for (final line in response.split(RegExp(r'\r\n|\n'))) {
    if (line.toUpperCase().startsWith('LOCATION')) {
      final colonIndex = line.indexOf(':');
      if (colonIndex == -1) return null;
      final rest = line.substring(colonIndex + 1).trim();
      return rest.isEmpty ? null : rest;
    }
  }
  return null;
}

/// The LOCATION header quirk: `substringAfter(":")` cuts at the FIRST colon,
/// so `LOCATION: http://192.168.1.50:1815/desc.xml` yields
/// ` http://192.168.1.50:1815/desc.xml` before trimming and URI-parsing.
/// Reproduced exactly rather than "fixed" -- it happens to still work
/// because the header's own colon-space separator is what gets cut.
String? extractIpFromSsdpResponse(String response) {
  final location = _locationOf(response);
  if (location == null) return null;
  try {
    final host = Uri.parse(location).host;
    return host.isEmpty ? null : host;
  } catch (_) {
    return null;
  }
}

String _subnetOf(String ip) {
  final parts = ip.split('.');
  return parts.length == 4 ? '${parts[0]}.${parts[1]}.${parts[2]}' : ip;
}

Future<void> _portScan(String localIp, Set<String> results) async {
  final parts = localIp.split('.');
  if (parts.length != 4) return;
  final base = '${parts[0]}.${parts[1]}.${parts[2]}';

  final deadline = DateTime.now().add(const Duration(milliseconds: 3000));
  final hosts = List.generate(254, (i) => '$base.${i + 1}');
  var nextIndex = 0;

  Future<void> worker() async {
    while (nextIndex < hosts.length && DateTime.now().isBefore(deadline)) {
      final host = hosts[nextIndex++];
      if (await _confirmWebOsTv(host)) results.add(host);
    }
  }

  // 50 parallel connects, 300 ms timeout each -- ~2 s for 254 hosts.
  const poolSize = 50;
  try {
    await Future.wait(
      List.generate(poolSize, (_) => worker()),
    ).timeout(const Duration(milliseconds: 3000));
  } on TimeoutException {
    // Let discoverTvs()'s outer hard cap take over.
  }
}

/// First non-loopback IPv4 address, preferring an interface that looks like
/// Wi-Fi/Ethernet over one that could be cellular.
Future<String?> _localIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  if (interfaces.isEmpty) return null;

  final lanNamePattern = RegExp(
    r'wlan|wi-?fi|en0|en1|eth',
    caseSensitive: false,
  );
  NetworkInterface? chosen;
  for (final iface in interfaces) {
    if (iface.addresses.isEmpty) continue;
    if (lanNamePattern.hasMatch(iface.name)) {
      chosen = iface;
      break;
    }
  }
  chosen ??= interfaces.firstWhere(
    (iface) => iface.addresses.isNotEmpty,
    orElse: () => interfaces.first,
  );
  return chosen.addresses.isNotEmpty ? chosen.addresses.first.address : null;
}

/// Every private IPv4 address the phone holds, one per /24. A hotspot is an
/// up interface with a private address of its own (`swlan0`, `ap0`, …),
/// which is how a TV tethered to the phone becomes reachable at all.
Future<List<String>> _siteLocalAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final seen = <String>{};
    final out = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!_isSiteLocal(addr) || addr.isLinkLocal) continue;
        if (seen.add(_subnetOf(addr.address))) out.add(addr.address);
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

bool _isSiteLocal(InternetAddress addr) {
  final b = addr.rawAddress;
  if (b.length != 4) return false;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}
