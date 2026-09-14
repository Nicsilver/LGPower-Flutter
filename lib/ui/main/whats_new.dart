import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/prefs.dart';
import '../../net/ir.dart';
import '../../theme/release_notes.dart';
import '../widgets/release_notes_dialog.dart';

/// Spec §5.2. No marker (fresh install that skipped the Setup redirect, or an
/// upgrade from before release notes existed) shows only the newest release;
/// otherwise everything newer than the last seen versionCode. Written only on
/// dismiss, not before showing, so a killed app shows it again.
///
/// [prefs] is optional -- `SharedPreferences.getInstance()` (which
/// `Prefs.load()` wraps) is memoised after the first call, so callers that
/// don't already hold a [Prefs] instance can just await `maybeShowWhatsNew(context)`.
Future<void> maybeShowWhatsNew(BuildContext context, [Prefs? prefs]) async {
  final resolvedPrefs = prefs ?? await Prefs.load();
  final info = await PackageInfo.fromPlatform();
  final versionCode = int.tryParse(info.buildNumber) ?? 0;
  final lastSeen = resolvedPrefs.lastSeenVersion;
  if (lastSeen >= versionCode) return;

  final releases = ReleaseNotes.forDevice(
    lastSeen < 0 ? ReleaseNotes.all.take(1).toList() : ReleaseNotes.since(lastSeen),
    hasIr: await Ir.hasEmitter(),
  );
  if (releases.isEmpty) return;
  if (!context.mounted) return;

  await showReleaseNotesDialog(
    context,
    title: "What's new",
    releases: releases,
    buttonLabel: 'Got it',
  );
  await resolvedPrefs.setLastSeenVersion(versionCode);
}
