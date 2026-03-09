import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/conversation_background.dart';
import '../services/chat_background_service.dart';

class ChatWallpaperScreen extends StatefulWidget {
  final String conversationId;

  const ChatWallpaperScreen({super.key, required this.conversationId});

  @override
  State<ChatWallpaperScreen> createState() => _ChatWallpaperScreenState();
}

class _ChatWallpaperScreenState extends State<ChatWallpaperScreen> {
  final ImagePicker _picker = ImagePicker();
  late final ValueNotifier<ConversationBackground> _bgNotifier;

  bool _loading = false;
  double _overlayOpacity = ConversationBackground.defaultOverlayOpacity;
  double _parallax = ConversationBackground.defaultParallaxStrength;

  @override
  void initState() {
    super.initState();
    _bgNotifier = ChatBackgroundService.instance.listenable(
      widget.conversationId,
    );
    final current = _bgNotifier.value;
    _overlayOpacity = current.overlayOpacity;
    _parallax = current.parallaxStrength;
  }

  Future<void> _pickAndSaveWallpaper() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 82,
      );
      if (picked == null) return;

      final storedPath = await ChatBackgroundService.instance
          .storeCompressedWallpaper(
            conversationId: widget.conversationId,
            croppedSourcePath: picked.path,
            quality: 72,
            targetMinSide: 980,
          );
      await ChatBackgroundService.instance.setWallpaperPath(
        conversationId: widget.conversationId,
        localPath: storedPath,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Wallpaper updated')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to set wallpaper')));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      } else {
        _loading = false;
      }
    }
  }

  Future<void> _removeWallpaper() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await ChatBackgroundService.instance.removeWallpaper(
        widget.conversationId,
      );
      _overlayOpacity = ConversationBackground.defaultOverlayOpacity;
      _parallax = ConversationBackground.defaultParallaxStrength;
      ChatBackgroundService.instance.previewStyle(
        conversationId: widget.conversationId,
        overlayOpacity: _overlayOpacity,
        parallaxStrength: _parallax,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Wallpaper removed')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to remove wallpaper')),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      } else {
        _loading = false;
      }
    }
  }

  Future<void> _persistStyle() async {
    await ChatBackgroundService.instance.persistStyle(
      conversationId: widget.conversationId,
      overlayOpacity: _overlayOpacity,
      parallaxStrength: _parallax,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat wallpaper')),
      body: ValueListenableBuilder<ConversationBackground>(
        valueListenable: _bgNotifier,
        builder: (context, bg, _) {
          final path = (bg.localPath ?? '').trim();
          final hasFile = path.isNotEmpty && File(path).existsSync();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Container(
                height: 230,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (hasFile)
                      Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        cacheWidth: 640,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (context, error, stackTrace) =>
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Color(0xFF0E1622),
                                    Color(0xFF0A1019),
                                  ],
                                ),
                              ),
                            ),
                      )
                    else
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Color(0xFF0E1622),
                              Color(0xFF0A1019),
                            ],
                          ),
                        ),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: _overlayOpacity),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          hasFile ? 'Preview' : 'No wallpaper selected',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.92),
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loading ? null : _pickAndSaveWallpaper,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from gallery'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _loading || !bg.hasWallpaper
                    ? null
                    : _removeWallpaper,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove wallpaper'),
              ),
              const SizedBox(height: 18),
              Text(
                'Dark overlay',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Slider(
                value: _overlayOpacity,
                min: 0,
                max: 0.7,
                divisions: 14,
                label: _overlayOpacity.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _overlayOpacity = v);
                  ChatBackgroundService.instance.previewStyle(
                    conversationId: widget.conversationId,
                    overlayOpacity: v,
                    parallaxStrength: _parallax,
                  );
                },
                onChangeEnd: (_) => unawaited(_persistStyle()),
              ),
              const SizedBox(height: 8),
              Text(
                'Parallax',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Slider(
                value: _parallax,
                min: 0,
                max: 0.06,
                divisions: 12,
                label: _parallax.toStringAsFixed(3),
                onChanged: (v) {
                  setState(() => _parallax = v);
                  ChatBackgroundService.instance.previewStyle(
                    conversationId: widget.conversationId,
                    overlayOpacity: _overlayOpacity,
                    parallaxStrength: v,
                  );
                },
                onChangeEnd: (_) => unawaited(_persistStyle()),
              ),
            ],
          );
        },
      ),
    );
  }
}
