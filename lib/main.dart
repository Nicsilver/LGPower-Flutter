import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/prefs.dart';
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
      child: MaterialApp(
        title: 'LG Power',
        debugShowCheckedModeBanner: false,
        home: prefs.tvIp.isEmpty ? SetupScreen(client: client) : const MainScreen(),
      ),
    );
  }
}
