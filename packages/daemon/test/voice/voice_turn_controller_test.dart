import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:agent_daemon/src/voice/voice_turn_controller.dart';
import 'package:test/test.dart';

void main() {
  group('voice turn controller', () {
    test('passes configured language to streaming STT', () async {
      final harness = _Harness(sttLanguage: 'pt');
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      expect(harness.lastSttLanguage, 'pt');
    });

    test('forwards audio to detector and streaming STT', () async {
      final harness = _Harness();
      await harness.controller.start();
      await harness.append([1, 2, 3, 4]);
      harness.detector.emitSpeechStarted();
      await harness.settle();
      await harness.append([5, 6, 7, 8]);
      harness.detector.emitSpeechStopped();
      await harness.settle();

      expect(harness.detector.appendedChunks, [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ]);
      expect(harness.sttSessions.single.appendedChunks, [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ]);
      expect(harness.speechStartedCount, 1);
      expect(harness.speechStoppedCount, 1);
      expect(harness.finalTranscripts, isEmpty);
      expect(harness.errors, isEmpty);
    });

    test('does not barge in on silence-only chunks', () async {
      final harness = _Harness();
      await harness.controller.start();
      await harness.append([0, 0, 0, 0]);
      await harness.append([0, 0, 0, 0]);
      await harness.settle();
      expect(harness.detector.appendedChunks, hasLength(2));
      expect(harness.speechStartedCount, 0);
      expect(harness.speechStoppedCount, 0);
      expect(harness.finalTranscripts, isEmpty);
      expect(harness.errors, isEmpty);
    });

    test('fires only the first non-filler partial in a turn', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      for (final transcript in ['uh', 'uh,', 'Um', 'uh um', 'hmm']) {
        harness.sttSessions.single.emitTranscript(
          _transcript(transcript, isFinal: false),
        );
        await harness.settle();
      }
      expect(harness.partialTranscripts, isEmpty);

      harness.sttSessions.single.emitTranscript(
        _transcript('uh hello', isFinal: false),
      );
      harness.sttSessions.single.emitTranscript(
        _transcript('hello again', isFinal: false),
      );
      await harness.settle();
      expect(harness.partialTranscripts, hasLength(1));
      expect(harness.partialTranscripts.single.segmentId, 'segment-1');
      expect(harness.partialTranscripts.single.transcript, 'uh hello');
    });

    test('ignores empty, final, and VAD-only partial candidates', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.sttSessions.single
        ..emitTranscript(_transcript('', isFinal: false))
        ..emitTranscript(_transcript('   ', isFinal: false))
        ..emitTranscript(_transcript('ignored final', isFinal: true));
      await harness.settle();
      expect(harness.partialTranscripts, isEmpty);
    });

    test('commits on speech stop and assembles final metadata', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      expect(harness.sttSessions.single.commitCount, 1);

      harness.sttSessions.single
        ..emitCommitted('segment-1')
        ..emitTranscript(
          StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: '  hello there  ',
            isFinal: true,
            language: 'en',
            avgLogprob: -0.2,
            isLowConfidence: false,
          ),
        );
      await harness.settle();
      expect(harness.finalTranscripts, hasLength(1));
      final finalTranscript = harness.finalTranscripts.single;
      expect(finalTranscript.segmentId, 'segment-1');
      expect(finalTranscript.transcript, 'hello there');
      expect(finalTranscript.language, 'en');
      expect(finalTranscript.avgLogprob, -0.2);
      expect(finalTranscript.isLowConfidence, isNull);
      expect(finalTranscript.durationMs, 250);
    });

    test('assembles multiple finals in commit order', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single
        ..emitCommitted('segment-1')
        ..emitCommitted('segment-2', previousSegmentId: 'segment-1')
        ..emitTranscript(
          _transcript(' world ', segmentId: 'segment-2', isFinal: true),
        )
        ..emitTranscript(_transcript(' hello ', isFinal: true));
      await harness.settle();
      expect(harness.finalTranscripts.single.segmentId, 'segment-1');
      expect(harness.finalTranscripts.single.transcript, 'hello world');
    });

    test('timeout uses arrived finals and excludes stale segments', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single
        ..emitTranscript(
          _transcript('stale text', segmentId: 'stale', isFinal: true),
        )
        ..emitCommitted('segment-1')
        ..emitCommitted('segment-2', previousSegmentId: 'segment-1')
        ..emitTranscript(_transcript('fresh text', isFinal: true));
      harness.timeout.fire();
      await harness.settle();
      expect(harness.finalTranscripts, hasLength(1));
      expect(harness.finalTranscripts.single.segmentId, 'segment-1');
      expect(harness.finalTranscripts.single.transcript, 'fresh text');
    });

    test('timeout emits empty final when only partial arrived', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.sttSessions.single.emitTranscript(
        _transcript('hello', isFinal: false),
      );
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single.emitCommitted('segment-1');
      harness.timeout.fire();
      await harness.settle();
      expect(harness.finalTranscripts.single.segmentId, 'segment-1');
      expect(harness.finalTranscripts.single.transcript, '');
    });

    test('reports STT errors and reconnects once per turn', () async {
      final harness = _Harness();
      await harness.controller.start();
      final first = harness.sttSessions.single;
      first.emitError(StateError('stream failed'));
      await harness.settle();
      expect(harness.errors.single, isA<StateError>());
      expect(first.closeCount, 1);
      expect(harness.sttSessions, hasLength(2));
      expect(harness.sttSessions.last.connectCount, 1);

      harness.sttSessions.last.emitError(StateError('failed again'));
      await harness.settle();
      expect(harness.errors, hasLength(2));
      expect(harness.sttSessions, hasLength(2));
      expect(harness.sttSessions.last.closeCount, 1);
    });

    test('seals a committed segment while capturing', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.sttSessions.single
        ..emitCommitted('segment-1')
        ..emitTranscript(
          _transcript('wrong segment', segmentId: 'segment-2', isFinal: false),
        );
      await harness.settle();
      expect(harness.partialTranscripts, isEmpty);
    });

    test('normalizes callback failures through the serial queue', () async {
      final harness = _Harness(throwOnSpeechStarted: true);
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      expect(harness.errors.single, isA<StateError>());
    });

    test('reports commit and append failures through STT recovery', () async {
      final commitHarness = _Harness();
      await commitHarness.controller.start();
      commitHarness.detector.emitSpeechStarted();
      await commitHarness.settle();
      commitHarness.sttSessions.single.throwOnCommit = true;
      commitHarness.detector.emitSpeechStopped();
      await commitHarness.settle();
      expect(commitHarness.errors, hasLength(1));
      expect(commitHarness.sttSessions, hasLength(2));

      final appendHarness = _Harness();
      await appendHarness.controller.start();
      appendHarness.sttSessions.single.throwOnAppend = true;
      await appendHarness.append([1, 2]);
      await appendHarness.settle();
      expect(appendHarness.errors, hasLength(1));
      expect(appendHarness.sttSessions, hasLength(2));
    });

    test('reports a failed STT reconnect', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.failNextSttConnect = true;
      harness.sttSessions.single.emitError(StateError('stream failed'));
      await harness.settle();
      expect(harness.errors, hasLength(2));
      expect(harness.sttSessions, hasLength(2));
      expect(harness.sttSessions.last.closeCount, 0);
    });

    test(
      'timeout accepts an uncommitted final and falls back to turn id',
      () async {
        final finalHarness = _Harness();
        await finalHarness.controller.start();
        finalHarness.detector.emitSpeechStarted();
        await finalHarness.settle();
        finalHarness.detector.emitSpeechStopped();
        await finalHarness.settle();
        finalHarness.sttSessions.single.emitTranscript(
          _transcript('uncommitted', isFinal: true),
        );
        finalHarness.timeout.fire();
        await finalHarness.settle();
        expect(finalHarness.finalTranscripts.single.segmentId, 'segment-1');
        expect(finalHarness.finalTranscripts.single.transcript, 'uncommitted');

        final emptyHarness = _Harness();
        await emptyHarness.controller.start();
        emptyHarness.detector.emitSpeechStarted();
        await emptyHarness.settle();
        emptyHarness.detector.emitSpeechStopped();
        await emptyHarness.settle();
        emptyHarness.timeout.fire();
        await emptyHarness.settle();
        expect(emptyHarness.finalTranscripts.single.segmentId, 'turn-1');
        expect(emptyHarness.finalTranscripts.single.transcript, '');
      },
    );

    test('resamples detector and STT independently', () async {
      final harness = _Harness(detectorSampleRate: 16000, sttSampleRate: 8000);
      await harness.controller.start();
      await harness.append(
        List<int>.generate(320, (index) => index.isEven ? 1 : 0),
        rate: 32000,
      );
      expect(harness.detector.appendedChunks.single.length, greaterThan(100));
      expect(
        harness.sttSessions.single.appendedChunks.single.length,
        lessThan(harness.detector.appendedChunks.single.length),
      );
    });

    test('stop cancels finalization and ignores later audio', () async {
      final harness = _Harness();
      await harness.controller.start();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      await harness.controller.stop();
      expect(harness.timeout.cancelled, isTrue);
      await harness.append([1, 2]);
      expect(harness.detector.appendedChunks, isEmpty);
      expect(harness.detector.closeCount, 1);
      expect(harness.sttSessions.single.closeCount, 1);
    });
  });
}

StreamingTranscriptionEvent _transcript(
  String transcript, {
  String segmentId = 'segment-1',
  required bool isFinal,
}) {
  return StreamingTranscriptionEvent(
    segmentId: segmentId,
    transcript: transcript,
    isFinal: isFinal,
  );
}

final class _Harness {
  _Harness({
    String? sttLanguage,
    int detectorSampleRate = 16000,
    int sttSampleRate = 16000,
    this.throwOnSpeechStarted = false,
  }) : detector = _FakeDetector(detectorSampleRate),
       _sttSampleRate = sttSampleRate {
    final clockValues = [
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2026, 1, 1, 0, 0, 0, 250),
      DateTime.utc(2026, 1, 1, 0, 0, 0, 250),
    ];
    var clockIndex = 0;
    controller = createVoiceTurnController(
      logger: const NullSpeechLogger(),
      turnDetection: _FakeDetectorProvider(detector),
      stt: _FakeSttProvider(this),
      sttLanguage: sttLanguage,
      callbacks: VoiceTurnControllerCallbacks(
        onSpeechStarted: () async {
          if (throwOnSpeechStarted) {
            throw StateError('speech-start callback failed');
          }
          speechStartedCount += 1;
        },
        onSpeechStopped: () async => speechStoppedCount += 1,
        onPartialTranscript: (value) async => partialTranscripts.add(value),
        onFinalTranscript: (value) async => finalTranscripts.add(value),
        onError: errors.add,
      ),
      now: () {
        final value = clockValues[clockIndex.clamp(0, clockValues.length - 1)];
        clockIndex += 1;
        return value;
      },
      createTurnId: () => 'turn-1',
      scheduleTimeout: (delay, callback) {
        expect(delay, voiceFinalTranscriptTimeout);
        timeout = _ManualTimeout(callback);
        return timeout;
      },
    );
  }

  final _FakeDetector detector;
  final int _sttSampleRate;
  final bool throwOnSpeechStarted;
  late final VoiceTurnController controller;
  final List<_FakeSttSession> sttSessions = [];
  final List<VoicePartialTranscript> partialTranscripts = [];
  final List<VoiceFinalTranscript> finalTranscripts = [];
  final List<Object> errors = [];
  late _ManualTimeout timeout;
  String? lastSttLanguage;
  int speechStartedCount = 0;
  int speechStoppedCount = 0;
  bool failNextSttConnect = false;

  Future<void> append(List<int> bytes, {int rate = 16000}) {
    return controller.appendClientChunk(
      audioBase64: base64Encode(bytes),
      format: 'audio/pcm;rate=$rate;bits=16',
    );
  }

  Future<void> settle() async {
    for (var index = 0; index < 6; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

final class _FakeDetectorProvider implements TurnDetectionProvider {
  const _FakeDetectorProvider(this.session);
  final _FakeDetector session;
  @override
  String get id => 'local';
  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) => session;
}

final class _FakeDetector implements TurnDetectionSession {
  _FakeDetector(this.requiredSampleRate);

  @override
  final int requiredSampleRate;
  final started = StreamController<void>.broadcast(sync: true);
  final stopped = StreamController<void>.broadcast(sync: true);
  final errorController = StreamController<Object?>.broadcast(sync: true);
  final List<List<int>> appendedChunks = [];
  int closeCount = 0;

  void emitSpeechStarted() => started.add(null);
  void emitSpeechStopped() => stopped.add(null);
  @override
  Stream<void> get speechStartedEvents => started.stream;
  @override
  Stream<void> get speechStoppedEvents => stopped.stream;
  @override
  Stream<Object?> get errors => errorController.stream;
  @override
  Future<void> connect() async {}
  @override
  void appendPcm16(Uint8List pcm16le) =>
      appendedChunks.add(List<int>.from(pcm16le));
  @override
  void flush() {}
  @override
  void reset() {}
  @override
  void close() => closeCount += 1;
}

final class _FakeSttProvider implements SpeechToTextProvider {
  const _FakeSttProvider(this.harness);
  final _Harness harness;
  @override
  String get id => 'local';
  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) {
    harness.lastSttLanguage = parameters.language;
    final session = _FakeSttSession(harness._sttSampleRate);
    if (harness.failNextSttConnect) {
      session.throwOnConnect = true;
      harness.failNextSttConnect = false;
    }
    harness.sttSessions.add(session);
    return session;
  }
}

final class _FakeSttSession implements StreamingTranscriptionSession {
  _FakeSttSession(this.requiredSampleRate);

  @override
  final int requiredSampleRate;
  final committed =
      StreamController<StreamingTranscriptionCommittedEvent>.broadcast(
        sync: true,
      );
  final transcripts = StreamController<StreamingTranscriptionEvent>.broadcast(
    sync: true,
  );
  final errorController = StreamController<Object?>.broadcast(sync: true);
  final List<List<int>> appendedChunks = [];
  int connectCount = 0;
  int closeCount = 0;
  int commitCount = 0;
  bool throwOnConnect = false;
  bool throwOnAppend = false;
  bool throwOnCommit = false;

  void emitCommitted(String segmentId, {String? previousSegmentId}) {
    committed.add(
      StreamingTranscriptionCommittedEvent(
        segmentId: segmentId,
        previousSegmentId: previousSegmentId,
      ),
    );
  }

  void emitTranscript(StreamingTranscriptionEvent event) =>
      transcripts.add(event);
  void emitError(Object error) => errorController.add(error);
  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      committed.stream;
  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      transcripts.stream;
  @override
  Stream<Object?> get errors => errorController.stream;
  @override
  Future<void> connect() async {
    connectCount += 1;
    if (throwOnConnect) throw StateError('connect failed');
  }

  @override
  void appendPcm16(List<int> pcm16le) {
    if (throwOnAppend) throw StateError('append failed');
    appendedChunks.add(List<int>.from(pcm16le));
  }

  @override
  void commit() {
    commitCount += 1;
    if (throwOnCommit) throw StateError('commit failed');
  }

  @override
  void clear() {}
  @override
  void close() => closeCount += 1;
}

final class _ManualTimeout implements VoiceTurnTimeoutHandle {
  _ManualTimeout(this.callback);
  final void Function() callback;
  bool cancelled = false;
  void fire() {
    if (!cancelled) callback();
  }

  @override
  void cancel() => cancelled = true;
}
