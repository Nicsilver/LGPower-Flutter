import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// `flutter test` on Windows wires up the real `path_provider_windows`
/// platform channel (unlike mobile, where `testWidgets` intercepts every
/// channel by default), so `WebOsClient`/`ThemeManager` reach a genuine
/// native call for a path. Worse, this host also runs an unrelated,
/// exhaustive filesystem scan for much of this session, which puts every
/// *fresh* `File`/`Directory` stat (even on an already-warm parent) behind a
/// long real disk queue -- so returning a real, resolvable directory here
/// just relocates the hang to the caller's `File(...).exists()` check.
///
/// Returning null instead reproduces the "no platform implementation"
/// fallback both callers already handle for headless/CI test runs
/// (`WebOsClient._primeIconDir` catches it and leaves icon caching off;
/// `ThemeManager.loadTheme` catches it and skips straight to the bundled
/// asset, matching a fresh install with no custom themes) -- so it's
/// exercising a real, already-tested code path, not inventing a shortcut.
class FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => null;

  @override
  Future<String?> getApplicationSupportPath() async => null;

  @override
  Future<String?> getApplicationDocumentsPath() async => null;

  @override
  Future<String?> getLibraryPath() async => null;

  @override
  Future<String?> getDownloadsPath() async => null;
}

void installFakePathProvider() {
  PathProviderPlatform.instance = FakePathProviderPlatform();
}
