import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'app_theme.dart';
import 'chat_service.dart';
import 'chat_screen.dart';
import 'edit_profile.dart';
import 'invite_service.dart';
import 'notification_service.dart';
import 'qr_scan_screen.dart';
import 'stories_screen.dart';
import 'user_service.dart';

class ChatsHome extends StatefulWidget {
  const ChatsHome({super.key});

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  final u = FirebaseAuth.instance.currentUser!;
  final _search = TextEditingController();
  Timer? _searchDebounce;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _inboxStream;
  String _query = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _inboxStream = inboxQuery().snapshots();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Query<Map<String, dynamic>> inboxQuery() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
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

  Future<void> createInviteAndShow() async {
    setState(() => busy = true);
    try {
      final res = await InviteService.createInvite();
      final inviteId = (res['code'] ?? '').toUpperCase();
      final link = (res['link'] ?? InviteService.buildInviteLink(inviteId))
          .trim();
      if (!mounted) return;
      showInviteSheet(link: link);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> joinWithInput(String input) async {
    final inviteId = InviteService.extractInviteId(input);
    if (inviteId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid invite link')));
      return;
    }
    setState(() => busy = true);
    try {
      final chatId = await InviteService.acceptInvite(inviteId);
      if (!mounted) return;
      if (chatId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid or used invite link')),
        );
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
      );
    } catch (e) {
      debugPrint('Join with link failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to join invite link')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _scanQrAndJoin() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (raw == null || raw.trim().isEmpty) return;
    await joinWithInput(raw);
  }

  Future<void> _openPeopleSearch() async {
    final otherUid = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _PeopleSearchSheet(),
    );
    if (!mounted || otherUid == null || otherUid.isEmpty) return;
    setState(() => busy = true);
    try {
      final chatId = await ChatService.getOrCreateDirectChat(
        otherUid: otherUid,
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Opening chat timed out. Check internet.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to open chat. Try again.')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _changeMyName() async {
    final currentName = ((FirebaseAuth.instance.currentUser?.displayName ?? ''))
        .trim();
    final ctrl = TextEditingController(text: currentName);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change your name'),
        content: TextField(
          controller: ctrl,
          textInputAction: TextInputAction.done,
          maxLength: 50,
          decoration: const InputDecoration(
            hintText: 'Type your name',
            border: OutlineInputBorder(),
          ),
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
    if (value == null || value.isEmpty) return;
    await UserService.updateMyProfile(name: value);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Name updated')));
  }

  void openJoinDialog() {
    final codeCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Join with invite link'),
        content: TextField(
          controller: codeCtrl,
          decoration: const InputDecoration(
            hintText: 'Paste invite link',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _scanQrAndJoin();
            },
            child: const Text('Scan QR'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = codeCtrl.text;
              Navigator.pop(context);
              joinWithInput(v);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void showInviteSheet({required String link}) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Invite / QR',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              SelectableText(
                link,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(data: link, size: 200),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: link));
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite link copied')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy Link'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Share.share('Noon Chat invite\n$link'),
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: ValueListenableBuilder<int>(
            valueListenable: NotificationService.unreadCounter,
            builder: (context, unread, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Noon Chat'),
                  if (unread > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        unread.toString(),
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          actions: [
            IconButton(
              tooltip: 'Stories',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StoriesScreen()),
                );
              },
              icon: const Icon(Icons.auto_stories_outlined),
            ),
            IconButton(
              tooltip: 'Find people',
              onPressed: busy ? null : _openPeopleSearch,
              icon: const Icon(Icons.person_search_rounded),
            ),
            IconButton(
              tooltip: 'Scan QR',
              onPressed: busy ? null : _scanQrAndJoin,
              icon: const Icon(Icons.qr_code_scanner),
            ),
            IconButton(
              tooltip: 'Join by link',
              onPressed: busy ? null : openJoinDialog,
              icon: const Icon(Icons.link_rounded),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'profile') {
                  if (!mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EditProfileScreen(),
                    ),
                  );
                  return;
                }
                if (v == 'change_name') {
                  await _changeMyName();
                  return;
                }
                if (v == 'logout') {
                  await FirebaseAuth.instance.signOut();
                } else if (v == 'invite') {
                  await createInviteAndShow();
                } else if (v == 'join') {
                  openJoinDialog();
                } else if (v == 'find_people') {
                  await _openPeopleSearch();
                } else if (v == 'theme') {
                  AppThemeController.toggleDarkLight();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'change_name', child: Text('Change name')),
                PopupMenuItem(value: 'profile', child: Text('Edit profile')),
                PopupMenuItem(value: 'theme', child: Text('Toggle dark/light')),
                PopupMenuItem(value: 'invite', child: Text('Invite / QR')),
                PopupMenuItem(value: 'join', child: Text('Join with link')),
                PopupMenuItem(value: 'find_people', child: Text('Find people')),
                PopupMenuItem(value: 'logout', child: Text('Logout')),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(98),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search chats',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: scheme.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabs: [
                    Tab(text: 'Chats'),
                    Tab(text: 'Archived'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [scheme.surface, scheme.surfaceContainerLowest],
            ),
          ),
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _inboxStream,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 30),
                        const SizedBox(height: 10),
                        Text(
                          'Failed to load chats.\n${snap.error}',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              return TabBarView(
                children: [
                  _InboxList(
                    docs: docs,
                    archivedOnly: false,
                    queryText: _query,
                  ),
                  _InboxList(docs: docs, archivedOnly: true, queryText: _query),
                ],
              );
            },
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: busy ? null : _openPeopleSearch,
          icon: const Icon(Icons.add_comment_outlined),
          label: const Text('New Chat'),
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
  final _ctrl = TextEditingController();
  Timer? _queryDebounce;
  String _query = '';

  @override
  void dispose() {
    _queryDebounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _selectUser(String otherUid) {
    Navigator.pop(context, otherUid);
  }

  void _onQueryChanged(String value) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 220), () {
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
              controller: _ctrl,
              autofocus: true,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search by name',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
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
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final doc = docs[i];
                      final data = doc.data();
                      final name = ((data['name'] ?? '') as String).trim();
                      final photo = ((data['photo'] ?? '') as String).trim();
                      final status = ((data['status'] ?? '') as String).trim();
                      final email = ((data['email'] ?? '') as String).trim();
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
                                  title[0].toUpperCase(),
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
                        onTap: () => _selectUser(doc.id),
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

class _InboxList extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final bool archivedOnly;
  final String queryText;
  const _InboxList({
    required this.docs,
    this.archivedOnly = false,
    this.queryText = '',
  });

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  String _extractOtherUidFromDmId(String chatId, String myUid) {
    final m = RegExp(r'^dm(?:2|x|u)?_([^_]+)_([^_]+)$').firstMatch(chatId);
    if (m == null) return '';
    final a = (m.group(1) ?? '').trim();
    final b = (m.group(2) ?? '').trim();
    if (a == myUid) return b;
    if (b == myUid) return a;
    return '';
  }

  Future<void> _openChat(
    BuildContext context,
    String chatId,
    Map<String, dynamic> inboxData,
  ) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    String targetChatId = chatId;
    final inboxPeerUid = ((inboxData['peerUid'] ?? '') as String).trim();
    final inboxTitle = ((inboxData['title'] ?? '') as String)
        .trim()
        .toLowerCase();

    try {
      final chatSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .get();
      if (!chatSnap.exists) {
        if (inboxPeerUid.isNotEmpty && inboxPeerUid != uid) {
          targetChatId = await ChatService.getOrCreateDirectChat(
            otherUid: inboxPeerUid,
          );
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This chat is no longer available. Start a new chat.',
                ),
              ),
            );
          }
          return;
        }
      } else {
        final participants = _asStringList(chatSnap.data()?['participants']);
        if (!participants.contains(uid)) {
          final otherUid = participants.firstWhere(
            (id) => id != uid,
            orElse: () => '',
          );
          final fallbackUid = otherUid.isNotEmpty ? otherUid : inboxPeerUid;
          if (fallbackUid.isNotEmpty && fallbackUid != uid) {
            targetChatId = await ChatService.getOrCreateDirectChat(
              otherUid: fallbackUid,
            );
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Cannot open this chat. Start a new chat instead.',
                  ),
                ),
              );
            }
            return;
          }
        } else if (inboxPeerUid.isNotEmpty && inboxPeerUid != uid) {
          final peerMissing = !participants.contains(inboxPeerUid);
          final tooSmall = participants.length < 2;
          if (peerMissing || tooSmall) {
            targetChatId = await ChatService.getOrCreateDirectChat(
              otherUid: inboxPeerUid,
            );
          }
        }
      }
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        var otherUid = _extractOtherUidFromDmId(chatId, uid);
        if (otherUid.isEmpty &&
            inboxPeerUid.isNotEmpty &&
            inboxPeerUid != uid) {
          otherUid = inboxPeerUid;
        }
        if (otherUid.isEmpty && inboxTitle.isNotEmpty) {
          try {
            final usersSnap = await FirebaseFirestore.instance
                .collection('users')
                .where('nameLower', isEqualTo: inboxTitle)
                .limit(3)
                .get();
            for (final doc in usersSnap.docs) {
              if (doc.id != uid) {
                otherUid = doc.id;
                break;
              }
            }
          } catch (_) {}
        }
        if (otherUid.isNotEmpty) {
          try {
            targetChatId = await ChatService.getOrCreateDirectChat(
              otherUid: otherUid,
            );
          } catch (_) {}
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Cannot open this chat. Start a new chat instead.',
                ),
              ),
            );
          }
          return;
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.message ?? e.code)));
        }
        return;
      }
    }

    if (targetChatId != chatId) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('inbox')
            .doc(chatId)
            .delete();
      } catch (_) {}
    }
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: targetChatId)),
    );
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

  Future<void> _action(
    BuildContext context,
    String chatId,
    String action,
  ) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    if (action == 'delete') {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inbox')
          .doc(chatId)
          .delete();
      return;
    }
    if (action == 'pin') {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inbox')
          .doc(chatId)
          .set({'pinned': true}, SetOptions(merge: true));
      return;
    }
    if (action == 'unpin') {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inbox')
          .doc(chatId)
          .set({'pinned': false}, SetOptions(merge: true));
      return;
    }
    if (action == 'archive') {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inbox')
          .doc(chatId)
          .set({'archived': true}, SetOptions(merge: true));
      return;
    }
    if (action == 'unarchive') {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inbox')
          .doc(chatId)
          .set({'archived': false}, SetOptions(merge: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var filteredDocs = docs
        .where((d) => ((d.data()['archived'] ?? false) as bool) == archivedOnly)
        .toList();
    filteredDocs.sort((a, b) {
      final ap = (a.data()['pinned'] ?? false) as bool;
      final bp = (b.data()['pinned'] ?? false) as bool;
      if (ap == bp) return 0;
      return ap ? -1 : 1;
    });
    if (queryText.isNotEmpty) {
      filteredDocs = filteredDocs.where((d) {
        final m = d.data();
        final t = ((m['title'] ?? '') as String).toLowerCase();
        final l = ((m['lastText'] ?? '') as String).toLowerCase();
        return t.contains(queryText) || l.contains(queryText);
      }).toList();
    }
    if (filteredDocs.isEmpty) return const Center(child: Text('No chats'));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      itemCount: filteredDocs.length,
      itemBuilder: (context, i) {
        final d = filteredDocs[i].data();
        final chatId = filteredDocs[i].id;
        final title = ((d['title'] ?? 'Chat') as String).trim();
        final last = (d['lastText'] ?? '') as String;
        final unread = (d['unread'] ?? 0) as int;
        final ts = d['lastTime'] as Timestamp?;
        final photo = ((d['photo'] ?? '') as String).trim();
        final pinned = (d['pinned'] ?? false) as bool;
        final timeText = _formatInboxTime(context, ts);

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: scheme.surfaceContainerLow,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
              child: photo.isEmpty
                  ? Text(title.isEmpty ? '?' : title[0].toUpperCase())
                  : null,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    title.isEmpty ? 'Chat' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (pinned) const Icon(Icons.push_pin, size: 16),
              ],
            ),
            subtitle: Text(
              last.isEmpty ? 'No messages yet' : last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(timeText, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      unread.toString(),
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            onTap: () async => _openChat(context, chatId, d),
            onLongPress: () async {
              final v = await showModalBottomSheet<String>(
                context: context,
                showDragHandle: true,
                builder: (_) => SafeArea(
                  child: Wrap(
                    children: [
                      ListTile(
                        leading: Icon(
                          pinned ? Icons.push_pin_outlined : Icons.push_pin,
                        ),
                        title: Text(pinned ? 'Unpin' : 'Pin'),
                        onTap: () =>
                            Navigator.pop(context, pinned ? 'unpin' : 'pin'),
                      ),
                      ListTile(
                        leading: Icon(
                          archivedOnly
                              ? Icons.unarchive_outlined
                              : Icons.archive_outlined,
                        ),
                        title: Text(archivedOnly ? 'Unarchive' : 'Archive'),
                        onTap: () => Navigator.pop(
                          context,
                          archivedOnly ? 'unarchive' : 'archive',
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: const Text('Delete'),
                        onTap: () => Navigator.pop(context, 'delete'),
                      ),
                    ],
                  ),
                ),
              );
              if (v != null) {
                if (!context.mounted) return;
                await _action(context, chatId, v);
              }
            },
          ),
        );
      },
    );
  }
}
