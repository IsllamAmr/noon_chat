import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

enum StoryType { text, image }

@immutable
class Story {
  final String storyId;
  final String ownerId;
  final String ownerName;
  final String? ownerPhotoUrl;
  final StoryType type;
  final String? text;
  final String? imageUrl;
  final String? backgroundId;
  final String? textStyleId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int viewersCount;

  const Story({
    required this.storyId,
    required this.ownerId,
    required this.ownerName,
    required this.ownerPhotoUrl,
    required this.type,
    required this.text,
    required this.imageUrl,
    required this.backgroundId,
    required this.textStyleId,
    required this.createdAt,
    required this.expiresAt,
    required this.viewersCount,
  });

  bool get isText => type == StoryType.text;
  bool get isImage => type == StoryType.image;
  bool get isExpired => expiresAt.isBefore(DateTime.now());
  bool get hasDefaultOwnerName => ownerName.trim().toLowerCase() == 'noon user';

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};

    DateTime readDate(Object? value, DateTime fallback) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      return fallback;
    }

    final now = DateTime.now();
    final createdAt = readDate(data['createdAt'], now);
    final expiresAt = readDate(
      data['expiresAt'],
      createdAt.add(const Duration(hours: 24)),
    );

    final ownerId = ((data['ownerId'] ?? data['uid'] ?? '') as String).trim();
    final ownerName =
        ((data['ownerName'] ?? data['displayName'] ?? data['name'] ?? '')
                as String)
            .trim()
            .isEmpty
        ? 'Noon User'
        : ((data['ownerName'] ?? data['displayName'] ?? data['name'] ?? '')
                  as String)
              .trim();

    final rawType = ((data['type'] ?? 'text') as String).trim().toLowerCase();
    final type = rawType == 'image' ? StoryType.image : StoryType.text;

    var viewersCount = 0;
    if (data['viewersCount'] is int) {
      viewersCount = data['viewersCount'] as int;
    } else if (data['viewers'] is List) {
      viewersCount = (data['viewers'] as List).length;
    }

    final imageUrl = ((data['imageUrl'] ?? data['mediaUrl'] ?? '') as String)
        .trim();
    final text = ((data['text'] ?? '') as String).trim();
    final ownerPhoto =
        ((data['ownerPhotoUrl'] ?? data['photoUrl'] ?? data['photo'] ?? '')
                as String)
            .trim();

    return Story(
      storyId: doc.id,
      ownerId: ownerId,
      ownerName: ownerName,
      ownerPhotoUrl: ownerPhoto.isEmpty ? null : ownerPhoto,
      type: type,
      text: text.isEmpty ? null : text,
      imageUrl: imageUrl.isEmpty ? null : imageUrl,
      backgroundId: ((data['backgroundId'] ?? '') as String).trim().isEmpty
          ? null
          : ((data['backgroundId'] ?? '') as String).trim(),
      textStyleId: ((data['textStyleId'] ?? '') as String).trim().isEmpty
          ? null
          : ((data['textStyleId'] ?? '') as String).trim(),
      createdAt: createdAt,
      expiresAt: expiresAt,
      viewersCount: viewersCount < 0 ? 0 : viewersCount,
    );
  }

  Story copyWith({
    String? storyId,
    String? ownerId,
    String? ownerName,
    String? ownerPhotoUrl,
    StoryType? type,
    String? text,
    String? imageUrl,
    String? backgroundId,
    String? textStyleId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? viewersCount,
  }) {
    return Story(
      storyId: storyId ?? this.storyId,
      ownerId: ownerId ?? this.ownerId,
      ownerName: ownerName ?? this.ownerName,
      ownerPhotoUrl: ownerPhotoUrl ?? this.ownerPhotoUrl,
      type: type ?? this.type,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      backgroundId: backgroundId ?? this.backgroundId,
      textStyleId: textStyleId ?? this.textStyleId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      viewersCount: viewersCount ?? this.viewersCount,
    );
  }
}
