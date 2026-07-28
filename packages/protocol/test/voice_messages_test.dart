import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('abort request matches the frozen type-only shape', () {
    expect(
      AbortRequestMessage.fromJson(const {'type': 'abort_request'}).toJson(),
      {'type': 'abort_request'},
    );
    expect(
      () => AbortRequestMessage.fromJson(const {'type': 'wrong'}),
      throwsFormatException,
    );
  });

  test('audio played message matches the frozen top-level shape', () {
    const message = AudioPlayedMessage(id: 'audio-id:0');

    expect(message.toJson(), {'type': 'audio_played', 'id': 'audio-id:0'});
    expect(
      AudioPlayedMessage.fromJson(message.toJson()).toJson(),
      message.toJson(),
    );
  });

  test('audio output message round-trips the complete frozen payload', () {
    const message = AudioOutputMessage(
      payload: AudioOutputPayload(
        audio: 'YWI=',
        format: 'mp3',
        id: 'audio-id:0',
        isVoiceMode: true,
        groupId: 'audio-id',
        chunkIndex: 0,
        isLastChunk: true,
      ),
    );

    expect(message.toJson(), {
      'type': 'audio_output',
      'payload': {
        'audio': 'YWI=',
        'format': 'mp3',
        'id': 'audio-id:0',
        'isVoiceMode': true,
        'groupId': 'audio-id',
        'chunkIndex': 0,
        'isLastChunk': true,
      },
    });
    expect(
      AudioOutputMessage.fromJson(message.toJson()).toJson(),
      message.toJson(),
    );
  });

  test('optional audio output grouping fields remain omitted', () {
    const message = AudioOutputMessage(
      payload: AudioOutputPayload(
        audio: '',
        format: 'pcm16',
        id: 'audio-id',
        isVoiceMode: false,
      ),
    );

    expect(message.toJson(), {
      'type': 'audio_output',
      'payload': {
        'audio': '',
        'format': 'pcm16',
        'id': 'audio-id',
        'isVoiceMode': false,
      },
    });
  });

  test('voice message boundaries reject malformed payloads', () {
    expect(
      () => AudioPlayedMessage.fromJson(const {
        'type': AudioPlayedMessage.type,
        'id': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => AudioOutputMessage.fromJson(const {
        'type': AudioOutputMessage.type,
        'payload': {
          'audio': '',
          'format': 'mp3',
          'id': 'id',
          'isVoiceMode': false,
          'chunkIndex': -1,
        },
      }),
      throwsFormatException,
    );
    expect(
      () => AudioOutputMessage.fromJson(const {
        'type': AudioOutputMessage.type,
        'payload': {
          'audio': '',
          'format': 'mp3',
          'id': 'id',
          'isVoiceMode': 'yes',
        },
      }),
      throwsFormatException,
    );
  });

  test('dictation inbound messages match frozen top-level shapes', () {
    const start = DictationStreamStartMessage(
      dictationId: 'd1',
      format: 'audio/pcm;rate=16000;bits=16',
    );
    const chunk = DictationStreamChunkMessage(
      dictationId: 'd1',
      seq: 0,
      audio: 'AAE=',
      format: 'audio/pcm;rate=16000;bits=16',
    );
    const finish = DictationStreamFinishMessage(dictationId: 'd1', finalSeq: 0);
    const cancel = DictationStreamCancelMessage(dictationId: 'd1');

    for (final pair in [
      (
        start.toJson(),
        DictationStreamStartMessage.fromJson(start.toJson()).toJson(),
      ),
      (
        chunk.toJson(),
        DictationStreamChunkMessage.fromJson(chunk.toJson()).toJson(),
      ),
      (
        finish.toJson(),
        DictationStreamFinishMessage.fromJson(finish.toJson()).toJson(),
      ),
      (
        cancel.toJson(),
        DictationStreamCancelMessage.fromJson(cancel.toJson()).toJson(),
      ),
    ]) {
      expect(pair.$2, pair.$1);
      expect(pair.$1, isNot(contains('payload')));
    }
  });

  test('dictation outbound messages round-trip frozen payloads', () {
    final messages = <(Map<String, Object?>, Map<String, Object?>)>[
      (
        const VoiceInputStateMessage(isSpeaking: true).toJson(),
        VoiceInputStateMessage.fromJson(
          const VoiceInputStateMessage(isSpeaking: true).toJson(),
        ).toJson(),
      ),
      (
        const DictationStreamAckMessage(dictationId: 'd1', ackSeq: -1).toJson(),
        DictationStreamAckMessage.fromJson(
          const DictationStreamAckMessage(
            dictationId: 'd1',
            ackSeq: -1,
          ).toJson(),
        ).toJson(),
      ),
      (
        const DictationStreamFinishAcceptedMessage(
          dictationId: 'd1',
          timeoutMs: 10000,
        ).toJson(),
        DictationStreamFinishAcceptedMessage.fromJson(
          const DictationStreamFinishAcceptedMessage(
            dictationId: 'd1',
            timeoutMs: 10000,
          ).toJson(),
        ).toJson(),
      ),
      (
        const DictationStreamPartialMessage(
          dictationId: 'd1',
          text: 'hel',
        ).toJson(),
        DictationStreamPartialMessage.fromJson(
          const DictationStreamPartialMessage(
            dictationId: 'd1',
            text: 'hel',
          ).toJson(),
        ).toJson(),
      ),
      (
        const DictationStreamFinalMessage(
          dictationId: 'd1',
          text: 'hello',
          debugRecordingPath: 'recording.wav',
        ).toJson(),
        DictationStreamFinalMessage.fromJson(
          const DictationStreamFinalMessage(
            dictationId: 'd1',
            text: 'hello',
            debugRecordingPath: 'recording.wav',
          ).toJson(),
        ).toJson(),
      ),
      (
        const DictationStreamErrorMessage(
          dictationId: 'd1',
          error: 'missing model',
          retryable: true,
          reasonCode: 'model_missing',
          missingModelIds: ['parakeet'],
          debugRecordingPath: 'recording.wav',
        ).toJson(),
        DictationStreamErrorMessage.fromJson(
          const DictationStreamErrorMessage(
            dictationId: 'd1',
            error: 'missing model',
            retryable: true,
            reasonCode: 'model_missing',
            missingModelIds: ['parakeet'],
            debugRecordingPath: 'recording.wav',
          ).toJson(),
        ).toJson(),
      ),
    ];
    for (final pair in messages) {
      expect(pair.$2, pair.$1);
      expect(pair.$1['payload'], isA<Map<String, Object?>>());
    }
  });

  test('dictation message boundaries reject invalid integers and payloads', () {
    expect(
      () => DictationStreamChunkMessage.fromJson(const {
        'type': DictationStreamChunkMessage.type,
        'dictationId': 'd',
        'seq': -1,
        'audio': '',
        'format': 'pcm',
      }),
      throwsFormatException,
    );
    expect(
      () => DictationStreamFinishAcceptedMessage.fromJson(const {
        'type': DictationStreamFinishAcceptedMessage.type,
        'payload': {'dictationId': 'd', 'timeoutMs': 0},
      }),
      throwsFormatException,
    );
    expect(
      () => DictationStreamErrorMessage.fromJson(const {
        'type': DictationStreamErrorMessage.type,
        'payload': {
          'dictationId': 'd',
          'error': 'x',
          'retryable': true,
          'missingModelIds': [1],
        },
      }),
      throwsFormatException,
    );
  });

  test(
    'voice session messages preserve frozen top-level and payload shapes',
    () {
      const audio = VoiceAudioChunkMessage(
        audio: 'AAE=',
        format: 'audio/pcm;rate=16000;bits=16',
        isLast: true,
      );
      const mode = SetVoiceModeMessage(
        enabled: true,
        agentId: 'agent',
        requestId: 'request',
      );
      const response = SetVoiceModeResponseMessage(
        requestId: 'request',
        enabled: true,
        agentId: 'agent',
        accepted: true,
        error: null,
        reasonCode: 'ready',
        retryable: false,
        missingModelIds: [],
      );
      const transcript = TranscriptionResultMessage(
        text: 'hello',
        requestId: 'request',
        language: 'en',
        duration: 250,
        avgLogprob: -0.1,
        isLowConfidence: false,
        byteLength: 3200,
        format: 'audio/wav',
        debugRecordingPath: 'input.wav',
      );
      final activity = ActivityLogMessage(
        id: 'activity',
        timestamp: DateTime.utc(2026, 7, 29),
        logType: 'transcript',
        content: 'hello',
        metadata: const {'language': 'en'},
      );

      expect(
        VoiceAudioChunkMessage.fromJson(audio.toJson()).toJson(),
        audio.toJson(),
      );
      expect(
        SetVoiceModeMessage.fromJson(mode.toJson()).toJson(),
        mode.toJson(),
      );
      expect(
        SetVoiceModeResponseMessage.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
      expect(
        TranscriptionResultMessage.fromJson(transcript.toJson()).toJson(),
        transcript.toJson(),
      );
      expect(
        ActivityLogMessage.fromJson(activity.toJson()).toJson(),
        activity.toJson(),
      );
      expect(audio.toJson(), isNot(contains('payload')));
      expect(mode.toJson(), isNot(contains('payload')));
    },
  );

  test('voice session message boundaries reject malformed values', () {
    expect(
      () => VoiceAudioChunkMessage.fromJson(const {
        'type': VoiceAudioChunkMessage.type,
        'audio': '',
        'format': '',
        'isLast': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => SetVoiceModeMessage.fromJson(const {
        'type': SetVoiceModeMessage.type,
        'enabled': 'yes',
      }),
      throwsFormatException,
    );
    expect(
      () => SetVoiceModeResponseMessage.fromJson(const {
        'type': SetVoiceModeResponseMessage.type,
        'payload': {
          'requestId': 'r',
          'enabled': true,
          'agentId': null,
          'accepted': false,
          'error': null,
          'missingModelIds': [1],
        },
      }),
      throwsFormatException,
    );
    expect(
      () => TranscriptionResultMessage.fromJson(const {
        'type': TranscriptionResultMessage.type,
        'payload': {'text': '', 'requestId': 'r', 'duration': 'long'},
      }),
      throwsFormatException,
    );
    expect(
      () => ActivityLogMessage.fromJson(const {
        'type': ActivityLogMessage.type,
        'payload': {
          'id': 'a',
          'timestamp': 'invalid',
          'type': 'unknown',
          'content': '',
        },
      }),
      throwsFormatException,
    );
  });
}
