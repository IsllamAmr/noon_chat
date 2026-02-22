import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class StoryService {
  static final _db = FirebaseFirestore.instance;

  static String get _uid => FirebaseAuth.instance.currentUser!.uid;

  static CollectionReference<Map<String, dynamic>> get _stories =>
      _db.collection('stories');

  static Future<void> addTextStory(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      throw StateError('Story text cannot be empty');
    }
    final now = DateTime.now();
    await _stories.add({
      'uid': _uid,
      'type': 'text',
      'text': clean,
      'mediaUrl': '',
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'viewers': <String>[],
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> addImageStory({
    required String mediaUrl,
    String caption = '',
  }) async {
    final now = DateTime.now();
    await _stories.add({
      'uid': _uid,
      'type': 'image',
      'text': caption.trim(),
      'mediaUrl': mediaUrl.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'viewers': <String>[],
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> storiesStream() {
    return _stories
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots();
  }

  static Future<void> markViewed(String storyId) async {
    await _stories.doc(storyId).set({
      'viewers': FieldValue.arrayUnion([_uid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> deleteStory(String storyId) async {
    await _stories.doc(storyId).delete();
  }
}
