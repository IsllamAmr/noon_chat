import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../app_navigator.dart';
import 'fcm_token_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.notification != null) return;

  final conversationId =
      (message.data['conversationId'] ?? message.data['chatId'] ?? '')
          .toString()
          .trim();
  if (conversationId.isEmpty) return;

  final title =
      (message.data['senderName'] ?? message.data['title'] ?? 'Noon Chat')
          .toString()
          .trim();
  final body =
      (message.data['textPreview'] ?? message.data['body'] ?? 'New message')
          .toString()
          .trim();

  await NotificationService.showLocalChatNotification(
    conversationId: conversationId,
    title: title.isEmpty ? 'Noon Chat' : title,
    body: body.isEmpty ? 'New message' : body,
    payloadData: message.data,
  );
}

class NotificationService {
  static final ValueNotifier<int> unreadCounter = ValueNotifier<int>(0);
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _androidChannel =
      AndroidNotificationChannel(
        'chat_high',
        'Chat Messages',
        description: 'High priority chat notifications',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );

  static bool _initialized = false;
  static bool _localInitialized = false;
  static StreamSubscription<User?>? _authSub;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _unreadSub;

  static Future<void> registerBackgroundHandler() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _initializeLocalNotifications();
    await _requestPermissions();
    await FcmTokenService.initialize();

    _bindAuth();
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      await FcmTokenService.syncCurrentUserToken();
      _bindUnreadCounter(currentUser.uid);
    }

    FirebaseMessaging.onMessage.listen((message) async {
      await _showForegroundFromRemoteMessage(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _routeFromData(message.data);
    });

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _routeFromData(initialMessage.data);
    }
  }

  static Future<void> _initializeLocalNotifications() async {
    if (_localInitialized) return;
    _localInitialized = true;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onLocalNotificationResponse,
    );

    final androidImpl = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.createNotificationChannel(_androidChannel);
  }

  static Future<void> _requestPermissions() async {
    try {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
    } catch (e) {
      debugPrint('FCM permission request failed: $e');
    }

    final androidImpl = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.requestNotificationsPermission();
  }

  static void _bindAuth() {
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        unreadCounter.value = 0;
        await _unreadSub?.cancel();
        _unreadSub = null;
        return;
      }

      await FcmTokenService.syncCurrentUserToken();
      _bindUnreadCounter(user.uid);
    });
  }

  static void _bindUnreadCounter(String uid) {
    _unreadSub?.cancel();
    _unreadSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
          final data = doc.data() ?? const <String, dynamic>{};
          final total = data['unreadTotal'];
          unreadCounter.value = total is int && total >= 0 ? total : 0;
        });
  }

  static Future<void> _showForegroundFromRemoteMessage(
    RemoteMessage message,
  ) async {
    final conversationId =
        (message.data['conversationId'] ?? message.data['chatId'] ?? '')
            .toString()
            .trim();
    if (conversationId.isEmpty) return;

    final title =
        (message.data['senderName'] ??
                message.notification?.title ??
                message.data['title'] ??
                'Noon Chat')
            .toString()
            .trim();
    final body =
        (message.data['textPreview'] ??
                message.notification?.body ??
                message.data['body'] ??
                'New message')
            .toString()
            .trim();

    await showLocalChatNotification(
      conversationId: conversationId,
      title: title.isEmpty ? 'Noon Chat' : title,
      body: body.isEmpty ? 'New message' : body,
      payloadData: message.data,
    );
  }

  static Future<void> showLocalChatNotification({
    required String conversationId,
    required String title,
    required String body,
    Map<String, dynamic>? payloadData,
  }) async {
    await _initializeLocalNotifications();
    final cleanConversationId = conversationId.trim();
    if (cleanConversationId.isEmpty) return;

    final notificationId = cleanConversationId.hashCode.abs();
    final payloadMap = <String, dynamic>{
      'conversationId': cleanConversationId,
      'chatId': cleanConversationId,
      ...?payloadData,
    };

    final person = Person(name: title);
    final androidDetails = AndroidNotificationDetails(
      _androidChannel.id,
      _androidChannel.name,
      channelDescription: _androidChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      groupKey: 'chat_$cleanConversationId',
      styleInformation: MessagingStyleInformation(
        person,
        conversationTitle: title,
        messages: <Message>[Message(body, DateTime.now(), person)],
      ),
      ticker: 'New message',
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      threadIdentifier: 'chat_$cleanConversationId',
    );

    await _localNotifications.show(
      notificationId,
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(payloadMap),
    );
  }

  static Future<void> _onLocalNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload?.trim() ?? '';
    if (payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        _routeFromData(decoded);
      }
    } catch (_) {}
  }

  static void _routeFromData(Map<String, dynamic> data) {
    final conversationId = (data['conversationId'] ?? data['chatId'] ?? '')
        .toString()
        .trim();
    if (conversationId.isEmpty) return;
    unawaited(_openChatFromNotification(conversationId));
  }

  static Future<void> _openChatFromNotification(String conversationId) async {
    final targetConversationId = conversationId.trim();
    if (targetConversationId.isEmpty) return;

    for (var attempt = 0; attempt < 20; attempt++) {
      final navReady = AppNavigator.navigatorKey.currentState != null;
      final userReady = FirebaseAuth.instance.currentUser != null;
      if (navReady && userReady) {
        await AppNavigator.openChat(targetConversationId);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
