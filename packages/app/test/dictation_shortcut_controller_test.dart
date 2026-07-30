import 'package:coding_agent_app/composer/dictation_shortcut_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts again after the previous recording is confirmed', () async {
    var recording = false;
    final actions = <String>[];
    final controller = DictationShortcutController(
      isRecording: () => recording,
      start: () {
        actions.add('start');
        recording = true;
      },
      markTranscriptForSend: () => actions.add('send transcript'),
      confirm: () {
        actions.add('confirm');
        recording = false;
      },
    );

    expect(controller.toggle(), isTrue);
    expect(controller.toggle(), isTrue);
    expect(controller.toggle(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(actions, ['start', 'send transcript', 'confirm', 'start']);
  });

  test('retries when start does not enter the recording state', () async {
    final actions = <String>[];
    final controller = DictationShortcutController(
      isRecording: () => false,
      start: () => actions.add('start'),
      markTranscriptForSend: () => actions.add('send transcript'),
      confirm: () => actions.add('confirm'),
    );

    controller.toggle();
    controller.toggle();
    await Future<void>.delayed(Duration.zero);

    expect(actions, ['start', 'start']);
  });
}
