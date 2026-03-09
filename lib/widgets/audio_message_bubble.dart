import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class AudioMessageBubble extends StatefulWidget {
  final String messageId;
  final String audioUrl;
  final int durationMs;
  final bool isMe;

  const AudioMessageBubble({
    super.key,
    required this.messageId,
    required this.audioUrl,
    required this.durationMs,
    required this.isMe,
  });

  static Future<void> stopAllPlayback() async {
    await _SharedAudioController.instance.stop();
  }

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble> {
  late final _SharedAudioController _audio;

  @override
  void initState() {
    super.initState();
    _audio = _SharedAudioController.instance;
    _audio.ensureInitialized();
  }

  String _formatDuration(Duration duration) {
    final total = duration.inSeconds.clamp(0, 99 * 60);
    final mm = (total ~/ 60).toString().padLeft(2, '0');
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _audio.activeMessageId,
        _audio.position,
        _audio.duration,
        _audio.playing,
      ]),
      builder: (context, _) {
        final isActive = _audio.activeMessageId.value == widget.messageId;
        final isPlaying = isActive && _audio.playing.value;
        final current = isActive ? _audio.position.value : Duration.zero;
        final total = isActive && _audio.duration.value > Duration.zero
            ? _audio.duration.value
            : Duration(milliseconds: widget.durationMs);
        final progress = total.inMilliseconds <= 0
            ? 0.0
            : (current.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

        return SizedBox(
          width: 220,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: scheme.primary.withValues(alpha: 0.16),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _audio.togglePlay(
                    messageId: widget.messageId,
                    audioUrl: widget.audioUrl,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: progress,
                    backgroundColor: scheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      widget.isMe ? scheme.primary : scheme.secondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDuration(total),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SharedAudioController {
  _SharedAudioController._();
  static final _SharedAudioController instance = _SharedAudioController._();

  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<String?> activeMessageId = ValueNotifier<String?>(null);
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  bool _initialized = false;

  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _player.positionStream.listen((value) {
      position.value = value;
    });
    _player.durationStream.listen((value) {
      duration.value = value ?? Duration.zero;
    });
    _player.playerStateStream.listen((state) {
      playing.value = state.playing;
      if (state.processingState == ProcessingState.completed) {
        unawaited(stop());
      }
    });
  }

  Future<void> togglePlay({
    required String messageId,
    required String audioUrl,
  }) async {
    ensureInitialized();

    if (audioUrl.trim().isEmpty) return;

    if (activeMessageId.value == messageId) {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    activeMessageId.value = messageId;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    try {
      await _player.setUrl(audioUrl);
      await _player.play();
    } catch (_) {
      await stop();
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    activeMessageId.value = null;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    playing.value = false;
  }
}
