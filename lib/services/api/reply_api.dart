import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class ReplyApi {
  static const String _region = String.fromEnvironment(
    'FIREBASE_FUNCTIONS_REGION',
    defaultValue: 'us-central1',
  );

  static Uri _endpointUri() {
    final projectId = Firebase.app().options.projectId;
    if (projectId.isEmpty) {
      throw StateError('Missing Firebase projectId for sendReply endpoint');
    }
    return Uri.parse(
      'https://$_region-$projectId.cloudfunctions.net/sendReply',
    );
  }

  static String buildNotificationPayload({
    required String conversationId,
    String senderId = '',
    String senderName = '',
    String messageId = '',
  }) {
    return jsonEncode({
      'type': 'chat',
      'conversationId': conversationId,
      'senderId': senderId,
      'senderName': senderName,
      'messageId': messageId,
    });
  }

  static Map<String, dynamic> parsePayload(String payload) {
    if (payload.trim().isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }

  static String conversationIdFromPayload(String payload) {
    final data = parsePayload(payload);
    final value = (data['conversationId'] ?? data['chatId'] ?? '')
        .toString()
        .trim();
    return value;
  }

  static Future<bool> sendReply({
    required String conversationId,
    required String replyText,
    String senderUid = '',
  }) async {
    final text = replyText.trim();
    if (conversationId.trim().isEmpty || text.isEmpty) return false;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final idToken = await user.getIdToken(true);
    final sender = senderUid.trim().isEmpty ? user.uid : senderUid.trim();
    final uri = _endpointUri();
    final body = jsonEncode({
      'conversationId': conversationId.trim(),
      'replyText': text,
      'senderUid': sender,
    });

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $idToken');
      request.write(body);

      final response = await request.close();
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e, st) {
      debugPrint('ReplyApi.sendReply failed: $e\n$st');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> sendReplyFromNotification({
    required String payload,
    required String replyText,
  }) async {
    final conversationId = conversationIdFromPayload(payload);
    if (conversationId.isEmpty) return false;
    return sendReply(conversationId: conversationId, replyText: replyText);
  }
}
