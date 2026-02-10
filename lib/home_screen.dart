import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'invite_service.dart';
import 'chat_screen.dart';

enum _MenuAction { inviteQr, logout }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final db = FirebaseFirestore.instance;
  final codeCtrl = TextEditingController();

  String lastInviteCode = "";
  bool busy = false;

  @override
  void dispose() {
    codeCtrl.dispose();
    super.dispose();
  }

  // ✅ WhatsApp-like: show my chats list
  Stream<QuerySnapshot<Map<String, dynamic>>> myChatsStream() {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .orderBy('lastMessageAt', descending: true)
        .snapshots();
  }

  Future<Map<String, dynamic>?> getUserDoc(String uid) async {
    final snap = await db.collection('users').doc(uid).get();
    return snap.data();
  }

  Future<void> createInvite() async {
    setState(() => busy = true);

    try {
      final res = await InviteService.createInvite();
      final code = (res['code'] ?? '').toUpperCase();

      if (!mounted) return;
      setState(() => lastInviteCode = code);

      // مهم: افتح الـ sheet بعد إغلاق أي Menu/Route (خصوصًا من PopupMenu)
      Future.delayed(Duration.zero, () {
        if (mounted) openInviteSheet(code);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void openJoinDialog() {
    codeCtrl.clear();
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

  void openMainActions() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.add_link),
                  title: const Text("Create Invite"),
                  subtitle: const Text("اعمل كود وشارك/QR زي واتساب"),
                  onTap: busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          createInvite();
                        },
                ),
                ListTile(
                  leading: const Icon(Icons.key),
                  title: const Text("Join with code"),
                  subtitle: const Text("ادخل الكود اللي اتبعت لك"),
                  onTap: busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          openJoinDialog();
                        },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

 void openInviteSheet(String code) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,   // 🔥 مهم جدًا
    builder: (_) {
      return SafeArea(
        child: SingleChildScrollView(   // ✅ يمنع الـ Overflow
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

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    children: [
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
                        child: QrImageView(
                          data: code,
                          size: 200,
                        ),
                      ),

                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: code),
                                );
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
                                Share.share(
                                  "Noon Chat 🎁\nInvite Code: $code\nافتح التطبيق وادخل الكود.",
                                );
                              },
                              icon: const Icon(Icons.share),
                              label: const Text("Share"),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      );
    },
  );
}

  Future<void> _handleMenu(_MenuAction action) async {
    switch (action) {
      case _MenuAction.inviteQr:
        // لو عندك كود قديم -> افتح sheet
        if (lastInviteCode.isNotEmpty) {
          Future.delayed(Duration.zero, () {
            if (mounted) openInviteSheet(lastInviteCode);
          });
        } else {
          // لو مفيش كود -> اعمل واحد جديد
          await createInvite();
        }
        break;

      case _MenuAction.logout:
        await FirebaseAuth.instance.signOut();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser!;
    final myUid = me.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Noon Chat"),
        actions: [
          IconButton(
            tooltip: "Join",
            onPressed: busy ? null : openJoinDialog,
            icon: const Icon(Icons.key),
          ),

          // ✅ ده اللي بيصلح مشكلة "Invite / QR" مش بيعمل حاجة
          PopupMenuButton<_MenuAction>(
            onSelected: _handleMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _MenuAction.inviteQr,
                child: Text("Invite / QR"),
              ),
              PopupMenuItem(
                value: _MenuAction.logout,
                child: Text("Logout"),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: busy ? null : openMainActions,
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: myChatsStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            // مهم جدًا: لو Firestore محتاج Index هتشوفه هنا بدل "مفيش شاتات"
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  "Firestore error:\n${snapshot.error}\n\n"
                  "لو مكتوب محتاج Index: افتح الرسالة كاملة من الـ Debug Console واعمل Create Index.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;

          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.chat_bubble_outline, size: 44),
                    const SizedBox(height: 10),
                    const Text(
                      "مفيش شاتات لسه",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "اضغط + عشان تعمل Invite وتبعت لها الكود",
                      style: TextStyle(color: Colors.grey.shade700),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (context, i) {
              final data = docs[i].data();
              final chatId = docs[i].id;

              final participants = List<String>.from(data['participants'] ?? []);
              final otherUid =
                  participants.firstWhere((x) => x != myUid, orElse: () => myUid);

              final lastMessage = (data['lastMessage'] ?? '') as String;
              final ts = data['lastMessageAt'];
              final timeText = (ts is Timestamp)
                  ? TimeOfDay.fromDateTime(ts.toDate()).format(context)
                  : "";

              return FutureBuilder<Map<String, dynamic>?>(
                future: getUserDoc(otherUid),
                builder: (context, uSnap) {
                  final u = uSnap.data;
                  final name = (u?['name'] as String?)?.trim();
                  final photo = (u?['photo'] as String?)?.trim();

                  final displayName =
                      (name != null && name.isNotEmpty) ? name : "New chat";

                  final avatarUrl = (photo != null && photo.isNotEmpty)
                      ? photo
                      : "https://ui-avatars.com/api/?name=${Uri.encodeComponent(displayName)}&background=eee&color=333";

                  return ListTile(
                    leading: CircleAvatar(
                      radius: 24,
                      backgroundImage: NetworkImage(avatarUrl),
                    ),
                    title: Text(
                      displayName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      lastMessage.isEmpty ? "No messages yet" : lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      timeText,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(chatId: chatId),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
