import 'dart:async';
import 'dart:convert';

import '../core/prefs.dart';
import 'command_session.dart';
import 'ssap_messages.dart';
import 'typing_support.dart';

const String _imeBase = 'ssap://com.webos.service.ime';

/// The hidden Settings > About > Keyboard test. Runs one fixed script against
/// the shared command session and returns a plain-text report, so a user whose
/// typing fails can paste back what the TV actually answered. The two control
/// calls tell a blocked keyboard from a broken connection.
class KeyboardProbe {
  KeyboardProbe(
    this.session, {
    required this.header,
    required this.prefs,
    required this.notificationInsert,
    this.listenFor = const Duration(seconds: 15),
    this.onStage,
  });

  final CommandSession session;
  final String header;
  final Prefs prefs;

  /// The createAlert route aimed at insertText; both raw replies.
  final Future<(CmdReply, CmdReply?)> Function(String text) notificationInsert;
  final Duration listenFor;
  final void Function(String stage)? onStage;

  final _clock = Stopwatch();
  // Measured from its own start, not from the whole run, so a slow call
  // earlier on does not eat into the listening time.
  final _window = Stopwatch();
  final _summary = <String>[];
  final _lengths = <int>[];
  // Answers of the plain insertText calls; the verdict follows from them alone.
  final _typingAnswers = <CmdReply>[];
  // Text that lands through the notification route means the sheet can type,
  // so it must not go search-only.
  bool _notificationTyped = false;
  final _log = StringBuffer();

  Future<String> run() async {
    _clock.start();
    _logRegistration();

    onStage?.call('Reading TV info');
    await _call('getSystemInfo', 'ssap://system/getSystemInfo');
    await _call('getSoftwareInformation', 'ssap://com.webos.service.update/getCurrentSWInformation');
    _summary.add('Software version the app stored for this TV: '
        '${TypingSupport.softwareVersion(prefs) ?? 'none (the TV did not report one)'}');

    onStage?.call('Checking the connection');
    await _call('control: getVolume', 'ssap://audio/getVolume');
    await _call(
      'control: getForegroundAppInfo',
      'ssap://com.webos.applicationManager/getForegroundAppInfo',
    );

    onStage?.call('Typing without the keyboard subscription');
    await _typingCall('insertText "A" replace=false', {'text': 'A', 'replace': false});
    await _typingCall('insertText "B" replace=0', {'text': 'B', 'replace': 0});

    await _keyboardWindow();
    await _recordVerdict();

    final out = StringBuffer()
      ..writeln(header)
      ..writeln()
      ..writeln('Summary')
      ..writeln(_summary.join('\n'))
      ..writeln()
      ..write(_log);
    return out.toString().trimRight();
  }

  Future<void> _keyboardWindow() async {
    onStage?.call('Listening to the TV keyboard');
    _window.start();
    _section('registerRemoteKeyboard (${listenFor.inSeconds} s)');
    var pushes = 0;
    final id = session.subscribe(
      '$_imeBase/registerRemoteKeyboard',
      (_) {},
      onFrame: (frame) {
        pushes++;
        _line('push #$pushes ${frame['type']}', frame: frame);
        final length = keyboardTextLengthOf(frame['payload'] as Map<String, dynamic>?);
        if (length != null) _lengths.add(length);
      },
    );
    if (id == null) {
      _summary.add('registerRemoteKeyboard: not sent (session not ready)');
      _line('subscribe not sent: session is ${session.state.name}');
    }

    await _until(listenFor * 0.2);
    await _typingCall('insertText "C" replace=false (subscribed)', {'text': 'C', 'replace': false});
    await _until(listenFor * 0.3);
    await _notificationProbe();
    await _until(listenFor * 0.4);
    await _call(
      'deleteCharacters count=1',
      '$_imeBase/deleteCharacters',
      payload: {'count': 1},
    );
    await _until(listenFor * 0.6);
    await _call('sendEnterKey', '$_imeBase/sendEnterKey');
    await _until(listenFor);

    if (id != null) {
      session.unsubscribe(id);
      _summary.add('registerRemoteKeyboard: $pushes frame(s) in ${listenFor.inSeconds} s');
    }
  }

  Future<void> _typingCall(String label, Map<String, dynamic> payload) async {
    final reply = await _call(label, '$_imeBase/insertText', payload: payload);
    _typingAnswers.add(reply);
  }

  Future<void> _notificationProbe() async {
    _section('insertText "D" through the notification route');
    final before = _lengths.isEmpty ? null : _lengths.last;
    final (alert, close) = await notificationInsert('D');
    _line('alert: ${_statusOf(alert)}', frame: alert is CmdReplyOk ? alert.raw : null);
    if (close != null) _line('close: ${_statusOf(close)}', frame: close is CmdReplyOk ? close.raw : null);
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = _lengths.isEmpty ? null : _lengths.last;
    if (before != null && after != null && after > before) _notificationTyped = true;
    _summary.add('insertText "D" through the notification route: alert ${_statusOf(alert)}'
        '${close == null ? '' : ', close ${_statusOf(close)}'}'
        ', text length ${before == null || after == null ? 'not reported' : after > before ? 'grew' : 'did not grow'}');
  }

  String _statusOf(CmdReply r) => switch (r) {
        CmdReplyOk() => 'OK',
        CmdReplyErr(:final message) => 'ERROR $message',
        CmdReplyNeedsPairing() => 'TV is asking for pairing',
      };

  /// Re-checks the per-TV "typing refused" mark from this run, so a TV is
  /// never stuck as unsupported.
  Future<void> _recordVerdict() async {
    final accepted = _typingAnswers.any((r) => r is CmdReplyOk) || _notificationTyped;
    final refused = _typingAnswers.isNotEmpty &&
        _typingAnswers.every((r) => r is CmdReplyErr && isSsapPermissionError(r.message));
    if (accepted) {
      await TypingSupport.clear(prefs);
      _summary.add('Typing verdict: the TV accepted text, the keyboard is on for this TV');
    } else if (refused) {
      await TypingSupport.markRefused(prefs);
      _summary.add('Typing verdict: the TV refused text with a permission error, '
          'the keyboard now offers a web search on the TV instead');
    } else {
      _summary.add('Typing verdict: unclear, nothing was changed');
    }
  }

  Future<void> _until(Duration at) async {
    final wait = at - _window.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  void _logRegistration() {
    _section('Registration');
    _line('requested permissions: ${ssapPermissions.length}, '
        'CONTROL_INPUT_TEXT requested: ${ssapPermissions.contains('CONTROL_INPUT_TEXT')}');
    final frame = session.registeredFrame;
    _line(
      frame == null ? 'registered frame: none seen on this session' : 'registered frame:',
      frame: frame,
    );
    final perms = (frame?['payload'] as Map?)?['permissions'];
    _line(perms == null
        ? 'granted permissions: not reported by the TV'
        : 'granted permissions: $perms');
  }

  Future<CmdReply> _call(
    String label,
    String uri, {
    Map<String, dynamic> payload = const {},
  }) async {
    _section(label);
    final reply = await session.send(uri, payload: payload, timeoutSecs: 6);
    switch (reply) {
      case CmdReplyOk(:final raw):
        _summary.add('$label: OK');
        _line('ok', frame: raw);
      case CmdReplyErr(:final message, :final raw):
        _summary.add('$label: ERROR $message');
        _line('error: $message', frame: raw);
      case CmdReplyNeedsPairing():
        _summary.add('$label: TV is asking for pairing');
        _line('the TV is waiting for the pairing prompt to be accepted');
    }
    return reply;
  }

  void _section(String title) => _log.writeln('\n== $title ==');

  void _line(String text, {Map<String, dynamic>? frame}) {
    _log.writeln('[${_stamp()}] $text');
    if (frame != null) _log.writeln('  ${trimFrame(frame)}');
  }

  String _stamp() => '+${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';
}

/// One frame as a single line: the client key and the TV's identifiers
/// (MAC, device id, serial, address) never leave the phone, and a
/// long frame (system info, app lists) is cut so a report stays pasteable.
String trimFrame(Map<String, dynamic> frame, {int max = 500}) {
  final text = jsonEncode(_redact(frame));
  if (text.length <= max) return text;
  return '${text.substring(0, max)}... (${text.length - max} more characters)';
}

// getCurrentSWInformation's device_id is the TV's MAC, so MAC-shaped values
// are caught wherever they turn up, not only under known keys.
final _macPattern = RegExp(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}');

bool _sensitiveKey(String key) {
  final k = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return k == 'clientkey' ||
      k == 'ip' ||
      k.contains('ipaddress') ||
      k.contains('mac') ||
      k.contains('serial') ||
      k.contains('deviceid') ||
      k.contains('uuid');
}

Object? _redact(Object? value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        e.key: e.key is String && _sensitiveKey(e.key as String)
            ? '<redacted>'
            : _redact(e.value),
    };
  }
  if (value is List) return [for (final e in value) _redact(e)];
  if (value is String) return value.replaceAll(_macPattern, '<redacted>');
  return value;
}
