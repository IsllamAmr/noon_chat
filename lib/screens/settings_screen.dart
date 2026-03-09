import 'package:flutter/material.dart';

import '../app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ThemeMode _mode;
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    _mode = AppThemeController.mode.value;
    AppThemeController.mode.addListener(_onModeChanged);
  }

  @override
  void dispose() {
    AppThemeController.mode.removeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged() {
    if (!mounted) return;
    setState(() => _mode = AppThemeController.mode.value);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    await AppThemeController.setMode(mode);
  }

  Future<void> _clearLocalCache() async {
    setState(() => _clearingCache = true);
    try {
      await AppThemeController.clearLocalPreferences();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Local cache cleared')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to clear local cache')),
      );
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Noon Chat',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.chat_rounded),
      children: const [
        Text('A modern realtime chat app built with Flutter and Firebase.'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Text(
            'Appearance',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Theme mode'),
                  const SizedBox(height: 10),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.phone_android_rounded),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode_outlined),
                      ),
                    ],
                    selected: <ThemeMode>{_mode},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) return;
                      _setThemeMode(selection.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Changes apply instantly and are saved on this device.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'General',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: _clearingCache
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: scheme.primary,
                          ),
                        )
                      : const Icon(Icons.cleaning_services_outlined),
                  title: const Text('Clear cache'),
                  subtitle: const Text(
                    'Clears local preferences on this device',
                  ),
                  onTap: _clearingCache ? null : _clearLocalCache,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About'),
                  onTap: _showAbout,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
