// Port of Paseo's `composer/submit.test.ts`.
import 'dart:async';

import 'package:coding_agent_app/composer/composer_submit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records everything the submit flow does to the composer.
class SubmitHarness {
  final events = <String>[];
  String userInput = 'hello';
  List<String> attachments = ['a1'];
  String? sendError = 'stale error';
  bool isProcessing = false;
  final queued = <({String message, List<String> attachments})>[];

  Completer<void>? gate;
  Object? failWith;

  Future<AgentInputSubmitResult> run({
    String message = 'hello',
    List<String> attachments = const ['a1'],
    bool isAgentRunning = false,
    bool canSubmit = true,
    bool hasExternalContent = false,
    bool allowEmptySubmit = false,
    ComposerSubmitBehavior submitBehavior = ComposerSubmitBehavior.clear,
    bool forceSend = false,
    String? failedToSendMessage,
  }) => submitAgentInput<String>(
    message: message,
    attachments: attachments,
    isAgentRunning: isAgentRunning,
    canSubmit: canSubmit,
    hasExternalContent: hasExternalContent,
    allowEmptySubmit: allowEmptySubmit,
    submitBehavior: submitBehavior,
    forceSend: forceSend,
    failedToSendMessage: failedToSendMessage,
    queueMessage: ({required message, required attachments}) {
      events.add('queue:$message');
      queued.add((message: message, attachments: attachments));
    },
    submitMessage: ({required message, required attachments}) async {
      events.add('submit:$message');
      await gate?.future;
      final failure = failWith;
      if (failure != null) throw failure;
    },
    clearDraft: (lifecycle) => events.add('clearDraft:$lifecycle'),
    setUserInput: (text) {
      events.add('setUserInput:$text');
      userInput = text;
    },
    setAttachments: (next) {
      events.add('setAttachments:${next.length}');
      // Qualified: `run`'s parameter of the same name shadows the field.
      this.attachments = next;
    },
    setSendError: (message) {
      events.add('setSendError:$message');
      sendError = message;
    },
    setIsProcessing: (value) {
      events.add('setIsProcessing:$value');
      isProcessing = value;
    },
    onSubmitError: (error) => events.add('onSubmitError'),
  );
}

void main() {
  test('clears the composer before an in-flight submit resolves', () async {
    final harness = SubmitHarness()..gate = Completer<void>();
    final pending = harness.run();

    await Future<void>.delayed(Duration.zero);
    // Cleared while the submit is still awaiting.
    expect(harness.userInput, '');
    expect(harness.attachments, isEmpty);
    expect(harness.isProcessing, isTrue);
    expect(harness.sendError, isNull);

    harness.gate!.complete();
    expect(await pending, AgentInputSubmitResult.submitted);
    expect(harness.events, contains('clearDraft:sent'));
    expect(harness.isProcessing, isFalse);
  });

  test('preserves the composer when requested', () async {
    final harness = SubmitHarness()..gate = Completer<void>();
    final pending = harness.run(
      submitBehavior: ComposerSubmitBehavior.preserveAndLock,
    );

    await Future<void>.delayed(Duration.zero);
    expect(harness.userInput, 'hello');
    expect(harness.attachments, ['a1']);

    harness.gate!.complete();
    expect(await pending, AgentInputSubmitResult.submitted);
    expect(
      harness.events.where((event) => event.startsWith('setUserInput')),
      isEmpty,
    );
  });

  test('queues while the agent is running and clears immediately', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(isAgentRunning: true),
      AgentInputSubmitResult.queued,
    );
    expect(harness.queued.single.message, 'hello');
    expect(harness.userInput, '');
    expect(harness.attachments, isEmpty);
    // Queuing never runs the submit path.
    expect(
      harness.events.where((event) => event.startsWith('submit:')),
      isEmpty,
    );
  });

  test('sends now rather than queuing when force-send is set', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(isAgentRunning: true, forceSend: true),
      AgentInputSubmitResult.submitted,
    );
    expect(harness.queued, isEmpty);
    expect(harness.events, contains('submit:hello'));
  });

  test('restores the composer when submit fails', () async {
    final harness = SubmitHarness()..failWith = StateError('host offline');

    expect(await harness.run(), AgentInputSubmitResult.failed);
    expect(harness.userInput, 'hello');
    expect(harness.attachments, ['a1']);
    expect(harness.isProcessing, isFalse);
    expect(harness.sendError, contains('host offline'));
    expect(harness.events, contains('onSubmitError'));
    // A failed send is not a sent draft.
    expect(harness.events, isNot(contains('clearDraft:sent')));
  });

  test('a preserved composer is not restored on failure', () async {
    final harness = SubmitHarness()..failWith = StateError('host offline');

    expect(
      await harness.run(submitBehavior: ComposerSubmitBehavior.preserveAndLock),
      AgentInputSubmitResult.failed,
    );
    expect(
      harness.events.where((event) => event.startsWith('setUserInput')),
      isEmpty,
    );
  });

  test('ignores an empty submission', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(message: '   ', attachments: const []),
      AgentInputSubmitResult.noop,
    );
    expect(harness.events, isEmpty);
  });

  test('submits when empty submit is explicitly allowed', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(
        message: '',
        attachments: const [],
        allowEmptySubmit: true,
      ),
      AgentInputSubmitResult.submitted,
    );
    expect(harness.events, contains('submit:'));
  });

  test('external content alone is enough to submit', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(
        message: '',
        attachments: const [],
        hasExternalContent: true,
      ),
      AgentInputSubmitResult.submitted,
    );
  });

  test('attachments alone are enough to submit', () async {
    final harness = SubmitHarness();

    expect(
      await harness.run(message: '', attachments: const ['a1']),
      AgentInputSubmitResult.submitted,
    );
  });

  test('does nothing when the surface cannot submit', () async {
    final harness = SubmitHarness();

    expect(await harness.run(canSubmit: false), AgentInputSubmitResult.noop);
    expect(harness.events, isEmpty);
  });

  test('trims the message before queueing and submitting', () async {
    final queueHarness = SubmitHarness();
    await queueHarness.run(message: '  spaced  ', isAgentRunning: true);
    expect(queueHarness.queued.single.message, 'spaced');

    final submitHarness = SubmitHarness();
    await submitHarness.run(message: '  spaced  ');
    expect(submitHarness.events, contains('submit:spaced'));
  });

  test(
    'falls back to the caller copy when the failure has no message',
    () async {
      final harness = SubmitHarness()..failWith = _BlankError();

      expect(
        await harness.run(failedToSendMessage: 'Could not send'),
        AgentInputSubmitResult.failed,
      );
      expect(harness.sendError, 'Could not send');
    },
  );
}

/// An error whose string form is empty, standing in for a thrown value that
/// carries no usable message.
class _BlankError implements Exception {
  @override
  String toString() => '';
}
