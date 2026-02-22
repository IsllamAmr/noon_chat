import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

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

  static String _normalizeName(String value) => value.trim().toLowerCase();

  static Future<void> upsertMe() async {
    final u = FirebaseAuth.instance.currentUser!;
    final ref = _db.collection('users').doc(u.uid);
    final snap = await ref.get();
    final data = snap.data();
    final existingName = (data?['name'] as String?)?.trim() ?? '';
    final existingPhoto = (data?['photo'] as String?)?.trim() ?? '';
    final unreadRaw = data == null ? null : data['unreadTotal'];
    final unreadTotal = unreadRaw is int ? unreadRaw : 0;
    final effectiveName = existingName.isNotEmpty
        ? existingName
        : (u.displayName ?? 'Noon User');

    await ref.set({
      'name': effectiveName,
      'nameLower': _normalizeName(effectiveName),
      'email': u.email ?? '',
      'photo': existingPhoto.isNotEmpty ? existingPhoto : (u.photoURL ?? ''),
      'status': (data?['status'] as String?)?.trim().isNotEmpty == true
          ? (data?['status'] as String).trim()
          : 'Available',
      'privacy':
          data?['privacy'] ?? {'lastSeen': 'everyone', 'photo': 'everyone'},
      'unreadTotal': unreadTotal,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': data?['createdAt'] ?? FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<String> uploadMyPhoto(Uint8List bytes) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final ref = FirebaseStorage.instance.ref().child('users/$uid/profile.jpg');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  static Future<void> updateMyProfile({
    required String name,
    String? status,
    String? photoUrl,
  }) async {
    final u = FirebaseAuth.instance.currentUser!;
    final cleanName = name.trim();
    final finalName = cleanName.isEmpty ? 'Noon User' : cleanName;
    final cleanPhoto = (photoUrl ?? '').trim();
    final cleanStatus = (status ?? '').trim();

    await _db.collection('users').doc(u.uid).set({
      'name': finalName,
      'nameLower': _normalizeName(finalName),
      if (cleanStatus.isNotEmpty) 'status': cleanStatus,
      if (cleanPhoto.isNotEmpty) 'photo': cleanPhoto,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await u.updateDisplayName(finalName);
    if (cleanPhoto.isNotEmpty) {
      await u.updatePhotoURL(cleanPhoto);
    }
  }

  static Query<Map<String, dynamic>> peopleSearchQuery(
    String query, {
    int limit = 25,
  }) {
    return PeopleSearchRepository(_db).queryByName(query, limit: limit);
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
