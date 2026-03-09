import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation_background.dart';

class ChatBackgroundService {
  ChatBackgroundService._();

  static final ChatBackgroundService instance = ChatBackgroundService._();
  static const String _prefsKey = 'chat_backgrounds';

  final Map<String, ConversationBackground> _cache =
      <String, ConversationBackground>{};
  final Map<String, ValueNotifier<ConversationBackground>> _notifiers =
      <String, ValueNotifier<ConversationBackground>>{};

  bool _loaded = false;
  Future<void>? _loadTask;

  ValueNotifier<ConversationBackground> listenable(String conversationId) {
    final id = conversationId.trim();
    final notifier = _notifiers.putIfAbsent(
      id,
      () => ValueNotifier<ConversationBackground>(
        ConversationBackground.fallback(id),
      ),
    );
    unawaited(_syncNotifier(id));
    return notifier;
  }

  Future<ConversationBackground> get(String conversationId) async {
    final id = conversationId.trim();
    await _ensureLoaded();
    return _cache[id] ?? ConversationBackground.fallback(id);
  }

  void previewStyle({
    required String conversationId,
    required double overlayOpacity,
    required double parallaxStrength,
  }) {
    final id = conversationId.trim();
    final current = _cache[id] ?? ConversationBackground.fallback(id);
    final updated = current.copyWith(
      overlayOpacity: overlayOpacity,
      parallaxStrength: parallaxStrength,
    );
    _cache[id] = updated;
    _emit(updated);
  }

  Future<void> persistStyle({
    required String conversationId,
    required double overlayOpacity,
    required double parallaxStrength,
  }) async {
    final id = conversationId.trim();
    await _ensureLoaded();
    final current = _cache[id] ?? ConversationBackground.fallback(id);
    final updated = current.copyWith(
      overlayOpacity: overlayOpacity,
      parallaxStrength: parallaxStrength,
    );
    _cache[id] = updated;
    _emit(updated);
    await _savePrefs();
  }

  Future<String> storeCompressedWallpaper({
    required String conversationId,
    required String croppedSourcePath,
    int quality = 76,
    int targetMinSide = 1080,
  }) async {
    final id = conversationId.trim();
    if (id.isEmpty) throw StateError('conversationId is empty');
    if (croppedSourcePath.trim().isEmpty) {
      throw StateError('Image path is empty');
    }

    final docs = await getApplicationDocumentsDirectory();
    final bgDir = Directory('${docs.path}${Platform.pathSeparator}chat_bg');
    if (!bgDir.existsSync()) {
      await bgDir.create(recursive: true);
    }

    final safeId = id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final targetPath = '${bgDir.path}${Platform.pathSeparator}$safeId.jpg';
    final compressedPath =
        '${bgDir.path}${Platform.pathSeparator}${safeId}_tmp.jpg';

    final compressed = await FlutterImageCompress.compressAndGetFile(
      croppedSourcePath,
      compressedPath,
      format: CompressFormat.jpeg,
      quality: quality.clamp(60, 85),
      minWidth: targetMinSide,
      minHeight: targetMinSide,
      keepExif: false,
    );

    final sourcePath = compressed?.path ?? croppedSourcePath;
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw StateError('Compressed file was not created');
    }

    final target = File(targetPath);
    if (target.existsSync()) {
      await target.delete();
    }
    await source.copy(targetPath);

    if (compressed != null) {
      try {
        await File(compressed.path).delete();
      } catch (_) {}
    }
    return targetPath;
  }

  Future<void> setWallpaperPath({
    required String conversationId,
    required String localPath,
  }) async {
    final id = conversationId.trim();
    final path = localPath.trim();
    if (id.isEmpty) throw StateError('conversationId is empty');
    if (path.isEmpty) throw StateError('wallpaper path is empty');

    await _ensureLoaded();
    final current = _cache[id] ?? ConversationBackground.fallback(id);
    final updated = current.copyWith(localPath: path);
    _cache[id] = updated;
    _emit(updated);
    await _savePrefs();
  }

  Future<void> removeWallpaper(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    await _ensureLoaded();
    final existing = _cache[id];
    if (existing != null && existing.hasWallpaper) {
      final file = File(existing.localPath!);
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    _cache.remove(id);
    _emit(ConversationBackground.fallback(id));
    await _savePrefs();
  }

  Future<void> cleanupBrokenPath({
    required String conversationId,
    required String brokenPath,
  }) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    await _ensureLoaded();
    final existing = _cache[id];
    if (existing == null) return;
    if ((existing.localPath ?? '').trim() != brokenPath.trim()) return;
    _cache.remove(id);
    _emit(ConversationBackground.fallback(id));
    await _savePrefs();
  }

  Future<void> _syncNotifier(String conversationId) async {
    await _ensureLoaded();
    final current =
        _cache[conversationId] ??
        ConversationBackground.fallback(conversationId);
    _emit(current);
  }

  void _emit(ConversationBackground value) {
    final notifier = _notifiers.putIfAbsent(
      value.conversationId,
      () => ValueNotifier<ConversationBackground>(
        ConversationBackground.fallback(value.conversationId),
      ),
    );
    if (notifier.value.toJson().toString() == value.toJson().toString() &&
        notifier.value.conversationId == value.conversationId) {
      return;
    }
    notifier.value = value;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loadTask ??= _load();
    await _loadTask;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final decoded = decodeConversationBackgrounds(raw);

    _cache.clear();
    for (final entry in decoded.entries) {
      final id = entry.key.trim();
      final value = entry.value;
      if (id.isEmpty || value is! Map) continue;
      final map = value.map((key, val) => MapEntry(key.toString(), val));
      _cache[id] = ConversationBackground.fromJson(id, map);
    }
    _loaded = true;
    _loadTask = null;
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{};
    for (final entry in _cache.entries) {
      payload[entry.key] = entry.value.toJson();
    }
    await prefs.setString(_prefsKey, jsonEncode(payload));
  }
}
