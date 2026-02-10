import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'invite_service.dart';
import 'chat_screen.dart';

class ChatsHome extends StatefulWidget {
  const ChatsHome({super.key});

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  final u = FirebaseAuth.instance.currentUser!;
  bool busy = false;

  Query<Map<String, dynamic>> inboxQuery() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .collection('inbox')
        .orderBy('lastTime', descending: true);
  }

  Future<void> createInviteAndShow() async {
    setState(() => busy = true);
    try {
      final res = await InviteService.createInvite();
      final code = (res['code'] ?? '').toUpperCase();
      if (!mounted) return;
      showInviteSheet(code);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> joinWithCode(String code) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) return;

    setState(() => busy = true);
    try {
      final chatId = await InviteService.acceptInvite(clean);

      if (!mounted) return;

      if (chatId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("الكود غير صحيح أو مستخدم")),
        );
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void openJoinDialog() {
    final codeCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Join with code"),
        content: TextField(
          controller: codeCtrl,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: "مثال: VCQN8J9S",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    final v = codeCtrl.text;
                    Navigator.pop(context);
                    joinWithCode(v);
                  },
            child: const Text("Join"),
          ),
        ],
      ),
    );
  }

  void showInviteSheet(String code) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Invite / QR",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                Text(
                  code,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(data: code, size: 200),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: code));
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Copied ✅")),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text("Copy"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Share.share("Noon Chat\nInvite Code: $code");
                        },
                        icon: const Icon(Icons.share),
                        label: const Text("Share"),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final inboxRef = inboxQuery();

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Noon Chat'),
          actions: [
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.camera_alt_outlined),
            ),
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.search),
            ),
            PopupMenuButton(
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'invite', child: Text('Invite / QR')),
                const PopupMenuItem(value: 'join', child: Text('Join with code')),
                const PopupMenuItem(value: 'logout', child: Text('Logout')),
              ],
              onSelected: (v) async {
                if (v == 'logout') {
                  await FirebaseAuth.instance.signOut();
                } else if (v == 'invite') {
                  if (!busy) await createInviteAndShow();
                } else if (v == 'join') {
                  if (!busy) openJoinDialog();
                }
              },
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'All'),
              Tab(text: 'Unread'),
              Tab(text: 'Personal'),
              Tab(text: 'Business'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _InboxList(query: inboxRef),
            _InboxList(query: inboxRef.where('unread', isGreaterThan: 0)),
            _InboxList(query: inboxRef.where('type', isEqualTo: 'personal')),
            _InboxList(query: inboxRef.where('type', isEqualTo: 'business')),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: busy ? null : createInviteAndShow,
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chat),
        ),
      ),
    );
  }
}

class _InboxList extends StatelessWidget {
  final Query<Map<String, dynamic>> query;
  const _InboxList({required this.query});

  Future<void> _deleteFromInbox(BuildContext context, String chatId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete chat?"),
        content: const Text("هيتم حذف الشات من عندك فقط. الرسائل هتفضل محفوظة."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final uid = FirebaseAuth.instance.currentUser!.uid;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('inbox')
        .doc(chatId)
        .delete();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Chat deleted from your list ✅")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return const Center(child: Text('No chats yet'));
        }

        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final d = docs[i].data();
            final chatId = docs[i].id;

            final title = (d['title'] ?? 'Chat') as String;
            final last = (d['lastText'] ?? '') as String;
            final unread = (d['unread'] ?? 0) as int;
            final ts = d['lastTime'] as Timestamp?;

            final timeText = ts == null
                ? ''
                : TimeOfDay.fromDateTime(ts.toDate()).format(context);

            return ListTile(
              leading: CircleAvatar(
                child: Text(title.isNotEmpty ? title[0].toUpperCase() : '?'),
              ),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(timeText, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  if (unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        unread.toString(),
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    )
                ],
              ),

              // ✅ فتح الشات
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(chatId: chatId),
                  ),
                );
              },

              // ✅ حذف بالشدة المطولة
              onLongPress: () => _deleteFromInbox(context, chatId),
            );
          },
        );
      },
    );
  }
}
