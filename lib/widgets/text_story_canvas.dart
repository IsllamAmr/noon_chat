import 'package:flutter/material.dart';

class StoryBackgroundPreset {
  final String id;
  final List<Color> colors;
  final Alignment begin;
  final Alignment end;

  const StoryBackgroundPreset({
    required this.id,
    required this.colors,
    this.begin = Alignment.topLeft,
    this.end = Alignment.bottomRight,
  });
}

class StoryTextStylePreset {
  final String id;
  final TextStyle style;

  const StoryTextStylePreset({required this.id, required this.style});
}

class TextStoryCanvas extends StatelessWidget {
  final String text;
  final String backgroundId;
  final String textStyleId;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry padding;
  final String placeholder;

  const TextStoryCanvas({
    super.key,
    required this.text,
    required this.backgroundId,
    required this.textStyleId,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding = const EdgeInsets.all(24),
    this.placeholder = 'Write your story',
  });

  static const List<StoryBackgroundPreset> backgroundPresets = [
    StoryBackgroundPreset(
      id: 'sunset',
      colors: [Color(0xFF4F46E5), Color(0xFFEC4899)],
    ),
    StoryBackgroundPreset(
      id: 'emerald',
      colors: [Color(0xFF065F46), Color(0xFF10B981)],
    ),
    StoryBackgroundPreset(
      id: 'ocean',
      colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
    ),
    StoryBackgroundPreset(
      id: 'night',
      colors: [Color(0xFF111827), Color(0xFF1F2937)],
    ),
    StoryBackgroundPreset(
      id: 'lavender',
      colors: [Color(0xFF4338CA), Color(0xFF6366F1)],
    ),
    StoryBackgroundPreset(
      id: 'coral',
      colors: [Color(0xFF9A3412), Color(0xFFFB7185)],
    ),
    StoryBackgroundPreset(
      id: 'mint',
      colors: [Color(0xFF134E4A), Color(0xFF2DD4BF)],
    ),
    StoryBackgroundPreset(
      id: 'violet',
      colors: [Color(0xFF4C1D95), Color(0xFFA855F7)],
    ),
  ];

  static final List<StoryTextStylePreset> textStylePresets = [
    const StoryTextStylePreset(
      id: 'modernBold',
      style: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        height: 1.15,
        color: Colors.white,
      ),
    ),
    const StoryTextStylePreset(
      id: 'clean',
      style: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: Colors.white,
      ),
    ),
    const StoryTextStylePreset(
      id: 'serif',
      style: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        fontStyle: FontStyle.italic,
        height: 1.15,
        color: Colors.white,
      ),
    ),
    const StoryTextStylePreset(
      id: 'mono',
      style: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        height: 1.2,
        color: Colors.white,
      ),
    ),
    const StoryTextStylePreset(
      id: 'soft',
      style: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: Colors.white,
      ),
    ),
  ];

  static StoryBackgroundPreset backgroundById(String? id) {
    final safeId = (id ?? '').trim();
    for (final preset in backgroundPresets) {
      if (preset.id == safeId) return preset;
    }
    return backgroundPresets.first;
  }

  static StoryTextStylePreset textStyleById(String? id) {
    final safeId = (id ?? '').trim();
    for (final preset in textStylePresets) {
      if (preset.id == safeId) return preset;
    }
    return textStylePresets.first;
  }

  @override
  Widget build(BuildContext context) {
    final background = backgroundById(backgroundId);
    final textStyle = textStyleById(textStyleId);
    final content = text.trim().isEmpty ? placeholder : text.trim();
    final isPlaceholder = text.trim().isEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: background.begin,
          end: background.end,
          colors: background.colors,
        ),
      ),
      child: Container(
        padding: padding,
        alignment: Alignment.center,
        child: Text(
          content,
          maxLines: 9,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: textStyle.style.copyWith(
            color: isPlaceholder
                ? textStyle.style.color?.withValues(alpha: 0.55)
                : textStyle.style.color,
          ),
        ),
      ),
    );
  }
}
