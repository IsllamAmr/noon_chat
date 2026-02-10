import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> sendText({
    required String chatId,
    required String text,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final msg = text.trim();
    if (msg.isEmpty) return;

    final chatRef = _db.collection("chats").doc(chatId);
    final msgRef = chatRef.collection("messages").doc();
    final now = FieldValue.serverTimestamp();

    await _db.runTransaction((tx) async {
      final chatSnap = await tx.get(chatRef);
      if (!chatSnap.exists) return;

      final chatData = chatSnap.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);

      tx.set(msgRef, {
        "type": "text",
        "text": msg,
        "senderId": me.uid,
        "createdAt": now,
      });

      tx.set(
        chatRef,
        {
          "lastMessage": msg,
          "lastMessageAt": now,
          "lastSenderId": me.uid,
        },
        SetOptions(merge: true),
      );

      for (final uid in participants) {
        final inboxRef =
            _db.collection('users').doc(uid).collection('inbox').doc(chatId);

        tx.set(
          inboxRef,
          {
            "chatId": chatId,
            "title": "Chat",
            "photo": "",
            "lastText": msg,
            "lastTime": now,
            "type": "personal",
            "unread": uid == me.uid ? 0 : FieldValue.increment(1),
          },
          SetOptions(merge: true),
        );
      }
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(String chatId) {
    return _db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .orderBy("createdAt", descending: true)
        .snapshots();
  }
}
