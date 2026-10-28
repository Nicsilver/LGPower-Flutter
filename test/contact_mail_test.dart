import 'package:flutter_test/flutter_test.dart';
import 'package:lgpower/core/contact_mail.dart';

void main() {
  test('subject names the app and version', () {
    expect(
      ContactMail.subject(appName: 'Tiny TV Remote', version: '1.40.7'),
      'Tiny TV Remote feedback (1.40.7)',
    );
  });

  test('mailto uri encodes spaces as %20 and newlines as %0A', () {
    final body = ContactMail.body(
      version: '1.40.7',
      build: '53',
      os: 'iOS 18.1',
      phone: 'iPhone 15',
    );
    final uri = ContactMail.uri(
      subject: ContactMail.subject(appName: 'Tiny TV Remote', version: '1.40.7'),
      body: body,
    );
    final text = uri.toString();
    expect(text, startsWith('mailto:nic.silver@hotmail.dk?subject=Tiny%20TV%20Remote%20feedback%20(1.40.7)&body=%0A%0A%0A'));
    expect(text, isNot(contains('+')));
    expect(uri.queryParameters['body'], body);
    expect(body, contains('App: 1.40.7 (53)'));
    expect(body, contains('OS: iOS 18.1'));
    expect(body, contains('Phone: iPhone 15'));
  });
}
