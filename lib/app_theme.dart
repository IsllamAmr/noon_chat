import 'package:flutter/material.dart';

class AppThemeController {
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);
  static final ValueNotifier<Color> seed =
      ValueNotifier<Color>(const Color(0xFF0D8E79));

  static void toggleDarkLight() {
    mode.value = mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  static void setSeed(Color color) {
    seed.value = color;
  }
}
