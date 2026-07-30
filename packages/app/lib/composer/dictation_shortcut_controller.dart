import 'dart:async';

typedef DictationRecordingState = bool Function();
typedef DictationShortcutAction = FutureOr<void> Function();

/// Routes the desktop dictation shortcut through the recording lifecycle's
/// synchronous state instead of retaining a second, potentially stale latch.
final class DictationShortcutController {
  const DictationShortcutController({
    required this.isRecording,
    required this.start,
    required this.markTranscriptForSend,
    required this.confirm,
  });

  final DictationRecordingState isRecording;
  final DictationShortcutAction start;
  final void Function() markTranscriptForSend;
  final DictationShortcutAction confirm;

  bool toggle() {
    if (isRecording()) {
      markTranscriptForSend();
      unawaited(Future<void>.sync(confirm));
    } else {
      unawaited(Future<void>.sync(start));
    }
    return true;
  }
}
