import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'chat_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();

  Future<void> send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    await ChatService.sendText(
      chatId: widget.chatId,
      text: text,
    );

    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ✅ آمن: يدعم senderId أو senderUid
  String _readSenderId(Map<String, dynamic> data) {
    final a = data['senderId'];
    final b = data['senderUid'];
    return (a is String && a.isNotEmpty)
        ? a
        : (b is String && b.isNotEmpty)
            ? b
            : '';
  }

  // ✅ آمن: يدعم createdAt أو timestamp
  DateTime? _readTime(Map<String, dynamic> data) {
    final t1 = data['createdAt'];
    final t2 = data['timestamp'];
    final t = (t1 is Timestamp) ? t1 : (t2 is Timestamp ? t2 : null);
    return t?.toDate();
  }

  BorderRadius _bubbleRadius(bool isMe) {
    return BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMe ? 16 : 4),
      bottomRight: Radius.circular(isMe ? 4 : 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser!;

    return Scaffold(
      appBar: AppBar(title: const Text("Chat")),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: ChatService.messagesStream(widget.chatId),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data!.docs;

                if (docs.isEmpty) {
                  return const Center(child: Text("No messages yet"));
                }

                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data();

                    final text = (data['text'] ?? '') as String;
                    final senderId = _readSenderId(data);
                    final isMe = senderId == me.uid;

                    final dt = _readTime(data);
                    final timeText = (dt == null)
                        ? ''
                        : TimeOfDay.fromDateTime(dt).format(context);

                    return Align(
                      alignment:
                          isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.78,
                        ),
                        child: Container(
                          margin: EdgeInsets.fromLTRB(
                            isMe ? 60 : 12,
                            6,
                            isMe ? 12 : 60,
                            6,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isMe
                                ? Colors.green.shade100
                                : Colors.grey.shade200,
                            borderRadius: _bubbleRadius(isMe),
                          ),
                          child: Column(
                            crossAxisAlignment: isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Text(
                                text,
                                style: const TextStyle(fontSize: 16),
                              ),
                              if (timeText.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  timeText,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // Input
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => send(),
                      decoration: InputDecoration(
                        hintText: "اكتب رسالة...",
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: send,
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
