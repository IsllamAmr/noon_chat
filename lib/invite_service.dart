import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class InviteService {
  static final _db = FirebaseFirestore.instance;

  static String _code({int len = 8}) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static Future<Map<String, String>> createInvite() async {
    final me = FirebaseAuth.instance.currentUser!;
    final code = _code();
    final now = FieldValue.serverTimestamp();

    final chatRef = await _db.collection('chats').add({
      'participants': [me.uid],
      'createdBy': me.uid,
      'createdAt': now,
      'lastMessage': '',
      'lastMessageAt': now,
      'lastSenderId': me.uid,
    });

    await _db.collection('invites').doc(code).set({
      'code': code,
      'chatId': chatRef.id,
      'inviterUid': me.uid,
      'createdAt': now,
      'usedBy': null,
      'usedAt': null,
    });

    // ✅ اعمل inbox للـ inviter عشان يظهر في ChatsHome حتى قبل أول رسالة
    await _db.collection('users').doc(me.uid).collection('inbox').doc(chatRef.id).set({
      "chatId": chatRef.id,
      "title": "New chat",
      "photo": me.photoURL ?? "",
      "lastText": "",
      "lastTime": now,
      "type": "personal",
      "unread": 0,
    }, SetOptions(merge: true));

    return {'code': code, 'chatId': chatRef.id};
  }

  static Future<String?> acceptInvite(String code) async {
    final me = FirebaseAuth.instance.currentUser!;
    final clean = code.trim().toUpperCase();
    final inviteRef = _db.collection('invites').doc(clean);

    return _db.runTransaction((tx) async {
      final snap = await tx.get(inviteRef);
      if (!snap.exists) return null;

      final data = snap.data() as Map<String, dynamic>;
      if (data['usedBy'] != null) return null;

      final chatId = data['chatId'] as String;
      final inviterUid = data['inviterUid'] as String;

      tx.update(inviteRef, {
        'usedBy': me.uid,
        'usedAt': FieldValue.serverTimestamp(),
      });

      final chatRef = _db.collection('chats').doc(chatId);
      tx.set(chatRef, {
        'participants': FieldValue.arrayUnion([me.uid]),
        'lastMessageAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // ✅ inbox للطرف اللي انضم
      tx.set(
        _db.collection('users').doc(me.uid).collection('inbox').doc(chatId),
        {
          "chatId": chatId,
          "title": "New chat",
          "photo": "",
          "lastText": "",
          "lastTime": FieldValue.serverTimestamp(),
          "type": "personal",
          "unread": 0,
        },
        SetOptions(merge: true),
      );

      // ✅ inbox للطرف اللي دعا (تحديث بسيط)
      tx.set(
        _db.collection('users').doc(inviterUid).collection('inbox').doc(chatId),
        {
          "chatId": chatId,
          "lastTime": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      return chatId;
    });
  }
}
