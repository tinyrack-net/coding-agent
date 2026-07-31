// Port of Paseo's `composer/input/labels.test.ts`.
import 'package:coding_agent_app/composer/composer_input_labels.dart';
import 'package:flutter_test/flutter_test.dart';

const _translations = {
  'composer.input.interruptAgent': 'Interrupt agent',
  'composer.input.queueMessage': 'Queue message',
  'composer.input.sendAndInterrupt': 'Send and interrupt',
  'composer.input.sendMessage': 'Send message',
  'composer.input.queue': 'Queue',
  'composer.input.send': 'Send',
  'composer.voice.unmuteVoiceMode': 'Unmute Voice mode',
  'composer.voice.muteVoiceMode': 'Mute Voice mode',
  'composer.voice.stopDictation': 'Stop dictation',
  'composer.voice.startDictation': 'Start dictation',
  'composer.voice.unmuteVoice': 'Unmute voice',
  'composer.voice.muteVoice': 'Mute voice',
  'composer.voice.dictation': 'Dictation',
};

String t(String key) => _translations[key] ?? key;

void main() {
  test('resolves submit accessibility labels by precedence', () {
    expect(
      resolveSubmitAccessibilityLabel(
        canPressLoadingButton: true,
        defaultActionQueues: false,
        isAgentRunning: true,
        t: t,
      ),
      'Interrupt agent',
    );
    expect(
      resolveSubmitAccessibilityLabel(
        canPressLoadingButton: false,
        defaultActionQueues: true,
        isAgentRunning: true,
        t: t,
      ),
      'Queue message',
    );
    expect(
      resolveSubmitAccessibilityLabel(
        canPressLoadingButton: false,
        defaultActionQueues: false,
        isAgentRunning: true,
        t: t,
      ),
      'Send and interrupt',
    );
    expect(
      resolveSubmitAccessibilityLabel(
        canPressLoadingButton: false,
        defaultActionQueues: false,
        isAgentRunning: false,
        t: t,
      ),
      'Send message',
    );
  });

  test('a caller-supplied submit label wins over every other branch', () {
    expect(
      resolveSubmitAccessibilityLabel(
        submitButtonAccessibilityLabel: 'Custom',
        canPressLoadingButton: true,
        defaultActionQueues: true,
        isAgentRunning: true,
        t: t,
      ),
      'Custom',
    );
  });

  test('resolves voice accessibility labels', () {
    expect(
      resolveVoiceAccessibilityLabel(
        isRealtimeVoiceForCurrentAgent: true,
        isMuted: true,
        isDictating: false,
        t: t,
      ),
      'Unmute Voice mode',
    );
    expect(
      resolveVoiceAccessibilityLabel(
        isRealtimeVoiceForCurrentAgent: true,
        isMuted: false,
        isDictating: false,
        t: t,
      ),
      'Mute Voice mode',
    );
    expect(
      resolveVoiceAccessibilityLabel(
        isRealtimeVoiceForCurrentAgent: false,
        isMuted: false,
        isDictating: true,
        t: t,
      ),
      'Stop dictation',
    );
    expect(
      resolveVoiceAccessibilityLabel(
        isRealtimeVoiceForCurrentAgent: false,
        isMuted: false,
        isDictating: false,
        t: t,
      ),
      'Start dictation',
    );
  });

  test('resolves voice tooltip text', () {
    expect(
      resolveVoiceTooltipText(
        isRealtimeVoiceForCurrentAgent: true,
        isMuted: true,
        t: t,
      ),
      'Unmute voice',
    );
    expect(
      resolveVoiceTooltipText(
        isRealtimeVoiceForCurrentAgent: true,
        isMuted: false,
        t: t,
      ),
      'Mute voice',
    );
    expect(
      resolveVoiceTooltipText(
        isRealtimeVoiceForCurrentAgent: false,
        isMuted: false,
        t: t,
      ),
      'Dictation',
    );
  });

  test('resolves send tooltip labels', () {
    expect(resolveSendTooltipLabel(defaultActionQueues: true, t: t), 'Queue');
    expect(resolveSendTooltipLabel(defaultActionQueues: false, t: t), 'Send');
    expect(
      resolveSendTooltipLabel(
        submitButtonAccessibilityLabel: 'Custom',
        defaultActionQueues: true,
        t: t,
      ),
      'Custom',
    );
  });
}
