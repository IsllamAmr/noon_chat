import 'package:flutter/material.dart';

import 'services/theme_service.dart';

class AppThemeController {
  static final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );
  static final ValueNotifier<Color> seed = ValueNotifier<Color>(
    const Color(0xFF0D8E79),
  );

  static Future<void> initialize() async {
    mode.value = await ThemeService.instance.loadThemeMode();
  }

  static Future<void> setMode(ThemeMode newMode, {bool persist = true}) async {
    if (mode.value == newMode) return;
    mode.value = newMode;
    if (persist) {
      await ThemeService.instance.saveThemeMode(newMode);
    }
  }

  static Future<void> toggleDarkLight() async {
    final next = mode.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    await setMode(next);
  }

  static Future<void> clearLocalPreferences() async {
    await ThemeService.instance.clearLocalPreferences();
    await setMode(ThemeMode.system, persist: false);
  }

  static void setSeed(Color color) {
    seed.value = color;
  }
}
