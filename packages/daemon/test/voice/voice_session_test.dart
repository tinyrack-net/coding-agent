import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/speech_readiness.dart';
import 'package:agent_daemon/src/voice/tts_debug.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:agent_daemon/src/voice/voice_bridge_registry.dart';
import 'package:agent_daemon/src/voice/voice_session.dart';
import 'package:agent_daemon/src/voice/voice_turn_controller.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const voiceAgentId = '11111111-1111-4111-8111-111111111111';
const otherAgentId = '22222222-2222-4222-8222-222222222222';

void main() {
  group('voice session mode lifecycle', () {
    test(
      'enables existing agent, installs bridge, and emits response',
      () async {
        final harness = _Harness();
        await harness.session.handleSetVoiceMode(
          true,
          agentId: voiceAgentId,
          requestId: 'request-1',
        );

        expect(harness.session.isActiveForAgent(voiceAgentId), isTrue);
        expect(harness.host.loadedIds, [voiceAgentId]);
        expect(harness.host.reloads, hasLength(1));
        expect(
          harness.host.reloads.single.systemPrompt,
          contains('<paseo_voice_mode>'),
        );
        expect(harness.bridge.resolveSpeakHandler(voiceAgentId), isNotNull);
        final caller = harness.bridge.resolveCallerContext(voiceAgentId)!;
        expect(caller.allowCustomCwd, isFalse);
        expect(caller.enableVoiceTools, isTrue);
        expect(_payload(harness.host.emitted, 'set_voice_mode_response'), {
          'requestId': 'request-1',
          'enabled': true,
          'agentId': voiceAgentId,
          'accepted': true,
          'error': null,
        });
      },
    );

    test('rejects invalid target with response or thrown error', () async {
      final harness = _Harness();
      await harness.session.handleSetVoiceMode(
        true,
        agentId: 'not-a-guid',
        requestId: 'request-1',
      );
      expect(
        _payload(harness.host.emitted, 'set_voice_mode_response'),
        containsPair('accepted', false),
      );
      expect(
        _payload(harness.host.emitted, 'set_voice_mode_response')['error'],
        'set_voice_mode: agentId must be a UUID',
      );

      await expectLater(
        harness.session.handleSetVoiceMode(true, agentId: 'bad'),
        throwsFormatException,
      );
    });

    test('switches agents and restores disabled system prompts', () async {
      final harness = _Harness(baseSystemPrompt: 'Base prompt');
      await harness.session.handleSetVoiceMode(true, agentId: voiceAgentId);
      await harness.session.handleSetVoiceMode(true, agentId: otherAgentId);
      expect(harness.session.isActiveForAgent(otherAgentId), isTrue);
      expect(harness.bridge.resolveSpeakHandler(voiceAgentId), isNull);
      expect(
        harness.host.reloads[1].systemPrompt,
        contains('voice mode is now off'),
      );

      await harness.session.handleSetVoiceMode(false, requestId: 'disable');
      expect(harness.session.isActiveForAgent(otherAgentId), isFalse);
      expect(harness.bridge.resolveSpeakHandler(otherAgentId), isNull);
      expect(
        _payload(harness.host.emitted, 'set_voice_mode_response'),
        containsPair('requestId', 'disable'),
      );
    });

    test(
      'returns readiness metadata for unavailable voice and dictation',
      () async {
        final unavailable = _readiness(
          realtime: const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'models_missing',
            message: 'Voice models are missing',
            retryable: true,
            missingModelIds: ['vad', 'stt'],
          ),
          dictation: const SpeechReadinessState(
            enabled: false,
            available: false,
            reasonCode: 'disabled',
            message: 'Dictation disabled',
            retryable: false,
          ),
        );
        final harness = _Harness(readiness: unavailable);
        await harness.session.handleSetVoiceMode(
          true,
          agentId: voiceAgentId,
          requestId: 'voice',
        );
        expect(_payload(harness.host.emitted, 'set_voice_mode_response'), {
          'requestId': 'voice',
          'enabled': false,
          'agentId': null,
          'accepted': false,
          'error': 'Voice models are missing',
          'reasonCode': 'models_missing',
          'retryable': true,
          'missingModelIds': ['vad', 'stt'],
        });
        expect(
          VoiceFeatureUnavailableException(
            reasonCode: 'models_missing',
            message: 'Voice models are missing',
            retryable: true,
            missingModelIds: const ['vad', 'stt'],
          ).toString(),
          'Voice models are missing',
        );

        await harness.session.handleDictationStreamStart(
          const DictationStreamStartMessage(
            dictationId: 'd1',
            format: 'audio/pcm;rate=16000;bits=16',
          ),
        );
        expect(_payload(harness.host.emitted, 'dictation_stream_error'), {
          'dictationId': 'd1',
          'error': 'Dictation disabled',
          'retryable': false,
          'reasonCode': 'disabled',
          'missingModelIds': <String>[],
        });
      },
    );

    test('surfaces missing turn detection and STT configuration', () async {
      final noDetector = _Harness(detectorAvailable: false);
      await noDetector.session.handleSetVoiceMode(
        true,
        agentId: voiceAgentId,
        requestId: 'detector',
      );
      expect(
        _payload(noDetector.host.emitted, 'set_voice_mode_response')['error'],
        'Voice turn detection is not configured',
      );

      final noStt = _Harness(sttAvailable: false);
      await noStt.session.handleSetVoiceMode(
        true,
        agentId: voiceAgentId,
        requestId: 'stt',
      );
      expect(
        _payload(noStt.host.emitted, 'set_voice_mode_response')['error'],
        'Voice speech-to-text is not configured',
      );
    });

    test('cleans bridge registration when agent reload fails', () async {
      final harness = _Harness();
      harness.host.reloadError = StateError('reload failed');
      await harness.session.handleSetVoiceMode(
        true,
        agentId: voiceAgentId,
        requestId: 'reload',
      );
      expect(harness.bridge.resolveSpeakHandler(voiceAgentId), isNull);
      expect(harness.bridge.resolveCallerContext(voiceAgentId), isNull);
      expect(
        _payload(harness.host.emitted, 'set_voice_mode_response')['error'],
        'reload failed',
      );
    });

    test('disable tolerates agent config restoration failure', () async {
      final harness = _Harness(baseSystemPrompt: 'Base');
      await harness.enableVoice();
      harness.host.reloadError = StateError('restore failed');
      await harness.session.handleSetVoiceMode(false);
      expect(harness.session.isActiveForAgent(voiceAgentId), isFalse);
      expect(harness.bridge.resolveSpeakHandler(voiceAgentId), isNull);
    });

    test('voice feature readiness gates otherwise-ready mode', () async {
      final harness = _Harness(
        readiness: SpeechReadinessSnapshot(
          generatedAt: '2026-07-29T00:00:00Z',
          realtimeVoice: _readyState,
          dictation: _readyState,
          voiceFeature: const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'model_download_in_progress',
            message: 'Downloading voice models',
            retryable: true,
            missingModelIds: ['tts'],
          ),
        ),
      );
      await harness.session.handleSetVoiceMode(
        true,
        agentId: voiceAgentId,
        requestId: 'readiness',
      );
      expect(
        _payload(harness.host.emitted, 'set_voice_mode_response')['reasonCode'],
        'model_download_in_progress',
      );
    });
  });

  group('voice session streaming transcription', () {
    test('delivers final transcript to agent exactly once', () async {
      final harness = _Harness();
      await harness.enableVoice();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.sttSessions.single.emitTranscript(
        const StreamingTranscriptionEvent(
          segmentId: 'segment-1',
          transcript: 'ship the streaming final',
          isFinal: false,
        ),
      );
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single
        ..emitCommitted('segment-1')
        ..emitTranscript(
          const StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: 'ship the streaming final',
            isFinal: true,
            language: 'en',
            avgLogprob: -0.1,
            isLowConfidence: false,
          ),
        );
      await harness.settle();

      expect(harness.sttSessions.single.commitCalls, 1);
      expect(harness.host.spokenInput, [
        (agentId: voiceAgentId, text: 'ship the streaming final'),
      ]);
      expect(
        _payload(harness.host.emitted, 'transcription_result'),
        containsPair('text', 'ship the streaming final'),
      );
      expect(_voiceStates(harness.host.emitted), [true, false]);
    });

    test('empty timeout final is emitted without agent submission', () async {
      final harness = _Harness();
      await harness.enableVoice();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single.emitCommitted('segment-1');
      harness.turnTimeout.fire();
      await harness.settle();

      expect(harness.host.spokenInput, isEmpty);
      expect(
        _payload(harness.host.emitted, 'transcription_result')['text'],
        '',
      );
    });

    test('filters low-confidence final without submission', () async {
      final harness = _Harness();
      await harness.enableVoice();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.detector.emitSpeechStopped();
      await harness.settle();
      harness.sttSessions.single
        ..emitCommitted('segment-1')
        ..emitTranscript(
          const StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: 'background noise',
            isFinal: true,
            avgLogprob: -2.5,
            isLowConfidence: true,
          ),
        );
      await harness.settle();
      expect(harness.host.spokenInput, isEmpty);
      expect(
        _payload(harness.host.emitted, 'transcription_result'),
        containsPair('isLowConfidence', true),
      );
      expect(
        _payload(harness.host.emitted, 'transcription_result')['text'],
        '',
      );
    });

    test('barge-in interruption failure is emitted and propagated', () async {
      final harness = _Harness();
      harness.host.interruptError = StateError(
        'active run cancellation was not acknowledged',
      );
      await harness.enableVoice();

      await expectLater(harness.session.handleAbort(), throwsStateError);
      expect(
        _payload(harness.host.emitted, 'activity_log')['content'],
        'Voice interruption failed: active run cancellation was not acknowledged',
      );
      expect(_payload(harness.host.emitted, 'activity_log')['metadata'], {
        'voiceAbortFailed': true,
      });
    });

    test('duplicate partials trigger one barge-in interruption', () async {
      final harness = _Harness();
      await harness.enableVoice();
      harness.detector.emitSpeechStarted();
      await harness.settle();
      harness.sttSessions.single
        ..emitTranscript(
          const StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: 'hello',
            isFinal: false,
          ),
        )
        ..emitTranscript(
          const StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: 'hello again',
            isFinal: false,
          ),
        );
      await harness.settle();
      expect(harness.host.interruptedIds, [voiceAgentId]);
      expect(_voiceStates(harness.host.emitted), [true]);
    });

    test(
      'voice chunks are forwarded and controller errors are contained',
      () async {
        final harness = _Harness();
        await harness.enableVoice();
        await harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 20)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: false,
          ),
        );
        expect(harness.detector.appendedBytes, greaterThan(0));
        harness.detector.emitError(StateError('vad failed'));
        await harness.settle();
        expect(harness.session.isActiveForAgent(voiceAgentId), isTrue);
      },
    );
  });

  group('voice bridge and non-voice audio', () {
    test(
      'speak bridge emits audio and assistant activity after playback',
      () async {
        final harness = _Harness(ttsAvailable: true);
        await harness.enableVoice();
        final handler = harness.bridge.resolveSpeakHandler(voiceAgentId)!;
        final task = handler(text: 'Hello aloud', callerAgentId: voiceAgentId);
        await harness.waitForMessage('audio_output');
        final audio = _payload(harness.host.emitted, 'audio_output');
        harness.session.handleAudioPlayed(audio['id']! as String);
        await task;
        expect(base64Decode(audio['audio']! as String), [1, 2, 3]);
        expect(
          harness.host.emitted
              .where((message) => message['type'] == 'activity_log')
              .map((message) => (message['payload']! as Map)['content']),
          contains('Hello aloud'),
        );
      },
    );

    test(
      'non-voice PCM is wrapped as WAV and transcribed only to client',
      () async {
        final harness = _Harness(autoFinalizeBatchStt: true);
        await harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 100)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: true,
          ),
        );
        await harness.settle();
        expect(
          _payload(harness.host.emitted, 'transcription_result')['text'],
          'batch transcript',
        );
        expect(harness.host.spokenInput, isEmpty);
        final batchSession = harness.sttSessions.single;
        expect(
          String.fromCharCodes(batchSession.appended.single.take(4)),
          isNot('RIFF'),
        );
      },
    );

    test('dictation messages delegate through the stream manager', () async {
      final harness = _Harness();
      await harness.session.handleDictationStreamStart(
        const DictationStreamStartMessage(
          dictationId: 'd1',
          format: 'audio/pcm;rate=16000;bits=16',
        ),
      );
      await harness.session.handleDictationChunk(
        DictationStreamChunkMessage(
          dictationId: 'd1',
          seq: 0,
          audio: base64Encode(_pcm(1000, 100)),
          format: 'audio/pcm;rate=16000;bits=16',
        ),
      );
      await harness.session.handleDictationFinish(
        const DictationStreamFinishMessage(dictationId: 'd1', finalSeq: 0),
      );
      final dictationSession = harness.sttSessions.single;
      dictationSession
        ..emitCommitted('segment-1')
        ..emitTranscript(
          const StreamingTranscriptionEvent(
            segmentId: 'segment-1',
            transcript: 'dictated text',
            isFinal: true,
          ),
        );
      await harness.settle();
      expect(
        _payload(harness.host.emitted, 'dictation_stream_final')['text'],
        'dictated text',
      );
      harness.session.handleDictationCancel(
        const DictationStreamCancelMessage(dictationId: 'd1'),
      );
    });

    test('format changes flush PCM and process non-PCM audio', () async {
      final harness = _Harness(autoFinalizeBatchStt: true);
      await harness.session.handleAudioChunk(
        VoiceAudioChunkMessage(
          audio: base64Encode(_pcm(1000, minimumStreamingSegmentBytes ~/ 2)),
          format: 'audio/pcm;rate=16000;bits=16',
          isLast: false,
        ),
      );
      final wav = _wav(_pcm(1000, 100));
      await harness.session.handleAudioChunk(
        VoiceAudioChunkMessage(
          audio: base64Encode(wav),
          format: 'audio/wav',
          isLast: true,
        ),
      );
      expect(
        harness.host.emitted.where(
          (message) => message['type'] == 'transcription_result',
        ),
        hasLength(2),
      );
      expect(harness.sttSessions, hasLength(2));
    });

    test('buffers a second segment while transcription is active', () async {
      final harness = _Harness();
      final firstTask = harness.session.handleAudioChunk(
        VoiceAudioChunkMessage(
          audio: base64Encode(_pcm(1000, 100)),
          format: 'audio/pcm;rate=16000;bits=16',
          isLast: true,
        ),
      );
      await harness.waitForSttSessions(1);
      await harness.session.handleAudioChunk(
        VoiceAudioChunkMessage(
          audio: base64Encode(_pcm(1000, 100)),
          format: 'audio/pcm;rate=16000;bits=16',
          isLast: true,
        ),
      );
      expect(harness.bufferTimeout.cancelled, isFalse);
      await harness.bufferTimeout.fire();
      expect(harness.bufferTimeout.cancelled, isFalse);

      harness.sttSessions.first.complete('first');
      await harness.waitForSttSessions(2);
      harness.sttSessions.last.complete('second');
      await firstTask;
      await harness.settle();
      final texts = harness.host.emitted
          .where((message) => message['type'] == 'transcription_result')
          .map((message) => (message['payload']! as Map)['text']);
      expect(texts, ['first', 'second']);
    });

    test(
      'system buffer timer is cancelled after pending audio flushes',
      () async {
        final harness = _Harness(
          useSystemBufferScheduler: true,
          useDefaultIdGenerator: true,
        );
        final firstTask = harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 100)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: true,
          ),
        );
        await harness.waitForSttSessions(1);
        await harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 100)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: true,
          ),
        );
        harness.sttSessions.first.complete('first');
        await harness.waitForSttSessions(2);
        harness.sttSessions.last.complete('second');
        await firstTask;
        await harness.settle();
        expect(
          harness.host.emitted.where(
            (message) => message['type'] == 'transcription_result',
          ),
          hasLength(2),
        );
      },
    );

    test('transcription errors emit activity and remain retryable', () async {
      final harness = _Harness(failSttConnect: true);
      await expectLater(
        harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 100)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: true,
          ),
        ),
        throwsStateError,
      );
      expect(
        harness.host.emitted
            .where((message) => message['type'] == 'activity_log')
            .map((message) => (message['payload']! as Map)['content']),
        contains('Transcription error: connect failed'),
      );
    });

    test('reports persisted input audio with transcription metadata', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-voice-session-stt-debug-',
      );
      try {
        final harness = _Harness(
          autoFinalizeBatchStt: true,
          sttDebugDirectory: temporary.path,
        );
        await harness.session.handleAudioChunk(
          VoiceAudioChunkMessage(
            audio: base64Encode(_pcm(1000, 100)),
            format: 'audio/pcm;rate=16000;bits=16',
            isLast: true,
          ),
        );
        final saved = harness.host.emitted
            .where((message) => message['type'] == 'activity_log')
            .map((message) => message['payload']! as Map)
            .firstWhere(
              (payload) => (payload['content']! as String).startsWith(
                'Saved input audio:',
              ),
            );
        final metadata = saved['metadata']! as Map;
        expect(
          await File(metadata['recordingPath']! as String).exists(),
          isTrue,
        );
        expect(metadata['format'], 'audio/wav');
        expect(metadata['requestId'], 'id-1');
      } finally {
        await temporary.delete(recursive: true);
      }
    });

    test('cleanup unregisters bridge and restores agent config', () async {
      final harness = _Harness(baseSystemPrompt: 'Base');
      await harness.enableVoice();
      await harness.session.cleanup();
      expect(harness.bridge.resolveSpeakHandler(voiceAgentId), isNull);
      expect(harness.detector.closed, isTrue);
      expect(harness.sttSessions.single.closed, isTrue);
      expect(
        harness.host.reloads.last.systemPrompt,
        contains('voice mode is now off'),
      );
    });

    test('cleanup is safe before voice mode is enabled', () async {
      final harness = _Harness();
      await harness.session.cleanup();
      expect(harness.host.reloads, isEmpty);
    });

    test(
      'captures emitted TTS groups without delaying live playback',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'tinyrack-voice-session-tts-debug-',
        );
        try {
          final harness = _Harness(
            ttsAvailable: true,
            ttsDebugAudioStore: TtsDebugAudioStore(
              environment: {'TINYRACK_TTS_DEBUG_AUDIO_DIR': temporary.path},
              cwd: temporary.path,
              now: () => DateTime.utc(2026, 7, 29),
            ),
          );
          await harness.enableVoice();
          final task = harness.bridge.resolveSpeakHandler(voiceAgentId)!(
            text: 'Captured speech',
            callerAgentId: voiceAgentId,
          );
          await harness.waitForMessage('audio_output');
          final audio = _payload(harness.host.emitted, 'audio_output');
          harness.session.handleAudioPlayed(audio['id']! as String);
          await task;
          await harness.waitForActivityPrefix('Saved TTS audio:');
          final saved = harness.host.emitted
              .where((message) => message['type'] == 'activity_log')
              .map((message) => message['payload']! as Map)
              .firstWhere(
                (payload) => (payload['content']! as String).startsWith(
                  'Saved TTS audio:',
                ),
              );
          final path = (saved['metadata']! as Map)['recordingPath']! as String;
          expect(await File(path).readAsBytes(), [1, 2, 3]);
        } finally {
          await temporary.delete(recursive: true);
        }
      },
    );
  });

  group('TTS debug store', () {
    test('persists grouped audio with frozen filename metadata', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-tts-debug-',
      );
      try {
        final store = TtsDebugAudioStore(
          environment: {'TINYRACK_TTS_DEBUG_AUDIO_DIR': temporary.path},
          cwd: temporary.path,
          now: () => DateTime.utc(2026, 7, 29, 1, 2, 3, 456),
        );
        final logger = _RecordingLogger();
        final path = await store.persist(
          Uint8List.fromList([1, 2, 3]),
          const TtsDebugAudioMetadata(
            sessionId: 'session/1',
            groupId: 'group:2',
            format: 'audio/mp3',
          ),
          logger,
        );
        expect(path, endsWith('2026-07-29T01-02-03-456Z_group_2.mp3'));
        expect(await File(path!).readAsBytes(), [1, 2, 3]);
        expect(logger.infoMessages, ['TTS audio capture enabled']);
      } finally {
        await temporary.delete(recursive: true);
      }
    });

    test('disabled store is a no-op', () async {
      final store = TtsDebugAudioStore(
        environment: const {},
        cwd: Directory.current.path,
      );
      expect(store.enabled, isFalse);
      expect(
        await store.persist(
          Uint8List(0),
          const TtsDebugAudioMetadata(
            sessionId: 's',
            groupId: 'g',
            format: 'audio/wav',
          ),
          const NullSpeechLogger(),
        ),
        isNull,
      );
    });
  });
}

final class _Harness {
  _Harness({
    this.baseSystemPrompt,
    this.readiness,
    this.detectorAvailable = true,
    this.sttAvailable = true,
    this.ttsAvailable = false,
    this.autoFinalizeBatchStt = false,
    this.failSttConnect = false,
    this.ttsDebugAudioStore,
    this.sttDebugDirectory,
    this.useSystemBufferScheduler = false,
    this.useDefaultIdGenerator = false,
  }) {
    session = VoiceSession(
      host: host,
      logger: const NullSpeechLogger(),
      sessionId: 'voice-session-test',
      resolveTts: () => ttsAvailable ? _FakeTtsProvider() : null,
      resolveStt: () => sttAvailable ? _FakeSttProvider(this) : null,
      resolveTurnDetection: () =>
          detectorAvailable ? _FakeDetectorProvider(detector) : null,
      voiceBridge: bridge,
      getSpeechReadiness: readiness == null ? null : () => readiness!,
      environment: sttDebugDirectory == null
          ? const {'TINYRACK_DICTATION_DEBUG': 'false'}
          : {
              'TINYRACK_DICTATION_DEBUG': 'false',
              'TINYRACK_STT_DEBUG_AUDIO_DIR': sttDebugDirectory!,
            },
      createId: useDefaultIdGenerator ? null : () => 'id-${idCounter++}',
      now: () => DateTime.utc(2026, 7, 29),
      scheduleTurnTimeout: (delay, callback) {
        turnTimeout = _ManualTurnTimeout(callback);
        return turnTimeout;
      },
      scheduleBufferTimeout: useSystemBufferScheduler
          ? null
          : (delay, callback) {
              bufferTimeout = _ManualSessionTimeout(callback);
              return bufferTimeout;
            },
      ttsDebugAudioStore: ttsDebugAudioStore,
    );
    host.baseSystemPrompt = baseSystemPrompt;
  }

  final String? baseSystemPrompt;
  final SpeechReadinessSnapshot? readiness;
  final bool detectorAvailable;
  final bool sttAvailable;
  final bool ttsAvailable;
  final bool autoFinalizeBatchStt;
  final bool failSttConnect;
  final TtsDebugAudioStore? ttsDebugAudioStore;
  final String? sttDebugDirectory;
  final bool useSystemBufferScheduler;
  final bool useDefaultIdGenerator;
  final host = _FakeHost();
  final bridge = VoiceBridgeRegistry();
  final detector = _FakeDetector();
  final List<_FakeSttSession> sttSessions = [];
  late final VoiceSession session;
  late _ManualTurnTimeout turnTimeout;
  late _ManualSessionTimeout bufferTimeout;
  int idCounter = 0;

  Future<void> enableVoice() =>
      session.handleSetVoiceMode(true, agentId: voiceAgentId);

  Future<void> settle() async {
    for (var index = 0; index < 8; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitForMessage(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!host.emitted.any((message) => message['type'] == type)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for $type');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> waitForSttSessions(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (sttSessions.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for $count STT sessions');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> waitForActivityPrefix(String prefix) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!host.emitted.any(
      (message) =>
          message['type'] == 'activity_log' &&
          ((message['payload']! as Map)['content']! as String).startsWith(
            prefix,
          ),
    )) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for activity $prefix');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

final class _FakeHost implements VoiceSessionHost {
  final List<Map<String, Object?>> emitted = [];
  final List<String> loadedIds = [];
  final List<VoiceSessionAgentOverrides> reloads = [];
  final List<({String agentId, String text})> spokenInput = [];
  final List<String> interruptedIds = [];
  String? baseSystemPrompt;
  Object? interruptError;
  Object? reloadError;

  @override
  void emit(Map<String, Object?> message) => emitted.add(message);

  @override
  Future<VoiceSessionAgent> loadAgent(String agentId) async {
    loadedIds.add(agentId);
    return VoiceSessionAgent(id: agentId, systemPrompt: baseSystemPrompt);
  }

  @override
  Future<VoiceSessionAgent> reloadAgentSession(
    String agentId,
    VoiceSessionAgentOverrides overrides,
  ) async {
    if (reloadError != null) throw reloadError!;
    reloads.add(overrides);
    return VoiceSessionAgent(id: agentId, systemPrompt: overrides.systemPrompt);
  }

  @override
  Future<void> sendSpokenInput(String agentId, String text) async {
    spokenInput.add((agentId: agentId, text: text));
  }

  @override
  Future<void> interruptAgentIfRunning(String agentId) async {
    interruptedIds.add(agentId);
    if (interruptError != null) throw interruptError!;
  }

  @override
  bool hasActiveAgentRun(String? agentId) => false;
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
  final started = StreamController<void>.broadcast(sync: true);
  final stopped = StreamController<void>.broadcast(sync: true);
  final errorController = StreamController<Object?>.broadcast(sync: true);
  bool closed = false;
  int appendedBytes = 0;
  @override
  int get requiredSampleRate => 16000;
  void emitSpeechStarted() => started.add(null);
  void emitSpeechStopped() => stopped.add(null);
  @override
  Stream<void> get speechStartedEvents => started.stream;
  @override
  Stream<void> get speechStoppedEvents => stopped.stream;
  @override
  Stream<Object?> get errors => errorController.stream;
  void emitError(Object error) => errorController.add(error);
  @override
  Future<void> connect() async {}
  @override
  void appendPcm16(Uint8List pcm16le) => appendedBytes += pcm16le.length;
  @override
  void flush() {}
  @override
  void reset() {}
  @override
  void close() => closed = true;
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
    final session = _FakeSttSession(
      autoFinalizeOnCommit: harness.autoFinalizeBatchStt,
      throwOnConnect: harness.failSttConnect,
    );
    harness.sttSessions.add(session);
    return session;
  }
}

final class _FakeSttSession implements StreamingTranscriptionSession {
  _FakeSttSession({
    required this.autoFinalizeOnCommit,
    required this.throwOnConnect,
  });
  final bool autoFinalizeOnCommit;
  final bool throwOnConnect;
  final committed =
      StreamController<StreamingTranscriptionCommittedEvent>.broadcast(
        sync: true,
      );
  final transcripts = StreamController<StreamingTranscriptionEvent>.broadcast(
    sync: true,
  );
  final errorController = StreamController<Object?>.broadcast(sync: true);
  final List<List<int>> appended = [];
  int commitCalls = 0;
  bool closed = false;
  @override
  int get requiredSampleRate => 16000;

  void emitCommitted(String segmentId) {
    committed.add(
      StreamingTranscriptionCommittedEvent(
        segmentId: segmentId,
        previousSegmentId: null,
      ),
    );
  }

  void emitTranscript(StreamingTranscriptionEvent event) =>
      transcripts.add(event);
  void complete(String text) {
    emitCommitted('segment-$text');
    emitTranscript(
      StreamingTranscriptionEvent(
        segmentId: 'segment-$text',
        transcript: text,
        isFinal: true,
      ),
    );
  }

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
    if (throwOnConnect) throw StateError('connect failed');
  }

  @override
  void appendPcm16(List<int> pcm16le) => appended.add(List<int>.from(pcm16le));
  @override
  void commit() {
    commitCalls += 1;
    if (autoFinalizeOnCommit) {
      emitCommitted('batch-segment');
      emitTranscript(
        const StreamingTranscriptionEvent(
          segmentId: 'batch-segment',
          transcript: 'batch transcript',
          isFinal: true,
          language: 'en',
        ),
      );
    }
  }

  @override
  void clear() {}
  @override
  void close() => closed = true;
}

final class _FakeTtsProvider implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async {
    return SpeechStreamResult(
      stream: Stream<List<int>>.value([1, 2, 3]),
      format: 'audio/mpeg',
    );
  }
}

final class _ManualTurnTimeout implements VoiceTurnTimeoutHandle {
  _ManualTurnTimeout(this.callback);
  final void Function() callback;
  bool cancelled = false;
  void fire() {
    if (!cancelled) callback();
  }

  @override
  void cancel() => cancelled = true;
}

final class _ManualSessionTimeout implements VoiceSessionTimeoutHandle {
  _ManualSessionTimeout(this.callback);
  final FutureOr<void> Function() callback;
  bool cancelled = false;
  Future<void> fire() async {
    if (!cancelled) await callback();
  }

  @override
  void cancel() => cancelled = true;
}

const _readyState = SpeechReadinessState(
  enabled: true,
  available: true,
  reasonCode: 'ready',
  message: 'Ready',
  retryable: false,
);

SpeechReadinessSnapshot _readiness({
  SpeechReadinessState realtime = _readyState,
  SpeechReadinessState dictation = _readyState,
}) {
  return SpeechReadinessSnapshot(
    generatedAt: '2026-07-29T00:00:00Z',
    realtimeVoice: realtime,
    dictation: dictation,
    voiceFeature: const SpeechReadinessState(
      enabled: true,
      available: true,
      reasonCode: 'ready',
      message: 'Ready',
      retryable: false,
    ),
  );
}

Uint8List _pcm(int sample, int count) {
  final output = Uint8List(count * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < count; index += 1) {
    bytes.setInt16(index * 2, sample, Endian.little);
  }
  return output;
}

Uint8List _wav(Uint8List pcm) {
  final output = Uint8List(44 + pcm.length);
  final bytes = ByteData.sublistView(output);
  output.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setUint32(4, 36 + pcm.length, Endian.little);
  output.setRange(8, 12, 'WAVE'.codeUnits);
  output.setRange(12, 16, 'fmt '.codeUnits);
  bytes
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  output.setRange(36, 40, 'data'.codeUnits);
  bytes.setUint32(40, pcm.length, Endian.little);
  output.setRange(44, output.length, pcm);
  return output;
}

Map<String, Object?> _payload(
  List<Map<String, Object?>> messages,
  String type,
) =>
    messages.firstWhere((message) => message['type'] == type)['payload']!
        as Map<String, Object?>;

List<bool> _voiceStates(List<Map<String, Object?>> messages) => messages
    .where((message) => message['type'] == 'voice_input_state')
    .map((message) => (message['payload']! as Map)['isSpeaking']! as bool)
    .toList();

final class _RecordingLogger implements SpeechLogger {
  final List<String> infoMessages = [];
  @override
  SpeechLogger child(Map<String, Object?> context) => this;
  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}
  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}
  @override
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      infoMessages.add(message);
  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}
