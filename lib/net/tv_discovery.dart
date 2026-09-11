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
const String mSearchMessage = 'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: 2\r\n'
    'ST: urn:lge-com:service:webos-second-screen:1\r\n'
    '\r\n';

/// SSDP multicast and the /24 port scan run concurrently and write into one
/// ordered, deduplicated result set -- whichever scanner finds an IP first
/// decides its position. Bounded to a 4 s hard cap regardless of whether
/// either scan finished.
///
/// TODO: the Android app binds every socket here to the Wi-Fi/Ethernet
/// `Network` (and holds a multicast lock for the SSDP send) so discovery
/// doesn't silently run over mobile data or fail wifi's multicast permission
/// check -- Dart has no `Network.bindSocket` equivalent, so this port uses
/// unbound sockets (degraded, not fatal: see spec §1.3/§4).
Future<List<String>> discoverTvs() async {
  final results = <String>{};
  try {
    await Future.wait([
      _ssdpScan(results),
      _portScan(results),
    ]).timeout(_hardCap);
  } on TimeoutException {
    // Hard cap reached -- return whatever either scan found so far.
  }
  return results.toList();
}

Future<bool> _confirmWebOsTv(String ip) async {
  // A live SSAP port is what separates a webOS TV from any other UPnP
  // responder (or, for the port scan, any other host on the /24).
  try {
    final socket =
        await Socket.connect(ip, webosPort, timeout: const Duration(milliseconds: 300));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _ssdpScan(Set<String> results) async {
  RawDatagramSocket? socket;
  final pendingConfirms = <Future<void>>[];
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
      final ip = extractIpFromSsdpResponse(text);
      if (ip == null || !checked.add(ip)) return;
      pendingConfirms.add(_confirmWebOsTv(ip).then((ok) {
        if (ok) results.add(ip);
      }));
    });

    await Future.delayed(_scanDuration);
    await sub.cancel();
    try {
      await Future.wait(pendingConfirms).timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // Let discoverTvs()'s outer hard cap take over.
    }
  } finally {
    socket?.close();
  }
}

/// The LOCATION header quirk: `substringAfter(":")` cuts at the FIRST colon,
/// so `LOCATION: http://192.168.1.50:1815/desc.xml` yields
/// ` http://192.168.1.50:1815/desc.xml` before trimming and URI-parsing.
/// Reproduced exactly rather than "fixed" -- it happens to still work
/// because the header's own colon-space separator is what gets cut.
String? extractIpFromSsdpResponse(String response) {
  final lines = response.split(RegExp(r'\r\n|\n'));
  String? locationLine;
  for (final line in lines) {
    if (line.toUpperCase().startsWith('LOCATION')) {
      locationLine = line;
      break;
    }
  }
  if (locationLine == null) return null;
  final colonIndex = locationLine.indexOf(':');
  if (colonIndex == -1) return null;
  final rest = locationLine.substring(colonIndex + 1).trim();
  if (rest.isEmpty) return null;
  try {
    final host = Uri.parse(rest).host;
    return host.isEmpty ? null : host;
  } catch (_) {
    return null;
  }
}

Future<void> _portScan(Set<String> results) async {
  final localIp = await _localIPv4();
  if (localIp == null) return;
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
    await Future.wait(List.generate(poolSize, (_) => worker()))
        .timeout(const Duration(milliseconds: 3000));
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

  final lanNamePattern = RegExp(r'wlan|wi-?fi|en0|en1|eth', caseSensitive: false);
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
