import 'dart:io';
import 'dart:typed_data';

/// Sends the Wake-on-LAN magic packet once to the limited broadcast address.
/// No SecureOn password; every failure is swallowed -- a wake attempt that
/// can't even send is not worth surfacing as an error to the user.
Future<void> sendWakeOnLan(String mac) async {
  final packet = buildMagicPacket(mac);
  if (packet == null) return;
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.send(packet, InternetAddress('255.255.255.255'), 9);
  } catch (_) {
    // Swallowed -- see doc comment.
  } finally {
    socket?.close();
  }
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
