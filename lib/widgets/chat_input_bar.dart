import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/voice_service.dart';

class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEmojiPressed;
  final VoidCallback? onAttachPressed;
  final VoidCallback? onCameraPressed;
  final VoidCallback? onSendPressed;
  final Future<bool> Function()? onRecordStart;
  final Future<void> Function()? onRecordLock;
  final Future<void> Function()? onRecordStop;
  final Future<void> Function()? onRecordCancel;
  final ValueListenable<VoiceComposerState>? recordingListenable;
  final bool sending;
  final bool enabled;

  const ChatInputBar({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onEmojiPressed,
    this.onAttachPressed,
    this.onCameraPressed,
    this.onSendPressed,
    this.onRecordStart,
    this.onRecordLock,
    this.onRecordStop,
    this.onRecordCancel,
    this.recordingListenable,
    this.sending = false,
    this.enabled = true,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  static const double _cancelThresholdX = -80;
  static const double _lockThresholdY = -70;

  late final ValueNotifier<bool> _hasText;
  late final ValueNotifier<VoiceComposerState> _fallbackRecordState;

  bool _gestureRecording = false;
  bool _gestureActive = false;
  bool _finishingGesture = false;
  bool _lockRequested = false;
  bool _showCanceledHint = false;
  double _dragDx = 0;
  double _dragDy = 0;
  int _recordStartEpoch = 0;
  Timer? _canceledHintTimer;

  VoiceComposerState get _recordState =>
      widget.recordingListenable?.value ?? const VoiceComposerState();

  ValueListenable<VoiceComposerState> get _effectiveRecordingListenable =>
      widget.recordingListenable ?? _fallbackRecordState;

  @override
  void initState() {
    super.initState();
    _hasText = ValueNotifier<bool>(_computeHasText());
    _fallbackRecordState = ValueNotifier<VoiceComposerState>(
      const VoiceComposerState(),
    );
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _hasText.value = _computeHasText();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _hasText.dispose();
    _fallbackRecordState.dispose();
    _canceledHintTimer?.cancel();
    super.dispose();
  }

  bool _computeHasText() => widget.controller.text.trim().isNotEmpty;

  void _onControllerChanged() {
    final next = _computeHasText();
    if (_hasText.value == next) return;
    _hasText.value = next;
  }

  Future<void> _handleLongPressStart() async {
    if (!widget.enabled || widget.sending || _recordState.isUploading) return;
    if (_hasText.value) return;
    if (_gestureRecording || _recordState.isRecording) return;

    _gestureActive = true;
    final token = ++_recordStartEpoch;
    final started = await (widget.onRecordStart?.call() ?? Future.value(false));
    if (!mounted || token != _recordStartEpoch) return;

    if (!_gestureActive) {
      if (started) {
        await widget.onRecordCancel?.call();
      }
      return;
    }
    if (!started) return;

    setState(() {
      _gestureRecording = true;
      _lockRequested = false;
      _dragDx = 0;
      _dragDy = 0;
      _showCanceledHint = false;
    });
  }

  Future<void> _handleLongPressMove(LongPressMoveUpdateDetails details) async {
    if (!_gestureRecording || _recordState.isRecordingLocked) return;

    final dx = details.offsetFromOrigin.dx;
    final dy = details.offsetFromOrigin.dy;
    if (!mounted) return;
    setState(() {
      _dragDx = dx;
      _dragDy = dy;
    });

    // Hold -> cancel transition when user slides enough to the left.
    if (dx <= _cancelThresholdX) {
      await _finishRecordingGesture(cancel: true, canceledBySlide: true);
      return;
    }

    // Hold -> locked transition when user slides up.
    if (dy <= _lockThresholdY) {
      await _lockRecordingGesture();
    }
  }

  Future<void> _lockRecordingGesture() async {
    if (!_gestureRecording) return;
    _lockRequested = true;
    _gestureRecording = false;
    _gestureActive = false;
    if (mounted) {
      setState(() {
        _dragDx = 0;
        _dragDy = 0;
      });
    }
    try {
      await widget.onRecordLock?.call();
    } catch (_) {
      _lockRequested = false;
      rethrow;
    }
  }

  Future<void> _finishRecordingGesture({
    required bool cancel,
    bool canceledBySlide = false,
  }) async {
    if (_finishingGesture) return;
    _finishingGesture = true;

    try {
      _gestureActive = false;
      final shouldCancel =
          cancel || canceledBySlide || _dragDx <= _cancelThresholdX;
      final hadGesture = _gestureRecording;

      if (mounted) {
        setState(() {
          _gestureRecording = false;
          _dragDx = 0;
          _dragDy = 0;
        });
      } else {
        _gestureRecording = false;
      }

      if (!hadGesture && !_recordState.isRecordingHold) return;
      if (_lockRequested && !shouldCancel) return;

      if (shouldCancel) {
        await widget.onRecordCancel?.call();
        _lockRequested = false;
        _showCanceledOnce();
        return;
      }

      // If recording already got locked, do not auto-send on finger release.
      if (_recordState.isRecordingLocked) return;
      await widget.onRecordStop?.call();
    } finally {
      _finishingGesture = false;
    }
  }

  void _showCanceledOnce() {
    _canceledHintTimer?.cancel();
    if (!mounted) return;
    setState(() => _showCanceledHint = true);
    _canceledHintTimer = Timer(const Duration(milliseconds: 850), () {
      if (!mounted) return;
      setState(() => _showCanceledHint = false);
    });
  }

  String _formatDuration(int durationMs) {
    final totalSeconds = (durationMs / 1000).floor().clamp(0, 99 * 60);
    final mm = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Widget _buildRecordingHud(ThemeData theme, VoiceComposerState state) {
    final scheme = theme.colorScheme;
    final cancelArmed = _dragDx <= _cancelThresholdX;
    final lockProgress = (-_dragDy / _lockThresholdY.abs()).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.fiber_manual_record_rounded,
            color: cancelArmed ? scheme.error : Colors.redAccent,
            size: 12,
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(state.durationMs),
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              state.isRecordingLocked
                  ? 'Recording locked'
                  : (cancelArmed
                        ? 'Release to cancel'
                        : 'Slide left to cancel'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cancelArmed ? scheme.error : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!state.isRecordingLocked)
            Opacity(
              opacity: 0.55 + (0.45 * lockProgress),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 1.6,
                    height: 24,
                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 1),
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _normalComposer(ThemeData theme, bool enabled) {
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          tooltip: 'Emoji',
          onPressed: enabled ? widget.onEmojiPressed : null,
          icon: Icon(
            Icons.emoji_emotions_outlined,
            color: scheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            onChanged: widget.onChanged,
            minLines: 1,
            maxLines: 5,
            enabled: enabled,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: 'Write a message...',
              hintStyle: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 12,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Attach',
          onPressed: enabled ? widget.onAttachPressed : null,
          icon: Icon(Icons.attach_file_rounded, color: scheme.onSurfaceVariant),
        ),
        IconButton(
          tooltip: 'Camera',
          onPressed: enabled ? widget.onCameraPressed : null,
          icon: Icon(Icons.camera_alt_outlined, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _recordingPlaceholder(ThemeData theme, VoiceComposerState state) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.mic_rounded,
            size: 18,
            color: state.isRecordingLocked
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.isRecordingLocked
                  ? 'Recording locked'
                  : 'Recording... slide up to lock',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleAction({
    required Widget child,
    required Color color,
    required VoidCallback? onTap,
    double size = 54,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: ValueListenableBuilder<VoiceComposerState>(
          valueListenable: _effectiveRecordingListenable,
          builder: (context, recordState, _) {
            final effectiveEnabled =
                widget.enabled && !widget.sending && !recordState.isUploading;
            final isRecording = recordState.isRecording;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _showCanceledHint
                      ? Container(
                          key: const ValueKey('canceled-chip'),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.errorContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Canceled',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onErrorContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: isRecording
                      ? _buildRecordingHud(theme, recordState)
                      : const SizedBox.shrink(),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.24,
                            ),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) {
                            final offset = Tween<Offset>(
                              begin: const Offset(0, 0.08),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: offset,
                                child: child,
                              ),
                            );
                          },
                          child: isRecording
                              ? SizedBox(
                                  key: const ValueKey('recording-placeholder'),
                                  child: _recordingPlaceholder(
                                    theme,
                                    recordState,
                                  ),
                                )
                              : SizedBox(
                                  key: const ValueKey('normal-composer'),
                                  child: _normalComposer(
                                    theme,
                                    effectiveEnabled,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (recordState.isUploading || widget.sending)
                      _buildCircleAction(
                        color: const Color(0xFF25D366),
                        onTap: null,
                        child: const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                      )
                    else if (recordState.isRecordingLocked)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildCircleAction(
                            size: 48,
                            color: scheme.surfaceContainerHigh,
                            onTap: effectiveEnabled
                                ? () => unawaited(widget.onRecordCancel?.call())
                                : null,
                            child: Icon(
                              Icons.delete_outline_rounded,
                              color: scheme.onSurfaceVariant,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildCircleAction(
                            color: const Color(0xFF25D366),
                            onTap: effectiveEnabled
                                ? () => unawaited(widget.onRecordStop?.call())
                                : null,
                            child: const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 23,
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        width: 54,
                        height: 54,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _hasText,
                          builder: (context, hasText, _) {
                            final canPress = effectiveEnabled && !isRecording;
                            final showSend = hasText;

                            Widget buttonChild = Icon(
                              showSend ? Icons.send_rounded : Icons.mic_rounded,
                              key: ValueKey(showSend ? 'send' : 'mic'),
                              color: Colors.white,
                              size: 24,
                            );

                            final circle = _buildCircleAction(
                              color: const Color(0xFF25D366),
                              onTap: showSend && canPress
                                  ? widget.onSendPressed
                                  : null,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  final scale = Tween<double>(
                                    begin: 0.78,
                                    end: 1,
                                  ).animate(animation);
                                  return FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: scale,
                                      child: child,
                                    ),
                                  );
                                },
                                child: buttonChild,
                              ),
                            );

                            if (showSend) return circle;

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPressStart: (_) =>
                                  unawaited(_handleLongPressStart()),
                              onLongPressMoveUpdate: (details) =>
                                  unawaited(_handleLongPressMove(details)),
                              onLongPressEnd: (_) {
                                if (_lockRequested ||
                                    _recordState.isRecordingLocked) {
                                  _gestureActive = false;
                                  _gestureRecording = false;
                                  return;
                                }
                                unawaited(
                                  _finishRecordingGesture(cancel: false),
                                );
                              },
                              onLongPressCancel: () {
                                unawaited(
                                  _finishRecordingGesture(cancel: true),
                                );
                              },
                              child: circle,
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
