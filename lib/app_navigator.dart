import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'screens/chat_screen.dart';

class AppNavigator {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Future<void> openChat(String chatId) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    var name = 'Chat';
    var photo = '';
    var peerUid = '';

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        final inboxDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('inbox')
            .doc(chatId)
            .get();
        final data = inboxDoc.data() ?? const <String, dynamic>{};
        final inboxName = ((data['title'] ?? '') as String).trim();
        final inboxPhoto = ((data['photo'] ?? '') as String).trim();
        final inboxPeerUid = ((data['peerUid'] ?? '') as String).trim();

        if (inboxName.isNotEmpty) name = inboxName;
        photo = inboxPhoto;
        peerUid = inboxPeerUid;
      } catch (_) {}
    }

    await nav.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conversationId: chatId,
          otherUser: ChatOtherUser(
            uid: peerUid,
            name: name,
            avatarUrl: photo.isEmpty ? null : photo,
          ),
        ),
      ),
    );
  }
}
