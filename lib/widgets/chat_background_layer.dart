import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/conversation_background.dart';

class ChatBackgroundLayer extends StatefulWidget {
  final ValueListenable<ConversationBackground> backgroundListenable;
  final ValueListenable<double> scrollOffsetListenable;
  final VoidCallback? onMissingFile;

  const ChatBackgroundLayer({
    super.key,
    required this.backgroundListenable,
    required this.scrollOffsetListenable,
    this.onMissingFile,
  });

  @override
  State<ChatBackgroundLayer> createState() => _ChatBackgroundLayerState();
}

class _ChatBackgroundLayerState extends State<ChatBackgroundLayer> {
  String _lastReportedBrokenPath = '';

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          widget.backgroundListenable,
          widget.scrollOffsetListenable,
        ]),
        builder: (context, _) {
          final bg = widget.backgroundListenable.value;
          final path = (bg.localPath ?? '').trim();
          final hasFile = path.isNotEmpty && File(path).existsSync();
          if (!hasFile && path.isNotEmpty && _lastReportedBrokenPath != path) {
            _lastReportedBrokenPath = path;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onMissingFile?.call();
            });
          }
          if (hasFile) {
            _lastReportedBrokenPath = '';
          }

          final offset = widget.scrollOffsetListenable.value;
          final translateY = (-offset * bg.parallaxStrength).clamp(-42.0, 42.0);
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final width = MediaQuery.sizeOf(context).width;
          final cacheWidth = math.min((width * dpr).round(), 1600);

          return Stack(
            fit: StackFit.expand,
            children: [
              if (hasFile)
                Transform.translate(
                  offset: Offset(0, translateY.toDouble()),
                  child: Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    cacheWidth: cacheWidth,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (context, error, stackTrace) {
                      return const SizedBox.shrink();
                    },
                  ),
                )
              else
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0xFF0E1622), Color(0xFF0A1019)],
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: bg.overlayOpacity),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
