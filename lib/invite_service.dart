import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'chat_service.dart';

class InviteService {
  static final _db = FirebaseFirestore.instance;
  static final _functions = FirebaseFunctions.instance;
  static const _inviteDomain = 'noon-8531a.web.app';
  static const _appScheme = 'noonchat';
  static final _inviteCodeRegex = RegExp(r'^[A-Z2-9]{6,20}$');
  static final _embeddedLinkRegex = RegExp(
    r'((?:https?:\/\/|noonchat:\/\/)[^\s]+)',
    caseSensitive: false,
  );

  static String _stripTrailingPunctuation(String value) {
    return value.replaceFirst(RegExp(r'[)\]}>.,!?;:]+$'), '');
  }

  static String _inviteId({int len = 12}) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String buildInviteLink(String inviteId) {
    return buildWebInviteLink(inviteId);
  }

  static String buildAppInviteLink(String inviteId) {
    return '$_appScheme://invite/${inviteId.toUpperCase()}';
  }

  static String buildWebInviteLink(String inviteId) {
    return 'https://$_inviteDomain/invite/${inviteId.toUpperCase()}';
  }

  static String? extractInviteId(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;
    final sanitized = _stripTrailingPunctuation(raw);

    final codeOnly = sanitized.toUpperCase();
    if (_inviteCodeRegex.hasMatch(codeOnly)) {
      return codeOnly;
    }

    final embedded = _embeddedLinkRegex.firstMatch(raw);
    if (embedded != null) {
      final embeddedRaw = _stripTrailingPunctuation(
        (embedded.group(1) ?? '').trim(),
      );
      if (embeddedRaw.isNotEmpty && embeddedRaw != raw) {
        final parsedEmbedded = extractInviteId(embeddedRaw);
        if (parsedEmbedded != null) return parsedEmbedded;
      }
    }

    final normalized =
        sanitized.startsWith('http://') || sanitized.startsWith('https://')
        ? sanitized
        : sanitized.startsWith('$_inviteDomain/')
        ? 'https://$sanitized'
        : sanitized;

    final uri = Uri.tryParse(normalized);
    if (uri == null) return null;

    if (uri.scheme.toLowerCase() == _appScheme) {
      final host = uri.host.toLowerCase();
      if ((host == 'invite' || host == 'join') && uri.pathSegments.isNotEmpty) {
        final id = uri.pathSegments.first.trim().toUpperCase();
        if (_inviteCodeRegex.hasMatch(id)) return id;
      }
    }

    final queryId = uri.queryParameters['invite']?.trim();
    if (queryId != null && queryId.isNotEmpty) {
      final id = queryId.toUpperCase();
      if (_inviteCodeRegex.hasMatch(id)) return id;
    }

    if (uri.pathSegments.length >= 2) {
      final first = uri.pathSegments.first.toLowerCase();
      final second = uri.pathSegments[1].trim().toUpperCase();
      if ((first == 'invite' || first == 'join') &&
          _inviteCodeRegex.hasMatch(second)) {
        return second;
      }
    }

    return null;
  }

  static Future<Map<String, String>> createInvite() async {
    final me = FirebaseAuth.instance.currentUser!;
    final inviteId = _inviteId();
    final now = FieldValue.serverTimestamp();

    final chatRef = await _db.collection('chats').add({
      'participants': [me.uid],
      'createdBy': me.uid,
      'createdAt': now,
      'lastMessage': '',
      'lastMessageAt': now,
      'lastSenderId': '',
      'chatType': 'direct',
      'disappearingSeconds': 0,
    });

    await _db.collection('invites').doc(inviteId).set({
      'code': inviteId,
      'chatId': chatRef.id,
      'inviterUid': me.uid,
      'createdAt': now,
      'usedBy': null,
      'usedAt': null,
    });

    await _db
        .collection('users')
        .doc(me.uid)
        .collection('inbox')
        .doc(chatRef.id)
        .set({
          'chatId': chatRef.id,
          'title': 'New chat',
          'photo': me.photoURL ?? '',
          'lastText': '',
          'lastTime': now,
          'type': 'personal',
          'unread': 0,
        }, SetOptions(merge: true));

    return {
      'code': inviteId,
      'chatId': chatRef.id,
      'link': buildInviteLink(inviteId),
    };
  }

  static Future<String?> acceptInvite(String inviteLink) async {
    final clean = extractInviteId(inviteLink);
    if (clean == null) return null;

    try {
      final callable = _functions.httpsCallable('acceptInvite');
      final res = await callable.call(<String, dynamic>{'inviteLink': clean});
      final data = res.data;
      if (data is Map) {
        final chatId = (data['chatId'] ?? '').toString().trim();
        if (chatId.isNotEmpty) return chatId;
      }
    } on FirebaseFunctionsException {
      // Spark plan or undeployed functions: fallback to client transaction.
    } catch (_) {
      // Fallback below.
    }
    try {
      final joinedChatId = await _acceptInviteClient(clean);
      if (joinedChatId != null) return joinedChatId;
      final existing = await _chatIfAlreadyJoined(clean);
      if (existing != null) return existing;
      return _openDirectWithInviter(clean);
    } on FirebaseException catch (e) {
      debugPrint('Invite fallback failed (${e.code}): ${e.message}');
      final existing = await _chatIfAlreadyJoined(clean);
      if (existing != null) return existing;
      return _openDirectWithInviter(clean);
    } catch (e) {
      debugPrint('Invite fallback failed: $e');
      final existing = await _chatIfAlreadyJoined(clean);
      if (existing != null) return existing;
      return _openDirectWithInviter(clean);
    }
  }

  static Future<String?> _chatIfAlreadyJoined(String inviteId) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return null;
    try {
      final inviteSnap = await _db.collection('invites').doc(inviteId).get();
      if (!inviteSnap.exists) return null;
      final invite = inviteSnap.data() ?? const <String, dynamic>{};
      final chatId = (invite['chatId'] ?? '').toString().trim();
      if (chatId.isEmpty) return null;

      final inboxSnap = await _db
          .collection('users')
          .doc(me.uid)
          .collection('inbox')
          .doc(chatId)
          .get();
      if (inboxSnap.exists) return chatId;

      final chatSnap = await _db.collection('chats').doc(chatId).get();
      if (!chatSnap.exists) return null;
      final participants = (chatSnap.data()?['participants'] is List)
          ? (chatSnap.data()!['participants'] as List)
                .map((e) => e?.toString().trim() ?? '')
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[];
      if (participants.contains(me.uid)) return chatId;
    } catch (_) {
      // Ignore and return null below.
    }
    return null;
  }

  static Future<String?> _openDirectWithInviter(String inviteId) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return null;
    try {
      final inviteSnap = await _db.collection('invites').doc(inviteId).get();
      if (!inviteSnap.exists) return null;
      final invite = inviteSnap.data() ?? const <String, dynamic>{};
      final inviterUid = (invite['inviterUid'] ?? '').toString().trim();
      if (inviterUid.isEmpty) return null;

      if (inviterUid == me.uid) {
        final ownChatId = (invite['chatId'] ?? '').toString().trim();
        return ownChatId.isEmpty ? null : ownChatId;
      }

      final chatId = await ChatService.getOrCreateDirectChat(
        otherUid: inviterUid,
      );

      // Best-effort: mark invite as used by this user.
      try {
        await _db.collection('invites').doc(inviteId).set({
          'usedBy': me.uid,
          'usedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      return chatId;
    } catch (e) {
      debugPrint('Invite direct fallback failed: $e');
      return null;
    }
  }

  static Future<String?> _acceptInviteClient(String inviteId) async {
    final me = FirebaseAuth.instance.currentUser!;
    final inviteRef = _db.collection('invites').doc(inviteId);

    return _db.runTransaction((tx) async {
      final inviteSnap = await tx.get(inviteRef);
      if (!inviteSnap.exists) return null;
      final invite = inviteSnap.data() ?? const <String, dynamic>{};
      final usedBy = (invite['usedBy'] ?? '').toString().trim();

      final chatId = (invite['chatId'] ?? '').toString().trim();
      final inviterUid = (invite['inviterUid'] ?? '').toString().trim();
      if (chatId.isEmpty || inviterUid.isEmpty) return null;

      final chatRef = _db.collection('chats').doc(chatId);
      final chatSnap = await tx.get(chatRef);
      if (!chatSnap.exists) return null;
      final chat = chatSnap.data() ?? const <String, dynamic>{};
      final participants = (chat['participants'] is List)
          ? (chat['participants'] as List)
                .map((e) => e?.toString().trim() ?? '')
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList()
          : <String>[];

      final alreadyParticipant = participants.contains(me.uid);
      final inviterClaimOnly =
          usedBy.isNotEmpty &&
          usedBy == inviterUid &&
          participants.length == 1 &&
          participants.contains(inviterUid);

      // If chat is full and user is not inside, reject.
      if (!alreadyParticipant && participants.length >= 2) {
        return null;
      }
      // If invite is claimed by someone else, reject unless this is the
      // special "inviter self-scanned first" case (single-participant chat).
      if (!alreadyParticipant && usedBy.isNotEmpty && usedBy != me.uid) {
        if (!(inviterClaimOnly && me.uid != inviterUid)) return null;
      }

      final inviterRef = _db.collection('users').doc(inviterUid);
      final inviterSnap = await tx.get(inviterRef);
      final inviter = inviterSnap.data() ?? const <String, dynamic>{};
      final inviterName = (inviter['name'] ?? '').toString().trim();
      final inviterPhoto = (inviter['photo'] ?? '').toString().trim();
      final now = FieldValue.serverTimestamp();

      if (!alreadyParticipant) {
        tx.set(chatRef, {
          'participants': FieldValue.arrayUnion([me.uid]),
          'updatedAt': now,
          'lastMessageAt': chat['lastMessageAt'] ?? now,
        }, SetOptions(merge: true));
      }

      tx.set(
        _db.collection('users').doc(me.uid).collection('inbox').doc(chatId),
        {
          'chatId': chatId,
          'peerUid': inviterUid,
          'title': inviterName.isEmpty ? 'New chat' : inviterName,
          'photo': inviterPhoto,
          'lastText': (chat['lastMessage'] ?? '').toString(),
          'lastTime': chat['lastMessageAt'] ?? now,
          'type': 'personal',
          'unread': 0,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );

      final shouldClaimInvite =
          !alreadyParticipant &&
          (usedBy.isEmpty || usedBy == me.uid || inviterClaimOnly);
      if (shouldClaimInvite) {
        tx.set(inviteRef, {
          'usedBy': me.uid,
          'usedAt': now,
        }, SetOptions(merge: true));
      }

      return chatId;
    });
  }
}
