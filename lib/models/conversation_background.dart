import 'dart:convert';

class ConversationBackground {
  static const double defaultOverlayOpacity = 0.24;
  static const double defaultParallaxStrength = 0.018;

  final String conversationId;
  final String? localPath;
  final double overlayOpacity;
  final double parallaxStrength;

  const ConversationBackground({
    required this.conversationId,
    this.localPath,
    this.overlayOpacity = defaultOverlayOpacity,
    this.parallaxStrength = defaultParallaxStrength,
  });

  bool get hasWallpaper => (localPath ?? '').trim().isNotEmpty;

  ConversationBackground copyWith({
    String? localPath,
    bool clearPath = false,
    double? overlayOpacity,
    double? parallaxStrength,
  }) {
    return ConversationBackground(
      conversationId: conversationId,
      localPath: clearPath ? null : (localPath ?? this.localPath),
      overlayOpacity: _clampOverlay(overlayOpacity ?? this.overlayOpacity),
      parallaxStrength: _clampParallax(
        parallaxStrength ?? this.parallaxStrength,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'localPath': localPath,
      'overlayOpacity': _clampOverlay(overlayOpacity),
      'parallaxStrength': _clampParallax(parallaxStrength),
    };
  }

  static ConversationBackground fromJson(
    String conversationId,
    Map<String, dynamic> json,
  ) {
    final localPath = (json['localPath'] ?? '').toString().trim();
    final overlay =
        double.tryParse((json['overlayOpacity'] ?? '').toString()) ??
        defaultOverlayOpacity;
    final parallax =
        double.tryParse((json['parallaxStrength'] ?? '').toString()) ??
        defaultParallaxStrength;
    return ConversationBackground(
      conversationId: conversationId,
      localPath: localPath.isEmpty ? null : localPath,
      overlayOpacity: _clampOverlay(overlay),
      parallaxStrength: _clampParallax(parallax),
    );
  }

  static ConversationBackground fallback(String conversationId) {
    return ConversationBackground(conversationId: conversationId);
  }

  static double _clampOverlay(double value) => value.clamp(0.0, 0.7);
  static double _clampParallax(double value) => value.clamp(0.0, 0.06);
}

Map<String, dynamic> decodeConversationBackgrounds(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, dynamic>{};
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  } catch (_) {
    return <String, dynamic>{};
  }
}
