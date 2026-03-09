import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../models/story.dart';
import 'cloudinary_storage_service.dart';

class StoryUploadException implements Exception {
  final String message;

  const StoryUploadException(this.message);

  @override
  String toString() => message;
}

class StoryImageUploadResult {
  final String storyId;
  final String downloadUrl;
  final String storagePath;
  final String bucket;

  const StoryImageUploadResult({
    required this.storyId,
    required this.downloadUrl,
    required this.storagePath,
    required this.bucket,
  });
}

class _OwnerProfile {
  final String name;
  final String photoUrl;

  const _OwnerProfile({required this.name, required this.photoUrl});
}

class StoryService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final Map<String, DateTime> _recentStoryDedup = <String, DateTime>{};
  static final Map<String, _OwnerProfile> _ownerProfileCache =
      <String, _OwnerProfile>{};
  static const Duration _storyDedupWindow = Duration(seconds: 2);
  static const Duration _storyDedupGcWindow = Duration(minutes: 5);
  static bool _textStoryPosting = false;
  static bool _imageStoryPosting = false;

  static CollectionReference<Map<String, dynamic>> get _stories =>
      _db.collection('stories');

  static String get _uid => FirebaseAuth.instance.currentUser!.uid;

  static bool _isPermissionDenied(FirebaseException e) {
    return e.code.trim().toLowerCase() == 'permission-denied';
  }

  static String _friendlyNameFromEmail(String email) {
    final clean = email.trim();
    if (clean.isEmpty || !clean.contains('@')) return '';
    final local = clean.split('@').first.trim();
    if (local.isEmpty) return '';
    return local.replaceAll(RegExp(r'[._-]+'), ' ').replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  }

  static String _pickBestOwnerName(
    Map<String, dynamic> userData, {
    User? authUser,
  }) {
    final fromProfile = ((userData['displayName'] ?? userData['name'] ?? '')
            .toString())
        .trim();
    if (fromProfile.isNotEmpty) return fromProfile;

    final fromAuth = ((authUser?.displayName ?? '').trim());
    if (fromAuth.isNotEmpty) return fromAuth;

    final email = ((userData['email'] ?? authUser?.email ?? '').toString())
        .trim();
    final fromEmail = _friendlyNameFromEmail(email);
    if (fromEmail.isNotEmpty) return fromEmail;

    return 'Noon User';
  }

  static String _pickBestOwnerPhoto(
    Map<String, dynamic> userData, {
    User? authUser,
  }) {
    return ((userData['photoUrl'] ?? userData['photo'] ?? authUser?.photoURL ?? '')
            .toString())
        .trim();
  }

  static String _friendlyFirestoreError(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'You do not have permission to post this story.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Could not save story right now. Check internet and retry.';
      default:
        return e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : 'Failed to save story data. Please try again.';
    }
  }

  static Future<void> _cleanupUploadedStoryImageInBucket(
    String storagePath, {
    required String? bucket,
  }) async {
    final cleanPath = storagePath.trim();
    if (cleanPath.isEmpty) return;

    try {
      final storage = _storageForBucket(bucket);
      await storage.ref().child(cleanPath).delete();
    } catch (e, st) {
      debugPrint('Story cleanup failed at $cleanPath: $e\n$st');
    }
  }

  static FirebaseStorage _storageForBucket(String? bucket) {
    final clean = (bucket ?? '').trim();
    if (clean.isEmpty) return _storage;
    final gsBucket = clean.startsWith('gs://') ? clean : 'gs://$clean';
    try {
      return FirebaseStorage.instanceFor(bucket: gsBucket);
    } catch (_) {
      return _storage;
    }
  }

  static List<FirebaseStorage> _storyStorageCandidates() {
    final candidates = <FirebaseStorage>[];
    final seenBuckets = <String>{};

    void addBucket(String rawBucket) {
      final normalized = rawBucket.trim().replaceFirst(RegExp(r'^gs://'), '');
      if (normalized.isEmpty) return;
      final key = normalized.toLowerCase();
      if (!seenBuckets.add(key)) return;
      candidates.add(FirebaseStorage.instanceFor(bucket: 'gs://$normalized'));
    }

    try {
      final projectId = Firebase.app().options.projectId.trim();
      if (projectId.isNotEmpty) {
        addBucket('$projectId.appspot.com');
        addBucket('$projectId.firebasestorage.app');
      }

      final configured = (Firebase.app().options.storageBucket ?? '').trim();
      addBucket(configured);
      final normalized = configured.replaceFirst(RegExp(r'^gs://'), '');
      if (normalized.endsWith('.firebasestorage.app')) {
        addBucket(
          normalized.replaceFirst('.firebasestorage.app', '.appspot.com'),
        );
      } else if (normalized.endsWith('.appspot.com')) {
        addBucket(
          normalized.replaceFirst('.appspot.com', '.firebasestorage.app'),
        );
      }
    } catch (_) {}

    if (candidates.isEmpty) {
      candidates.add(_storage);
    }
    return candidates;
  }

  static bool _isDuplicateStoryRequest(String signature) {
    final now = DateTime.now();
    _recentStoryDedup.removeWhere(
      (_, ts) => now.difference(ts) > _storyDedupGcWindow,
    );
    final previous = _recentStoryDedup[signature];
    if (previous != null && now.difference(previous) < _storyDedupWindow) {
      return true;
    }
    _recentStoryDedup[signature] = now;
    return false;
  }

  static Future<Map<String, String?>> _loadOwnerSnapshot() async {
    final user = FirebaseAuth.instance.currentUser!;
    final userDoc = await _db.collection('users').doc(user.uid).get();
    final userData = userDoc.data() ?? const <String, dynamic>{};
    final displayName = _pickBestOwnerName(userData, authUser: user);
    final photo = _pickBestOwnerPhoto(userData, authUser: user);

    return <String, String?>{
      'name': displayName,
      'photoUrl': photo.isEmpty ? null : photo,
    };
  }

  static Iterable<List<String>> _chunkStrings(
    List<String> source, {
    int size = 10,
  }) sync* {
    for (var i = 0; i < source.length; i += size) {
      final end = (i + size < source.length) ? i + size : source.length;
      yield source.sublist(i, end);
    }
  }

  static Future<void> _hydrateOwnerProfiles(Set<String> ownerIds) async {
    final ids = ownerIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return;

    for (final chunk in _chunkStrings(ids, size: 10)) {
      try {
        final snap = await _db
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .limit(chunk.length)
            .get();
        for (final doc in snap.docs) {
          final data = doc.data();
          final name = _pickBestOwnerName(data);
          final photo = _pickBestOwnerPhoto(data);
          _ownerProfileCache[doc.id] = _OwnerProfile(name: name, photoUrl: photo);
        }
      } on FirebaseException catch (e) {
        debugPrint('hydrateOwnerProfiles skipped (${e.code})');
      } catch (e, st) {
        debugPrint('hydrateOwnerProfiles failed: $e\n$st');
      }
    }
  }

  static Future<List<Story>> _withResolvedOwners(List<Story> stories) async {
    if (stories.isEmpty) return stories;

    final missingOwnerIds = <String>{};
    for (final story in stories) {
      final ownerId = story.ownerId.trim();
      if (ownerId.isEmpty) continue;
      final cache = _ownerProfileCache[ownerId];
      final needsName = story.hasDefaultOwnerName;
      final needsPhoto = (story.ownerPhotoUrl ?? '').trim().isEmpty;
      final cacheHasName = (cache?.name ?? '').trim().isNotEmpty;
      final cacheHasPhoto = (cache?.photoUrl ?? '').trim().isNotEmpty;
      if ((needsName && !cacheHasName) || (needsPhoto && !cacheHasPhoto)) {
        missingOwnerIds.add(ownerId);
      }
    }

    if (missingOwnerIds.isNotEmpty) {
      await _hydrateOwnerProfiles(missingOwnerIds);
    }

    return stories.map((story) {
      final profile = _ownerProfileCache[story.ownerId.trim()];
      if (profile == null) return story;

      final resolvedName = story.hasDefaultOwnerName && profile.name.trim().isNotEmpty
          ? profile.name.trim()
          : story.ownerName;
      final resolvedPhoto = (story.ownerPhotoUrl ?? '').trim().isEmpty &&
              profile.photoUrl.trim().isNotEmpty
          ? profile.photoUrl.trim()
          : story.ownerPhotoUrl;

      if (resolvedName == story.ownerName && resolvedPhoto == story.ownerPhotoUrl) {
        return story;
      }
      return story.copyWith(
        ownerName: resolvedName,
        ownerPhotoUrl: resolvedPhoto,
      );
    }).toList(growable: false);
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> storiesStream() {
    return _stories
        .orderBy('createdAt', descending: true)
        .limit(80)
        .snapshots();
  }

  static Stream<List<Story>> watchActiveStories({int limit = 120}) {
    final now = Timestamp.fromDate(DateTime.now());
    return _stories
        .where('expiresAt', isGreaterThan: now)
        .orderBy('expiresAt', descending: true)
        .limit(limit)
        .snapshots()
        .asyncMap((snap) async {
          final stories = snap.docs
              .map(Story.fromDoc)
              .where((s) => !s.isExpired)
              .toList();
          final hydrated = await _withResolvedOwners(stories);
          hydrated.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return hydrated;
        });
  }

  static Stream<Set<String>> watchViewedStoryIds() {
    final controller = StreamController<Set<String>>();
    final viewedViaSubcollection = <String>{};
    final viewedViaLegacyArray = <String>{};

    late final StreamSubscription subcollectionSub;
    late final StreamSubscription legacyArraySub;

    void emit() {
      if (controller.isClosed) return;
      controller.add(<String>{
        ...viewedViaSubcollection,
        ...viewedViaLegacyArray,
      });
    }

    subcollectionSub = _db
        .collectionGroup('views')
        .where('uid', isEqualTo: _uid)
        .snapshots()
        .listen((snap) {
          viewedViaSubcollection
            ..clear()
            ..addAll(
              snap.docs
                  .map((doc) => doc.reference.parent.parent?.id ?? '')
                  .where((id) => id.isNotEmpty),
            );
          emit();
        }, onError: (error, stack) => controller.addError(error, stack));

    legacyArraySub = _stories
        .where('viewers', arrayContains: _uid)
        .snapshots()
        .listen((snap) {
          viewedViaLegacyArray
            ..clear()
            ..addAll(snap.docs.map((doc) => doc.id));
          emit();
        }, onError: (error, stack) => controller.addError(error, stack));

    controller.onCancel = () async {
      await subcollectionSub.cancel();
      await legacyArraySub.cancel();
    };

    return controller.stream;
  }

  static Future<List<Story>> fetchActiveStoriesForOwner(String ownerId) async {
    final now = Timestamp.fromDate(DateTime.now());
    QuerySnapshot<Map<String, dynamic>> snap;

    try {
      snap = await _stories
          .where('ownerId', isEqualTo: ownerId)
          .where('expiresAt', isGreaterThan: now)
          .orderBy('expiresAt', descending: true)
          .limit(24)
          .get();
    } on FirebaseException catch (e) {
      if (!_isPermissionDenied(e)) rethrow;
      snap = await _stories
          .where('uid', isEqualTo: ownerId)
          .where('expiresAt', isGreaterThan: now)
          .orderBy('expiresAt', descending: true)
          .limit(24)
          .get();
    }

    final stories = snap.docs
        .map(Story.fromDoc)
        .where((s) => !s.isExpired)
        .toList();
    stories.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return stories;
  }

  static Future<StoryImageUploadResult> uploadStoryImage(File file) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const StoryUploadException('Please login first.');
    }

    final sourcePath = file.path.trim();
    if (sourcePath.isEmpty) {
      throw const StoryUploadException('Invalid image file selected.');
    }
    if (!await file.exists()) {
      throw const StoryUploadException('Selected image file was not found.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const StoryUploadException('Selected image is empty. Please re-pick.');
    }

    final storyId = _stories.doc().id.trim();
    if (storyId.isEmpty) {
      throw const StoryUploadException('Failed to generate story id.');
    }

    try {
      final upload = await CloudinaryStorageService.uploadImageBytes(
        bytes: bytes,
        folder: 'stories/${user.uid}',
        publicId: storyId,
        fileName: '$storyId.jpg',
      );

      return StoryImageUploadResult(
        storyId: storyId,
        downloadUrl: upload.secureUrl,
        storagePath: '',
        bucket: 'cloudinary',
      );
    } on ImageStorageException catch (e) {
      throw StoryUploadException(e.message);
    } catch (e, st) {
      debugPrint('Story image upload failed: $e\n$st');
      throw const StoryUploadException(
        'Failed to upload story image. Please try again.',
      );
    }
  }

  static Future<String> createTextStory({
    required String text,
    required String backgroundId,
    required String textStyleId,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      throw StateError('Story text cannot be empty.');
    }
    if (_textStoryPosting) {
      throw const StoryUploadException(
        'A story is already being posted. Please wait.',
      );
    }
    final dedupSignature =
        'text|$_uid|$cleanText|${backgroundId.trim()}|${textStyleId.trim()}';
    if (_isDuplicateStoryRequest(dedupSignature)) {
      throw const StoryUploadException(
        'Duplicate story prevented. Please wait a moment.',
      );
    }

    _textStoryPosting = true;
    try {
      final owner = await _loadOwnerSnapshot();
      final storyRef = _stories.doc();
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 24));

      final newPayload = <String, dynamic>{
        'storyId': storyRef.id,
        'ownerId': _uid,
        'ownerName': owner['name'],
        'ownerPhotoUrl': owner['photoUrl'],
        'type': 'text',
        'text': cleanText,
        'imageUrl': null,
        'backgroundId': backgroundId,
        'textStyleId': textStyleId,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'viewersCount': 0,
        // Legacy fields kept for backward compatibility with older screens.
        'uid': _uid,
        'mediaUrl': '',
        'viewers': <String>[],
        'updatedAt': FieldValue.serverTimestamp(),
      };

      try {
        await storyRef.set(newPayload);
      } on FirebaseException catch (e) {
        if (!_isPermissionDenied(e)) rethrow;
        // Fallback for projects still running old stories rules.
        await storyRef.set({
          'uid': _uid,
          'type': 'text',
          'text': cleanText,
          'mediaUrl': '',
          'createdAt': Timestamp.fromDate(now),
          'expiresAt': Timestamp.fromDate(expiresAt),
          'viewers': <String>[],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      return storyRef.id;
    } finally {
      _textStoryPosting = false;
    }
  }

  static Future<String> createImageStory({
    required File imageFile,
    String caption = '',
  }) async {
    if (_imageStoryPosting) {
      throw const StoryUploadException(
        'A story upload is already in progress. Please wait.',
      );
    }

    final cleanPath = imageFile.path.trim();
    final cleanCaption = caption.trim();
    final dedupSignature = 'image|$_uid|$cleanPath|$cleanCaption';
    if (_isDuplicateStoryRequest(dedupSignature)) {
      throw const StoryUploadException(
        'Duplicate story prevented. Please wait a moment.',
      );
    }

    _imageStoryPosting = true;
    try {
      final owner = await _loadOwnerSnapshot();
      final upload = await uploadStoryImage(imageFile);
      final storyRef = _stories.doc(upload.storyId);

      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 24));

      final newPayload = <String, dynamic>{
        'storyId': upload.storyId,
        'ownerId': _uid,
        'ownerName': owner['name'],
        'ownerPhotoUrl': owner['photoUrl'],
        'type': 'image',
        'text': cleanCaption.isEmpty ? null : cleanCaption,
        'imageUrl': upload.downloadUrl,
        'backgroundId': null,
        'textStyleId': null,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'viewersCount': 0,
        // Legacy fields kept for backward compatibility with older screens.
        'uid': _uid,
        'mediaUrl': upload.downloadUrl,
        'viewers': <String>[],
        'updatedAt': FieldValue.serverTimestamp(),
      };

      try {
        await storyRef.set(newPayload);
        return upload.storyId;
      } on FirebaseException catch (e, st) {
        debugPrint(
          'Failed to save image story to Firestore: '
          'storyId=${upload.storyId}, code=${e.code}, message=${e.message}\n$st',
        );

        if (_isPermissionDenied(e)) {
          try {
            // Fallback for projects still running old stories rules.
            await storyRef.set({
              'uid': _uid,
              'type': 'image',
              'text': cleanCaption,
              'mediaUrl': upload.downloadUrl,
              'createdAt': Timestamp.fromDate(now),
              'expiresAt': Timestamp.fromDate(expiresAt),
              'viewers': <String>[],
              'updatedAt': FieldValue.serverTimestamp(),
            });
            return upload.storyId;
          } on FirebaseException catch (fallback, fallbackSt) {
            debugPrint(
              'Fallback image story save failed: '
              'storyId=${upload.storyId}, code=${fallback.code}, '
              'message=${fallback.message}\n$fallbackSt',
            );
            await _cleanupUploadedStoryImageInBucket(
              upload.storagePath,
              bucket: upload.bucket,
            );
            throw StoryUploadException(_friendlyFirestoreError(fallback));
          }
        }

        await _cleanupUploadedStoryImageInBucket(
          upload.storagePath,
          bucket: upload.bucket,
        );
        throw StoryUploadException(_friendlyFirestoreError(e));
      } catch (e, st) {
        debugPrint(
          'Unexpected error while creating image story '
          'storyId=${upload.storyId}: $e\n$st',
        );
        await _cleanupUploadedStoryImageInBucket(
          upload.storagePath,
          bucket: upload.bucket,
        );
        if (e is StoryUploadException) rethrow;
        throw const StoryUploadException(
          'Failed to post image story. Please try again.',
        );
      }
    } finally {
      _imageStoryPosting = false;
    }
  }

  static Future<void> addTextStory(String text) async {
    await createTextStory(
      text: text,
      backgroundId: 'sunset',
      textStyleId: 'modernBold',
    );
  }

  static Future<void> addImageStory({
    required String mediaUrl,
    String caption = '',
  }) async {
    final owner = await _loadOwnerSnapshot();
    final storyRef = _stories.doc();
    final now = DateTime.now();
    final expiresAt = now.add(const Duration(hours: 24));
    final cleanCaption = caption.trim();

    final newPayload = <String, dynamic>{
      'storyId': storyRef.id,
      'ownerId': _uid,
      'ownerName': owner['name'],
      'ownerPhotoUrl': owner['photoUrl'],
      'type': 'image',
      'text': cleanCaption.isEmpty ? null : cleanCaption,
      'imageUrl': mediaUrl,
      'backgroundId': null,
      'textStyleId': null,
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'viewersCount': 0,
      'uid': _uid,
      'mediaUrl': mediaUrl,
      'viewers': <String>[],
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await storyRef.set(newPayload);
    } on FirebaseException catch (e) {
      if (!_isPermissionDenied(e)) rethrow;
      await storyRef.set({
        'uid': _uid,
        'type': 'image',
        'text': cleanCaption,
        'mediaUrl': mediaUrl,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'viewers': <String>[],
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  static Future<void> markViewed(String storyId) async {
    final cleanId = storyId.trim();
    if (cleanId.isEmpty) return;

    final storyRef = _stories.doc(cleanId);
    final viewRef = storyRef.collection('views').doc(_uid);

    try {
      await _db.runTransaction((tx) async {
        final storySnap = await tx.get(storyRef);
        if (!storySnap.exists) return;

        final data = storySnap.data() ?? const <String, dynamic>{};
        final ownerId = ((data['ownerId'] ?? data['uid'] ?? '') as String)
            .trim();
        if (ownerId == _uid) return;

        final viewSnap = await tx.get(viewRef);
        if (viewSnap.exists) return;

        tx.set(viewRef, {
          'uid': _uid,
          'viewedAt': FieldValue.serverTimestamp(),
        });
        tx.set(storyRef, {
          'viewersCount': FieldValue.increment(1),
        }, SetOptions(merge: true));
      });
    } on FirebaseException catch (e) {
      if (!_isPermissionDenied(e)) rethrow;
      // Fallback for legacy rules that only allow viewers array updates.
      await storyRef.set({
        'viewers': FieldValue.arrayUnion([_uid]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  static Future<void> deleteStory(String storyId) async {
    final cleanId = storyId.trim();
    if (cleanId.isEmpty) return;

    final storyRef = _stories.doc(cleanId);
    final snap = await storyRef.get();
    if (!snap.exists) return;

    final data = snap.data() ?? const <String, dynamic>{};
    final ownerId =
        ((data['ownerId'] ??
                    data['uid'] ??
                    data['ownerUid'] ??
                    data['userId'] ??
                    '')
                as String)
            .trim();
    if (ownerId != _uid) {
      throw StateError('Only the story owner can delete this story.');
    }

    var deleted = false;
    try {
      final views = await storyRef.collection('views').limit(500).get();
      final batch = _db.batch();
      for (final doc in views.docs) {
        batch.delete(doc.reference);
      }
      batch.delete(storyRef);
      await batch.commit();
      deleted = true;
    } on FirebaseException catch (e, st) {
      debugPrint(
        'deleteStory batched delete failed for $cleanId '
        '(likely legacy rules on stories/{id}/views): '
        'code=${e.code}, message=${e.message}\n$st',
      );
      if (!_isPermissionDenied(e)) rethrow;
    }

    if (!deleted) {
      // Legacy fallback: if deleting `views` is blocked by rules, at least
      // delete the story document itself so the user can remove their story.
      await storyRef.delete();
    }

    final storyPath = 'stories/$_uid/$cleanId.jpg';
    for (final storage in _storyStorageCandidates()) {
      try {
        await storage.ref().child(storyPath).delete();
        break;
      } catch (_) {
        // Storage file may be absent for text stories or already deleted.
      }
    }
  }
}
