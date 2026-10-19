import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds the pre-filled support email behind Settings > About > Contact. The
/// app sends nothing itself: the draft opens in the user's own mail app.
class ContactMail {
  const ContactMail._();

  static const address = 'nic.silver@hotmail.dk';

  static String subject({required String appName, required String version}) =>
      '$appName feedback ($version)';

  static String body({
    required String version,
    required String build,
    required String os,
    required String phone,
  }) =>
      '\n\n\nApp: $version ($build)\nOS: $os\nPhone: $phone\n';

  /// `Uri(queryParameters:)` encodes spaces as `+`, which mail apps show
  /// literally in a mailto: draft, so the query is joined by hand with %20.
  static Uri uri({required String subject, required String body}) => Uri(
        scheme: 'mailto',
        path: address,
        query: 'subject=${Uri.encodeComponent(subject)}'
            '&body=${Uri.encodeComponent(body)}',
      );

  /// Returns false when no mail app took the draft; the address is then on the
  /// clipboard so the caller can say so.
  static Future<bool> open() async {
    final package = await PackageInfo.fromPlatform();
    final (os, phone) = await _device();
    final mailto = uri(
      subject: subject(appName: package.appName, version: package.version),
      body: body(
        version: package.version,
        build: package.buildNumber,
        os: os,
        phone: phone,
      ),
    );
    try {
      if (await launchUrl(mailto, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {
      // Fall through: a missing handler can surface as an exception too.
    }
    await Clipboard.setData(const ClipboardData(text: address));
    return false;
  }

  static Future<(String os, String phone)> _device() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return (
          'Android ${info.version.release} (API ${info.version.sdkInt})',
          '${info.manufacturer} ${info.model}',
        );
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final model = info.modelName.isNotEmpty ? info.modelName : info.utsname.machine;
        return ('iOS ${info.systemVersion}', model);
      }
    } catch (_) {
      // The info block is a convenience; the mail still goes out without it.
    }
    return (Platform.operatingSystem, 'unknown');
  }
}
