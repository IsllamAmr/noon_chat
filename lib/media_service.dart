import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'services/cloudinary_storage_service.dart';

class MediaService {
  static Future<String> uploadChatImage({
    required String chatId,
    required Uint8List bytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final upload = await CloudinaryStorageService.uploadImageBytes(
      bytes: bytes,
      folder: 'chats/$chatId/images/$uid',
      publicId: 'img_$stamp',
      fileName: 'img_$stamp.jpg',
    );
    return upload.secureUrl;
  }

  static Future<String> uploadChatImageFile({
    required String chatId,
    required String imagePath,
  }) async {
    if (imagePath.trim().isEmpty) {
      throw const ImageStorageException('Selected image path is invalid.');
    }

    final compressedBytes = await FlutterImageCompress.compressWithFile(
      imagePath,
      minWidth: 1280,
      minHeight: 1280,
      quality: 72,
      format: CompressFormat.jpeg,
      keepExif: false,
    );

    final bytes = compressedBytes ?? await File(imagePath).readAsBytes();

    if (bytes.isEmpty) {
      throw const ImageStorageException('Selected image is empty.');
    }

    return uploadChatImage(chatId: chatId, bytes: bytes);
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
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final upload = await CloudinaryStorageService.uploadBinaryBytes(
      bytes: bytes,
      folder: 'chat_audio/$chatId',
      publicId: 'aud_$stamp',
      fileName: 'aud_$stamp.m4a',
    );
    return upload.secureUrl;
  }

  static Future<String> uploadChatAudioFile({
    required String chatId,
    required String messageId,
    required String localPath,
  }) async {
    final cleanPath = localPath.trim();
    if (cleanPath.isEmpty) {
      throw const ImageStorageException('Audio file path is empty.');
    }
    final file = File(cleanPath);
    if (!file.existsSync()) {
      throw const ImageStorageException('Recorded audio file not found.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const ImageStorageException('Recorded audio is empty.');
    }
    final upload = await CloudinaryStorageService.uploadBinaryBytes(
      bytes: bytes,
      folder: 'chat_audio/$chatId',
      publicId: messageId,
      fileName: '$messageId.m4a',
    );
    return upload.secureUrl;
  }

  static Future<String> uploadStoryImage({required Uint8List bytes}) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final upload = await CloudinaryStorageService.uploadImageBytes(
      bytes: bytes,
      folder: 'stories/$uid',
      publicId: 'story_$stamp',
      fileName: 'story_$stamp.jpg',
    );
    return upload.secureUrl;
  }
}
