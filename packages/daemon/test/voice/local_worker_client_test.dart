import 'dart:async';
import 'dart:typed_data';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:test/test.dart';

void main() {
  group('LocalSpeechWorkerClient', () {
    test('lazily starts once and returns TTS bytes from the worker', () async {
      final fixture = _Fixture();
      final provider = WorkerBackedTextToSpeechProvider(fixture.client);
      expect(fixture.workers, isEmpty);
      expect(fixture.client.hasWorker, isFalse);

      final pending = provider.synthesizeSpeech('hello');
      await fixture.pump();
      expect(fixture.workers, hasLength(1));
      expect(fixture.client.hasWorker, isTrue);
      final request = fixture.worker.sent.single;
      expect(request, isA<LocalSpeechTtsSynthesizeRequest>());
      expect((request as LocalSpeechTtsSynthesizeRequest).text, 'hello');
      fixture.worker.respond(
        request,
        LocalSpeechTtsResult(
          audio: Uint8List.fromList([1, 2, 3, 4]),
          format: 'pcm;rate=24000',
        ).toJson(),
      );

      final result = await pending;
      expect(await result.stream.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(result.format, 'pcm;rate=24000');
      await fixture.close();
    });

    test('forwards STT session commands and typed transcript events', () async {
      final fixture = _Fixture();
      final provider = WorkerBackedSpeechToTextProvider(
        fixture.client,
        LocalSpeechSessionKind.voiceStt,
      );
      final session = provider.createSession(
        const SpeechSessionParameters(logger: NullSpeechLogger()),
      );
      expect(provider.id, 'local');
      expect(session.requiredSampleRate, defaultLocalSpeechSampleRate);

      final firstConnect = session.connect();
      final secondConnect = session.connect();
      await fixture.pump();
      final create = fixture.worker.sent.single;
      expect(create, isA<LocalSpeechSessionCreateRequest>());
      expect(
        (create as LocalSpeechSessionCreateRequest).kind,
        LocalSpeechSessionKind.voiceStt,
      );
      fixture.worker.respond(
        create,
        const LocalSpeechCreateSessionResult(
          requiredSampleRate: 22050,
        ).toJson(),
      );
      await Future.wait([firstConnect, secondConnect]);
      expect(session.requiredSampleRate, 22050);
      expect(
        fixture.worker.sent.whereType<LocalSpeechSessionCreateRequest>(),
        hasLength(1),
      );

      session.appendPcm16([9, 8, 7, 6]);
      session.commit();
      await fixture.pump();
      final append = fixture.worker.sent
          .whereType<LocalSpeechSessionAppendRequest>()
          .single;
      expect(append.audio, [9, 8, 7, 6]);
      final commit = fixture.worker.sent
          .whereType<LocalSpeechSessionCommandRequest>()
          .singleWhere((request) => request.type == 'session.commit');
      fixture.worker.respond(append);
      fixture.worker.respond(commit);

      final committed = session.committedEvents.first;
      final transcript = session.transcriptEvents.first;
      fixture.worker.emitMessage(
        LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.committed,
          sessionId: create.sessionId,
          payload: const StreamingTranscriptionCommittedEvent(
            segmentId: 'seg-1',
            previousSegmentId: null,
          ).toJson(),
        ),
      );
      fixture.worker.emitMessage(
        LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.transcript,
          sessionId: create.sessionId,
          payload: const StreamingTranscriptionEvent(
            segmentId: 'seg-1',
            transcript: 'hello',
            isFinal: true,
          ).toJson(),
        ),
      );
      expect((await committed).segmentId, 'seg-1');
      expect((await transcript).transcript, 'hello');

      session.clear();
      session.close();
      await fixture.pump();
      for (final command
          in fixture.worker.sent
              .whereType<LocalSpeechSessionCommandRequest>()
              .where(
                (request) =>
                    request.type == 'session.clear' ||
                    request.type == 'session.close',
              )) {
        fixture.worker.respond(command);
      }
      await fixture.close();
    });

    test('forwards VAD events, audio, flush, reset, and close', () async {
      final fixture = _Fixture();
      final provider = WorkerBackedTurnDetectionProvider(fixture.client);
      final session = provider.createSession(
        const TurnDetectionSessionParameters(logger: NullSpeechLogger()),
      );
      expect(provider.id, 'local');

      final connect = session.connect();
      await fixture.pump();
      final create =
          fixture.worker.sent.single as LocalSpeechSessionCreateRequest;
      expect(create.kind, LocalSpeechSessionKind.vad);
      fixture.worker.respond(
        create,
        const LocalSpeechCreateSessionResult(
          requiredSampleRate: 16000,
        ).toJson(),
      );
      await connect;
      expect(session.requiredSampleRate, 16000);

      final started = session.speechStartedEvents.first;
      final stopped = session.speechStoppedEvents.first;
      fixture.worker
        ..emitMessage(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.speechStarted,
            sessionId: create.sessionId,
          ),
        )
        ..emitMessage(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.speechStopped,
            sessionId: create.sessionId,
          ),
        );
      await Future.wait([started, stopped]);

      session.appendPcm16(Uint8List.fromList([1, 2]));
      session.flush();
      session.reset();
      session.close();
      await fixture.pump();
      expect(
        fixture.worker.sent.whereType<LocalSpeechSessionAppendRequest>(),
        hasLength(1),
      );
      expect(
        fixture.worker.sent.whereType<LocalSpeechSessionCommandRequest>().map(
          (request) => request.type,
        ),
        containsAll(['session.flush', 'session.reset', 'session.close']),
      );
      for (final request in fixture.worker.sent.skip(1)) {
        fixture.worker.respond(request);
      }
      await fixture.close();
    });

    test('reports not-connected use and worker session errors', () async {
      final fixture = _Fixture();
      final stt =
          WorkerBackedSpeechToTextProvider(
            fixture.client,
            LocalSpeechSessionKind.dictationStt,
          ).createSession(
            const SpeechSessionParameters(logger: NullSpeechLogger()),
          );
      final vad = WorkerBackedTurnDetectionProvider(fixture.client)
          .createSession(
            const TurnDetectionSessionParameters(logger: NullSpeechLogger()),
          );

      final sttErrors = <Object?>[];
      final vadErrors = <Object?>[];
      final sttSubscription = stt.errors.listen(sttErrors.add);
      final vadSubscription = vad.errors.listen(vadErrors.add);
      stt
        ..appendPcm16([1, 2])
        ..commit();
      vad.appendPcm16(Uint8List.fromList([1, 2]));
      expect(sttErrors, hasLength(2));
      expect(vadErrors, hasLength(1));

      final connect = stt.connect();
      await fixture.pump();
      final create =
          fixture.worker.sent.single as LocalSpeechSessionCreateRequest;
      fixture.worker.respond(
        create,
        const LocalSpeechCreateSessionResult(
          requiredSampleRate: 16000,
        ).toJson(),
      );
      await connect;
      fixture.worker.emitMessage(
        LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.error,
          sessionId: create.sessionId,
          error: 'native failure',
        ),
      );
      expect(sttErrors.last.toString(), contains('native failure'));
      await sttSubscription.cancel();
      await vadSubscription.cancel();
      stt.close();
      await fixture.pump();
      fixture.respondToOutstanding();
      await fixture.close();
    });

    test('supports one-shot voice transcription', () async {
      final fixture = _Fixture();
      final pending = fixture.client.transcribeVoice([1, 2, 3], 'wav');
      await fixture.pump();
      final request =
          fixture.worker.sent.single as LocalSpeechSttTranscribeRequest;
      expect(request.model, LocalSpeechTranscriptionModel.voice);
      expect(request.audio, [1, 2, 3]);
      fixture.worker.respond(
        request,
        const TranscriptionResult(
          text: 'hello',
          language: 'en',
          duration: 42,
        ).toJson(),
      );
      final result = await pending;
      expect(result.text, 'hello');
      expect(result.language, 'en');
      await fixture.close();
    });

    test('times out requests and rejects worker response failures', () async {
      final fixture = _Fixture(requestTimeout: const Duration(milliseconds: 5));
      await expectLater(
        fixture.client.synthesizeSpeech('timeout'),
        throwsA(isA<TimeoutException>()),
      );

      final failed = fixture.client.synthesizeSpeech('failure');
      await fixture.pump();
      final request = fixture.worker.sent.last;
      fixture.worker.fail(request, 'model unavailable');
      await expectLater(
        failed,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'model unavailable',
          ),
        ),
      );
      await fixture.close();
    });

    test('surfaces send and malformed result failures', () async {
      final fixture = _Fixture();
      fixture.workerOnStart = (worker) {
        worker.sendError = StateError('IPC closed');
      };
      await expectLater(
        fixture.client.synthesizeSpeech('send'),
        throwsA(isA<StateError>()),
      );

      fixture.worker.sendError = null;
      final malformed = fixture.client.synthesizeSpeech('bad result');
      await fixture.pump();
      fixture.worker.respond(fixture.worker.sent.last, {'audio': 'AQ=='});
      await expectLater(malformed, throwsFormatException);
      await fixture.close();
    });

    test('worker crash rejects pending work with stderr context', () async {
      final fixture = _Fixture();
      final errors = <Object?>[];
      final provider = WorkerBackedSpeechToTextProvider(
        fixture.client,
        LocalSpeechSessionKind.dictationStt,
      );
      final session = provider.createSession(
        const SpeechSessionParameters(logger: NullSpeechLogger()),
      );
      final subscription = session.errors.listen(errors.add);
      final connect = session.connect();
      await fixture.pump();
      final connectExpectation = expectLater(
        connect,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('signal SIGABRT'),
              contains('session.create (dictationStt)'),
              contains('libsherpa-onnx-c-api.dylib'),
            ),
          ),
        ),
      );
      fixture.worker.stderrController.add(
        'dyld: Library not loaded: libsherpa-onnx-c-api.dylib\n'.codeUnits,
      );
      await fixture.worker.crash(signal: 'SIGABRT');

      await connectExpectation;
      expect(
        fixture.logger.records.where(
          (record) => record.message == 'Local speech worker exited',
        ),
        hasLength(1),
      );
      expect(errors, hasLength(1));
      await subscription.cancel();
      await fixture.client.shutdown();
    });

    test('idle shutdown is intentional and a later request respawns', () async {
      final fixture = _Fixture(idleTtl: const Duration(milliseconds: 5));
      final first = fixture.client.synthesizeSpeech('first');
      await fixture.pump();
      fixture.worker.respond(
        fixture.worker.sent.single,
        LocalSpeechTtsResult(
          audio: Uint8List.fromList([1]),
          format: 'pcm;rate=24000',
        ).toJson(),
      );
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.workers.single.shutdownCalls, 1);

      final second = fixture.client.synthesizeSpeech('second');
      await fixture.pump();
      expect(fixture.workers, hasLength(2));
      fixture.worker.respond(
        fixture.worker.sent.single,
        LocalSpeechTtsResult(
          audio: Uint8List.fromList([2]),
          format: 'pcm;rate=24000',
        ).toJson(),
      );
      expect(await (await second).stream.first, [2]);
      expect(
        fixture.logger.records.any(
          (record) =>
              record.message == 'Local speech worker closed after shutdown',
        ),
        isTrue,
      );
      await fixture.close();
    });

    test(
      'failed session creation cleans up and allows idle shutdown',
      () async {
        final fixture = _Fixture(idleTtl: const Duration(milliseconds: 5));
        final session = WorkerBackedTurnDetectionProvider(fixture.client)
            .createSession(
              const TurnDetectionSessionParameters(logger: NullSpeechLogger()),
            );
        final connect = session.connect();
        await fixture.pump();
        fixture.worker.fail(fixture.worker.sent.single, 'VAD unavailable');
        await expectLater(connect, throwsA(isA<StateError>()));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fixture.worker.shutdownCalls, 1);
        await fixture.client.shutdown();
      },
    );
  });
}

final class _Fixture {
  _Fixture({
    Duration requestTimeout = const Duration(seconds: 1),
    Duration idleTtl = const Duration(seconds: 1),
  }) {
    client = LocalSpeechWorkerClient(
      config: const LocalSpeechWorkerConfig(
        modelsDirectory: r'C:\models',
        voiceSttModel: 'parakeet-tdt-0.6b-v2-int8',
        dictationSttModel: 'parakeet-tdt-0.6b-v2-int8',
        voiceTtsModel: 'kokoro-en-v0_19',
      ),
      requestTimeout: requestTimeout,
      idleTtl: idleTtl,
      logger: logger,
      startWorker: () {
        final worker = _FakeWorker();
        workers.add(worker);
        workerOnStart?.call(worker);
        return worker;
      },
    );
  }

  late final LocalSpeechWorkerClient client;
  final _CapturingLogger logger = _CapturingLogger.root();
  final List<_FakeWorker> workers = [];
  void Function(_FakeWorker worker)? workerOnStart;

  _FakeWorker get worker => workers.last;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  void respondToOutstanding() {
    for (final request in worker.sent) {
      if (!worker.responded.contains(request.requestId)) {
        worker.respond(request);
      }
    }
  }

  Future<void> close() async {
    respondToOutstanding();
    await pump();
    await client.shutdown();
  }
}

final class _FakeWorker implements LocalSpeechWorkerTransport {
  final StreamController<LocalSpeechWorkerMessage> messageController =
      StreamController.broadcast(sync: true);
  final StreamController<List<int>> stderrController =
      StreamController.broadcast(sync: true);
  final Completer<LocalSpeechWorkerExit> exitCompleter = Completer();
  final List<LocalSpeechWorkerRequest> sent = [];
  final Set<String> responded = {};
  Object? sendError;
  int shutdownCalls = 0;
  bool _connected = true;
  bool _killed = false;

  @override
  int get pid => 12345;

  @override
  bool get connected => _connected;

  @override
  bool get killed => _killed;

  @override
  Stream<LocalSpeechWorkerMessage> get messages => messageController.stream;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  Future<LocalSpeechWorkerExit> get exited => exitCompleter.future;

  @override
  Future<void> send(LocalSpeechWorkerRequest request) async {
    sent.add(request);
    final error = sendError;
    if (error != null) throw error;
  }

  void respond(LocalSpeechWorkerRequest request, [Object? result]) {
    responded.add(request.requestId);
    emitMessage(
      LocalSpeechWorkerResponse.success(
        requestId: request.requestId,
        result: result,
      ),
    );
  }

  void fail(LocalSpeechWorkerRequest request, String error) {
    responded.add(request.requestId);
    emitMessage(
      LocalSpeechWorkerResponse.failure(
        requestId: request.requestId,
        error: error,
      ),
    );
  }

  void emitMessage(LocalSpeechWorkerMessage message) =>
      messageController.add(message);

  Future<void> crash({int? exitCode, String? signal}) async {
    _connected = false;
    _killed = true;
    exitCompleter.complete(
      LocalSpeechWorkerExit(exitCode: exitCode, signal: signal),
    );
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    _connected = false;
    _killed = true;
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(const LocalSpeechWorkerExit(signal: 'SIGTERM'));
    }
  }
}

final class _LogRecord {
  const _LogRecord(this.level, this.message, this.fields);

  final String level;
  final String message;
  final Map<String, Object?> fields;
}

final class _CapturingLogger implements SpeechLogger {
  _CapturingLogger._(this.records, this.context);

  factory _CapturingLogger.root() => _CapturingLogger._([], const {});

  final List<_LogRecord> records;
  final Map<String, Object?> context;

  @override
  SpeechLogger child(Map<String, Object?> context) =>
      _CapturingLogger._(records, {...this.context, ...context});

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) =>
      records.add(_LogRecord('debug', message, {...context, ...fields}));

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      records.add(_LogRecord('info', message, {...context, ...fields}));

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) =>
      records.add(_LogRecord('warning', message, {...context, ...fields}));

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) =>
      records.add(_LogRecord('error', message, {...context, ...fields}));
}

final Matcher throwsFormatException = throwsA(isA<FormatException>());
