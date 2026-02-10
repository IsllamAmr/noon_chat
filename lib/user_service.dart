import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> upsertMe() async {
    final u = FirebaseAuth.instance.currentUser!;
    await _db.collection('users').doc(u.uid).set({
      'name': u.displayName ?? 'Noon User',
      'email': u.email ?? '',
      'photo': u.photoURL ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
