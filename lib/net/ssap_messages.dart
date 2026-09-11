import 'dart:convert';

/// 37 flat permissions, in this exact order. webOS 25/26 firmware silently
/// drops registrations carrying the legacy `signatures`/`signed` block, so
/// the manifest below (mirroring aiowebostv's webOS 26 handshake fix,
/// home-assistant-libs#719) must stay flat with no signature block.
const List<String> ssapPermissions = [
  'APP_TO_APP',
  'CLOSE',
  'CONTROL_AUDIO',
  'CONTROL_DISPLAY',
  'CONTROL_INPUT_JOYSTICK',
  'CONTROL_INPUT_MEDIA_PLAYBACK',
  'CONTROL_INPUT_MEDIA_RECORDING',
  'CONTROL_INPUT_TEXT',
  'CONTROL_INPUT_TV',
  'CONTROL_MOUSE_AND_KEYBOARD',
  'CONTROL_POWER',
  'CONTROL_TV_SCREEN',
  'LAUNCH',
  'LAUNCH_WEBAPP',
  'READ_APP_STATUS',
  'READ_COUNTRY_INFO',
  'READ_CURRENT_CHANNEL',
  'READ_INPUT_DEVICE_LIST',
  'READ_INSTALLED_APPS',
  'READ_LGE_SDX',
  'READ_LGE_TV_INPUT_EVENTS',
  'READ_NETWORK_STATE',
  'READ_NOTIFICATIONS',
  'READ_POWER_STATE',
  'READ_RUNNING_APPS',
  'READ_SETTINGS',
  'READ_TV_CHANNEL_LIST',
  'READ_TV_CURRENT_TIME',
  'READ_UPDATE_INFO',
  'SEARCH',
  'TEST_OPEN',
  'TEST_PROTECTED',
  'TEST_SECURE',
  'UPDATE_FROM_REMOTE_APP',
  'WRITE_NOTIFICATION_ALERT',
  'WRITE_NOTIFICATION_TOAST',
  'WRITE_SETTINGS',
];

const String regMessageId = 'reg_0';
const String macLookupMessageId = 's_mac';

/// `client-key` is omitted entirely (not sent as null) when there is no
/// saved key yet — the TV treats a present-but-null key differently from an
/// absent one on some firmware.
Map<String, dynamic> buildRegistration(String? clientKey) {
  return {
    'id': regMessageId,
    'type': 'register',
    'payload': {
      'forcePairing': false,
      'pairingType': 'PROMPT',
      if (clientKey != null && clientKey.isNotEmpty) 'client-key': clientKey,
      'manifest': {
        'manifestVersion': 1,
        'appVersion': '1.1',
        'permissions': ssapPermissions,
      },
    },
  };
}

/// Ids for requests/subscriptions all come from one counter per socket:
/// `c<N>` for a request, `s<N>` for a subscription. `reg_0` and `s_mac` are
/// fixed ids handled specially by [CommandSession], never drawn from here.
class SsapIdSequence {
  int _seq = 0;

  String nextRequestId() => 'c${++_seq}';
  String nextSubscriptionId() => 's${++_seq}';
}

Map<String, dynamic> decodeSsapMessage(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

String encodeSsapMessage(Map<String, dynamic> message) => jsonEncode(message);
