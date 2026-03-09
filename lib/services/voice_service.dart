import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

enum VoiceRecorderStage {
  idle,
  recordingHold,
  recordingLocked,
  uploading,
  error,
}

@immutable
class VoiceComposerState {
  final VoiceRecorderStage stage;
  final int durationMs;
  final String? errorMessage;

  const VoiceComposerState({
    this.stage = VoiceRecorderStage.idle,
    this.durationMs = 0,
    this.errorMessage,
  });

  bool get isIdle => stage == VoiceRecorderStage.idle;
  bool get isRecordingHold => stage == VoiceRecorderStage.recordingHold;
  bool get isRecordingLocked => stage == VoiceRecorderStage.recordingLocked;
  bool get isRecording => isRecordingHold || isRecordingLocked;
  bool get isUploading => stage == VoiceRecorderStage.uploading;
  bool get isError => stage == VoiceRecorderStage.error;
  bool get isLocked => stage == VoiceRecorderStage.recordingLocked;

  VoiceComposerState copyWith({
    VoiceRecorderStage? stage,
    int? durationMs,
    String? errorMessage,
    bool clearError = false,
  }) {
    return VoiceComposerState(
      stage: stage ?? this.stage,
      durationMs: durationMs ?? this.durationMs,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

@immutable
class VoiceRecordResult {
  final String filePath;
  final int durationMs;

  const VoiceRecordResult({required this.filePath, required this.durationMs});
}

@immutable
class MicPermissionResult {
  final bool granted;
  final bool permanentlyDenied;

  const MicPermissionResult({
    required this.granted,
    required this.permanentlyDenied,
  });
}

class VoiceService {
  final AudioRecorder _recorder = AudioRecorder();
  final ValueNotifier<VoiceComposerState> composer =
      ValueNotifier<VoiceComposerState>(const VoiceComposerState());

  Timer? _timer;
  DateTime? _startedAt;
  String? _activePath;

  Future<MicPermissionResult> requestMicrophonePermission() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    return MicPermissionResult(
      granted: status.isGranted,
      permanentlyDenied: status.isPermanentlyDenied || status.isRestricted,
    );
  }

  // idle -> recordingHold
  Future<bool> startRecording() async {
    if (!composer.value.isIdle) return false;

    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
      ),
      path: filePath,
    );

    _activePath = filePath;
    _startedAt = DateTime.now();
    composer.value = const VoiceComposerState(
      stage: VoiceRecorderStage.recordingHold,
      durationMs: 0,
    );
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final start = _startedAt;
      if (start == null || !composer.value.isRecording) return;
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      composer.value = composer.value.copyWith(durationMs: elapsed);
    });
    return true;
  }

  // recordingHold -> recordingLocked
  void lockRecording() {
    if (!composer.value.isRecordingHold) return;
    composer.value = composer.value.copyWith(
      stage: VoiceRecorderStage.recordingLocked,
    );
  }

  // recordingHold/recordingLocked -> idle (returns recorded file path)
  Future<VoiceRecordResult?> stopRecording() async {
    if (!composer.value.isRecording) return null;

    final path = await _recorder.stop();
    _timer?.cancel();
    _timer = null;

    final durationMs = _safeDurationMs();
    _startedAt = null;
    _activePath = null;
    composer.value = const VoiceComposerState(stage: VoiceRecorderStage.idle);

    if (path == null || path.trim().isEmpty) return null;
    return VoiceRecordResult(filePath: path, durationMs: durationMs);
  }

  // recordingHold/recordingLocked -> idle (delete local file)
  Future<void> cancelRecording() async {
    if (composer.value.isRecording) {
      final path = await _recorder.stop();
      if (path != null && path.isNotEmpty) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            await file.delete();
          }
        } catch (_) {}
      }
    } else if (_activePath != null && _activePath!.trim().isNotEmpty) {
      try {
        final file = File(_activePath!);
        if (file.existsSync()) {
          await file.delete();
        }
      } catch (_) {}
    }

    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    _activePath = null;
    if (!composer.value.isUploading) {
      composer.value = const VoiceComposerState(stage: VoiceRecorderStage.idle);
    }
  }

  // idle -> uploading -> idle
  void setUploading(bool uploading) {
    if (uploading) {
      _timer?.cancel();
      _timer = null;
      composer.value = const VoiceComposerState(
        stage: VoiceRecorderStage.uploading,
        durationMs: 0,
      );
      return;
    }
    composer.value = const VoiceComposerState(stage: VoiceRecorderStage.idle);
  }

  // Any -> error.
  void setError(Object error) {
    composer.value = VoiceComposerState(
      stage: VoiceRecorderStage.error,
      durationMs: 0,
      errorMessage: error.toString(),
    );
  }

  void resetToIdle() {
    if (composer.value.isIdle) return;
    composer.value = const VoiceComposerState(stage: VoiceRecorderStage.idle);
  }

  int _safeDurationMs() {
    final start = _startedAt;
    if (start == null) return composer.value.durationMs;
    final value = DateTime.now().difference(start).inMilliseconds;
    if (value <= 0) return composer.value.durationMs;
    return value;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    _activePath = null;
    await _recorder.dispose();
    composer.dispose();
  }
}
