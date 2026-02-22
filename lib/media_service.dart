import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class MediaService {
  static Future<String> uploadChatImage({
    required String chatId,
    required Uint8List bytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final name = '${DateTime.now().millisecondsSinceEpoch}.jpg';

    final ref = FirebaseStorage.instance.ref().child(
      'chats/$chatId/images/$uid/$name',
    );

    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  static Future<String> uploadChatFile({
    required String chatId,
    required String fileName,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final safeName = fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final ref = FirebaseStorage.instance.ref().child(
      'chats/$chatId/files/$uid/${DateTime.now().millisecondsSinceEpoch}_$safeName',
    );

    await ref.putData(bytes, SettableMetadata(contentType: contentType));
    return ref.getDownloadURL();
  }

  static Future<String> uploadChatAudio({
    required String chatId,
    required Uint8List bytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final ref = FirebaseStorage.instance.ref().child(
      'chats/$chatId/audio/$uid/${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await ref.putData(bytes, SettableMetadata(contentType: 'audio/m4a'));
    return ref.getDownloadURL();
  }

  static Future<String> uploadStoryImage({required Uint8List bytes}) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final name = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance.ref().child('stories/$uid/$name');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }
}
