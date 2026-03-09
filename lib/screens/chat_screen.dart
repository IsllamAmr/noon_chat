import 'package:flutter/material.dart';

import '../chat_screen.dart' as legacy;

@immutable
class ChatOtherUser {
  final String uid;
  final String name;
  final String? avatarUrl;

  const ChatOtherUser({required this.uid, required this.name, this.avatarUrl});
}

class ChatScreen extends StatelessWidget {
  final String conversationId;
  final ChatOtherUser otherUser;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.otherUser,
  });

  @override
  Widget build(BuildContext context) {
    return legacy.ChatScreen(chatId: conversationId);
  }
}
