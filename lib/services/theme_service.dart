import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService {
  static const String _themeModeKey = 'theme_mode';
  static ThemeService? _instance;

  SharedPreferences? _prefs;

  ThemeService._();

  static ThemeService get instance => _instance ??= ThemeService._();

  Future<SharedPreferences> _ensurePrefs() async {
    final cached = _prefs;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    return prefs;
  }

  Future<ThemeMode> loadThemeMode() async {
    final prefs = await _ensurePrefs();
    return _decodeThemeMode(prefs.getString(_themeModeKey));
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_themeModeKey, _encodeThemeMode(mode));
  }

  Future<void> clearLocalPreferences() async {
    final prefs = await _ensurePrefs();
    await prefs.clear();
  }

  String _encodeThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  ThemeMode _decodeThemeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
