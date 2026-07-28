import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
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
}
