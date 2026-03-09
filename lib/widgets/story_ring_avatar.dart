import 'package:flutter/material.dart';

class StoryRingAvatar extends StatelessWidget {
  final String label;
  final String? imageUrl;
  final bool hasStory;
  final bool isViewed;
  final bool isMine;
  final VoidCallback? onTap;

  const StoryRingAvatar({
    super.key,
    required this.label,
    this.imageUrl,
    required this.hasStory,
    required this.isViewed,
    this.isMine = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cleanLabel = label.trim().isEmpty ? 'Story' : label.trim();
    final shortName = cleanLabel.split(' ').first;
    final hasImage = (imageUrl ?? '').trim().isNotEmpty;

    Color ringColor;
    if (!hasStory) {
      ringColor = scheme.outlineVariant;
    } else if (isViewed) {
      ringColor = scheme.outline;
    } else {
      ringColor = scheme.primary;
    }

    return SizedBox(
      width: 80,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: ringColor, width: 1.8),
                      ),
                      child: CircleAvatar(
                        radius: 24,
                        backgroundColor: scheme.surfaceContainerHigh,
                        backgroundImage: hasImage
                            ? NetworkImage(imageUrl!.trim())
                            : null,
                        child: hasImage
                            ? null
                            : Text(
                                shortName.substring(0, 1).toUpperCase(),
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                    if (isMine)
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.add,
                            size: 12,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
