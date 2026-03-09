import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final String? imageUrl;
  final String timeLabel;
  final bool isMe;
  final bool showSeenIndicator;
  final bool isSeen;
  final bool animateOnBuild;
  final bool isPending;
  final bool isEdited;
  final String? replyAuthor;
  final String? replyText;
  final Map<String, int> reactionCounts;
  final String? myReaction;

  const MessageBubble({
    super.key,
    required this.text,
    this.imageUrl,
    required this.timeLabel,
    required this.isMe,
    this.showSeenIndicator = false,
    this.isSeen = false,
    this.animateOnBuild = false,
    this.isPending = false,
    this.isEdited = false,
    this.replyAuthor,
    this.replyText,
    this.reactionCounts = const <String, int>{},
    this.myReaction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.75;
    final hasImage = (imageUrl ?? '').trim().isNotEmpty;
    final cleanText = text.trim();
    final showText = cleanText.isNotEmpty;
    final cleanReplyText = (replyText ?? '').trim();
    final hasReply = cleanReplyText.isNotEmpty;
    final reactions = reactionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final bubbleColor = isMe
        ? scheme.primaryContainer.withValues(alpha: isPending ? 0.72 : 0.92)
        : scheme.surfaceContainerHigh.withValues(alpha: isPending ? 0.78 : 0.9);
    final textColor = isMe ? scheme.onPrimaryContainer : scheme.onSurface;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(isMe ? 20 : 8),
      bottomRight: Radius.circular(isMe ? 8 : 20),
    );

    final bubbleChild = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: hasImage
                ? const EdgeInsets.fromLTRB(6, 6, 8, 8)
                : const EdgeInsets.fromLTRB(12, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasReply)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border(
                        left: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.9),
                          width: 2.4,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          (replyAuthor ?? '').trim().isEmpty
                              ? 'Reply'
                              : replyAuthor!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: textColor.withValues(alpha: 0.88),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          cleanReplyText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: textColor.withValues(alpha: 0.82),
                              ),
                        ),
                      ],
                    ),
                  ),
                if (hasReply && (hasImage || showText))
                  const SizedBox(height: 8),
                if (hasImage)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: maxBubbleWidth,
                        maxHeight: screenHeight * 0.36,
                        minWidth: 120,
                        minHeight: 120,
                      ),
                      child: Image.network(
                        imageUrl!.trim(),
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: Colors.black.withValues(alpha: 0.06),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: Colors.black.withValues(alpha: 0.08),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Text(
                              'Image unavailable',
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(color: textColor),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                if (hasImage && showText) const SizedBox(height: 8),
                if (showText)
                  Text(
                    cleanText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      height: 1.35,
                    ),
                  ),
                if (showText || hasImage) const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEdited) ...[
                      Text(
                        'edited',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.6),
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      timeLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: textColor.withValues(alpha: 0.72),
                      ),
                    ),
                    if (isPending) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.schedule_rounded,
                        size: 14,
                        color: textColor.withValues(alpha: 0.72),
                      ),
                    ] else if (showSeenIndicator) ...[
                      const SizedBox(width: 4),
                      Icon(
                        isSeen ? Icons.done_all_rounded : Icons.done_rounded,
                        size: 15,
                        color: isSeen
                            ? scheme.primary
                            : textColor.withValues(alpha: 0.72),
                      ),
                    ],
                  ],
                ),
                if (reactions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: reactions.map((entry) {
                      final selected = myReaction == entry.key;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? scheme.primary.withValues(alpha: 0.17)
                              : scheme.surfaceContainerHighest.withValues(
                                  alpha: 0.55,
                                ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? scheme.primary.withValues(alpha: 0.6)
                                : scheme.outlineVariant.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          '${entry.key} ${entry.value}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: selected
                                    ? scheme.primary
                                    : textColor.withValues(alpha: 0.82),
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                              ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (!animateOnBuild) {
      return bubbleChild;
    }

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0.9, end: 1),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.scale(
            scale: value,
            alignment: isMe ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        );
      },
      child: bubbleChild,
    );
  }
}
