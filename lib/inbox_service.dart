import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class InboxService {
  static final _db = FirebaseFirestore.instance;

  /// يحذف الشات من قائمة المستخدم الحالية فقط
  static Future<void> deleteFromMyInbox(String chatId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await _db
        .collection('users')
        .doc(uid)
        .collection('inbox')
        .doc(chatId)
        .delete();
  }
}
