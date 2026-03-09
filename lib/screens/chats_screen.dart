import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../models/story.dart';
import '../services/chat_service.dart';
import '../services/user_service.dart';
import '../widgets/brand_header_non.dart';
import '../widgets/chat_search_bar.dart';
import '../widgets/chat_tile.dart';
import '../widgets/stories_row.dart' as stories_ui;
import 'add_story_screen.dart';
import 'chat_screen.dart';
import 'profile_edit_screen.dart';
import 'settings_screen.dart';
import 'story_viewer_screen.dart';
import 'user_search_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _chatScrollController = ScrollController();
  final ValueNotifier<bool> _showArchivedControl = ValueNotifier<bool>(true);
  Timer? _searchDebounce;

  String _query = '';
  bool _openingChat = false;
  bool _showArchivedOnly = false;
  double _lastScrollOffset = 0;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _inboxStream;

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _inboxStream = _inboxQuery().snapshots();
    _chatScrollController.addListener(_onChatScroll);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _chatScrollController.removeListener(_onChatScroll);
    _chatScrollController.dispose();
    _showArchivedControl.dispose();
    super.dispose();
  }

  Query<Map<String, dynamic>> _inboxQuery() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(_myUid)
        .collection('inbox')
        .orderBy('lastTime', descending: true);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = value.trim().toLowerCase());
    });
  }

  void _setArchivedControlVisible(bool visible) {
    if (_showArchivedControl.value == visible) return;
    _showArchivedControl.value = visible;
  }

  void _onChatScroll() {
    if (!_chatScrollController.hasClients) return;
    final currentOffset = _chatScrollController.offset < 0
        ? 0.0
        : _chatScrollController.offset;
    final delta = currentOffset - _lastScrollOffset;
    final nearTop = currentOffset <= 20;

    if (nearTop) {
      _setArchivedControlVisible(true);
    } else if (delta > 6) {
      _setArchivedControlVisible(false);
    } else if (delta < -6) {
      _setArchivedControlVisible(true);
    }
    _lastScrollOffset = currentOffset;
  }

  Future<void> _toggleArchivedView() async {
    setState(() => _showArchivedOnly = !_showArchivedOnly);
    _setArchivedControlVisible(true);
    if (_chatScrollController.hasClients) {
      unawaited(
        _chatScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatInboxTime(BuildContext context, Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate();
    final now = DateTime.now();
    if (_isSameDay(dt, now)) {
      return TimeOfDay.fromDateTime(dt).format(context);
    }
    if (_isSameDay(dt, now.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    }
    return dt.year == now.year
        ? '${dt.day}/${dt.month}'
        : '${dt.day}/${dt.month}/${dt.year}';
  }

  int _readInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  List<InboxConversation> _toInboxConversations(
    BuildContext context,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    required bool archivedOnly,
  }) {
    final items = <InboxConversation>[];
    for (final doc in docs) {
      final data = doc.data();
      final isArchived = data['archived'] == true;
      if (isArchived != archivedOnly) continue;

      final title = ((data['title'] ?? 'Chat') as String).trim();
      final lastText = ((data['lastText'] ?? '') as String).trim();
      final peerUid = ((data['peerUid'] ?? '') as String).trim();
      final photo = ((data['photo'] ?? '') as String).trim();
      final pinned = data['pinned'] == true;
      final unread = _readInt(data['unread']).clamp(0, 9999);
      final senderId = ((data['lastSenderId'] ?? '') as String).trim();
      final lastSeen =
          data['lastMessageSeen'] == true ||
          (senderId == _myUid && unread == 0 && lastText.isNotEmpty);
      final searchText = '$title $lastText'.toLowerCase();
      if (_query.isNotEmpty && !searchText.contains(_query)) {
        continue;
      }

      items.add(
        InboxConversation(
          chatId: doc.id,
          peerUid: peerUid,
          pinned: pinned,
          conversation: Conversation(
            id: doc.id,
            name: title.isEmpty ? 'Chat' : title,
            lastMessage: lastText.isEmpty ? 'No messages yet' : lastText,
            time: _formatInboxTime(context, data['lastTime'] as Timestamp?),
            avatarUrl: photo.isEmpty ? null : photo,
            unreadCount: unread,
            lastMessageSeen: lastSeen,
            isArchived: isArchived,
          ),
        ),
      );
    }

    items.sort((a, b) {
      if (a.pinned == b.pinned) return 0;
      return a.pinned ? -1 : 1;
    });
    return items;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  DocumentReference<Map<String, dynamic>> _inboxDocRef(String chatId) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(_myUid)
        .collection('inbox')
        .doc(chatId);
  }

  Future<void> _setPinned(InboxConversation item, bool pinned) async {
    try {
      await _inboxDocRef(item.chatId).set({
        'pinned': pinned,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _showMessage(pinned ? 'Chat pinned' : 'Chat unpinned');
    } catch (_) {
      _showMessage('Failed to update pin');
    }
  }

  Future<void> _setArchived(InboxConversation item, bool archived) async {
    try {
      await _inboxDocRef(item.chatId).set({
        'archived': archived,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _showMessage(archived ? 'Chat archived' : 'Chat unarchived');
    } catch (_) {
      _showMessage('Failed to update archive');
    }
  }

  Future<void> _deleteChat(InboxConversation item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            'This removes "${item.conversation.name}" from your chats list.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    try {
      await _inboxDocRef(item.chatId).delete();
      _showMessage('Chat deleted');
    } catch (_) {
      _showMessage('Failed to delete chat');
    }
  }

  Future<void> _onConversationLongPress(InboxConversation item) async {
    if (_openingChat) return;

    final isArchived = item.conversation.isArchived;
    final isPinned = item.pinned;

    final action = await showModalBottomSheet<_ConversationAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                ),
                title: Text(isPinned ? 'Unpin' : 'Pin'),
                onTap: () {
                  Navigator.of(context).pop(
                    isPinned
                        ? _ConversationAction.unpin
                        : _ConversationAction.pin,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                title: Text(isArchived ? 'Unarchive' : 'Archive'),
                onTap: () {
                  Navigator.of(context).pop(
                    isArchived
                        ? _ConversationAction.unarchive
                        : _ConversationAction.archive,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete chat',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () =>
                    Navigator.of(context).pop(_ConversationAction.delete),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    switch (action) {
      case _ConversationAction.pin:
        await _setPinned(item, true);
        break;
      case _ConversationAction.unpin:
        await _setPinned(item, false);
        break;
      case _ConversationAction.archive:
        await _setArchived(item, true);
        break;
      case _ConversationAction.unarchive:
        await _setArchived(item, false);
        break;
      case _ConversationAction.delete:
        await _deleteChat(item);
        break;
      case null:
        break;
    }
  }

  Future<void> _openChat(InboxConversation item) async {
    if (_openingChat) return;
    setState(() => _openingChat = true);
    try {
      var targetChatId = item.chatId;
      final chatSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(item.chatId)
          .get();

      if (!chatSnap.exists && item.peerUid.isNotEmpty) {
        targetChatId = await ChatService.getOrCreateDirectChat(
          otherUid: item.peerUid,
        ).timeout(const Duration(seconds: 12));
      }

      if (!mounted) return;
      final peer = ChatOtherUser(
        uid: item.peerUid,
        name: item.conversation.name,
        avatarUrl: item.conversation.avatarUrl,
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(conversationId: targetChatId, otherUser: peer),
        ),
      );
    } on TimeoutException {
      _showMessage('Opening chat timed out. Check internet and try again.');
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied' && item.peerUid.isNotEmpty) {
        try {
          final repaired = await ChatService.getOrCreateDirectChat(
            otherUid: item.peerUid,
          );
          if (!mounted) return;
          final peer = ChatOtherUser(
            uid: item.peerUid,
            name: item.conversation.name,
            avatarUrl: item.conversation.avatarUrl,
          );
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  ChatScreen(conversationId: repaired, otherUser: peer),
            ),
          );
          return;
        } catch (_) {}
      }
      _showMessage('Failed to open chat.');
    } catch (_) {
      _showMessage('Failed to open chat.');
    } finally {
      if (mounted) {
        setState(() => _openingChat = false);
      } else {
        _openingChat = false;
      }
    }
  }

  Future<void> _startNewChat() async {
    final otherUid = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _PeopleSearchSheet(),
    );
    if (!mounted || otherUid == null || otherUid.isEmpty) return;

    try {
      final chatId = await ChatService.getOrCreateDirectChat(
        otherUid: otherUid,
      ).timeout(const Duration(seconds: 12));
      final otherSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(otherUid)
          .get();
      final otherData = otherSnap.data() ?? const <String, dynamic>{};
      final otherUser = ChatOtherUser(
        uid: otherUid,
        name: ((otherData['name'] ?? 'Noon User') as String).trim(),
        avatarUrl: ((otherData['photo'] ?? '') as String).trim(),
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(conversationId: chatId, otherUser: otherUser),
        ),
      );
    } on TimeoutException {
      _showMessage('Creating chat timed out. Check internet and try again.');
    } catch (_) {
      _showMessage('Failed to create chat.');
    }
  }

  Future<void> _openProfile() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
  }

  Future<void> _openUserSearch() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const UserSearchScreen()));
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  Future<void> _openAddStory() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddStoryScreen()));
  }

  Future<void> _openStoryViewer(List<Story> stories, int initialIndex) async {
    if (stories.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            StoryViewerScreen(stories: stories, initialIndex: initialIndex),
      ),
    );
  }

  Future<void> _logout() async {
    try {
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      _showMessage('Failed to logout');
    }
  }

  Future<void> _handleMenuSelection(String value) async {
    switch (value) {
      case 'settings':
        await _openSettings();
        break;
      case 'logout':
        await _logout();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width > 720 ? 24.0 : 16.0;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 74,
        titleSpacing: 16,
        title: const BrandHeaderNON(
          variant: BrandHeaderNONVariant.gradient,
          brandShort: 'NON',
          brandFull: 'Noon Chat',
          shortFontSize: 22,
          fullFontSize: 12,
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: _openUserSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: _openProfile,
            icon: const Icon(Icons.account_circle_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: _handleMenuSelection,
            itemBuilder: (context) => const [
              PopupMenuItem<String>(value: 'settings', child: Text('Settings')),
              PopupMenuItem<String>(value: 'logout', child: Text('Logout')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 8),
                  child: ChatSearchBar(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onSearchChanged,
                    onFilterTap: () => _showMessage('Filter UI placeholder'),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 6),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _showArchivedControl,
                    builder: (context, visible, _) {
                      return _ArchivedControlAnimated(
                        visible: visible,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ArchivedControl(
                            isActive: _showArchivedOnly,
                            onTap: _toggleArchivedView,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _inboxStream,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              'Failed to load chats.\n${snap.error}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final docs = snap.data!.docs;
                      final chats = _toInboxConversations(
                        context,
                        docs,
                        archivedOnly: false,
                      );
                      final archived = _toInboxConversations(
                        context,
                        docs,
                        archivedOnly: true,
                      );
                      final visibleConversations = _showArchivedOnly
                          ? archived
                          : chats;

                      return Column(
                        children: [
                          stories_ui.StoriesRow(
                            padding: EdgeInsets.fromLTRB(
                              horizontal,
                              0,
                              horizontal,
                              6,
                            ),
                            onAddStoryTap: _openAddStory,
                            onOpenStories: _openStoryViewer,
                          ),
                          Expanded(
                            child: ChatList(
                              scrollController: _chatScrollController,
                              conversations: visibleConversations,
                              onTapConversation: _openChat,
                              onLongPressConversation: _onConversationLongPress,
                              onNewChat: _startNewChat,
                              horizontalPadding: horizontal,
                              openingChat: _openingChat,
                              emptyTitle: _showArchivedOnly
                                  ? 'No archived chats'
                                  : 'No conversations yet',
                              emptySubtitle: _showArchivedOnly
                                  ? 'Long press a chat and archive it'
                                  : 'Start a new chat',
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startNewChat,
        child: const Icon(Icons.add_comment_rounded),
      ),
    );
  }
}

class _ArchivedControlAnimated extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _ArchivedControlAnimated({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
      height: visible ? 34 : 0,
      child: ClipRect(
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            opacity: visible ? 1 : 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 210),
              curve: Curves.easeOutCubic,
              offset: visible ? Offset.zero : const Offset(0, -0.45),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class ArchivedControl extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const ArchivedControl({
    super.key,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark ? const Color(0xFF0F172A) : scheme.surface;
    final activeBg = isDark
        ? const Color(0xFF141D38)
        : scheme.primaryContainer.withValues(alpha: 0.5);
    final baseBorder = isDark ? const Color(0xFF1E293B) : scheme.outlineVariant;
    final activeBorder = isDark ? const Color(0xFF6366F1) : scheme.primary;
    final textColor = isActive ? activeBorder : scheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isActive ? activeBg : baseBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? activeBorder : baseBorder,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isActive ? Icons.arrow_back_rounded : Icons.archive_outlined,
                size: 16,
                color: textColor,
              ),
              const SizedBox(width: 7),
              Text(
                isActive ? 'Back to chats' : 'Archived',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatList extends StatelessWidget {
  final ScrollController scrollController;
  final List<InboxConversation> conversations;
  final ValueChanged<InboxConversation> onTapConversation;
  final ValueChanged<InboxConversation> onLongPressConversation;
  final VoidCallback onNewChat;
  final double horizontalPadding;
  final bool openingChat;
  final String emptyTitle;
  final String emptySubtitle;

  const ChatList({
    super.key,
    required this.scrollController,
    required this.conversations,
    required this.onTapConversation,
    required this.onLongPressConversation,
    required this.onNewChat,
    required this.horizontalPadding,
    required this.openingChat,
    required this.emptyTitle,
    required this.emptySubtitle,
  });

  @override
  Widget build(BuildContext context) {
    if (conversations.isEmpty) {
      return _EmptyState(
        onNewChat: onNewChat,
        title: emptyTitle,
        subtitle: emptySubtitle,
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 96),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final item = conversations[index];
        return Padding(
          key: ValueKey(item.chatId),
          padding: const EdgeInsets.only(bottom: 10),
          child: ChatTile(
            conversation: item.conversation,
            animationIndex: index,
            onTap: openingChat ? null : () => onTapConversation(item),
            onLongPress: openingChat
                ? null
                : () => onLongPressConversation(item),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onNewChat;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.onNewChat,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: scheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onNewChat,
              icon: const Icon(Icons.add_comment_rounded),
              label: const Text('New chat'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeopleSearchSheet extends StatefulWidget {
  const _PeopleSearchSheet();

  @override
  State<_PeopleSearchSheet> createState() => _PeopleSearchSheetState();
}

class _PeopleSearchSheetState extends State<_PeopleSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final meUid = FirebaseAuth.instance.currentUser!.uid;
    final query = UserService.peopleSearchQuery(_query, limit: 30);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search by name',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: query.snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const Center(child: Text('Failed to load users'));
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs
                      .where((d) => d.id != meUid)
                      .toList();
                  if (docs.isEmpty) {
                    return const Center(child: Text('No users found'));
                  }

                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final data = docs[index].data();
                      final name = ((data['name'] ?? '') as String).trim();
                      final photo = ((data['photo'] ?? '') as String).trim();
                      final email = ((data['email'] ?? '') as String).trim();
                      final status = ((data['status'] ?? '') as String).trim();
                      final title = name.isEmpty ? 'Noon User' : name;
                      final subtitle = status.isNotEmpty
                          ? status
                          : (email.isNotEmpty ? email : 'Start a chat');

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundImage: photo.isNotEmpty
                              ? NetworkImage(photo)
                              : null,
                          child: photo.isEmpty
                              ? Text(
                                  title.substring(0, 1).toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(title),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chat_bubble_outline_rounded),
                        onTap: () => Navigator.pop(context, docs[index].id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InboxConversation {
  final String chatId;
  final String peerUid;
  final bool pinned;
  final Conversation conversation;

  const InboxConversation({
    required this.chatId,
    required this.peerUid,
    required this.pinned,
    required this.conversation,
  });
}

enum _ConversationAction { pin, unpin, archive, unarchive, delete }
