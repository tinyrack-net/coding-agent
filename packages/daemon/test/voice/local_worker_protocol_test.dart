import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:test/test.dart';

void main() {
  const config = LocalSpeechWorkerConfig(
    modelsDirectory: r'C:\models',
    voiceSttModel: 'parakeet-tdt-0.6b-v2-int8',
    dictationSttModel: 'parakeet-tdt-0.6b-v3-int8',
    voiceTtsModel: 'kokoro-en-v0_19',
    voiceTtsSpeakerId: 2,
    voiceTtsSpeed: 1.25,
  );

  test('worker bytes detach views and JSON round-trip exactly', () {
    final source = Uint8List.fromList([0, 1, 2, 3, 4]);
    final view = Uint8List.sublistView(source, 1, 5);
    final detached = bufferToWorkerBytes(view);
    source[2] = 99;

    expect(detached, [1, 2, 3, 4]);
    expect(workerBytesToBuffer(detached), [1, 2, 3, 4]);
    expect(workerBytesFromJson(workerBytesToJson(detached)), detached);
    expect(() => workerBytesFromJson(42), throwsA(isA<FormatException>()));
    expect(() => workerBytesFromJson('***'), throwsA(isA<FormatException>()));
  });

  test('worker config preserves frozen wire names and optional tuning', () {
    expect(LocalSpeechWorkerConfig.fromJson(config.toJson()).toJson(), {
      'modelsDir': r'C:\models',
      'voiceSttModel': 'parakeet-tdt-0.6b-v2-int8',
      'dictationSttModel': 'parakeet-tdt-0.6b-v3-int8',
      'voiceTtsModel': 'kokoro-en-v0_19',
      'voiceTtsSpeakerId': 2,
      'voiceTtsSpeed': 1.25,
    });
    expect(
      () => LocalSpeechWorkerConfig.fromJson({
        ...config.toJson(),
        'voiceTtsSpeed': 'fast',
      }),
      throwsFormatException,
    );
  });

  test(
    'every worker request serializes and parses as a discriminated union',
    () {
      final requests = <LocalSpeechWorkerRequest>[
        const LocalSpeechTtsSynthesizeRequest(
          requestId: 'r1',
          config: config,
          text: 'hello',
        ),
        LocalSpeechSttTranscribeRequest(
          requestId: 'r2',
          config: config,
          model: LocalSpeechTranscriptionModel.dictation,
          audio: Uint8List.fromList([1, 2, 3]),
          format: 'wav',
        ),
        const LocalSpeechSessionCreateRequest(
          requestId: 'r3',
          config: config,
          sessionId: 's1',
          kind: LocalSpeechSessionKind.voiceStt,
        ),
        LocalSpeechSessionAppendRequest(
          requestId: 'r4',
          sessionId: 's1',
          audio: Uint8List.fromList([4, 5]),
        ),
        for (final type in localSpeechSessionCommandTypes)
          LocalSpeechSessionCommandRequest(
            requestId: 'r-$type',
            sessionId: 's1',
            type: type,
          ),
      ];

      for (final request in requests) {
        final json = request.toJson();
        final decoded = LocalSpeechWorkerRequest.fromJson(
          Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map),
        );
        expect(decoded.runtimeType, request.runtimeType);
        expect(decoded.toJson(), json);
        expect(decoded.summary, request.summary);
      }

      expect(
        () => LocalSpeechSessionCommandRequest(
          requestId: 'bad',
          sessionId: 's1',
          type: 'session.nope',
        ),
        throwsArgumentError,
      );
      expect(
        () => LocalSpeechWorkerRequest.fromJson({
          'type': 'unknown',
          'requestId': 'r',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'worker responses and all event variants round-trip with validation',
    () {
      final messages = <LocalSpeechWorkerMessage>[
        LocalSpeechWorkerResponse.success(
          requestId: 'r1',
          result: const LocalSpeechCreateSessionResult(
            requiredSampleRate: 16000,
          ).toJson(),
        ),
        LocalSpeechWorkerResponse.failure(requestId: 'r2', error: 'boom'),
        LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.committed,
          sessionId: 's1',
          payload: const StreamingTranscriptionCommittedEvent(
            segmentId: 'seg-1',
            previousSegmentId: null,
          ).toJson(),
        ),
        LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.transcript,
          sessionId: 's1',
          payload: const StreamingTranscriptionEvent(
            segmentId: 'seg-1',
            transcript: 'hello',
            isFinal: true,
          ).toJson(),
        ),
        const LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.speechStarted,
          sessionId: 's1',
        ),
        const LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.speechStopped,
          sessionId: 's1',
        ),
        const LocalSpeechWorkerEvent(
          eventType: LocalSpeechWorkerEventType.error,
          sessionId: 's1',
          error: 'bad audio',
        ),
      ];

      for (final message in messages) {
        final json = message.toJson();
        final decoded = LocalSpeechWorkerMessage.fromJson(
          Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map),
        );
        expect(decoded.runtimeType, message.runtimeType);
        expect(decoded.toJson(), json);
      }

      expect(
        () => LocalSpeechWorkerMessage.fromJson({
          'type': 'response',
          'requestId': 'r1',
          'ok': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => LocalSpeechWorkerMessage.fromJson({
          'type': 'session.error',
          'sessionId': 's1',
        }),
        throwsFormatException,
      );
      expect(
        () => LocalSpeechWorkerMessage.fromJson({
          'type': 'session.transcript',
          'sessionId': 's1',
          'payload': {'transcript': 'missing fields'},
        }),
        throwsFormatException,
      );
    },
  );

  test('typed worker results reject malformed boundaries', () {
    final tts = LocalSpeechTtsResult(
      audio: Uint8List.fromList([1, 2, 3]),
      format: 'pcm;rate=24000',
    );
    expect(LocalSpeechTtsResult.fromJson(tts.toJson()).audio, [1, 2, 3]);
    expect(
      () => LocalSpeechTtsResult.fromJson({'audio': 'AQI='}),
      throwsFormatException,
    );
    expect(
      () => LocalSpeechCreateSessionResult.fromJson({
        'requiredSampleRate': '16000',
      }),
      throwsFormatException,
    );
  });
}

final Matcher throwsFormatException = throwsA(isA<FormatException>());
