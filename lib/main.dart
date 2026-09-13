import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/prefs.dart';
import 'core/tv_store.dart';
import 'net/webos_client.dart';
import 'theme/theme_manager.dart';
import 'ui/main/main_screen.dart';
import 'ui/setup/setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final prefs = await Prefs.load();
  // Folds a pre-saved-TVs install's flat prefs into the TV list before any
  // screen reads it
  TvStore.list(prefs);
  final client = WebOsClient(prefs);
  final controller = await AppThemeController.load();

  if (prefs.tvIp.isEmpty) {
    // Mirrors MainActivity's pre-setContentView redirect (spec §1.1): a
    // fresh install (or one that never finished Setup) must never show a
    // what's-new dialog once Setup completes.
    final info = await PackageInfo.fromPlatform();
    final versionCode = int.tryParse(info.buildNumber) ?? 0;
    await prefs.setLastSeenVersion(versionCode);
  }

  runApp(LgPowerApp(prefs: prefs, client: client, controller: controller));
}

class LgPowerApp extends StatelessWidget {
  const LgPowerApp({super.key, required this.prefs, required this.client, required this.controller});

  final Prefs prefs;
  final WebOsClient client;
  final AppThemeController controller;

  @override
  Widget build(BuildContext context) {
    return AppTheme(
      controller: controller,
      // MaterialApp itself (not just its builder) has to live inside this so
      // `theme:` below is rebuilt on a theme change too -- otherwise route
      // transitions keep painting the OLD theme's colour behind the new page.
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final active = controller.theme;
          final brightness = ThemeData.estimateBrightnessForColor(active.windowBg);
          return MaterialApp(
            title: 'LG Power',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: brightness,
              scaffoldBackgroundColor: active.windowBg,
              canvasColor: active.windowBg,
              colorScheme: ColorScheme.fromSeed(seedColor: active.btnAccentBg, brightness: brightness)
                  .copyWith(surface: active.windowBg),
              splashFactory: NoSplash.splashFactory,
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
                  TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
                },
              ),
            ),
            // An imperative setSystemUIOverlayStyle call gets overridden by the
            // framework's own per-frame style; an AnnotatedRegion wins every frame.
            builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
              value: ThemeManager.overlayStyle(active),
              child: child ?? const SizedBox.shrink(),
            ),
            home: prefs.tvIp.isEmpty ? SetupScreen(client: client) : const MainScreen(),
          );
        },
      ),
    );
  }
}
