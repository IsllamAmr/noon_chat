import 'package:flutter/material.dart';

class StoryProgressBar extends StatelessWidget {
  final int itemCount;
  final int currentIndex;
  final double currentProgress;

  const StoryProgressBar({
    super.key,
    required this.itemCount,
    required this.currentIndex,
    required this.currentProgress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final safeCount = itemCount < 1 ? 1 : itemCount;
    final safeProgress = currentProgress.clamp(0.0, 1.0);

    return Row(
      children: List.generate(safeCount, (index) {
        var fill = 0.0;
        if (index < currentIndex) {
          fill = 1;
        } else if (index == currentIndex) {
          fill = safeProgress;
        }

        return Expanded(
          child: Container(
            height: 3,
            margin: EdgeInsets.only(right: index == safeCount - 1 ? 0 : 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.26),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fill,
                child: Container(
                  decoration: BoxDecoration(
                    color: index == currentIndex
                        ? Colors.white
                        : scheme.primary.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
