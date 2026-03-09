import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;
  static const int pageSize = 24;
  static final Random _random = Random.secure();
  static final Map<String, Completer<void>> _sendLocksByChat =
      <String, Completer<void>>{};
  static final Map<String, DateTime> _recentSendDedup = <String, DateTime>{};
  static const Duration _sendDedupWindow = Duration(milliseconds: 1400);
  static const Duration _sendDedupGcWindow = Duration(minutes: 3);

  static String deterministicConversationId(String uid1, String uid2) {
    final ids = [uid1.trim(), uid2.trim()]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  static String _legacyDirectChatId(String prefix, String a, String b) {
    final ids = [a.trim(), b.trim()]..sort();
    return '${prefix}_${ids[0]}_${ids[1]}';
  }

  static List<String> _legacyDirectChatCandidates(String a, String b) {
    return <String>[
      _legacyDirectChatId('dm', a, b),
      _legacyDirectChatId('dm2', a, b),
      _legacyDirectChatId('dmx', a, b),
      _legacyDirectChatId('dmu', a, b),
    ];
  }

  static List<String> _directChatCandidates(String a, String b) {
    final canonical = deterministicConversationId(a, b);
    return <String>[canonical, ..._legacyDirectChatCandidates(a, b)];
  }

  static Future<String> getOrCreateConversation({
    required String otherUid,
    String? otherDisplayName,
    String? otherPhotoUrl,
  }) async {
    final targetUid = otherUid.trim();
    final chatId = await getOrCreateDirectChat(otherUid: targetUid);

    final me = FirebaseAuth.instance.currentUser!;
    var otherName = (otherDisplayName ?? '').trim();
    var otherPhoto = (otherPhotoUrl ?? '').trim();
    if (otherName.isEmpty || otherPhoto.isEmpty) {
      final otherSnap = await _db.collection('users').doc(targetUid).get();
      final otherData = otherSnap.data() ?? const <String, dynamic>{};
      if (otherName.isEmpty) {
        otherName =
            ((otherData['displayName'] ?? otherData['name'] ?? '') as String)
                .trim();
      }
      if (otherPhoto.isEmpty) {
        otherPhoto =
            ((otherData['photoUrl'] ?? otherData['photo'] ?? '') as String)
                .trim();
      }
    }
    if (otherName.isEmpty) otherName = 'Noon User';

    await _upsertMyInbox(
      myUid: me.uid,
      chatId: chatId,
      otherUid: targetUid,
      otherName: otherName,
      otherPhoto: otherPhoto,
      touchLastTime: false,
    );
    return chatId;
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
    bool touchLastTime = false,
  }) async {
    final now = FieldValue.serverTimestamp();
    final payload = <String, dynamic>{
      'chatId': chatId,
      'peerUid': otherUid,
      'title': otherName.isEmpty ? 'Chat' : otherName,
      'photo': otherPhoto,
      'type': 'personal',
      'unread': 0,
      'updatedAt': now,
    };
    if (touchLastTime) {
      payload['lastTime'] = now;
      payload['lastText'] = '';
    }

    await _db
        .collection('users')
        .doc(myUid)
        .collection('inbox')
        .doc(chatId)
        .set(payload, SetOptions(merge: true));
  }

  static Future<void> _ensureDirectChatDocument({
    required String chatId,
    required String meUid,
    required String otherUid,
  }) async {
    final now = FieldValue.serverTimestamp();
    final ref = _db.collection('chats').doc(chatId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) {
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
        return;
      }

      final data = snap.data() ?? const <String, dynamic>{};
      final participants = _normalizedParticipants(data['participants']);
      final mergedParticipants = <String>{
        ...participants,
        meUid,
        otherUid,
      }.toList();
      tx.set(ref, {
        'participants': mergedParticipants,
        'chatType': 'direct',
        'updatedAt': now,
        if ((data['createdBy'] ?? '').toString().trim().isEmpty)
          'createdBy': meUid,
        if (data['createdAt'] == null) 'createdAt': now,
      }, SetOptions(merge: true));
    });
  }

  static Future<void> _ensureConversationDocument({
    required String chatId,
    required String meUid,
    required String otherUid,
  }) async {
    try {
      final ref = _db.collection('conversations').doc(chatId);
      final now = FieldValue.serverTimestamp();
      await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) {
          tx.set(ref, {
            'members': [meUid, otherUid],
            'memberMap': {meUid: true, otherUid: true},
            'participants': [meUid, otherUid],
            'createdBy': meUid,
            'chatType': 'direct',
            'lastMessage': '',
            'lastMessageAt': now,
            'lastSenderId': '',
            'createdAt': now,
            'updatedAt': now,
            'disappearingSeconds': 0,
          });
          return;
        }

        final data = snap.data() ?? const <String, dynamic>{};
        final participants = _normalizedParticipants(data['participants']);
        final mergedParticipants = <String>{
          ...participants,
          meUid,
          otherUid,
        }.toList();
        tx.set(ref, {
          'members': mergedParticipants,
          'memberMap': {meUid: true, otherUid: true},
          'participants': mergedParticipants,
          'chatType': 'direct',
          'updatedAt': now,
          if ((data['createdBy'] ?? '').toString().trim().isEmpty)
            'createdBy': meUid,
          if (data['createdAt'] == null) 'createdAt': now,
        }, SetOptions(merge: true));
      });
    } on FirebaseException catch (e) {
      // Some projects lock conversations writes; chats is the source of truth.
      debugPrint('ensureConversationDocument skipped (${e.code}) for $chatId');
    }
  }

  static Future<String?> _findExistingDirectChatId({
    required String meUid,
    required String otherUid,
  }) async {
    for (final chatId in _directChatCandidates(meUid, otherUid)) {
      try {
        final snap = await _db.collection('chats').doc(chatId).get();
        if (!snap.exists) continue;
        final data = snap.data() ?? const <String, dynamic>{};
        final participants = _normalizedParticipants(data['participants']);
        final hasMe = participants.contains(meUid);
        final hasOther = participants.contains(otherUid);
        if (hasMe && hasOther) return chatId;
        if (!hasMe && hasOther && participants.length == 1) return chatId;
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') continue;
        rethrow;
      }
    }

    // Legacy fallback for random IDs that still hold a direct chat.
    try {
      String? lastDocId;
      while (true) {
        var query = _db
            .collection('chats')
            .where('participants', arrayContains: meUid)
            .orderBy(FieldPath.documentId)
            .limit(120);
        if (lastDocId != null) {
          query = query.startAfter([lastDocId]);
        }

        final byMe = await query.get();
        if (byMe.docs.isEmpty) break;

        for (final doc in byMe.docs) {
          final data = doc.data();
          final participants = _normalizedParticipants(data['participants']);
          final chatType = ((data['chatType'] ?? 'direct') as String)
              .trim()
              .toLowerCase();
          if (chatType == 'direct' &&
              participants.contains(meUid) &&
              participants.contains(otherUid)) {
            return doc.id;
          }
        }

        lastDocId = byMe.docs.last.id;
        if (byMe.docs.length < 120) {
          break;
        }
      }
    } on FirebaseException catch (e) {
      debugPrint('direct chat fallback scan failed (${e.code})');
    }
    return null;
  }

  static Future<String> getOrCreateDirectChat({
    required String otherUid,
  }) async {
    final me = FirebaseAuth.instance.currentUser!;
    final targetUid = otherUid.trim();
    if (targetUid.isEmpty || targetUid == me.uid) {
      throw StateError('Invalid user');
    }

    final otherSnap = await _db.collection('users').doc(targetUid).get();
    if (!otherSnap.exists) {
      throw StateError('User not found');
    }
    final otherData = otherSnap.data() ?? <String, dynamic>{};
    final otherName =
        ((otherData['displayName'] ?? otherData['name'] ?? '') as String)
            .trim()
            .isEmpty
        ? 'Noon User'
        : ((otherData['displayName'] ?? otherData['name']) as String).trim();
    final otherPhoto =
        ((otherData['photoUrl'] ?? otherData['photo'] ?? '') as String).trim();

    final existingId = await _findExistingDirectChatId(
      meUid: me.uid,
      otherUid: targetUid,
    );
    final chatId = existingId ?? deterministicConversationId(me.uid, targetUid);

    await _ensureDirectChatDocument(
      chatId: chatId,
      meUid: me.uid,
      otherUid: targetUid,
    );
    await _ensureConversationDocument(
      chatId: chatId,
      meUid: me.uid,
      otherUid: targetUid,
    );

    await _upsertMyInbox(
      myUid: me.uid,
      chatId: chatId,
      otherUid: targetUid,
      otherName: otherName,
      otherPhoto: otherPhoto,
      touchLastTime: existingId == null,
    );

    return chatId;
  }

  static Future<void> sendText({
    required String chatId,
    required String text,
    Map<String, dynamic>? replyTo,
    String? clientMessageId,
  }) async {
    final msg = text.trim();
    if (msg.isEmpty) return;
    await _sendMessage(
      chatId: chatId,
      type: 'text',
      text: msg,
      lastPreview: msg,
      replyTo: replyTo,
      clientMessageId: clientMessageId,
    );
  }

  static Future<void> sendCallInvite({
    required String chatId,
    required bool video,
    String? clientMessageId,
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
      clientMessageId: clientMessageId,
    );
  }

  static Future<void> sendImage({
    required String chatId,
    required String imageUrl,
    Map<String, dynamic>? replyTo,
    String? clientMessageId,
  }) async {
    final url = imageUrl.trim();
    if (url.isEmpty) return;
    await _sendMessage(
      chatId: chatId,
      type: 'image',
      imageUrl: url,
      lastPreview: 'Photo',
      replyTo: replyTo,
      clientMessageId: clientMessageId,
    );
  }

  static Future<void> sendFile({
    required String chatId,
    required String fileUrl,
    required String fileName,
    required int fileSize,
    Map<String, dynamic>? replyTo,
    String? clientMessageId,
  }) async {
    await _sendMessage(
      chatId: chatId,
      type: 'file',
      fileUrl: fileUrl.trim(),
      fileName: fileName.trim(),
      fileSize: fileSize,
      lastPreview: 'File: $fileName',
      replyTo: replyTo,
      clientMessageId: clientMessageId,
    );
  }

  static Future<void> sendAudio({
    required String chatId,
    required String audioUrl,
    int durationMs = 0,
    Map<String, dynamic>? replyTo,
    String? clientMessageId,
  }) async {
    await _sendMessage(
      chatId: chatId,
      type: 'audio',
      audioUrl: audioUrl.trim(),
      durationMs: durationMs,
      lastPreview: 'Voice message',
      replyTo: replyTo,
      clientMessageId: clientMessageId,
    );
  }

  static List<FirebaseStorage> _audioStorageCandidates() {
    final result = <FirebaseStorage>[];
    final seen = <String>{};

    void addBucket(String rawBucket) {
      final normalized = rawBucket.trim().replaceFirst(RegExp(r'^gs://'), '');
      if (normalized.isEmpty) return;
      final key = normalized.toLowerCase();
      if (!seen.add(key)) return;
      try {
        result.add(FirebaseStorage.instanceFor(bucket: 'gs://$normalized'));
      } catch (_) {}
    }

    try {
      final options = Firebase.app().options;
      final projectId = options.projectId.trim();
      if (projectId.isNotEmpty) {
        addBucket('$projectId.appspot.com');
        addBucket('$projectId.firebasestorage.app');
      }
      final configuredBucket = (options.storageBucket ?? '').trim();
      addBucket(configuredBucket);
      final normalized = configuredBucket.replaceFirst(
        RegExp(r'^gs://'),
        '',
      );
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

    if (result.isEmpty) {
      result.add(FirebaseStorage.instance);
    }
    return result;
  }

  static Future<void> sendAudioMessage({
    required String conversationId,
    required File audioFile,
    required int durationMs,
    Map<String, dynamic>? replyTo,
  }) async {
    final cleanChatId = conversationId.trim();
    if (cleanChatId.isEmpty) throw StateError('Invalid conversation id');
    if (!audioFile.existsSync()) throw StateError('Audio file not found');
    final messageId = _db
        .collection('chats')
        .doc(cleanChatId)
        .collection('messages')
        .doc()
        .id;
    if (messageId.trim().isEmpty) {
      throw StateError('Audio message id generation failed');
    }

    final relativePath = 'chat_audio/$cleanChatId/$messageId.m4a';
    final metadata = SettableMetadata(contentType: 'audio/mp4');
    final configuredBucket = (Firebase.app().options.storageBucket ?? '').trim();
    final storageCandidates = _audioStorageCandidates();
    FirebaseException? lastStorageError;
    String? url;

    for (var i = 0; i < storageCandidates.length; i++) {
      final storage = storageCandidates[i];
      final ref = storage.ref().child(relativePath);
      final bucket = ref.bucket;
      StreamSubscription<TaskSnapshot>? progressSub;
      try {
        debugPrint(
          'Audio upload start [${i + 1}/${storageCandidates.length}] '
          'bucket=$bucket path=${ref.fullPath} local=${audioFile.path}',
        );

        final uploadTask = ref.putFile(audioFile, metadata);
        progressSub = uploadTask.snapshotEvents.listen((snapshot) {
          debugPrint(
            'Audio upload snapshot state=${snapshot.state.name} '
            'bytes=${snapshot.bytesTransferred}/${snapshot.totalBytes} '
            'bucket=${snapshot.ref.bucket} path=${snapshot.ref.fullPath}',
          );
        });

        final completed = await uploadTask;
        debugPrint(
          'Audio upload completed state=${completed.state.name} '
          'bucket=${completed.ref.bucket} path=${completed.ref.fullPath}',
        );

        if (completed.state != TaskState.success) {
          throw FirebaseException(
            plugin: 'firebase_storage',
            code: 'upload-failed',
            message:
                'Upload task completed with non-success state: '
                '${completed.state.name} at ${completed.ref.fullPath}',
          );
        }

        // Use the exact same reference used for upload.
        final downloadUrl = await completed.ref.getDownloadURL();
        debugPrint(
          'Audio download URL resolved bucket=${completed.ref.bucket} '
          'path=${completed.ref.fullPath} url=$downloadUrl',
        );
        if (downloadUrl.trim().isEmpty) {
          throw FirebaseException(
            plugin: 'firebase_storage',
            code: 'empty-download-url',
            message:
                'Upload succeeded but download URL is empty '
                'for ${completed.ref.fullPath}',
          );
        }
        url = downloadUrl;
        break;
      } on FirebaseException catch (e, st) {
        lastStorageError = e;
        debugPrint(
          'Audio upload failed code=${e.code} message=${e.message} '
          'bucket=$bucket path=${ref.fullPath}\n$st',
        );
      } catch (e, st) {
        debugPrint(
          'Audio upload failed with non-Firebase error '
          'bucket=$bucket path=${ref.fullPath}: $e\n$st',
        );
      } finally {
        await progressSub?.cancel();
      }
    }

    if (url == null || url.trim().isEmpty) {
      final err = lastStorageError;
      throw FirebaseException(
        plugin: 'firebase_storage',
        code: err?.code ?? 'audio-url-unresolved',
        message:
            'Audio upload finished but download URL could not be resolved. '
            'path=$relativePath configuredBucket=${configuredBucket.isEmpty ? '(empty)' : configuredBucket}. '
            'Last error=${err?.code ?? 'unknown'}: ${err?.message ?? 'none'}',
      );
    }

    await sendAudio(
      chatId: cleanChatId,
      audioUrl: url,
      durationMs: durationMs,
      replyTo: replyTo,
      clientMessageId: messageId,
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
      final createdAt = msg['createdAt'];
      if (createdAt is! Timestamp) {
        throw StateError('Message timestamp missing');
      }
      final editDeadline = createdAt.toDate().add(const Duration(minutes: 5));
      if (DateTime.now().isAfter(editDeadline)) {
        throw StateError('Edit is available only within 5 minutes');
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

  static String _nextMessageId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = List.generate(
      6,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  static String _replyAnchor(Map<String, dynamic>? replyTo) {
    if (replyTo == null || replyTo.isEmpty) return '';
    final keys = <String>['id', 'messageId', 'mid', 'text', 'fileName'];
    for (final key in keys) {
      final value = (replyTo[key] ?? '').toString().trim();
      if (value.isNotEmpty) return '$key:$value';
    }
    return '';
  }

  static String _messageDedupKey({
    required String senderUid,
    required String chatId,
    required String type,
    required String text,
    required String imageUrl,
    required String fileUrl,
    required String fileName,
    required String audioUrl,
    required int durationMs,
    required String callType,
    required String callLink,
    required bool forwarded,
    required Map<String, dynamic>? replyTo,
  }) {
    return [
      senderUid,
      chatId.trim(),
      type.trim(),
      text.trim(),
      imageUrl.trim(),
      fileUrl.trim(),
      fileName.trim(),
      audioUrl.trim(),
      durationMs.toString(),
      callType.trim(),
      callLink.trim(),
      forwarded ? '1' : '0',
      _replyAnchor(replyTo),
    ].join('|');
  }

  static bool _shouldSkipAsRecentDuplicate(String key) {
    final now = DateTime.now();
    _recentSendDedup.removeWhere(
      (_, ts) => now.difference(ts) > _sendDedupGcWindow,
    );
    final last = _recentSendDedup[key];
    if (last != null && now.difference(last) < _sendDedupWindow) {
      return true;
    }
    _recentSendDedup[key] = now;
    return false;
  }

  static Future<void> _runWithChatSendLock(
    String chatId,
    Future<void> Function() action,
  ) async {
    while (true) {
      final existing = _sendLocksByChat[chatId];
      if (existing == null) break;
      await existing.future;
    }

    final lock = Completer<void>();
    _sendLocksByChat[chatId] = lock;
    try {
      await action();
    } finally {
      if (!lock.isCompleted) {
        lock.complete();
      }
      if (identical(_sendLocksByChat[chatId], lock)) {
        _sendLocksByChat.remove(chatId);
      }
    }
  }

  static Future<void> _sendMessage({
    required String chatId,
    required String type,
    required String lastPreview,
    String? clientMessageId,
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
    final cleanChatId = chatId.trim();
    if (cleanChatId.isEmpty) {
      throw StateError('Invalid chat id');
    }

    final dedupKey = _messageDedupKey(
      senderUid: me.uid,
      chatId: cleanChatId,
      type: type,
      text: text,
      imageUrl: imageUrl,
      fileUrl: fileUrl,
      fileName: fileName,
      audioUrl: audioUrl,
      durationMs: durationMs,
      callType: callType,
      callLink: callLink,
      forwarded: forwarded,
      replyTo: replyTo,
    );
    if (_shouldSkipAsRecentDuplicate(dedupKey)) {
      debugPrint('Skipped duplicate message send for $cleanChatId');
      return;
    }

    await _runWithChatSendLock(cleanChatId, () async {
      final chatRef = _db.collection('chats').doc(cleanChatId);
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
      final now = FieldValue.serverTimestamp();

      final disappearing = chatData['disappearingSeconds'];
      final disappearingSeconds = disappearing is int && disappearing > 0
          ? disappearing
          : 0;
      final expiresAt = disappearingSeconds > 0
          ? Timestamp.fromDate(
              DateTime.now().add(Duration(seconds: disappearingSeconds)),
            )
          : null;

      final cleanedClientId = (clientMessageId ?? '').trim();
      final messageId = cleanedClientId.isEmpty
          ? _nextMessageId()
          : cleanedClientId;
      final msgRef = chatRef.collection('messages').doc(messageId);
      final payload = <String, dynamic>{
        'clientMessageId': messageId,
        'type': type,
        'text': text,
        'imageUrl': imageUrl,
        'fileUrl': fileUrl,
        'fileName': fileName,
        'fileSize': fileSize < 0 ? 0 : fileSize,
        'audioUrl': audioUrl,
        'durationMs': durationMs < 0 ? 0 : durationMs,
        'forwarded': forwarded,
        'senderId': me.uid,
        'createdAt': now,
      };
      if (expiresAt != null) payload['expiresAt'] = expiresAt;
      if (callType.isNotEmpty) payload['callType'] = callType;
      if (callLink.isNotEmpty) payload['callLink'] = callLink;
      if (replyTo != null && replyTo.isNotEmpty) {
        payload['replyTo'] = replyTo;
      }

      await msgRef.set(payload);

      final writes = <Future<void>>[];
      writes.add(
        chatRef.set({
          'lastMessage': lastPreview,
          'lastMessageAt': now,
          'lastSenderId': me.uid,
          'updatedAt': now,
          'typing.${me.uid}': false,
          'seenAt.${me.uid}': now,
          'deliveredAt.${me.uid}': now,
        }, SetOptions(merge: true)),
      );

      final myInboxRef = _db
          .collection('users')
          .doc(me.uid)
          .collection('inbox')
          .doc(cleanChatId);
      writes.add(
        myInboxRef.set({
          'chatId': cleanChatId,
          if (otherUid.isNotEmpty) 'peerUid': otherUid,
          'lastText': lastPreview,
          'lastTime': now,
          'lastSenderId': me.uid,
          'type': 'personal',
          'unread': 0,
          'updatedAt': now,
        }, SetOptions(merge: true)),
      );

      if (otherUid.isNotEmpty) {
        final myName = (me.displayName ?? '').trim();
        final myPhoto = (me.photoURL ?? '').trim();
        final otherInboxRef = _db
            .collection('users')
            .doc(otherUid)
            .collection('inbox')
            .doc(cleanChatId);
        writes.add(
          otherInboxRef.set({
            'chatId': cleanChatId,
            'peerUid': me.uid,
            'title': myName.isEmpty ? 'Chat' : myName,
            'photo': myPhoto,
            'lastText': lastPreview,
            'lastTime': now,
            'lastSenderId': me.uid,
            'type': 'personal',
            'unread': FieldValue.increment(1),
            'updatedAt': now,
          }, SetOptions(merge: true)),
        );
      }

      for (final write in writes) {
        try {
          await write;
        } on FirebaseException catch (e) {
          debugPrint('aux chat write failed (${e.code}) for $cleanChatId');
        } catch (e) {
          debugPrint('aux chat write failed for $cleanChatId: $e');
        }
      }

      // Push notifications are sent from backend only (Cloud Functions/server)
      // to keep one source of truth and avoid duplicate notifications.
    });
  }

  static String generateClientMessageId() => _nextMessageId();

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
    await Future.wait([
      _db.collection('users').doc(uid).collection('inbox').doc(chatId).set({
        'unread': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
      _db.collection('chats').doc(chatId).set({
        'seenAt.$uid': FieldValue.serverTimestamp(),
        'deliveredAt.$uid': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    ]);
  }

  static Future<void> setTyping({
    required String chatId,
    required bool isTyping,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      await _db.collection('chats').doc(chatId).set({
        'typing.$uid': isTyping,
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        debugPrint('setTyping denied for $chatId');
        return;
      }
      rethrow;
    }
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
