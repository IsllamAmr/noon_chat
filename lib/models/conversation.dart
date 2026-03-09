import 'package:flutter/foundation.dart';

@immutable
class Conversation {
  final String id;
  final String name;
  final String lastMessage;
  final String time;
  final String? avatarUrl;
  final int unreadCount;
  final bool lastMessageSeen;
  final bool isArchived;

  const Conversation({
    required this.id,
    required this.name,
    required this.lastMessage,
    required this.time,
    this.avatarUrl,
    this.unreadCount = 0,
    this.lastMessageSeen = false,
    this.isArchived = false,
  });
}
