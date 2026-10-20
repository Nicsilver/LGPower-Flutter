import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/contact_mail.dart';
import '../../net/keyboard_probe.dart';
import '../../net/webos_client.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_toast.dart';
import '../widgets/buttons.dart';
import '../widgets/ios_back_button.dart';
import '../widgets/section.dart';

/// Hidden diagnostic behind a long-press on the About card in Settings. Runs
/// [KeyboardProbe] against the active TV and offers the result as text to
/// copy, so a typing problem can be reported with what the TV answered.
class KeyboardTestScreen extends StatefulWidget {
  const KeyboardTestScreen({super.key, required this.client});

  final WebOsClient client;

  @override
  State<KeyboardTestScreen> createState() => _KeyboardTestScreenState();
}

class _KeyboardTestScreenState extends State<KeyboardTestScreen> {
  static const _letters = ['A', 'B', 'C'];

  bool _running = false;
  String _stage = '';
  String? _report;
  final _seen = <String>{};

  Future<String> _header() async {
    var app = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      app = '${info.appName} ${info.version} (${info.buildNumber})';
    } catch (_) {
      // The header is context for the reader; the test runs without it.
    }
    final (os, phone) = await ContactMail.deviceInfo();
    return 'Keyboard test report\n'
        'App: $app\n'
        'Phone: $phone\n'
        'OS: $os\n'
        'Time: ${DateTime.now().toUtc().toIso8601String()}';
  }

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _report = null;
      _seen.clear();
      _stage = 'Starting';
    });
    final header = await _header();
    final probe = KeyboardProbe(
      widget.client.diagnosticSession(),
      header: header,
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
    );
    final report = await probe.run();
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report;
    });
  }

  String get _fullReport {
    final seen = [for (final l in _letters) if (_seen.contains(l)) l];
    return '${_report ?? ''}\n\n'
        '== Letters on the TV afterwards ==\n'
        'A and B were typed before the keyboard subscription, C during it, '
        'then one character was deleted.\n'
        'Visible in the TV text field: ${seen.isEmpty ? 'none' : seen.join(', ')}';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullReport));
    if (mounted) showToast(context, 'Report copied');
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final report = _report;
    return Scaffold(
      backgroundColor: theme.windowBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, IosBackButton.visible(context) ? 4 : 20, 16, 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IosBackButton('Settings'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Keyboard test',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: theme.primaryText,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Padding(padding: EdgeInsets.only(bottom: 8), child: SectionLabel('Run')),
              SurfaceCard(
                radius: 14,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Open the TV search so the on-screen keyboard shows, then tap Start. '
                        'The test takes about 20 seconds and types the letters A, B and C '
                        'into the TV.',
                        style: TextStyle(fontSize: 14, height: 1.4, color: theme.primaryText),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: AccentButton(
                          label: _running ? _stage : (report == null ? 'Start' : 'Run again'),
                          height: 48,
                          onPressed: _running ? null : () => unawaited(_start()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (report != null) ...[
                const SizedBox(height: 28),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: SectionLabel('What is in the TV text field now?'),
                ),
                SurfaceCard(
                  radius: 14,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 10,
                      children: [
                        for (final l in _letters)
                          FilterChip(
                            key: Key('seen_$l'),
                            label: Text(l),
                            selected: _seen.contains(l),
                            onSelected: (on) => setState(() {
                              on ? _seen.add(l) : _seen.remove(l);
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Padding(padding: EdgeInsets.only(bottom: 8), child: SectionLabel('Report')),
                SurfaceCard(
                  radius: 14,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      _fullReport,
                      key: const Key('keyboard_report'),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        fontFamily: 'monospace',
                        color: theme.secondaryText,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: AccentButton(
                    label: 'Copy report',
                    height: 48,
                    onPressed: () => unawaited(_copy()),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
