import 'dart:io';
import 'dart:typed_data';

/// Sends the Wake-on-LAN magic packet. The limited broadcast is what the
/// Android app sends first; a TV on another VLAN never sees it, so the packet
/// also goes to the directed broadcast of the TV's own subnet and as a plain
/// unicast to its last known address (works while the gateway still has an
/// ARP entry for the sleeping TV). On iOS the broadcasts need Apple's
/// multicast entitlement and fail with "No route to host" without it, which
/// leaves the unicast copies on ports 9 and 7. An LG set in Quick Start
/// standby keeps its network stack up and still answers ARP, which is what
/// makes the unicast copy deliverable. No SecureOn password; every failure is
/// swallowed -- a wake attempt that can't even send is not worth surfacing
/// as an error to the user.
Future<void> sendWakeOnLan(String mac, {String tvIp = ''}) async {
  final packet = buildMagicPacket(mac);
  if (packet == null) return;
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final unicast = InternetAddress.tryParse(tvIp);
    final directed = _directedBroadcast(tvIp);
    for (var burst = 0; burst < 3; burst++) {
      if (burst > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      try {
        socket.broadcastEnabled = true;
        socket.send(packet, InternetAddress('255.255.255.255'), 9);
        if (directed != null) socket.send(packet, directed, 9);
      } catch (_) {
        // Not entitled to broadcast (iOS); the unicast copies still go out.
      }
      if (unicast != null) {
        socket.send(packet, unicast, 9);
        socket.send(packet, unicast, 7);
      }
    }
  } catch (_) {
    // Swallowed -- see doc comment.
  } finally {
    socket?.close();
  }
}

InternetAddress? _directedBroadcast(String tvIp) {
  final parts = tvIp.split('.');
  if (parts.length != 4) return null;
  return InternetAddress.tryParse('${parts[0]}.${parts[1]}.${parts[2]}.255');
}

/// 102 bytes: six 0xFF bytes followed by the 6-byte MAC repeated 16 times.
/// Returns null for an empty MAC or one that isn't 6 colon-separated hex
/// bytes (an empty `tv_mac` pref means Wake-on-LAN is a no-op).
Uint8List? buildMagicPacket(String mac) {
  if (mac.isEmpty) return null;
  final parts = mac.split(':');
  if (parts.length != 6) return null;

  final macBytes = Uint8List(6);
  for (var i = 0; i < 6; i++) {
    final byte = int.tryParse(parts[i], radix: 16);
    if (byte == null) return null;
    macBytes[i] = byte;
  }

  final packet = Uint8List(6 + 16 * 6);
  for (var i = 0; i < 6; i++) {
    packet[i] = 0xFF;
  }
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < 6; j++) {
      packet[6 + i * 6 + j] = macBytes[j];
    }
  }
  return packet;
}
