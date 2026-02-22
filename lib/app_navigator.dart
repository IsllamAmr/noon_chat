import 'package:flutter/material.dart';

import 'chat_screen.dart';

class AppNavigator {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Future<void> openChat(String chatId) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    await nav.push(
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
    );
  }
}
