// Port of Paseo's `composer/input/state.test.ts`.
import 'package:coding_agent_app/composer/composer_input_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors upstream's `createDictationKeyboard` harness.
class DictationKeyboard {
  DictationKeyboard({required this.startsRecording});

  final bool startsRecording;
  final actions = <String>[];
  bool _isRecording = false;

  void pressDictationShortcut() {
    runMessageInputKeyboardAction(
      MessageInputKeyboardAction.dictationToggle,
      MessageInputKeyboardActions(
        focusInput: () {},
        isDictationRecording: () => _isRecording,
        markTranscriptForSend: () => actions.add('send transcript'),
        startDictation: () {
          actions.add('start');
          _isRecording = startsRecording;
        },
        confirmDictation: () {
          actions.add('confirm');
          _isRecording = false;
        },
        cancelDictation: () {},
        toggleRealtimeVoice: () {},
        isRealtimeVoiceActive: false,
        toggleRealtimeVoiceMute: () {},
      ),
    );
  }
}

class SendActions {
  final calls = <String>[];

  SendActionContext context({
    required SendBehavior defaultSendBehavior,
    required bool isAgentRunning,
    bool canQueue = true,
  }) => SendActionContext(
    defaultSendBehavior: defaultSendBehavior,
    isAgentRunning: isAgentRunning,
    canQueue: canQueue,
    handleSendMessage: () => calls.add('send'),
    handleQueueMessage: () => calls.add('queue'),
  );
}

void main() {
  group('composer surface presentation', () {
    test('shows only the input when no voice overlay is active', () {
      final presentation = resolveComposerSurfacePresentation(false);

      expect(presentation.input.opacity, 1);
      expect(presentation.input.interactive, isTrue);
      expect(presentation.overlay.opacity, 0);
      expect(presentation.overlay.interactive, isFalse);
    });

    test('shows only the voice overlay while voice UI is active', () {
      final presentation = resolveComposerSurfacePresentation(true);

      expect(presentation.input.opacity, 0);
      expect(presentation.input.interactive, isFalse);
      expect(presentation.overlay.opacity, 1);
      expect(presentation.overlay.interactive, isTrue);
    });
  });

  group('computeCanStartDictation', () {
    test('returns false when the socket is disconnected', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: false,
          isReadyForDictation: true,
          disabled: false,
        ),
        isFalse,
      );
    });

    test('returns false when readiness is explicitly false', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: true,
          isReadyForDictation: false,
          disabled: false,
        ),
        isFalse,
      );
    });

    test('returns true when connected and ready', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: true,
          isReadyForDictation: true,
          disabled: false,
        ),
        isTrue,
      );
    });

    test('falls back to the socket when readiness is unknown', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: true,
          isReadyForDictation: null,
          disabled: false,
        ),
        isTrue,
      );
      expect(
        computeCanStartDictation(
          isSocketConnected: false,
          isReadyForDictation: null,
          disabled: false,
        ),
        isFalse,
      );
    });

    test('returns false when the input is disabled', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: true,
          isReadyForDictation: true,
          disabled: true,
        ),
        isFalse,
      );
    });

    test('returns false when dictation is unavailable', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: true,
          isReadyForDictation: true,
          disabled: false,
          dictationUnavailableMessage: 'Microphone unavailable',
        ),
        isFalse,
      );
    });

    test('returns false when there is no client', () {
      expect(
        computeCanStartDictation(
          isSocketConnected: null,
          isReadyForDictation: true,
          disabled: false,
        ),
        isFalse,
      );
    });
  });

  group('dictation keyboard behavior', () {
    test('starts dictation again after the previous dictation finishes', () {
      final keyboard = DictationKeyboard(startsRecording: true)
        ..pressDictationShortcut()
        ..pressDictationShortcut()
        ..pressDictationShortcut();

      expect(keyboard.actions, [
        'start',
        'send transcript',
        'confirm',
        'start',
      ]);
    });

    test('can retry when starting does not enter the recording state', () {
      final keyboard = DictationKeyboard(startsRecording: false)
        ..pressDictationShortcut()
        ..pressDictationShortcut();

      expect(keyboard.actions, ['start', 'start']);
    });
  });

  group('composer send behavior', () {
    test('Enter interrupts and Mod+Enter queues when interrupt is the '
        'default', () {
      final primary = SendActions();
      runDefaultSendAction(
        primary.context(
          defaultSendBehavior: SendBehavior.interrupt,
          isAgentRunning: true,
        ),
      );

      final alternate = SendActions();
      runAlternateSendAction(
        alternate.context(
          defaultSendBehavior: SendBehavior.interrupt,
          isAgentRunning: true,
        ),
      );

      expect(primary.calls, ['send']);
      expect(alternate.calls, ['queue']);
    });

    test('Enter queues and Mod+Enter submits when queue is the default', () {
      final primary = SendActions();
      runDefaultSendAction(
        primary.context(
          defaultSendBehavior: SendBehavior.queue,
          isAgentRunning: true,
        ),
      );

      final alternate = SendActions();
      runAlternateSendAction(
        alternate.context(
          defaultSendBehavior: SendBehavior.queue,
          isAgentRunning: true,
        ),
      );

      expect(primary.calls, ['queue']);
      expect(alternate.calls, ['send']);
    });

    test('sends rather than queues when no turn is running', () {
      final primary = SendActions();
      runDefaultSendAction(
        primary.context(
          defaultSendBehavior: SendBehavior.queue,
          isAgentRunning: false,
        ),
      );

      final alternate = SendActions();
      runAlternateSendAction(
        alternate.context(
          defaultSendBehavior: SendBehavior.interrupt,
          isAgentRunning: false,
        ),
      );

      expect(primary.calls, ['send']);
      // Nothing to queue behind, so the alternate action is inert.
      expect(alternate.calls, isEmpty);
    });

    test('sends when the surface cannot queue at all', () {
      final primary = SendActions();
      runDefaultSendAction(
        primary.context(
          defaultSendBehavior: SendBehavior.queue,
          isAgentRunning: true,
          canQueue: false,
        ),
      );

      expect(primary.calls, ['send']);
    });
  });

  group('runMessageInputKeyboardAction', () {
    MessageInputKeyboardActions actionsWith({
      required bool isRecording,
      required List<String> log,
      bool isRealtimeVoiceActive = false,
    }) => MessageInputKeyboardActions(
      focusInput: () => log.add('focus'),
      isDictationRecording: () => isRecording,
      markTranscriptForSend: () => log.add('mark'),
      confirmDictation: () => log.add('confirm'),
      cancelDictation: () => log.add('cancel'),
      startDictation: () => log.add('start'),
      toggleRealtimeVoice: () => log.add('toggle-voice'),
      isRealtimeVoiceActive: isRealtimeVoiceActive,
      toggleRealtimeVoiceMute: () => log.add('toggle-mute'),
    );

    test('always handles focus and voice toggle', () {
      final log = <String>[];
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.focus,
          actionsWith(isRecording: false, log: log),
        ),
        isTrue,
      );
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.voiceToggle,
          actionsWith(isRecording: false, log: log),
        ),
        isTrue,
      );
      expect(log, ['focus', 'toggle-voice']);
    });

    test('claims send and cancel only while dictation is recording', () {
      final idle = <String>[];
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.send,
          actionsWith(isRecording: false, log: idle),
        ),
        isFalse,
      );
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.dictationCancel,
          actionsWith(isRecording: false, log: idle),
        ),
        isFalse,
      );
      expect(idle, isEmpty);

      final recording = <String>[];
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.send,
          actionsWith(isRecording: true, log: recording),
        ),
        isTrue,
      );
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.dictationCancel,
          actionsWith(isRecording: true, log: recording),
        ),
        isTrue,
      );
      expect(recording, ['mark', 'confirm', 'cancel']);
    });

    test('mute toggle is handled but inert while voice is inactive', () {
      final log = <String>[];
      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.voiceMuteToggle,
          actionsWith(isRecording: false, log: log),
        ),
        isTrue,
      );
      expect(log, isEmpty);

      expect(
        runMessageInputKeyboardAction(
          MessageInputKeyboardAction.voiceMuteToggle,
          actionsWith(
            isRecording: false,
            log: log,
            isRealtimeVoiceActive: true,
          ),
        ),
        isTrue,
      );
      expect(log, ['toggle-mute']);
    });
  });

  group('stopRealtimeVoice', () {
    test(
      'is inert without voice or when voice targets another agent',
      () async {
        var stopped = false;
        await stopRealtimeVoice(
          hasVoice: false,
          isRealtimeVoiceForCurrentAgent: true,
          isAgentRunning: false,
          stopVoice: () async => stopped = true,
        );
        await stopRealtimeVoice(
          hasVoice: true,
          isRealtimeVoiceForCurrentAgent: false,
          isAgentRunning: false,
          stopVoice: () async => stopped = true,
        );

        expect(stopped, isFalse);
      },
    );

    test('stops voice directly when no turn is running', () async {
      var stopped = false;
      await stopRealtimeVoice(
        hasVoice: true,
        isRealtimeVoiceForCurrentAgent: true,
        isAgentRunning: false,
        stopVoice: () async => stopped = true,
      );

      expect(stopped, isTrue);
    });

    test('cancels the running turn before stopping voice', () async {
      final order = <String>[];
      await stopRealtimeVoice(
        hasVoice: true,
        isRealtimeVoiceForCurrentAgent: true,
        isAgentRunning: true,
        voiceAgentId: 'a1',
        cancelAgent: (agentId) async => order.add('cancel:$agentId'),
        stopVoice: () async => order.add('stop'),
      );

      expect(order, ['cancel:a1', 'stop']);
    });

    test('refuses to strand a running voice agent without a host', () async {
      await expectLater(
        stopRealtimeVoice(
          hasVoice: true,
          isRealtimeVoiceForCurrentAgent: true,
          isAgentRunning: true,
          stopVoice: () async {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
