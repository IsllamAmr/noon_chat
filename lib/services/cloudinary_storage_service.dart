import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ImageStorageException implements Exception {
  final String message;

  const ImageStorageException(this.message);

  @override
  String toString() => message;
}

class CloudinaryUploadResult {
  final String secureUrl;
  final String publicId;

  const CloudinaryUploadResult({
    required this.secureUrl,
    required this.publicId,
  });
}

class CloudinaryStorageService {
  static const String _cloudName = String.fromEnvironment(
    'CLOUDINARY_CLOUD_NAME',
    defaultValue: '',
  );
  static const String _uploadPreset = String.fromEnvironment(
    'CLOUDINARY_UPLOAD_PRESET',
    defaultValue: '',
  );
  static const String _baseFolder = String.fromEnvironment(
    'CLOUDINARY_BASE_FOLDER',
    defaultValue: 'noon_chat',
  );

  static bool get isConfigured =>
      _cloudName.trim().isNotEmpty && _uploadPreset.trim().isNotEmpty;

  static String _normalizeSegment(String value) {
    final v = value.trim().replaceAll(RegExp(r'[^\w\-/]'), '_');
    return v.replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/+|/+$'), '');
  }

  static String _safeFileName(String value) {
    final clean = value.trim().replaceAll(RegExp(r'[^\w.\-]'), '_');
    if (clean.isEmpty) return 'upload.jpg';
    return clean;
  }

  static String _joinWithUnderscore(String a, String b) {
    final left = a.trim().replaceAll(RegExp(r'[/\\]+'), '_');
    final right = b.trim().replaceAll(RegExp(r'[/\\]+'), '_');
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '${left}_$right';
  }

  static String _plainTextBody(http.Response response) {
    final body = response.body.trim();
    if (body.isEmpty) return '';
    return body.replaceAll('\n', '').replaceAll('\r', '').trim();
  }

  static Future<CloudinaryUploadResult> _uploadViaCloudinary({
    required Uint8List bytes,
    required String fullFolder,
    required String cleanPublicId,
    required String fileName,
    String resourceType = 'image',
    String failureLabel = 'File',
  }) async {
    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/${_cloudName.trim()}/$resourceType/upload',
    );

    final request = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = _uploadPreset.trim()
      ..fields['public_id'] = cleanPublicId;

    if (fullFolder.isNotEmpty) {
      request.fields['folder'] = fullFolder;
    }

    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: _safeFileName(fileName),
      ),
    );

    http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ImageStorageException(
        '$failureLabel upload timed out. Check internet and retry.',
      );
    } catch (_) {
      throw ImageStorageException(
        'Failed to upload $failureLabel. Check internet and retry.',
      );
    }

    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String details = 'Upload failed (${response.statusCode}).';
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          final err = body['error'];
          if (err is Map<String, dynamic>) {
            final msg = (err['message'] ?? '').toString().trim();
            if (msg.isNotEmpty) details = msg;
          }
        }
      } catch (_) {}
      throw ImageStorageException(details);
    }

    final dynamic body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const ImageStorageException('Upload response is invalid.');
    }

    final secureUrl = (body['secure_url'] ?? '').toString().trim();
    final returnedPublicId = (body['public_id'] ?? cleanPublicId).toString();

    if (secureUrl.isEmpty) {
      throw ImageStorageException(
        'Upload succeeded but $failureLabel URL is empty.',
      );
    }

    return CloudinaryUploadResult(
      secureUrl: secureUrl,
      publicId: returnedPublicId,
    );
  }

  static Future<CloudinaryUploadResult> _uploadViaCatbox({
    required Uint8List bytes,
    required String fileName,
    required String fallbackPublicId,
  }) async {
    final uri = Uri.parse('https://catbox.moe/user/api.php');
    final request = http.MultipartRequest('POST', uri)
      ..fields['reqtype'] = 'fileupload'
      ..files.add(
        http.MultipartFile.fromBytes(
          'fileToUpload',
          bytes,
          filename: _safeFileName(fileName),
        ),
      );

    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamed);
    final text = _plainTextBody(response);

    final ok =
        response.statusCode >= 200 &&
        response.statusCode < 300 &&
        (text.startsWith('https://') || text.startsWith('http://'));
    if (!ok) {
      throw ImageStorageException(
        text.isNotEmpty
            ? text
            : 'Fallback upload failed (${response.statusCode}).',
      );
    }

    return CloudinaryUploadResult(secureUrl: text, publicId: fallbackPublicId);
  }

  static Future<CloudinaryUploadResult> _uploadVia0x0({
    required Uint8List bytes,
    required String fileName,
    required String fallbackPublicId,
  }) async {
    final uri = Uri.parse('https://0x0.st');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: _safeFileName(fileName),
        ),
      );

    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamed);
    final text = _plainTextBody(response);

    final ok =
        response.statusCode >= 200 &&
        response.statusCode < 300 &&
        (text.startsWith('https://') || text.startsWith('http://'));
    if (!ok) {
      throw ImageStorageException(
        text.isNotEmpty
            ? text
            : 'Fallback upload failed (${response.statusCode}).',
      );
    }

    return CloudinaryUploadResult(secureUrl: text, publicId: fallbackPublicId);
  }

  static Future<CloudinaryUploadResult> uploadImageBytes({
    required Uint8List bytes,
    required String folder,
    required String publicId,
    String fileName = 'upload.jpg',
  }) async {
    if (bytes.isEmpty) {
      throw const ImageStorageException('Selected image is empty.');
    }

    final cleanPublicId = _normalizeSegment(publicId);
    if (cleanPublicId.isEmpty) {
      throw const ImageStorageException('Invalid upload id.');
    }

    final folderPart = _normalizeSegment(folder);
    final basePart = _normalizeSegment(_baseFolder);
    final fullFolder = [
      basePart,
      folderPart,
    ].where((p) => p.isNotEmpty).join('/');
    if (isConfigured) {
      return _uploadViaCloudinary(
        bytes: bytes,
        fullFolder: fullFolder,
        cleanPublicId: cleanPublicId,
        fileName: fileName,
        resourceType: 'image',
        failureLabel: 'Image',
      );
    }

    final fallbackPublicId = _joinWithUnderscore(fullFolder, cleanPublicId);
    final fallbackFileName = _safeFileName(
      _joinWithUnderscore(fallbackPublicId, fileName),
    );

    try {
      return await _uploadViaCatbox(
        bytes: bytes,
        fileName: fallbackFileName,
        fallbackPublicId: fallbackPublicId,
      );
    } catch (_) {}

    try {
      return await _uploadVia0x0(
        bytes: bytes,
        fileName: fallbackFileName,
        fallbackPublicId: fallbackPublicId,
      );
    } on ImageStorageException catch (e) {
      throw ImageStorageException(
        'Image upload failed. Configure Cloudinary or retry later. ${e.message}',
      );
    }
  }

  static Future<CloudinaryUploadResult> uploadBinaryBytes({
    required Uint8List bytes,
    required String folder,
    required String publicId,
    String fileName = 'upload.bin',
  }) async {
    if (bytes.isEmpty) {
      throw const ImageStorageException('Selected file is empty.');
    }

    final cleanPublicId = _normalizeSegment(publicId);
    if (cleanPublicId.isEmpty) {
      throw const ImageStorageException('Invalid upload id.');
    }

    final folderPart = _normalizeSegment(folder);
    final basePart = _normalizeSegment(_baseFolder);
    final fullFolder = [
      basePart,
      folderPart,
    ].where((p) => p.isNotEmpty).join('/');

    if (isConfigured) {
      return _uploadViaCloudinary(
        bytes: bytes,
        fullFolder: fullFolder,
        cleanPublicId: cleanPublicId,
        fileName: fileName,
        resourceType: 'auto',
        failureLabel: 'File',
      );
    }

    final fallbackPublicId = _joinWithUnderscore(fullFolder, cleanPublicId);
    final fallbackFileName = _safeFileName(
      _joinWithUnderscore(fallbackPublicId, fileName),
    );

    try {
      return await _uploadViaCatbox(
        bytes: bytes,
        fileName: fallbackFileName,
        fallbackPublicId: fallbackPublicId,
      );
    } catch (_) {}

    try {
      return await _uploadVia0x0(
        bytes: bytes,
        fileName: fallbackFileName,
        fallbackPublicId: fallbackPublicId,
      );
    } on ImageStorageException catch (e) {
      throw ImageStorageException(
        'File upload failed. Configure Cloudinary or retry later. ${e.message}',
      );
    }
  }
}
