import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/contact_mail.dart';
import '../../core/wifi_radio.dart';
import '../../net/conn_report.dart';
import '../../net/webos_client.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import 'buttons.dart';

Future<String> _collect(WebOsClient client, void Function(String) onStage) async {
  final heldBefore = await WifiRadio.lowLatencyHeld;
  // The lock is taken for the test so the numbers are those of the radio mode
  // the remote runs in, whatever screen the report was started from.
  final held = await WifiRadio.acquireLowLatency();
  TvProbe tv;
  try {
    tv = await client.probeConnection(onStage: onStage);
  } catch (e) {
    tv = TvProbe(failure: '${e.runtimeType}: $e');
  } finally {
    if (!heldBefore) WifiRadio.releaseLowLatency();
  }
  var versionName = 'unknown';
  var versionCode = 'unknown';
  try {
    final info = await PackageInfo.fromPlatform();
    versionName = info.version;
    versionCode = info.buildNumber;
  } catch (_) {
    // The report is still useful without the app version.
  }
  final (os, phone) = await ContactMail.deviceInfo();
  const lockName = 'low-latency';
  return ConnReport.finish(ReportInputs(
    appName: 'LG Power (Flutter)',
    versionName: versionName,
    versionCode: versionCode,
    phone: phone,
    os: os,
    wifi: await WifiRadio.snapshot(),
    lockLine: !WifiRadio.supported
        ? 'not used on this platform'
        : (held ? '$lockName, held during the test' : '$lockName requested, not granted'),
    tv: tv,
    deaths: DeathLog.shared.recent,
    now: DateTime.now(),
  ));
}

/// Settings > About > Copy connection report: runs the probe behind a progress
/// sheet, then offers the text to copy. Nothing leaves the phone.
Future<void> showConnReportSheet(BuildContext context, WebOsClient client) {
  final theme = AppTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    shape: const RoundedRectangleBorder(),
    isScrollControlled: true,
    builder: (_) => _ConnReportSheet(theme: theme, client: client),
  );
}

class _ConnReportSheet extends StatefulWidget {
  const _ConnReportSheet({required this.theme, required this.client});

  final ThemeConfig theme;
  final WebOsClient client;

  @override
  State<_ConnReportSheet> createState() => _ConnReportSheetState();
}

class _ConnReportSheetState extends State<_ConnReportSheet> {
  String _stage = 'Starting';
  String? _report;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final text = await _collect(widget.client, (s) {
      if (mounted) setState(() => _stage = s);
    });
    if (mounted) setState(() => _report = text);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report!));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final report = _report;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.82),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      decoration: BoxDecoration(
        color: theme.surfaceBg,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: theme.divider, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(
              'Connection report',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.primaryText),
            ),
            if (report == null)
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: theme.btnAccentBg),
                    ),
                    const SizedBox(width: 12),
                    Text(_stage, style: TextStyle(fontSize: 13, color: theme.secondaryText)),
                  ],
                ),
              )
            else ...[
              const SizedBox(height: 10),
              Flexible(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.windowBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: SelectableText(
                      report,
                      key: const Key('conn_report_text'),
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        fontFamily: 'monospace',
                        color: theme.primaryText,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: AccentButton(
                  label: _copied ? 'Copied' : 'Copy',
                  height: 46,
                  radius: 11,
                  onPressed: () => unawaited(_copy()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
