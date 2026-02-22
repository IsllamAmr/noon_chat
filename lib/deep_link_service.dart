import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'app_navigator.dart';
import 'invite_service.dart';

class DeepLinkService {
  static final AppLinks _appLinks = AppLinks();
  static bool _initialized = false;
  static String? _pendingInviteLink;
  static bool _joining = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        _tryOpenPendingInvite();
      }
    });

    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _captureInvite(initial);
      }
    } catch (e) {
      debugPrint('Deep link initial parse error: $e');
    }

    _appLinks.uriLinkStream.listen(
      _captureInvite,
      onError: (e) => debugPrint('Deep link stream error: $e'),
    );
  }

  static void _captureInvite(Uri uri) {
    final raw = uri.toString().trim();
    if (raw.isEmpty) return;
    if (InviteService.extractInviteId(raw) == null) return;
    _pendingInviteLink = raw;
    _tryOpenPendingInvite();
  }

  static Future<void> _tryOpenPendingInvite() async {
    if (_joining) return;
    final link = _pendingInviteLink;
    if (link == null) return;
    if (FirebaseAuth.instance.currentUser == null) return;

    _joining = true;
    try {
      final chatId = await InviteService.acceptInvite(link);
      if (chatId == null) return;
      _pendingInviteLink = null;
      await _openChatWhenNavigatorReady(chatId);
    } catch (e) {
      debugPrint('Deep link invite join failed: $e');
    } finally {
      _joining = false;
    }
  }

  static Future<void> _openChatWhenNavigatorReady(String chatId) async {
    for (var i = 0; i < 40; i++) {
      if (AppNavigator.navigatorKey.currentState != null) {
        await AppNavigator.openChat(chatId);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
