import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_navigator.dart';
import 'chat_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final chatId = (message.data['chatId'] ?? '').toString();
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (chatId.isEmpty || uid == null) return;
  await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
    'deliveredAt.$uid': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

class NotificationService {
  static final ValueNotifier<int> unreadCounter = ValueNotifier<int>(0);
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _inboxSub;
  static final Map<String, DateTime> _deliveryDebounce = <String, DateTime>{};
  static final Map<String, String> _lastInboxMarkerByChat = <String, String>{};
  static bool _inboxPrimed = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'chat_messages',
    'Chat Messages',
    description: 'Notifications for incoming chat messages',
    importance: Importance.high,
  );

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _local.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (r) async {
        final payload = r.payload ?? '';
        if (payload.isNotEmpty) {
          await AppNavigator.openChat(payload);
        }
      },
    );

    final androidPlugin = _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_channel);

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        await _syncToken(user.uid);
        _bindDeliveryTracker(user.uid);
      } else {
        unreadCounter.value = 0;
        await _inboxSub?.cancel();
        _deliveryDebounce.clear();
        _lastInboxMarkerByChat.clear();
        _inboxPrimed = false;
      }
    });

    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await _saveToken(uid, token);
      }
    });

    FirebaseMessaging.onMessage.listen((message) async {
      final chatId = (message.data['chatId'] ?? '').toString();
      if (chatId.isNotEmpty) {
        ChatService.markDelivered(chatId);
        // Chat notifications are driven from inbox updates to avoid duplicates.
        return;
      }

      final n = message.notification;
      if (n == null) return;

      await _local.show(
        n.hashCode,
        n.title ?? 'New message',
        n.body ?? '',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'chat_messages',
            'Chat Messages',
            channelDescription: 'Notifications for incoming chat messages',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
          ),
          iOS: DarwinNotificationDetails(
            presentSound: true,
            presentAlert: true,
            presentBadge: true,
          ),
        ),
        payload: '',
      );
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      final chatId = (message.data['chatId'] ?? '').toString();
      if (chatId.isNotEmpty) {
        ChatService.markDelivered(chatId);
        await AppNavigator.openChat(chatId);
      }
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      final chatId = (initial.data['chatId'] ?? '').toString();
      if (chatId.isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 500), () {
          AppNavigator.openChat(chatId);
        });
      }
    }
  }

  static Future<void> _syncToken(String uid) async {
    final token = await _messaging.getToken();
    if (token == null || token.isEmpty) return;
    await _saveToken(uid, token);
  }

  static Future<void> _saveToken(String uid, String token) async {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    await userRef.collection('fcmTokens').doc(token).set({
      'token': token,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await userRef.set({
      'fcmToken': token,
      'fcmUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static void _bindDeliveryTracker(String uid) async {
    await _inboxSub?.cancel();
    _deliveryDebounce.clear();
    _lastInboxMarkerByChat.clear();
    _inboxPrimed = false;
    _inboxSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('inbox')
        .where('unread', isGreaterThan: 0)
        .snapshots()
        .listen((snap) {
          final currentMarkers = <String, String>{};
          final now = DateTime.now();
          var totalUnread = 0;
          for (final doc in snap.docs) {
            final chatId = doc.id;
            final data = doc.data();
            final unread = (data['unread'] is int) ? (data['unread'] as int) : 0;
            if (unread > 0) totalUnread += unread;
            final senderId = ((data['lastSenderId'] ?? '') as String).trim();
            final lastText = ((data['lastText'] ?? '') as String).trim();
            final lastTime = data['lastTime'] is Timestamp
                ? (data['lastTime'] as Timestamp)
                    .toDate()
                    .millisecondsSinceEpoch
                    .toString()
                : '';
            final marker = '$senderId|$lastTime|$lastText';
            currentMarkers[chatId] = marker;
            final prevMarker = _lastInboxMarkerByChat[chatId];

            final incomingChanged =
                _inboxPrimed &&
                marker != prevMarker &&
                senderId.isNotEmpty &&
                senderId != uid;
            if (incomingChanged) {
              final body = lastText.isEmpty
                  ? 'You received a new message'
                  : lastText;
              final title = ((data['title'] ?? 'New message') as String).trim();
              unawaited(
                _showLocalNotification(
                  chatId: chatId,
                  title: title.isEmpty ? 'New message' : title,
                  body: body,
                ),
              );
              final last = _deliveryDebounce[chatId];
              if (last == null ||
                  now.difference(last) >= const Duration(seconds: 5)) {
                _deliveryDebounce[chatId] = now;
                ChatService.markDelivered(chatId);
              }
            }
          }
          _lastInboxMarkerByChat
            ..clear()
            ..addAll(currentMarkers);
          unreadCounter.value = totalUnread;
          _inboxPrimed = true;
        });
  }

  static Future<void> _showLocalNotification({
    required String chatId,
    required String title,
    required String body,
  }) async {
    await _local.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_messages',
          'Chat Messages',
          channelDescription: 'Notifications for incoming chat messages',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
          presentAlert: true,
          presentBadge: true,
        ),
      ),
      payload: chatId,
    );
  }
}
