import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;
  static const int pageSize = 40;

  static String _directChatId(String a, String b) {
    final ids = [a, b]..sort();
    return 'dm_${ids[0]}_${ids[1]}';
  }

  static String _directChatIdV2(String a, String b) {
    final ids = [a, b]..sort();
    return 'dm2_${ids[0]}_${ids[1]}';
  }

  static String _directChatIdFallback(String a, String b) {
    final ids = [a, b]..sort();
    return 'dmx_${ids[0]}_${ids[1]}';
  }

  static String _directChatIdRescue(String a, String b) {
    final ids = [a, b]..sort();
    return 'dmu_${ids[0]}_${ids[1]}';
  }

  static List<String> _directChatCandidates(String a, String b) {
    return <String>[
      _directChatId(a, b),
      _directChatIdV2(a, b),
      _directChatIdFallback(a, b),
      _directChatIdRescue(a, b),
    ];
  }

  static List<String> _normalizedParticipants(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  static Future<void> _upsertMyInbox({
    required String myUid,
    required String chatId,
    required String otherUid,
    required String otherName,
    required String otherPhoto,
  }) async {
    final now = FieldValue.serverTimestamp();
    await _db
        .collection('users')
        .doc(myUid)
        .collection('inbox')
        .doc(chatId)
        .set({
          'chatId': chatId,
          'peerUid': otherUid,
          'title': otherName.isEmpty ? 'Chat' : otherName,
          'photo': otherPhoto,
          'type': 'personal',
          'unread': 0,
          'lastTime': now,
          'updatedAt': now,
        }, SetOptions(merge: true));
  }

  static Future<void> _createDirectChatIfMissing({
    required String chatId,
    required String meUid,
    required String otherUid,
  }) async {
    final now = FieldValue.serverTimestamp();
    final ref = _db.collection('chats').doc(chatId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) throw StateError('exists');
      tx.set(ref, {
        'participants': [meUid, otherUid],
        'createdBy': meUid,
        'createdAt': now,
        'lastMessage': '',
        'lastMessageAt': now,
        'lastSenderId': '',
        'chatType': 'direct',
        'disappearingSeconds': 0,
        'updatedAt': now,
      });
    });
  }

  static Future<String> getOrCreateDirectChat({
    required String otherUid,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    if (otherUid.trim().isEmpty || otherUid == me.uid) {
      throw StateError('Invalid user');
    }

    final otherSnap = await _db.collection('users').doc(otherUid).get();
    if (!otherSnap.exists) {
      throw StateError('User not found');
    }
    final otherData = otherSnap.data() ?? <String, dynamic>{};
    final otherName = ((otherData['name'] ?? '') as String).trim();
    final otherPhoto = ((otherData['photo'] ?? '') as String).trim();
    final candidates = _directChatCandidates(me.uid, otherUid);
    final now = FieldValue.serverTimestamp();
    FirebaseException? lastPermissionError;

    for (final chatId in candidates) {
      try {
        final snap = await _db.collection('chats').doc(chatId).get();
        if (!snap.exists) continue;

        final data = snap.data() ?? const <String, dynamic>{};
        final participants = _normalizedParticipants(data['participants']);
        final hasMe = participants.contains(me.uid);
        final hasOther = participants.contains(otherUid);

        if (hasMe && hasOther) {
          await _upsertMyInbox(
            myUid: me.uid,
            chatId: chatId,
            otherUid: otherUid,
            otherName: otherName,
            otherPhoto: otherPhoto,
          );
          return chatId;
        }

        // Invite-created direct chat with one participant (other user).
        if (!hasMe && hasOther && participants.length == 1) {
          await _db.collection('chats').doc(chatId).set({
            'participants': [otherUid, me.uid],
            'updatedAt': now,
            'lastMessageAt': data['lastMessageAt'] ?? now,
          }, SetOptions(merge: true));
          await _upsertMyInbox(
            myUid: me.uid,
            chatId: chatId,
            otherUid: otherUid,
            otherName: otherName,
            otherPhoto: otherPhoto,
          );
          return chatId;
        }
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          lastPermissionError = e;
          continue;
        }
        rethrow;
      }
    }

    final createOrder = <String>[
      _directChatId(me.uid, otherUid),
      _directChatIdRescue(me.uid, otherUid),
      _directChatIdV2(me.uid, otherUid),
      _directChatIdFallback(me.uid, otherUid),
    ];

    for (final chatId in createOrder) {
      try {
        await _createDirectChatIfMissing(
          chatId: chatId,
          meUid: me.uid,
          otherUid: otherUid,
        );
        await _upsertMyInbox(
          myUid: me.uid,
          chatId: chatId,
          otherUid: otherUid,
          otherName: otherName,
          otherPhoto: otherPhoto,
        );
        return chatId;
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          lastPermissionError = e;
          continue;
        }
        rethrow;
      } on StateError catch (e) {
        if (e.message == 'exists') continue;
        rethrow;
      }
    }

    throw lastPermissionError ?? StateError('Unable to open chat');
  }

  static Future<void> sendText({
    required String chatId,
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    final msg = text.trim();
    if (msg.isEmpty) return;
    await _sendMessage(
      chatId: chatId,
      type: 'text',
      text: msg,
      lastPreview: msg,
      replyTo: replyTo,
    );
  }

  static Future<void> sendCallInvite({
    required String chatId,
    required bool video,
  }) async {
    final room = chatId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final link = 'https://meet.jit.si/noon_chat_$room';
    await _sendMessage(
      chatId: chatId,
      type: 'call',
      callType: video ? 'video' : 'voice',
      callLink: link,
      text: video ? 'Video call' : 'Voice call',
      lastPreview: video ? 'Video call' : 'Voice call',
    );
  }

  static Future<void> sendImage({
    required String chatId,
    required String imageUrl,
    Map<String, dynamic>? replyTo,
  }) async {
    final url = imageUrl.trim();
    if (url.isEmpty) return;
    await _sendMessage(
      chatId: chatId,
      type: 'image',
      imageUrl: url,
      lastPreview: 'Photo',
      replyTo: replyTo,
    );
  }

  static Future<void> sendFile({
    required String chatId,
    required String fileUrl,
    required String fileName,
    required int fileSize,
    Map<String, dynamic>? replyTo,
  }) async {
    await _sendMessage(
      chatId: chatId,
      type: 'file',
      fileUrl: fileUrl.trim(),
      fileName: fileName.trim(),
      fileSize: fileSize,
      lastPreview: 'File: $fileName',
      replyTo: replyTo,
    );
  }

  static Future<void> sendAudio({
    required String chatId,
    required String audioUrl,
    int durationMs = 0,
    Map<String, dynamic>? replyTo,
  }) async {
    await _sendMessage(
      chatId: chatId,
      type: 'audio',
      audioUrl: audioUrl.trim(),
      durationMs: durationMs,
      lastPreview: 'Voice message',
      replyTo: replyTo,
    );
  }

  static Future<void> editMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final clean = text.trim();
    if (clean.isEmpty) throw StateError('Message cannot be empty');

    final msgRef = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    final chatRef = _db.collection('chats').doc(chatId);

    await _db.runTransaction((tx) async {
      final msgSnap = await tx.get(msgRef);
      if (!msgSnap.exists) throw StateError('Message not found');
      final msg = msgSnap.data() ?? <String, dynamic>{};
      if ((msg['senderId'] ?? '').toString() != me.uid) {
        throw StateError('You can only edit your own messages');
      }
      if ((msg['type'] ?? '').toString() != 'text') {
        throw StateError('Only text messages can be edited');
      }
      if (msg['deletedForEveryone'] == true) {
        throw StateError('Deleted message cannot be edited');
      }

      final now = FieldValue.serverTimestamp();
      tx.set(msgRef, {'text': clean, 'editedAt': now}, SetOptions(merge: true));

      final chatSnap = await tx.get(chatRef);
      final lastMessage = (chatSnap.data()?['lastMessage'] ?? '').toString();
      final lastSenderId = (chatSnap.data()?['lastSenderId'] ?? '').toString();
      if (lastSenderId == me.uid &&
          lastMessage == (msg['text'] ?? '').toString()) {
        tx.set(chatRef, {
          'lastMessage': clean,
          'updatedAt': now,
        }, SetOptions(merge: true));
      }

      tx.set(
        _db.collection('users').doc(me.uid).collection('inbox').doc(chatId),
        {'lastText': clean, 'updatedAt': now},
        SetOptions(merge: true),
      );
    });
  }

  static Future<void> deleteMessageForMe({
    required String chatId,
    required String messageId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .set({
          'hiddenBy': FieldValue.arrayUnion([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  static Future<void> deleteMessageForEveryone({
    required String chatId,
    required String messageId,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final msgRef = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    final chatRef = _db.collection('chats').doc(chatId);

    await _db.runTransaction((tx) async {
      final msgSnap = await tx.get(msgRef);
      if (!msgSnap.exists) throw StateError('Message not found');
      final msg = msgSnap.data() ?? <String, dynamic>{};
      if ((msg['senderId'] ?? '').toString() != me.uid) {
        throw StateError('You can only delete your own messages for everyone');
      }
      if (msg['deletedForEveryone'] == true) return;

      final now = FieldValue.serverTimestamp();
      tx.set(msgRef, {
        'deletedForEveryone': true,
        'deletedAt': now,
        'deletedBy': me.uid,
        'text': '',
        'imageUrl': '',
        'fileUrl': '',
        'audioUrl': '',
        'fileName': '',
        'durationMs': 0,
        'replyTo': FieldValue.delete(),
      }, SetOptions(merge: true));

      final chatSnap = await tx.get(chatRef);
      final lastMessage = (chatSnap.data()?['lastMessage'] ?? '').toString();
      final lastSenderId = (chatSnap.data()?['lastSenderId'] ?? '').toString();
      if (lastSenderId == me.uid &&
          lastMessage == ((msg['text'] ?? '').toString().trim())) {
        tx.set(chatRef, {
          'lastMessage': 'Message deleted',
          'updatedAt': now,
        }, SetOptions(merge: true));
      }
    });
  }

  static Future<void> forwardMessage({
    required String toChatId,
    required Map<String, dynamic> source,
  }) async {
    final type = (source['type'] ?? 'text').toString();
    if (type == 'call') {
      await _sendMessage(
        chatId: toChatId,
        type: 'call',
        callType: (source['callType'] ?? 'voice').toString(),
        callLink: (source['callLink'] ?? '').toString(),
        text: (source['text'] ?? 'Call').toString(),
        lastPreview: 'Forwarded call',
        forwarded: true,
      );
      return;
    }

    final sourceText = (source['text'] ?? '').toString().trim();
    final sourceFileName = (source['fileName'] ?? '').toString().trim();
    final previewText = sourceText.isNotEmpty
        ? sourceText
        : sourceFileName.isNotEmpty
        ? sourceFileName
        : 'Forwarded message';

    await _sendMessage(
      chatId: toChatId,
      type: type,
      text: (source['text'] ?? '').toString(),
      imageUrl: (source['imageUrl'] ?? '').toString(),
      fileUrl: (source['fileUrl'] ?? '').toString(),
      fileName: (source['fileName'] ?? '').toString(),
      fileSize: (source['fileSize'] is int) ? source['fileSize'] as int : 0,
      audioUrl: (source['audioUrl'] ?? '').toString(),
      durationMs: (source['durationMs'] is int)
          ? source['durationMs'] as int
          : 0,
      lastPreview: previewText,
      forwarded: true,
    );
  }

  static Future<void> setDisappearingDuration({
    required String chatId,
    required int seconds,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final chatRef = _db.collection('chats').doc(chatId);
    await _db.runTransaction((tx) async {
      final chatSnap = await tx.get(chatRef);
      if (!chatSnap.exists) throw StateError('Chat not found');
      final participants = List<String>.from(
        chatSnap.data()?['participants'] ?? const <String>[],
      );
      if (!participants.contains(me.uid)) {
        throw StateError('No permission to update chat');
      }
      tx.set(chatRef, {
        'disappearingSeconds': seconds < 0 ? 0 : seconds,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  static Future<void> _sendMessage({
    required String chatId,
    required String type,
    required String lastPreview,
    String text = '',
    String imageUrl = '',
    String fileUrl = '',
    String fileName = '',
    int fileSize = 0,
    String audioUrl = '',
    int durationMs = 0,
    Map<String, dynamic>? replyTo,
    bool forwarded = false,
    String callType = '',
    String callLink = '',
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final chatRef = _db.collection("chats").doc(chatId);
    final msgRef = chatRef.collection("messages").doc();
    final now = FieldValue.serverTimestamp();
    final chatSnap = await chatRef.get();
    if (!chatSnap.exists) {
      throw StateError('Chat not found');
    }
    final chatData = chatSnap.data() as Map<String, dynamic>;
    final participants = (chatData['participants'] is List)
        ? (chatData['participants'] as List)
              .map((e) => e?.toString().trim() ?? '')
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    if (!participants.contains(me.uid)) {
      throw StateError('You are no longer a participant in this chat');
    }
    final otherUid = participants.firstWhere(
      (id) => id != me.uid,
      orElse: () => '',
    );

    final disappearing = chatData['disappearingSeconds'];
    final disappearingSeconds = disappearing is int && disappearing > 0
        ? disappearing
        : 0;
    final expiresAt = disappearingSeconds > 0
        ? Timestamp.fromDate(
            DateTime.now().add(Duration(seconds: disappearingSeconds)),
          )
        : null;

    final payload = <String, dynamic>{
      "type": type,
      "text": text,
      "imageUrl": imageUrl,
      "fileUrl": fileUrl,
      "fileName": fileName,
      "fileSize": fileSize,
      "audioUrl": audioUrl,
      "durationMs": durationMs,
      "forwarded": forwarded,
      "senderId": me.uid,
      "createdAt": now,
    };
    if (expiresAt != null) payload["expiresAt"] = expiresAt;
    if (callType.isNotEmpty) payload["callType"] = callType;
    if (callLink.isNotEmpty) payload["callLink"] = callLink;
    if (replyTo != null && replyTo.isNotEmpty) {
      payload['replyTo'] = replyTo;
    }

    await msgRef.set(payload);

    try {
      await chatRef.set({
        "lastMessage": lastPreview,
        "lastMessageAt": now,
        "lastSenderId": me.uid,
        "updatedAt": now,
        "typing.${me.uid}": false,
        "seenAt.${me.uid}": now,
        "deliveredAt.${me.uid}": now,
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      debugPrint('chat metadata update failed (${e.code}) for $chatId');
    }

    final myInboxRef = _db
        .collection('users')
        .doc(me.uid)
        .collection('inbox')
        .doc(chatId);
    try {
      await myInboxRef.set({
        "chatId": chatId,
        if (otherUid.isNotEmpty) "peerUid": otherUid,
        "lastText": lastPreview,
        "lastTime": now,
        "lastSenderId": me.uid,
        "type": "personal",
        "unread": 0,
        "updatedAt": now,
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      debugPrint('inbox update failed (${e.code}) for $chatId');
    }

    if (otherUid.isNotEmpty) {
      var myName = (me.displayName ?? '').trim();
      var myPhoto = (me.photoURL ?? '').trim();
      try {
        final meSnap = await _db.collection('users').doc(me.uid).get();
        final meData = meSnap.data() ?? const <String, dynamic>{};
        final n = ((meData['name'] ?? '') as String).trim();
        final p = ((meData['photo'] ?? '') as String).trim();
        if (n.isNotEmpty) myName = n;
        if (p.isNotEmpty) myPhoto = p;
      } catch (_) {}

      final otherInboxRef = _db
          .collection('users')
          .doc(otherUid)
          .collection('inbox')
          .doc(chatId);
      try {
        await otherInboxRef.set({
          "chatId": chatId,
          "peerUid": me.uid,
          "title": myName.isEmpty ? "Chat" : myName,
          "photo": myPhoto,
          "lastText": lastPreview,
          "lastTime": now,
          "lastSenderId": me.uid,
          "type": "personal",
          "unread": FieldValue.increment(1),
          "updatedAt": now,
        }, SetOptions(merge: true));
      } on FirebaseException catch (e) {
        debugPrint('receiver inbox update failed (${e.code}) for $chatId');
      }
    }
  }

  static Future<void> setReaction({
    required String chatId,
    required String messageId,
    required String reaction,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .set({'reactions.$uid': reaction}, SetOptions(merge: true));
  }

  static Future<void> clearReaction({
    required String chatId,
    required String messageId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .set({'reactions.$uid': FieldValue.delete()}, SetOptions(merge: true));
  }

  static Future<void> markChatRead(String chatId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('users').doc(uid).collection('inbox').doc(chatId).set({
      'unread': 0,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await markSeen(chatId);
    await markDelivered(chatId);
  }

  static Future<void> setTyping({
    required String chatId,
    required bool isTyping,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('chats').doc(chatId).set({
      'typing.$uid': isTyping,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> markSeen(String chatId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('chats').doc(chatId).set({
      'seenAt.$uid': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> markDelivered(String chatId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db.collection('chats').doc(chatId).set({
      'deliveredAt.$uid': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(
    String chatId, {
    int limit = pageSize,
  }) {
    return _db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .orderBy("createdAt", descending: true)
        .limit(limit)
        .snapshots();
  }

  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  loadOlderMessages({
    required String chatId,
    required QueryDocumentSnapshot<Map<String, dynamic>> startAfter,
    int limit = pageSize,
  }) async {
    final snap = await _db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .orderBy("createdAt", descending: true)
        .startAfterDocument(startAfter)
        .limit(limit)
        .get();
    return snap.docs;
  }
}
