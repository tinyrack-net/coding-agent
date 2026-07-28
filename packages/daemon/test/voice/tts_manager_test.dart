import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/tts_manager.dart';
import 'package:agent_daemon/src/voice/voice_types.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'emits one combined audio message and resolves once confirmed',
    () async {
      final manager = TtsManager(
        sessionId: 's1',
        resolveTts: () => _FakeTts(),
        createAudioId: () => 'audio-1',
      );
      final abort = VoiceAbortController();
      final emitted = <AudioOutputMessage>[];

      await manager.generateAndWaitForPlayback(
        text: 'hello',
        emitMessage: (message) {
          emitted.add(message);
          manager.confirmAudioPlayed(message.payload.id);
        },
        abortSignal: abort.signal,
        isVoiceMode: true,
      );

      expect(emitted, hasLength(1));
      expect(emitted.single.payload.toJson(), {
        'audio': base64Encode(utf8.encode('ab')),
        'format': 'pcm;rate=24000',
        'id': 'audio-1:0',
        'isVoiceMode': true,
        'groupId': 'audio-1',
        'chunkIndex': 0,
        'isLastChunk': true,
      });
    },
  );

  test('splits long text into safe synthesis segments', () async {
    final calls = <String>[];
    final provider = _CallbackTts((text) {
      calls.add(text);
      return SpeechStreamResult(
        stream: Stream.value(const [120]),
        format: 'pcm;rate=24000',
      );
    });
    final manager = TtsManager(sessionId: 's1', resolveTts: () => provider);
    final abort = VoiceAbortController();
    final longText = [
      for (var index = 1; index <= 180; index += 1) 'Sentence $index.',
    ].join(' ');

    await manager.generateAndWaitForPlayback(
      text: longText,
      emitMessage: (message) {
        manager.confirmAudioPlayed(message.payload.id);
      },
      abortSignal: abort.signal,
      isVoiceMode: true,
    );

    expect(calls.length, greaterThan(1));
    expect(calls.every((text) => text.length <= maxTtsSegmentChars), isTrue);
    expect(calls.first.length, lessThanOrEqualTo(120));
    expect(
      calls.skip(1).any((text) => text.length > calls.first.length),
      isTrue,
    );
  });

  test('normalizes whitespace and clause-splits oversized fragments', () async {
    final calls = <String>[];
    final provider = _CallbackTts((text) {
      calls.add(text);
      return SpeechStreamResult(stream: Stream.value(const [1]), format: 'mp3');
    });
    final manager = TtsManager(sessionId: 's1', resolveTts: () => provider);
    final abort = VoiceAbortController();
    final clause = List.filled(30, 'abcdefgh').join(' ');

    await manager.generateAndWaitForPlayback(
      text: '  $clause, \n $clause;   done  ',
      emitMessage: (message) {
        manager.confirmAudioPlayed(message.payload.id);
      },
      abortSignal: abort.signal,
      isVoiceMode: false,
    );

    expect(calls, hasLength(greaterThan(1)));
    expect(calls.every((text) => text.length <= maxTtsSegmentChars), isTrue);
    expect(calls.every((text) => !text.contains(RegExp(r'\s{2,}'))), isTrue);
  });

  test('hard-splits oversized fragments without usable spaces', () async {
    final calls = <String>[];
    final manager = TtsManager(
      sessionId: 's1',
      resolveTts: () => _CallbackTts((text) {
        calls.add(text);
        return SpeechStreamResult(
          stream: Stream.value(const [1]),
          format: 'mp3',
        );
      }),
    );

    await manager.generateAndWaitForPlayback(
      text: List.filled(600, 'x').join(),
      emitMessage: (message) {
        manager.confirmAudioPlayed(message.payload.id);
      },
      abortSignal: VoiceAbortController().signal,
      isVoiceMode: false,
    );

    expect(calls.map((text) => text.length), [260, 260, 80]);
  });

  test('prefetches two segments and advances before playback completes', () async {
    final started = <String>[];
    final gates = <String, Completer<void>>{};
    final provider = _CallbackTts((text) async {
      started.add(text);
      final gate = gates.putIfAbsent(text, Completer<void>.new);
      await gate.future;
      return SpeechStreamResult(
        stream: Stream.value(utf8.encode(text)),
        format: 'pcm;rate=24000',
      );
    });
    final manager = TtsManager(sessionId: 's1', resolveTts: () => provider);
    final abort = VoiceAbortController();
    const segments = [
      'One sentence that is long enough to stand alone in the first voice chunk.',
      'Two sentence that is also long enough to require a separate synthesized group.',
      'Three sentence that should only be synthesized after playback of the first group starts because it carries extra detail about the lookahead pipeline and should exceed the later packing target on its own.',
    ];
    final emitted = <AudioOutputMessage>[];

    final task = manager.generateAndWaitForPlayback(
      text: segments.join(' '),
      emitMessage: emitted.add,
      abortSignal: abort.signal,
      isVoiceMode: true,
    );

    expect(started, segments.take(2).toList());
    gates[segments[0]]!.complete();
    await _waitFor(() => emitted.isNotEmpty);

    expect(started, segments);
    expect(emitted, hasLength(1));

    manager.confirmAudioPlayed(emitted[0].payload.id);
    gates[segments[1]]!.complete();
    await _waitFor(() => emitted.length == 2);
    manager.confirmAudioPlayed(emitted[1].payload.id);
    gates[segments[2]]!.complete();
    await _waitFor(() => emitted.length == 3);
    manager.confirmAudioPlayed(emitted[2].payload.id);
    await task;
  });

  test('abort destroys current and prefetched speech streams', () async {
    final destroyed = <String>[];
    final provider = _CallbackTts((text) {
      return SpeechStreamResult(
        stream: Stream.value(utf8.encode(text)),
        format: 'pcm;rate=24000',
        onDestroy: () => destroyed.add(text),
      );
    });
    final manager = TtsManager(sessionId: 's1', resolveTts: () => provider);
    final abort = VoiceAbortController();
    final emitted = <AudioOutputMessage>[];

    final task = manager.generateAndWaitForPlayback(
      text: [
        'First sentence that is long enough to stand alone in the first synthesized group.',
        'Second sentence that should be prefetched and then discarded after abort is requested.',
        'Third sentence that should also be cleaned up if it was prefetched before the abort.',
      ].join(' '),
      emitMessage: emitted.add,
      abortSignal: abort.signal,
      isVoiceMode: true,
    );

    await _waitFor(() => emitted.isNotEmpty);
    abort.abort();
    await task;
    await _waitFor(() => destroyed.length >= 2);
    expect(destroyed.toSet().length, greaterThanOrEqualTo(2));
  });

  test(
    'stream iteration errors reject without a second asynchronous error',
    () async {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final provider = _CallbackTts((_) {
          return SpeechStreamResult(
            stream: (() async* {
              yield const [97];
              throw StateError('stream exploded');
            })(),
            format: 'pcm;rate=24000',
          );
        });
        final manager = TtsManager(sessionId: 's1', resolveTts: () => provider);

        await expectLater(
          manager.generateAndWaitForPlayback(
            text: 'hello',
            emitMessage: (_) {},
            abortSignal: VoiceAbortController().signal,
            isVoiceMode: true,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'stream exploded',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }, (error, _) => zoneErrors.add(error));

      expect(zoneErrors, isEmpty);
    },
  );

  test('empty audio stream resolves without emitting', () async {
    final manager = TtsManager(
      sessionId: 's1',
      resolveTts: () => _CallbackTts(
        (_) => SpeechStreamResult(stream: const Stream.empty(), format: 'mp3'),
      ),
    );
    final emitted = <AudioOutputMessage>[];

    await manager.generateAndWaitForPlayback(
      text: 'hello',
      emitMessage: emitted.add,
      abortSignal: VoiceAbortController().signal,
      isVoiceMode: false,
    );

    expect(emitted, isEmpty);
  });

  test('missing provider and blank text fail with frozen errors', () async {
    final manager = TtsManager(sessionId: 's1', resolveTts: () => null);

    expect(
      () => manager.generateAndWaitForPlayback(
        text: '   \n ',
        emitMessage: (_) {},
        abortSignal: VoiceAbortController().signal,
        isVoiceMode: false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Cannot synthesize empty text',
        ),
      ),
    );
    await expectLater(
      manager.generateAndWaitForPlayback(
        text: 'hello',
        emitMessage: (_) {},
        abortSignal: VoiceAbortController().signal,
        isVoiceMode: false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'TTS not configured',
        ),
      ),
    );
  });

  test('cancel resolves a pending playback and cleanup rejects it', () async {
    final provider = _FakeTts();
    final cancelManager = TtsManager(
      sessionId: 'cancel',
      resolveTts: () => provider,
    );
    final cancelEmitted = <AudioOutputMessage>[];
    final cancelTask = cancelManager.generateAndWaitForPlayback(
      text: 'hello',
      emitMessage: cancelEmitted.add,
      abortSignal: VoiceAbortController().signal,
      isVoiceMode: true,
    );
    await _waitFor(() => cancelEmitted.isNotEmpty);
    cancelManager.cancelPendingPlaybacks('user interrupt');
    await cancelTask;

    final cleanupManager = TtsManager(
      sessionId: 'cleanup',
      resolveTts: () => provider,
    );
    final cleanupEmitted = <AudioOutputMessage>[];
    final cleanupTask = cleanupManager.generateAndWaitForPlayback(
      text: 'hello',
      emitMessage: cleanupEmitted.add,
      abortSignal: VoiceAbortController().signal,
      isVoiceMode: true,
    );
    final cleanupExpectation = expectLater(
      cleanupTask,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Session closed',
        ),
      ),
    );
    await _waitFor(() => cleanupEmitted.isNotEmpty);
    cleanupManager.cleanup();
    await cleanupExpectation;
  });

  test('late confirmation is quiet until the closed-ID TTL expires', () async {
    var now = DateTime.utc(2026);
    final warnings = <String>[];
    final manager = TtsManager(
      sessionId: 's1',
      resolveTts: () => _FakeTts(),
      createAudioId: () => 'audio-1',
      now: () => now,
      onWarning: warnings.add,
    );
    final emitted = <AudioOutputMessage>[];

    await manager.generateAndWaitForPlayback(
      text: 'hello',
      emitMessage: (message) {
        emitted.add(message);
        manager.confirmAudioPlayed(message.payload.id);
      },
      abortSignal: VoiceAbortController().signal,
      isVoiceMode: true,
    );

    manager.confirmAudioPlayed(emitted.single.payload.id);
    expect(warnings, isEmpty);

    now = now.add(const Duration(seconds: 11));
    manager.confirmAudioPlayed(emitted.single.payload.id);
    expect(warnings, hasLength(1));
  });

  test(
    'abort controller is idempotent and publishes one abort future',
    () async {
      final controller = VoiceAbortController();
      var notifications = 0;
      final observed = controller.signal.onAbort.then(
        (_) => notifications += 1,
      );
      var retainedListenerCalls = 0;
      var removedListenerCalls = 0;
      controller.signal.addAbortListener(() => retainedListenerCalls += 1);
      final removeListener = controller.signal.addAbortListener(
        () => removedListenerCalls += 1,
      );
      removeListener();

      expect(controller.signal.aborted, isFalse);
      controller.abort();
      controller.abort();
      var postAbortListenerCalls = 0;
      controller.signal.addAbortListener(() => postAbortListenerCalls += 1);
      await observed;
      await Future<void>.delayed(Duration.zero);

      expect(controller.signal.aborted, isTrue);
      expect(notifications, 1);
      expect(retainedListenerCalls, 1);
      expect(removedListenerCalls, 0);
      expect(postAbortListenerCalls, 0);
    },
  );
}

final class _FakeTts implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async {
    return SpeechStreamResult(
      stream: Stream.fromIterable([utf8.encode('a'), utf8.encode('b')]),
      format: 'pcm;rate=24000',
    );
  }
}

final class _CallbackTts implements TextToSpeechProvider {
  _CallbackTts(this.callback);

  final FutureOr<SpeechStreamResult> Function(String text) callback;

  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async =>
      callback(text);
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
