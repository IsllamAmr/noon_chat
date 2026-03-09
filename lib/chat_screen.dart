import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'chat_service.dart';
import 'media_service.dart';
import 'models/conversation_background.dart';
import 'screens/chat_wallpaper_screen.dart';
import 'services/chat_background_service.dart';
import 'services/voice_service.dart';
import 'user_service.dart';
import 'widgets/audio_message_bubble.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/chat_background_layer.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _search = TextEditingController();
  final _picker = ImagePicker();
  final _voiceService = VoiceService();
  final ScrollController _messagesScrollController = ScrollController();
  final ValueNotifier<double> _messageScrollOffset = ValueNotifier<double>(0);
  Timer? _typingDebounce;
  Timer? _searchDebounce;
  late final String _myUid;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _chatStream;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _inboxStream;
  late final ValueNotifier<ConversationBackground> _conversationBackground;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _inboxSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _otherUserSub;
  Map<String, dynamic> _inboxData = const <String, dynamic>{};
  Map<String, dynamic> _otherUserData = const <String, dynamic>{};
  String _observedOtherUid = '';
  int _limit = ChatService.pageSize;
  bool _typingSent = false;
  bool _loadingMedia = false;
  bool _sendingAudio = false;
  bool _searchMode = false;
  String _query = '';
  String _lastIncomingMarked = '';
  String _lastSendText = '';
  DateTime _lastSendAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastReadSyncAt;
  bool _readSyncInFlight = false;
  bool _readOpsDenied = false;
  bool _autoRepairTried = false;
  Map<String, dynamic>? _replyTo;
  bool _repairingChat = false;

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser!.uid;
    _chatStream = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .snapshots();
    _inboxStream = FirebaseFirestore.instance
        .collection('users')
        .doc(_myUid)
        .collection('inbox')
        .doc(widget.chatId)
        .snapshots();
    _conversationBackground = ChatBackgroundService.instance.listenable(
      widget.chatId,
    );
    _messagesScrollController.addListener(_onMessagesScrolled);
    _refreshMessagesStream();
    _bindInboxStream();
    unawaited(_markChatReadBestEffort());
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _searchDebounce?.cancel();
    _controller.dispose();
    _search.dispose();
    unawaited(_voiceService.dispose());
    unawaited(AudioMessageBubble.stopAllPlayback());
    _messagesScrollController.removeListener(_onMessagesScrolled);
    _messagesScrollController.dispose();
    _messageScrollOffset.dispose();
    _inboxSub?.cancel();
    _otherUserSub?.cancel();
    if (_typingSent) {
      ChatService.setTyping(chatId: widget.chatId, isTyping: false);
    }
    super.dispose();
  }

  void _onMessagesScrolled() {
    final offset = _messagesScrollController.hasClients
        ? _messagesScrollController.offset
        : 0.0;
    if ((_messageScrollOffset.value - offset).abs() < 1.2) return;
    _messageScrollOffset.value = offset;
  }

  void _bindInboxStream() {
    _inboxSub?.cancel();
    _inboxSub = _inboxStream.listen(
      (snap) {
        final next = snap.data() ?? const <String, dynamic>{};
        if (mapEquals(_inboxData, next)) return;
        if (!mounted) {
          _inboxData = next;
          return;
        }
        setState(() => _inboxData = next);
      },
      onError: (Object e, StackTrace st) {
        debugPrint('inbox stream error for ${widget.chatId}: $e');
      },
    );
  }

  void _scheduleOtherUserBinding(String otherUid) {
    final cleanUid = otherUid.trim();
    if (_observedOtherUid == cleanUid) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bindOtherUserStream(cleanUid);
    });
  }

  void _bindOtherUserStream(String otherUid) {
    if (_observedOtherUid == otherUid) return;
    _observedOtherUid = otherUid;
    _otherUserSub?.cancel();
    _otherUserSub = null;

    final hadData = _otherUserData.isNotEmpty;
    _otherUserData = const <String, dynamic>{};
    if (hadData && mounted) {
      setState(() {});
    }

    if (otherUid.isEmpty) return;

    _otherUserSub = FirebaseFirestore.instance
        .collection('users')
        .doc(otherUid)
        .snapshots()
        .listen(
          (snap) {
            final next = snap.data() ?? const <String, dynamic>{};
            if (mapEquals(_otherUserData, next)) return;
            if (!mounted) {
              _otherUserData = next;
              return;
            }
            setState(() => _otherUserData = next);
          },
          onError: (Object e, StackTrace st) {
            debugPrint('other user stream error for $otherUid: $e');
          },
        );
  }

  String _sender(Map<String, dynamic> d) =>
      ((d['senderId'] ?? d['senderUid'] ?? '') as String);
  DateTime? _time(Map<String, dynamic> d) {
    final t = d['createdAt'];
    return t is Timestamp ? t.toDate() : null;
  }

  Map<String, dynamic> _asStringMap(Object? value) {
    if (value is! Map) return const <String, dynamic>{};
    return value.map((k, v) => MapEntry(k.toString(), v));
  }

  List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime? _maxTime(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  DateTime? _maxOtherTimestamp(Map<String, dynamic> values) {
    return values.entries
        .where((e) => e.key != _myUid && e.value is Timestamp)
        .map((e) => (e.value as Timestamp).toDate())
        .fold<DateTime?>(null, (p, c) => p == null || c.isAfter(p) ? c : p);
  }

  _ReadAcks _readAcksFromChat(Map<String, dynamic> chat) {
    final seenAt = _asStringMap(chat['seenAt']);
    final deliveredAt = _asStringMap(chat['deliveredAt']);
    return _ReadAcks(
      otherSeen: _maxOtherTimestamp(seenAt),
      otherDelivered: _maxOtherTimestamp(deliveredAt),
    );
  }

  String _formatMessageTime(BuildContext context, DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final time = TimeOfDay.fromDateTime(dt).format(context);
    if (_isSameDay(dt, now)) return time;
    final date = dt.year == now.year
        ? '${dt.day}/${dt.month}'
        : '${dt.day}/${dt.month}/${dt.year}';
    return '$date $time';
  }

  String _formatLastSeen(BuildContext context, Timestamp? lastSeen) {
    if (lastSeen == null) return '';
    final dt = lastSeen.toDate();
    final now = DateTime.now();
    final time = TimeOfDay.fromDateTime(dt).format(context);
    if (_isSameDay(dt, now)) {
      return 'last seen $time';
    }
    final date = dt.year == now.year
        ? '${dt.day}/${dt.month}'
        : '${dt.day}/${dt.month}/${dt.year}';
    return 'last seen $date $time';
  }

  Future<void> _sendText() async {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    final now = DateTime.now();
    if (v == _lastSendText &&
        now.difference(_lastSendAt) < const Duration(milliseconds: 1200)) {
      return;
    }
    _lastSendText = v;
    _lastSendAt = now;
    final replySnapshot = _replyTo;
    _controller.clear();
    if (_replyTo != null && mounted) {
      setState(() => _replyTo = null);
    }
    if (_typingSent) {
      _typingSent = false;
      unawaited(ChatService.setTyping(chatId: widget.chatId, isTyping: false));
    }
    try {
      await ChatService.sendText(
        chatId: widget.chatId,
        text: v,
        replyTo: replySnapshot,
      ).timeout(const Duration(seconds: 12));
    } on TimeoutException {
      _showError(StateError('Send timed out. Check internet and try again.'));
    } on FirebaseException catch (e) {
      if (_isPermissionDeniedError(e)) {
        final repaired = await _repairFromCurrentChat();
        if (repaired) return;
      }
      _showError(e);
    } on StateError catch (e) {
      final msg = e.message.toString().toLowerCase();
      if (msg.contains('chat not found') || msg.contains('participant')) {
        final repaired = await _repairFromCurrentChat();
        if (repaired) return;
      }
      _showError(e);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _sendImageFromSource(ImageSource source) async {
    XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
    } on PlatformException catch (e) {
      _showError(StateError('Cannot open gallery: ${e.message ?? e.code}'));
      return;
    } catch (e) {
      _showError(e);
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _loadingMedia = true);
    try {
      final url = await MediaService.uploadChatImageFile(
        chatId: widget.chatId,
        imagePath: picked.path,
      );
      await ChatService.sendImage(
        chatId: widget.chatId,
        imageUrl: url,
        replyTo: _replyTo,
      );
      if (mounted) {
        setState(() => _replyTo = null);
      }
    } on FirebaseException catch (e) {
      if (_isPermissionDeniedError(e)) {
        final repaired = await _repairFromCurrentChat();
        if (repaired) return;
      }
      _showError(e);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  Future<void> _sendImage() async {
    await _sendImageFromSource(ImageSource.gallery);
  }

  Future<void> _sendImageFromCamera() async {
    await _sendImageFromSource(ImageSource.camera);
  }

  Future<void> _openAttachMenu() async {
    if (_loadingMedia || _sendingAudio) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Gallery'),
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('File'),
                onTap: () => Navigator.pop(context, 'file'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'gallery') await _sendImage();
    if (action == 'file') await _sendFile();
  }

  Future<void> _sendFile() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes =
        f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    if (!mounted) return;
    setState(() => _loadingMedia = true);
    try {
      final url = await MediaService.uploadChatFile(
        chatId: widget.chatId,
        fileName: f.name,
        bytes: bytes,
      );
      await ChatService.sendFile(
        chatId: widget.chatId,
        fileUrl: url,
        fileName: f.name,
        fileSize: f.size,
        replyTo: _replyTo,
      );
      if (mounted) {
        setState(() => _replyTo = null);
      }
    } on FirebaseException catch (e) {
      if (_isPermissionDeniedError(e)) {
        final repaired = await _repairFromCurrentChat();
        if (repaired) return;
      }
      _showError(e);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  Future<bool> _startVoiceRecording() async {
    if (_loadingMedia || _sendingAudio) return false;
    final permission = await _voiceService.requestMicrophonePermission();
    if (!permission.granted) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            permission.permanentlyDenied
                ? 'Microphone permission is permanently denied. Enable it from system settings.'
                : 'Microphone permission denied.',
          ),
        ),
      );
      return false;
    }
    try {
      final started = await _voiceService.startRecording();
      if (started) {
        HapticFeedback.lightImpact();
      }
      return started;
    } catch (e) {
      _showError(e);
      return false;
    }
  }

  Future<void> _cancelVoiceRecording() async {
    try {
      await _voiceService.cancelRecording();
      HapticFeedback.selectionClick();
    } catch (e) {
      _voiceService.setError(e);
      _showError(e);
    }
  }

  Future<void> _lockVoiceRecording() async {
    try {
      _voiceService.lockRecording();
      HapticFeedback.mediumImpact();
    } catch (e) {
      _voiceService.setError(e);
      _showError(e);
    }
  }

  Future<void> _stopAndSendVoiceRecording() async {
    if (_sendingAudio) return;
    VoiceRecordResult? result;
    try {
      result = await _voiceService.stopRecording();
    } catch (e) {
      _voiceService.setError(e);
      _showError(e);
      return;
    }
    if (result == null) return;

    final audioFile = File(result.filePath);

    // WhatsApp-like behavior: ignore extremely short recordings.
    if (result.durationMs < 1000) {
      try {
        if (audioFile.existsSync()) {
          await audioFile.delete();
        }
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Voice message too short')));
      return;
    }

    _voiceService.setUploading(true);
    if (!mounted) {
      _voiceService.setUploading(false);
      return;
    }
    setState(() => _sendingAudio = true);
    try {
      await ChatService.sendAudioMessage(
        conversationId: widget.chatId,
        audioFile: audioFile,
        durationMs: result.durationMs,
        replyTo: _replyTo,
      );
      HapticFeedback.lightImpact();
      if (mounted && _replyTo != null) {
        setState(() => _replyTo = null);
      }
    } on FirebaseException catch (e) {
      if (_isPermissionDeniedError(e)) {
        final repaired = await _repairFromCurrentChat();
        if (repaired) return;
      }
      debugPrint('Voice send Firebase error code=${e.code} message=${e.message}');
      _voiceService.setError(e);
      _showError(e);
    } catch (e) {
      _voiceService.setError(e);
      _showError(e);
    } finally {
      if (audioFile.existsSync()) {
        try {
          await audioFile.delete();
        } catch (_) {}
      }
      _voiceService.setUploading(false);
      if (mounted) {
        setState(() => _sendingAudio = false);
      }
    }
  }

  void _typing(String v) {
    final hasText = v.trim().isNotEmpty;
    if (hasText && !_typingSent) {
      _typingSent = true;
      ChatService.setTyping(chatId: widget.chatId, isTyping: true);
    }
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 900), () {
      if (_typingSent && _controller.text.trim().isEmpty) {
        _typingSent = false;
        ChatService.setTyping(chatId: widget.chatId, isTyping: false);
      }
    });
  }

  void _onMessageSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = value.trim().toLowerCase());
    });
  }

  void _refreshMessagesStream() {
    _messagesStream = ChatService.messagesStream(widget.chatId, limit: _limit);
  }

  void _loadOlder() {
    setState(() {
      _limit += ChatService.pageSize;
      _refreshMessagesStream();
    });
  }

  void _retryMessages() {
    setState(_refreshMessagesStream);
  }

  void _showError(Object e) {
    if (!mounted) return;
    var msg = switch (e) {
      FirebaseException fe => (fe.message ?? fe.code).trim(),
      StateError se => se.message.toString().trim(),
      _ => e.toString().trim(),
    };
    if (_isPermissionDeniedError(e)) {
      msg = 'Chat access changed. Reopen the chat and try again.';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg.isEmpty ? 'Operation failed. Please try again.' : msg,
        ),
      ),
    );
  }

  bool _isPermissionDeniedError(Object e) {
    if (e is! FirebaseException) return false;
    final code = e.code.toLowerCase().trim();
    final msg = (e.message ?? '').toLowerCase().trim();
    return code == 'permission-denied' || msg.contains('permission');
  }

  String _extractOtherUidFromDmId(String chatId) {
    final m = RegExp(r'^dm(?:2|x|u)?_([^_]+)_([^_]+)$').firstMatch(chatId);
    if (m == null) return '';
    final a = (m.group(1) ?? '').trim();
    final b = (m.group(2) ?? '').trim();
    if (a == _myUid) return b;
    if (b == _myUid) return a;
    return '';
  }

  Future<String> _resolveOtherUidForRepair() async {
    final fromId = _extractOtherUidFromDmId(widget.chatId);
    if (fromId.isNotEmpty) return fromId;

    try {
      final chatSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .get();
      if (chatSnap.exists) {
        final participants = _asStringList(chatSnap.data()?['participants']);
        final other = participants.firstWhere(
          (x) => x != _myUid,
          orElse: () => '',
        );
        if (other.isNotEmpty) return other;
      }
    } catch (_) {}

    String title = '';
    try {
      final inboxSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(_myUid)
          .collection('inbox')
          .doc(widget.chatId)
          .get();
      if (inboxSnap.exists) {
        final data = inboxSnap.data() ?? const <String, dynamic>{};
        final peerUid = ((data['peerUid'] ?? '') as String).trim();
        if (peerUid.isNotEmpty && peerUid != _myUid) return peerUid;
        title = ((data['title'] ?? '') as String).trim().toLowerCase();
      }
    } catch (_) {}

    if (title.isNotEmpty) {
      try {
        final usersSnap = await FirebaseFirestore.instance
            .collection('users')
            .where('nameLower', isEqualTo: title)
            .limit(5)
            .get();
        for (final doc in usersSnap.docs) {
          if (doc.id != _myUid) return doc.id;
        }
      } catch (_) {}
    }
    return '';
  }

  Future<bool> _repairFromCurrentChat() async {
    if (_repairingChat) return false;
    final otherUid = await _resolveOtherUidForRepair();
    if (otherUid.isEmpty) return false;
    if (!mounted) return false;

    setState(() => _repairingChat = true);
    try {
      final fixedChatId = await ChatService.getOrCreateDirectChat(
        otherUid: otherUid,
      );
      if (fixedChatId != widget.chatId) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(_myUid)
              .collection('inbox')
              .doc(widget.chatId)
              .delete();
        } catch (_) {}
        if (!mounted) return true;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(chatId: fixedChatId)),
        );
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _repairingChat = false);
    }
  }

  Future<void> _markChatReadBestEffort({bool force = false}) async {
    if (_readOpsDenied && !force) return;
    if (_readSyncInFlight) return;
    final now = DateTime.now();
    if (!force &&
        _lastReadSyncAt != null &&
        now.difference(_lastReadSyncAt!) < const Duration(milliseconds: 700)) {
      return;
    }
    _readSyncInFlight = true;
    try {
      await ChatService.markChatRead(widget.chatId);
      _lastReadSyncAt = DateTime.now();
      _readOpsDenied = false;
    } on FirebaseException catch (e) {
      if (_isPermissionDeniedError(e)) {
        _readOpsDenied = true;
        debugPrint('markChatRead permission denied for ${widget.chatId}');
        unawaited(_autoRepairChatIfNeeded());
      } else {
        debugPrint('markChatRead failed (${e.code}) for ${widget.chatId}');
      }
    } catch (e) {
      debugPrint('markChatRead failed for ${widget.chatId}: $e');
    } finally {
      _readSyncInFlight = false;
    }
  }

  Future<void> _autoRepairChatIfNeeded() async {
    if (_autoRepairTried || !mounted) return;
    _autoRepairTried = true;
    final otherUid = await _resolveOtherUidForRepair();
    if (otherUid.isEmpty) return;
    try {
      final fixedChatId = await ChatService.getOrCreateDirectChat(
        otherUid: otherUid,
      );
      if (!mounted || fixedChatId == widget.chatId) return;
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_myUid)
            .collection('inbox')
            .doc(widget.chatId)
            .delete();
      } catch (_) {}
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: fixedChatId)),
      );
    } catch (_) {}
  }

  Future<void> _repairMissingChatAccess(List<String> participants) async {
    if (_repairingChat) return;
    final otherUid = participants.firstWhere(
      (x) => x != _myUid,
      orElse: () => '',
    );
    if (otherUid.isEmpty) {
      final repaired = await _repairFromCurrentChat();
      if (!repaired) {
        _showError(StateError('Cannot repair this chat.'));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _repairingChat = true);
    try {
      final fixedChatId = await ChatService.getOrCreateDirectChat(
        otherUid: otherUid,
      );
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_myUid)
            .collection('inbox')
            .doc(widget.chatId)
            .delete();
      } catch (_) {}

      if (!mounted) return;
      if (fixedChatId == widget.chatId) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Chat repaired.')));
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: fixedChatId)),
      );
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _repairingChat = false);
    }
  }

  String _callLinkForChat(String chatId) {
    final room = chatId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return 'https://meet.jit.si/noon_chat_$room';
  }

  Future<void> _startCall({required bool video}) async {
    try {
      await ChatService.sendCallInvite(chatId: widget.chatId, video: video);
      final uri = Uri.parse(_callLinkForChat(widget.chatId));
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _setDisappearingTimer(int seconds) async {
    try {
      await ChatService.setDisappearingDuration(
        chatId: widget.chatId,
        seconds: seconds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            seconds <= 0
                ? 'Disappearing messages disabled'
                : 'Messages disappear after ${_durationLabel(seconds)}',
          ),
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _setPinned(bool pinned) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_myUid)
          .collection('inbox')
          .doc(widget.chatId)
          .set({
            'pinned': pinned,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(pinned ? 'Chat pinned' : 'Chat unpinned')),
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openChatWallpaperSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatWallpaperScreen(conversationId: widget.chatId),
      ),
    );
  }

  void _handleBrokenWallpaperPath() {
    final path = (_conversationBackground.value.localPath ?? '').trim();
    if (path.isEmpty) return;
    unawaited(
      ChatBackgroundService.instance.cleanupBrokenPath(
        conversationId: widget.chatId,
        brokenPath: path,
      ),
    );
  }

  String _durationLabel(int seconds) {
    if (seconds >= 7 * 24 * 3600) return '7 days';
    if (seconds >= 24 * 3600) return '24 hours';
    if (seconds >= 3600) return '1 hour';
    return '$seconds sec';
  }

  Future<void> _editMessageDialog({
    required String messageId,
    required String currentText,
  }) async {
    final ctrl = TextEditingController(text: currentText);
    final updated = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          minLines: 1,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null || updated.trim().isEmpty) return;
    try {
      await ChatService.editMessage(
        chatId: widget.chatId,
        messageId: messageId,
        text: updated,
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<String?> _pickForwardTargetChat() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .collection('inbox')
                .orderBy('lastTime', descending: true)
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs
                  .where((d) => d.id != widget.chatId)
                  .toList();
              if (docs.isEmpty) {
                return const Center(child: Text('No chats to forward to'));
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final data = docs[i].data();
                  final title = ((data['title'] ?? 'Chat') as String).trim();
                  final photo = ((data['photo'] ?? '') as String).trim();
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage: photo.isNotEmpty
                          ? NetworkImage(photo)
                          : null,
                      child: photo.isEmpty
                          ? Text(title.isEmpty ? '?' : title[0].toUpperCase())
                          : null,
                    ),
                    title: Text(title.isEmpty ? 'Chat' : title),
                    subtitle: Text(
                      ((data['lastText'] ?? '') as String).trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, docs[i].id),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _forwardMessage(Map<String, dynamic> message) async {
    final toChatId = await _pickForwardTargetChat();
    if (toChatId == null || toChatId.isEmpty) return;
    try {
      await ChatService.forwardMessage(toChatId: toChatId, source: message);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message forwarded')));
    } catch (e) {
      _showError(e);
    }
  }

  String _replyPreview(Map<String, dynamic> data) {
    final deleted = data['deletedForEveryone'] == true;
    if (deleted) return 'Deleted message';

    final type = (data['type'] ?? 'text').toString().trim().toLowerCase();
    final text = (data['text'] ?? '').toString().trim();
    final fileName = (data['fileName'] ?? '').toString().trim();
    final callType = (data['callType'] ?? 'voice').toString().trim();

    switch (type) {
      case 'image':
        return text.isNotEmpty ? text : 'Photo';
      case 'file':
        return fileName.isNotEmpty ? fileName : 'File';
      case 'audio':
        return 'Voice message';
      case 'call':
        return callType == 'video' ? 'Video call' : 'Voice call';
      default:
        return text.isNotEmpty ? text : 'Message';
    }
  }

  void _setReplyToMessage({
    required String messageId,
    required Map<String, dynamic> data,
  }) {
    setState(() {
      _replyTo = {
        'messageId': messageId,
        'type': (data['type'] ?? 'text').toString(),
        'text': _replyPreview(data),
        'fileName': (data['fileName'] ?? '').toString(),
        'senderId': _sender(data),
      };
    });
  }

  bool _canEditMessageNow(Map<String, dynamic> data) {
    final createdAt = _time(data);
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) <= const Duration(minutes: 5);
  }

  Future<void> _openMessageActions(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> d,
  ) async {
    final isMe = _sender(d) == _myUid;
    final type = (d['type'] ?? 'text').toString();
    final deleted = d['deletedForEveryone'] == true;
    final text = (d['text'] ?? '').toString();

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.forward_to_inbox_outlined),
              title: const Text('Forward'),
              onTap: () => Navigator.pop(context, 'forward'),
            ),
            if (isMe && type == 'text' && !deleted && _canEditMessageNow(d))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Delete for me'),
              onTap: () => Navigator.pop(context, 'delete_me'),
            ),
            if (isMe && !deleted)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete for everyone'),
                onTap: () => Navigator.pop(context, 'delete_all'),
              ),
          ],
        ),
      ),
    );

    if (action == null) return;
    if (action == 'reply') {
      _setReplyToMessage(messageId: doc.id, data: d);
      return;
    }
    if (action == 'forward') {
      await _forwardMessage(d);
      return;
    }
    if (action == 'edit') {
      if (!_canEditMessageNow(d)) {
        _showError(StateError('Edit is available only within 5 minutes'));
        return;
      }
      await _editMessageDialog(messageId: doc.id, currentText: text);
      return;
    }
    if (action == 'delete_me') {
      try {
        await ChatService.deleteMessageForMe(
          chatId: widget.chatId,
          messageId: doc.id,
        );
      } catch (e) {
        _showError(e);
      }
      return;
    }
    if (action == 'delete_all') {
      try {
        await ChatService.deleteMessageForEveryone(
          chatId: widget.chatId,
          messageId: doc.id,
        );
      } catch (e) {
        _showError(e);
      }
    }
  }

  Widget _buildChatBody(ColorScheme scheme, _ReadAcks readAcks) {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _messagesStream,
            builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline),
                            const SizedBox(height: 8),
                            const Text('Failed to load messages'),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _retryMessages,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  var docs = snap.data!.docs;
                  if (_query.isNotEmpty) {
                    docs = docs.where((doc) {
                      final d = doc.data();
                      return ((d['text'] ?? '') as String)
                              .toLowerCase()
                              .contains(_query) ||
                          ((d['fileName'] ?? '') as String)
                              .toLowerCase()
                              .contains(_query);
                    }).toList();
                  }
                  final now = DateTime.now();
                  docs = docs.where((doc) {
                    final d = doc.data();
                    final hiddenBy = d['hiddenBy'];
                    if (hiddenBy is List &&
                        hiddenBy.any((v) => v?.toString().trim() == _myUid)) {
                      return false;
                    }
                    final expiresAt = d['expiresAt'];
                    if (expiresAt is Timestamp &&
                        expiresAt.toDate().isBefore(now)) {
                      return false;
                    }
                    return true;
                  }).toList();
                  if (docs.isEmpty) {
                    return const Center(child: Text('No messages yet'));
                  }

                  final latest = docs.first;
                  if (_sender(latest.data()) != _myUid &&
                      latest.id != _lastIncomingMarked) {
                    _lastIncomingMarked = latest.id;
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => unawaited(_markChatReadBestEffort(force: true)),
                    );
                  }
                  DateTime? latestIncomingAt;
                  for (final d in docs) {
                    if (_sender(d.data()) == _myUid) continue;
                    final t = _time(d.data());
                    latestIncomingAt = _maxTime(latestIncomingAt, t);
                  }
                  final inferredSeenAt = _maxTime(
                    readAcks.otherSeen,
                    latestIncomingAt,
                  );
                  final inferredDeliveredAt = _maxTime(
                    readAcks.otherDelivered,
                    latestIncomingAt,
                  );
                  final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.8;

                  return Column(
                    children: [
                      if (docs.length >= _limit)
                        TextButton(
                          onPressed: _loadOlder,
                          child: const Text('Load older'),
                        ),
                      Expanded(
                        child: ListView.builder(
                          controller: _messagesScrollController,
                          reverse: true,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                          cacheExtent: 720,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: docs.length,
                          itemBuilder: (context, i) {
                            final doc = docs[i];
                            final d = doc.data();
                            final isMe = _sender(d) == _myUid;
                            final type = (d['type'] ?? 'text') as String;
                            final dt = _time(d);
                            final seen =
                                isMe &&
                                dt != null &&
                                inferredSeenAt != null &&
                                (inferredSeenAt.isAfter(dt) ||
                                    inferredSeenAt.isAtSameMomentAs(dt));
                            final delivered =
                                isMe &&
                                dt != null &&
                                inferredDeliveredAt != null &&
                                (inferredDeliveredAt.isAfter(dt) ||
                                    inferredDeliveredAt.isAtSameMomentAs(dt));
                            final reactions =
                                (d['reactions'] as Map<String, dynamic>?) ??
                                const <String, dynamic>{};
                            final deletedForEveryone =
                                d['deletedForEveryone'] == true;
                            final edited = d['editedAt'] is Timestamp;
                            final forwarded = d['forwarded'] == true;
                            final callType = (d['callType'] ?? 'voice')
                                .toString();
                            final callLink = (d['callLink'] ?? '').toString();
                            var grouped = const <String, int>{};
                            if (reactions.isNotEmpty) {
                              grouped = <String, int>{};
                              for (final r in reactions.values) {
                                if (r is String && r.isNotEmpty) {
                                  grouped[r] = (grouped[r] ?? 0) + 1;
                                }
                              }
                            }

                            return _SwipeToReplyWrapper(
                              onReply: () {
                                HapticFeedback.lightImpact();
                                _setReplyToMessage(messageId: doc.id, data: d);
                              },
                              child: Align(
                                alignment: isMe
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: GestureDetector(
                                  onLongPress: () =>
                                      _openMessageActions(doc, d),
                                  onDoubleTap: () => _setReplyToMessage(
                                    messageId: doc.id,
                                    data: d,
                                  ),
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth: maxBubbleWidth,
                                    ),
                                    margin: EdgeInsets.fromLTRB(
                                      isMe ? 68 : 10,
                                      6,
                                      isMe ? 10 : 68,
                                      6,
                                    ),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isMe
                                          ? scheme.primaryContainer
                                          : scheme.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isMe
                                          ? CrossAxisAlignment.end
                                          : CrossAxisAlignment.start,
                                      children: [
                                        if (forwarded)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 4,
                                            ),
                                            child: Text(
                                              'Forwarded',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        if (d['replyTo']
                                            is Map<String, dynamic>)
                                          Container(
                                            margin: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: scheme
                                                  .surfaceContainerHighest,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              (((d['replyTo']
                                                          as Map<
                                                            String,
                                                            dynamic
                                                          >)['text'] ??
                                                      (d['replyTo']
                                                          as Map<
                                                            String,
                                                            dynamic
                                                          >)['fileName'] ??
                                                      'Reply')
                                                  as String),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        if (deletedForEveryone)
                                          Text(
                                            'This message was deleted',
                                            style: TextStyle(
                                              fontStyle: FontStyle.italic,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          )
                                        else if (type == 'image' &&
                                            ((d['imageUrl'] ?? '') as String)
                                                .isNotEmpty)
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: Image.network(
                                              (d['imageUrl'] ?? '') as String,
                                              height: 210,
                                              width: 210,
                                              fit: BoxFit.cover,
                                              filterQuality: FilterQuality.low,
                                              cacheWidth: 720,
                                            ),
                                          )
                                        else if (type == 'file')
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.attach_file),
                                              Flexible(
                                                child: Text(
                                                  ((d['fileName'] ?? 'File')
                                                      as String),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          )
                                        else if (type == 'audio')
                                          Builder(
                                            builder: (_) {
                                              final audioUrl =
                                                  (d['audioUrl'] ?? '')
                                                      .toString()
                                                      .trim();
                                              final durationMs =
                                                  d['durationMs'] is int
                                                  ? d['durationMs'] as int
                                                  : 0;
                                              if (audioUrl.isEmpty) {
                                                return const Text(
                                                  'Voice message',
                                                );
                                              }
                                              return AudioMessageBubble(
                                                key: ValueKey(
                                                  'audio-${doc.id}',
                                                ),
                                                messageId: doc.id,
                                                audioUrl: audioUrl,
                                                durationMs: durationMs,
                                                isMe: isMe,
                                              );
                                            },
                                          )
                                        else if (type == 'call')
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                callType == 'video'
                                                    ? Icons.videocam_outlined
                                                    : Icons.call_outlined,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                callType == 'video'
                                                    ? 'Video call'
                                                    : 'Voice call',
                                              ),
                                              const SizedBox(width: 10),
                                              TextButton(
                                                onPressed: callLink.isEmpty
                                                    ? null
                                                    : () => launchUrl(
                                                        Uri.parse(callLink),
                                                        mode: LaunchMode
                                                            .externalApplication,
                                                      ),
                                                child: const Text('Join'),
                                              ),
                                            ],
                                          )
                                        else
                                          Text(((d['text'] ?? '') as String)),
                                        if (grouped.isNotEmpty)
                                          Wrap(
                                            spacing: 6,
                                            children: grouped.entries
                                                .map(
                                                  (e) => Text(
                                                    '${e.key} ${e.value}',
                                                  ),
                                                )
                                                .toList(),
                                          ),
                                        const SizedBox(height: 2),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _formatMessageTime(context, dt),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                            if (edited) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                '(edited)',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                            if (isMe) ...[
                                              const SizedBox(width: 6),
                                              Icon(
                                                seen
                                                    ? Icons.done_all
                                                    : delivered
                                                    ? Icons.done_all
                                                    : Icons.done,
                                                size: 14,
                                                color: seen
                                                    ? scheme.primary
                                                    : scheme.onSurfaceVariant,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
          ),
        if (_replyTo != null)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.reply, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (((_replyTo!['text'] ?? _replyTo!['fileName'] ?? 'Reply')
                        as String)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _replyTo = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: ChatInputBar(
            controller: _controller,
            onChanged: _typing,
            onEmojiPressed: () {},
            onAttachPressed: _openAttachMenu,
            onCameraPressed: _sendImageFromCamera,
            onRecordStart: _startVoiceRecording,
            onRecordLock: _lockVoiceRecording,
            onRecordStop: _stopAndSendVoiceRecording,
            onRecordCancel: _cancelVoiceRecording,
            recordingListenable: _voiceService.composer,
            onSendPressed: _sendText,
            sending: _loadingMedia || _sendingAudio,
            enabled: !_loadingMedia && !_sendingAudio,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _chatStream,
      builder: (context, chatSnap) {
        if (chatSnap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Failed to load chat.\n${chatSnap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final chat = chatSnap.data?.data() ?? const <String, dynamic>{};
        final readAcks = _readAcksFromChat(chat);
        final typing = _asStringMap(chat['typing']);
        final typingNow = typing.entries.any(
          (e) => e.key != _myUid && e.value == true,
        );
        final participants = _asStringList(chat['participants']);
        final disappearingSeconds = (chat['disappearingSeconds'] is int)
            ? (chat['disappearingSeconds'] as int)
            : 0;
        if (chatSnap.hasData && !chatSnap.data!.exists) {
          return Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: const Center(
              child: Text('This chat does not exist anymore.'),
            ),
          );
        }
        if (participants.isNotEmpty && !participants.contains(_myUid)) {
          return Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 30),
                    const SizedBox(height: 10),
                    const Text(
                      'You no longer have access to this chat.\nTap repair to open the correct direct chat.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _repairingChat
                          ? null
                          : () => _repairMissingChatAccess(participants),
                      icon: _repairingChat
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.build_circle_outlined),
                      label: Text(
                        _repairingChat ? 'Repairing...' : 'Repair Chat',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final otherUid = participants.firstWhere(
          (x) => x != _myUid,
          orElse: () => '',
        );
        _scheduleOtherUserBinding(otherUid);
        final title = (_inboxData['title'] ??
                _otherUserData['displayName'] ??
                _otherUserData['name'] ??
                'Chat')
            .toString()
            .trim();
        final photo = (_inboxData['photo'] ??
                _otherUserData['photoUrl'] ??
                _otherUserData['photo'] ??
                '')
            .toString()
            .trim();
        final isPinned = _inboxData['pinned'] == true;
        final online = _otherUserData['online'] == true;
        final lastSeenRaw = _otherUserData['lastSeen'];
        final lastSeen = lastSeenRaw is Timestamp ? lastSeenRaw : null;
        final body = _buildChatBody(scheme, readAcks);

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                Hero(
                  tag: 'chat-avatar-${widget.chatId}',
                  child: CircleAvatar(
                    backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
                    child: photo.isEmpty
                        ? Text(title.isEmpty ? '?' : title[0].toUpperCase())
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title.isEmpty ? 'Chat' : title,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        typingNow
                            ? 'typing...'
                            : online
                            ? 'online'
                            : lastSeen == null
                            ? ''
                            : _formatLastSeen(context, lastSeen),
                        style: TextStyle(
                          fontSize: 11,
                          color: typingNow
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Voice call',
                onPressed: () => _startCall(video: false),
                icon: const Icon(Icons.call_outlined),
              ),
              IconButton(
                tooltip: 'Video call',
                onPressed: () => _startCall(video: true),
                icon: const Icon(Icons.videocam_outlined),
              ),
              IconButton(
                onPressed: () => setState(() => _searchMode = !_searchMode),
                icon: const Icon(Icons.search),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'wallpaper') {
                    await _openChatWallpaperSettings();
                  }
                  if (v == 'pin_toggle') {
                    await _setPinned(!isPinned);
                  }
                  if (v == 'block' && otherUid.isNotEmpty) {
                    await UserService.blockUser(otherUid);
                  }
                  if (v == 'report' && otherUid.isNotEmpty) {
                    await UserService.reportUser(
                      otherUid: otherUid,
                      reason: 'chat',
                      chatId: widget.chatId,
                    );
                  }
                  if (v == 'disappear_off') {
                    await _setDisappearingTimer(0);
                  }
                  if (v == 'disappear_1h') {
                    await _setDisappearingTimer(3600);
                  }
                  if (v == 'disappear_1d') {
                    await _setDisappearingTimer(24 * 3600);
                  }
                  if (v == 'disappear_7d') {
                    await _setDisappearingTimer(7 * 24 * 3600);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'wallpaper',
                    child: Text('Chat Wallpaper'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'pin_toggle',
                    child: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      'Disappearing: ${disappearingSeconds <= 0 ? 'Off' : _durationLabel(disappearingSeconds)}',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'disappear_off',
                    child: Text('Disappearing Off'),
                  ),
                  const PopupMenuItem(
                    value: 'disappear_1h',
                    child: Text('Disappear after 1 hour'),
                  ),
                  const PopupMenuItem(
                    value: 'disappear_1d',
                    child: Text('Disappear after 24 hours'),
                  ),
                  const PopupMenuItem(
                    value: 'disappear_7d',
                    child: Text('Disappear after 7 days'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'block',
                    child: Text('Block'),
                  ),
                  const PopupMenuItem(
                    value: 'report',
                    child: Text('Report'),
                  ),
                ],
              ),
            ],
            bottom: _searchMode
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(54),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: TextField(
                        controller: _search,
                        onChanged: _onMessageSearchChanged,
                        decoration: InputDecoration(
                          hintText: 'Search messages',
                          filled: true,
                          fillColor: scheme.surfaceContainerLow,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              ChatBackgroundLayer(
                backgroundListenable: _conversationBackground,
                scrollOffsetListenable: _messageScrollOffset,
                onMissingFile: _handleBrokenWallpaperPath,
              ),
              body,
            ],
          ),
        );
      },
    );
  }
}

class _SwipeToReplyWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;

  const _SwipeToReplyWrapper({required this.child, required this.onReply});

  @override
  State<_SwipeToReplyWrapper> createState() => _SwipeToReplyWrapperState();
}

class _SwipeToReplyWrapperState extends State<_SwipeToReplyWrapper> {
  double _dragOffset = 0;

  void _reset() {
    if (_dragOffset == 0) return;
    setState(() => _dragOffset = 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) {
        final next = (_dragOffset + details.delta.dx).clamp(0.0, 88.0);
        if (next == _dragOffset) return;
        setState(() => _dragOffset = next);
      },
      onHorizontalDragCancel: _reset,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        final shouldReply = _dragOffset > 56 || velocity > 700;
        _reset();
        if (shouldReply) {
          widget.onReply();
        }
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 18,
            child: Opacity(
              opacity: (_dragOffset / 56).clamp(0.0, 1.0),
              child: Icon(
                Icons.reply_rounded,
                color: scheme.primary.withValues(alpha: 0.9),
                size: 20,
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dragOffset, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _ReadAcks {
  final DateTime? otherSeen;
  final DateTime? otherDelivered;
  const _ReadAcks({this.otherSeen, this.otherDelivered});

  bool sameAs(_ReadAcks other) {
    return _sameMoment(otherSeen, other.otherSeen) &&
        _sameMoment(otherDelivered, other.otherDelivered);
  }

  bool _sameMoment(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.millisecondsSinceEpoch == b.millisecondsSinceEpoch;
  }
}
