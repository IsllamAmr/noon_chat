import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class FcmTokenService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static StreamSubscription<String>? _refreshSub;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _refreshSub = _messaging.onTokenRefresh.listen((token) async {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || token.trim().isEmpty) return;
      await saveToken(uid: uid, token: token);
    });
  }

  static Future<void> dispose() async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    _initialized = false;
  }

  static Future<void> syncCurrentUserToken() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final token = await _messaging.getToken();
    if (token == null || token.trim().isEmpty) return;
    await saveToken(uid: uid, token: token);
  }

  static Future<void> saveToken({
    required String uid,
    required String token,
  }) async {
    final cleanUid = uid.trim();
    final cleanToken = token.trim();
    if (cleanUid.isEmpty || cleanToken.isEmpty) return;

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(cleanUid);
    final now = FieldValue.serverTimestamp();

    await userRef.collection('fcmTokens').doc(cleanToken).set({
      'token': cleanToken,
      'platform': _platformName(),
      'updatedAt': now,
    }, SetOptions(merge: true));

    await userRef.set({
      'fcmToken': cleanToken,
      'fcmTokens': FieldValue.arrayUnion([cleanToken]),
      'fcmUpdatedAt': now,
    }, SetOptions(merge: true));
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }
}
