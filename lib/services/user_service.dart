import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cloudinary_storage_service.dart';

class PeopleSearchRepository {
  final FirebaseFirestore db;
  PeopleSearchRepository(this.db);

  Query<Map<String, dynamic>> queryByName(String query, {int limit = 25}) {
    final clean = query.trim().toLowerCase();
    final col = db.collection('users');
    if (clean.isEmpty) {
      return col.orderBy('nameLower').limit(limit);
    }
    return col
        .orderBy('nameLower')
        .startAt([clean])
        .endAt(['$clean\uf8ff'])
        .limit(limit);
  }
}

class UserService {
  static final _db = FirebaseFirestore.instance;
  static final _functions = FirebaseFunctions.instance;

  static String _normalizeName(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _normalizeQuery(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static List<String> buildSearchKeywords(String name) {
    final normalized = _normalizeName(name);
    if (normalized.isEmpty) return const <String>[];

    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    final keywords = <String>{};

    for (final word in words) {
      for (var i = 1; i <= word.length && i <= 24; i++) {
        keywords.add(word.substring(0, i));
      }
    }

    for (var i = 1; i <= normalized.length && i <= 32; i++) {
      keywords.add(normalized.substring(0, i));
    }

    if (words.length > 1) {
      var phrase = '';
      for (var i = 0; i < words.length; i++) {
        phrase = phrase.isEmpty ? words[i] : '$phrase ${words[i]}';
        for (var j = 1; j <= phrase.length && j <= 32; j++) {
          keywords.add(phrase.substring(0, j));
        }
      }
    }

    return keywords.take(320).toList();
  }

  static Future<void> upsertMe() async {
    final user = FirebaseAuth.instance.currentUser!;
    final ref = _db.collection('users').doc(user.uid);
    final snap = await ref.get();
    final data = snap.data() ?? const <String, dynamic>{};

    final existingDisplayName =
        (data['displayName'] as String?)?.trim().isNotEmpty == true
        ? (data['displayName'] as String).trim()
        : ((data['name'] as String?)?.trim() ?? '');
    final existingPhotoUrl =
        (data['photoUrl'] as String?)?.trim().isNotEmpty == true
        ? (data['photoUrl'] as String).trim()
        : ((data['photo'] as String?)?.trim() ?? '');
    final effectiveName = existingDisplayName.isNotEmpty
        ? existingDisplayName
        : ((user.displayName ?? '').trim().isNotEmpty
              ? user.displayName!.trim()
              : 'Noon User');
    final effectivePhoto = existingPhotoUrl.isNotEmpty
        ? existingPhotoUrl
        : (user.photoURL ?? '').trim();
    final email = (user.email ?? '').trim();
    await ref.set({
      'uid': user.uid,
      'displayName': effectiveName,
      'name': effectiveName,
      'nameLower': _normalizeName(effectiveName),
      'searchKeywords': buildSearchKeywords(effectiveName),
      'email': email,
      'emailLower': email.toLowerCase(),
      'photoUrl': effectivePhoto.isEmpty ? null : effectivePhoto,
      'photo': effectivePhoto,
      'status': (data['status'] as String?)?.trim().isNotEmpty == true
          ? (data['status'] as String).trim()
          : 'Available',
      'privacy':
          data['privacy'] ?? {'lastSeen': 'everyone', 'photo': 'everyone'},
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<Map<String, dynamic>> loadMyProfile() async {
    final user = FirebaseAuth.instance.currentUser!;
    final snap = await _db.collection('users').doc(user.uid).get();
    final data = snap.data() ?? const <String, dynamic>{};

    final displayName = ((data['displayName'] ?? data['name'] ?? '') as String)
        .trim();
    final photoUrl = ((data['photoUrl'] ?? data['photo'] ?? '') as String)
        .trim();
    final email = ((data['email'] ?? user.email ?? '') as String).trim();

    return <String, dynamic>{
      'uid': user.uid,
      'displayName': displayName.isEmpty
          ? ((user.displayName ?? '').trim().isEmpty
                ? 'Noon User'
                : user.displayName!.trim())
          : displayName,
      'email': email,
      'photoUrl': photoUrl,
    };
  }

  static Future<String> uploadMyPhoto(Uint8List bytes) async {
    return uploadProfileImage(bytes);
  }

  static Future<String> uploadProfileImage(Uint8List bytes) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final upload = await CloudinaryStorageService.uploadImageBytes(
      bytes: bytes,
      folder: 'users/$uid/profile',
      publicId: 'profile_$stamp',
      fileName: 'profile_$stamp.jpg',
    );
    return upload.secureUrl;
  }

  static Future<void> updateMyProfile({
    required String name,
    String? status,
    String? photoUrl,
  }) async {
    await updateMyProfileData(name: name, status: status, photoUrl: photoUrl);
  }

  static Future<void> updateMyProfileData({
    required String name,
    String? status,
    String? photoUrl,
  }) async {
    final user = FirebaseAuth.instance.currentUser!;
    final cleanName = name.trim();
    final finalName = cleanName.length < 2 ? 'Noon User' : cleanName;
    final cleanPhoto = (photoUrl ?? '').trim();
    final cleanStatus = (status ?? '').trim();
    final email = (user.email ?? '').trim();

    await _db.collection('users').doc(user.uid).set({
      'uid': user.uid,
      'displayName': finalName,
      'name': finalName,
      'nameLower': _normalizeName(finalName),
      'searchKeywords': buildSearchKeywords(finalName),
      'email': email,
      'emailLower': email.toLowerCase(),
      if (cleanStatus.isNotEmpty) 'status': cleanStatus,
      if (cleanPhoto.isNotEmpty) 'photoUrl': cleanPhoto,
      if (cleanPhoto.isNotEmpty) 'photo': cleanPhoto,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await user.updateDisplayName(finalName);
    if (cleanPhoto.isNotEmpty) {
      await user.updatePhotoURL(cleanPhoto);
    }
  }

  static Query<Map<String, dynamic>> peopleSearchQuery(
    String query, {
    int limit = 25,
  }) {
    return PeopleSearchRepository(_db).queryByName(query, limit: limit);
  }

  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  searchUsersByNamePrefix(String query, {int limit = 25}) async {
    final clean = _normalizeQuery(query);
    if (clean.isEmpty) {
      return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    }

    final collected = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    final keywordSnap = await _db
        .collection('users')
        .where('searchKeywords', arrayContains: clean)
        .limit(limit)
        .get();
    for (final doc in keywordSnap.docs) {
      collected[doc.id] = doc;
    }

    if (collected.length < limit) {
      final legacyPrefixSnap = await _db
          .collection('users')
          .orderBy('nameLower')
          .startAt([clean])
          .endAt(['$clean\uf8ff'])
          .limit(limit)
          .get();
      for (final doc in legacyPrefixSnap.docs) {
        collected.putIfAbsent(doc.id, () => doc);
      }
    }

    return collected.values.take(limit).toList();
  }

  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  searchUsersByEmailPrefix(String query, {int limit = 25}) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) {
      return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    }

    final snap = await _db
        .collection('users')
        .orderBy('emailLower')
        .startAt([clean])
        .endAt(['$clean\uf8ff'])
        .limit(limit)
        .get();
    return snap.docs;
  }

  static Future<void> setPrivacy({
    required String key,
    required String value,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('users').doc(uid).set({
      'privacy.$key': value,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> blockUser(String otherUid) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('users').doc(uid).set({
      'blocked': FieldValue.arrayUnion([otherUid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> unblockUser(String otherUid) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('users').doc(uid).set({
      'blocked': FieldValue.arrayRemove([otherUid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> reportUser({
    required String otherUid,
    required String reason,
    String? chatId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('reports').add({
      'reportedBy': uid,
      'reportedUid': otherUid,
      'reason': reason.trim().isEmpty ? 'unspecified' : reason.trim(),
      'chatId': chatId ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> deleteMyAccountData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final callable = _functions.httpsCallable('deleteMyAccount');
      await callable.call();
      await FirebaseAuth.instance.signOut();
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'unavailable' ||
          e.code == 'not-found' ||
          e.code == 'unimplemented') {
        throw StateError(
          'Account deletion service is not available right now.',
        );
      }
      rethrow;
    }
  }
}
