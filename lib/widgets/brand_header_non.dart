import 'package:flutter/material.dart';

enum BrandHeaderNONVariant { solid, gradient, richFirstLetter }

class BrandHeaderNON extends StatelessWidget {
  final BrandHeaderNONVariant variant;
  final String brandShort;
  final String brandFull;
  final double shortFontSize;
  final double fullFontSize;
  final CrossAxisAlignment crossAxisAlignment;
  final EdgeInsetsGeometry padding;
  final bool addGlow;

  const BrandHeaderNON({
    super.key,
    this.variant = BrandHeaderNONVariant.gradient,
    this.brandShort = 'NON',
    this.brandFull = 'Noon Chat',
    this.shortFontSize = 22,
    this.fullFontSize = 12,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.padding = EdgeInsets.zero,
    this.addGlow = true,
  });

  @override
  Widget build(BuildContext context) {
    const nonColor = Color(0xFF6366F1);
    const subtitleColor = Color(0xFF94A3B8);
    const accentColor = Color(0xFF38BDF8);

    final baseShortStyle = TextStyle(
      color: nonColor,
      fontSize: shortFontSize,
      fontWeight: FontWeight.w900,
      letterSpacing: 4.0,
      height: 1.0,
      shadows: addGlow
          ? const [
              Shadow(
                color: Color(0x406366F1),
                blurRadius: 10,
                offset: Offset(0, 1.5),
              ),
            ]
          : null,
    );

    final baseFullStyle = const TextStyle(
      color: subtitleColor,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.0,
      height: 1.0,
    ).copyWith(fontSize: fullFontSize);

    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxisAlignment,
        children: [
          _nonLabel(baseShortStyle, accentColor),
          const SizedBox(height: 5),
          Text(brandFull, style: baseFullStyle, maxLines: 1),
        ],
      ),
    );
  }

  Widget _nonLabel(TextStyle baseStyle, Color accentColor) {
    switch (variant) {
      case BrandHeaderNONVariant.solid:
        return Text(brandShort, style: baseStyle, maxLines: 1);
      case BrandHeaderNONVariant.gradient:
        return _GradientText(
          text: brandShort,
          style: baseStyle,
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF3B82F6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        );
      case BrandHeaderNONVariant.richFirstLetter:
        final first = brandShort.isEmpty ? 'N' : brandShort[0];
        final rest = brandShort.length > 1 ? brandShort.substring(1) : '';
        return RichText(
          maxLines: 1,
          text: TextSpan(
            children: [
              TextSpan(
                text: first,
                style: baseStyle.copyWith(color: accentColor),
              ),
              TextSpan(text: rest, style: baseStyle),
            ],
          ),
        );
    }
  }
}

class _GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Gradient gradient;

  const _GradientText({
    required this.text,
    required this.style,
    required this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) {
        return gradient.createShader(
          Rect.fromLTWH(0, 0, bounds.width, bounds.height),
        );
      },
      blendMode: BlendMode.srcIn,
      child: Text(text, style: style, maxLines: 1),
    );
  }
}
