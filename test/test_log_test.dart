import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lgpower/core/test_log.dart';

void main() {
  test('fields keep their order after app, t and ev', () {
    final s = formatTestLine('f', 123456789, 'key', {'sid': 'ptr3', 'n': 7, 'st': 'sent', 'name': 'UP'});
    expect(s, '{"app":"f","t":123456789,"ev":"key","sid":"ptr3","n":7,"st":"sent","name":"UP"}');
  });

  test('null fields are left out and booleans stay booleans', () {
    final s = formatTestLine('f', 5, 'res', {'ok': false, 'err': null, 'id': 'c1'});
    expect(s, '{"app":"f","t":5,"ev":"res","ok":false,"id":"c1"}');
  });

  test('a line is one line and strings survive a round trip', () {
    const nasty = 'a"b\\c\nd\u0001';
    final s = formatTestLine('f', 1, 'sock', {'reason': nasty});
    expect(s.contains('\n'), isFalse);
    expect((jsonDecode(s) as Map)['reason'], nasty);
  });

  test('logging calls are inert without a native log', () {
    expect(TestLog.nextSid('cmd'), 'cmd1');
    expect(TestLog.nextSid('cmd'), 'cmd2');
    expect(TestLog.nextSid('ptr'), 'ptr1');
    TestLog.key('ptr1', 1, 'sent', 'UP');
    TestLog.sock('cmd', 'cmd1', 'close', code: 1000);
  });
}
