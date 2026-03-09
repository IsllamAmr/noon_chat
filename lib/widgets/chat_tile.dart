import 'package:flutter/material.dart';

import '../models/conversation.dart';

class ChatTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final int animationIndex;

  const ChatTile({
    super.key,
    required this.conversation,
    this.onTap,
    this.onLongPress,
    this.animationIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final delay = animationIndex * 45;
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 260 + delay),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                ConversationAvatar(conversation: conversation, radius: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        conversation.lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _ChatTileTrailing(conversation: conversation),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConversationAvatar extends StatelessWidget {
  final Conversation conversation;
  final double radius;

  const ConversationAvatar({
    super.key,
    required this.conversation,
    this.radius = 22,
  });

  String get _heroTag => 'chat-avatar-${conversation.id}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasImage =
        conversation.avatarUrl != null &&
        conversation.avatarUrl!.trim().isNotEmpty;
    final initial = conversation.name.trim().isEmpty
        ? '?'
        : conversation.name.trim().substring(0, 1).toUpperCase();

    return Hero(
      tag: _heroTag,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: scheme.primaryContainer,
        foregroundImage: hasImage
            ? NetworkImage(conversation.avatarUrl!)
            : null,
        child: hasImage
            ? null
            : Text(
                initial,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}

class _ChatTileTrailing extends StatelessWidget {
  final Conversation conversation;

  const _ChatTileTrailing({required this.conversation});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          conversation.time,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (conversation.unreadCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${conversation.unreadCount}',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        else if (conversation.lastMessageSeen)
          Icon(Icons.done_all_rounded, size: 17, color: scheme.primary)
        else
          const SizedBox(height: 17),
      ],
    );
  }
}
