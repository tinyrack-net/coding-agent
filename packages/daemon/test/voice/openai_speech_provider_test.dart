import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/audio.dart';
import 'package:agent_daemon/src/voice/openai/config.dart';
import 'package:agent_daemon/src/voice/openai/stt.dart';
import 'package:agent_daemon/src/voice/openai/tts.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'OpenAI STT sends frozen multipart fields and confidence metadata',
    () async {
      late http.MultipartRequest captured;
      final provider = OpenAiSpeechToTextProvider(
        const OpenAiSttConfig(
          apiKey: 'sk-test',
          baseUrl: 'https://speech.test/v1/',
          model: 'gpt-4o-transcribe',
          confidenceThreshold: -1,
        ),
        client: MockClient.streaming((request, bodyStream) async {
          captured = request as http.MultipartRequest;
          await bodyStream.drain<void>();
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'text': 'hello',
                  'language': 'en',
                  'logprobs': [
                    {
                      'token': 'hel',
                      'logprob': -0.5,
                      'bytes': [1, 2],
                    },
                    {'token': 'lo', 'logprob': -2.5},
                  ],
                }),
              ),
            ),
            200,
          );
        }),
      );

      final result = await provider.transcribe(
        wav: pcm16MonoToWav(const [0, 0, 1, 0], 24000),
        language: 'en',
        prompt: 'Only transcribe the speaker.',
      );

      expect(provider.id, 'openai');
      expect(
        captured.url,
        Uri.parse('https://speech.test/v1/audio/transcriptions'),
      );
      expect(captured.headers['authorization'], 'Bearer sk-test');
      expect(captured.fields, {
        'model': 'gpt-4o-transcribe',
        'language': 'en',
        'response_format': 'json',
        'prompt': 'Only transcribe the speaker.',
        'include[]': 'logprobs',
      });
      expect(captured.files.single.field, 'file');
      expect(captured.files.single.filename, 'audio.wav');
      expect(captured.files.single.contentType.toString(), 'audio/wav');
      expect(result.text, 'hello');
      expect(result.language, 'en');
      expect(result.logprobs, hasLength(2));
      expect(result.avgLogprob, -1.5);
      expect(result.isLowConfidence, isTrue);
      expect(result.duration, isNonNegative);
    },
  );

  test(
    'whisper STT excludes logprobs and ignores malformed response logprobs',
    () async {
      late http.Request captured;
      final provider = OpenAiSpeechToTextProvider(
        const OpenAiSttConfig(apiKey: 'key'),
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'text': 'ok',
              'logprobs': [
                {'token': 1, 'logprob': 'bad'},
              ],
            }),
            200,
          );
        }),
      );

      final result = await provider.transcribe(
        wav: Uint8List(44),
        language: 'ko',
      );

      expect(captured.body, isNot(contains('name="include[]"')));
      expect(captured.body, isNot(contains('name="prompt"')));
      expect(result.logprobs, isNull);
      expect(result.avgLogprob, isNull);
      expect(result.isLowConfidence, isFalse);
    },
  );

  test('transcribe models discard malformed logprob token arrays', () async {
    final provider = OpenAiSpeechToTextProvider(
      const OpenAiSttConfig(apiKey: 'key', model: 'gpt-4o-mini-transcribe'),
      client: MockClient(
        (_) async => http.Response(
          '{"text":"ok","logprobs":[{"token":"x","logprob":"bad"}]}',
          200,
        ),
      ),
    );

    final result = await provider.transcribe(
      wav: Uint8List(44),
      language: 'en',
    );

    expect(result.logprobs, isNull);
    expect(result.avgLogprob, isNull);
  });

  test(
    'STT wraps HTTP, JSON, and transport errors with frozen prefix',
    () async {
      Future<void> expectFailure(http.Client client, String message) async {
        final provider = OpenAiSpeechToTextProvider(
          const OpenAiSttConfig(apiKey: 'key'),
          client: client,
        );
        await expectLater(
          provider.transcribe(wav: Uint8List(44), language: 'en'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(startsWith('STT transcription failed:'), contains(message)),
            ),
          ),
        );
      }

      await expectFailure(
        MockClient(
          (_) async => http.Response('{"error":{"message":"denied"}}', 401),
        ),
        'denied',
      );
      await expectFailure(
        MockClient((_) async => http.Response('{}', 200)),
        'response is invalid',
      );
      await expectFailure(
        MockClient((_) async => throw Exception('offline')),
        'offline',
      );
    },
  );

  test(
    'STT session enforces connection and emits ordered final segments',
    () async {
      var calls = 0;
      final provider = OpenAiSpeechToTextProvider(
        const OpenAiSttConfig(apiKey: 'key'),
        client: MockClient((_) async {
          calls += 1;
          return http.Response('{"text":"spoken","language":"ko"}', 200);
        }),
      );
      final session = provider.createSession(
        const SpeechSessionParameters(
          logger: NullSpeechLogger(),
          language: 'ko',
          prompt: 'names',
        ),
      );
      final errors = StreamQueue(session.errors);
      final commits = StreamQueue(session.committedEvents);
      final transcripts = StreamQueue(session.transcriptEvents);
      session.appendPcm16(const [0, 0]);
      expect(
        await errors.next.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('disconnected error not emitted'),
        ),
        isA<StateError>(),
      );

      await session.connect();
      session.appendPcm16(const [0, 0, 1, 0]);
      session.commit();
      final committed1 = await commits.next.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('first commit not emitted'),
      );
      final transcript1 = await transcripts.next.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('first transcript not emitted'),
      );
      expect(committed1.previousSegmentId, isNull);
      expect(transcript1.segmentId, committed1.segmentId);
      expect(transcript1.transcript, 'spoken');

      session.commit();
      final committed2 = await commits.next.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('second commit not emitted'),
      );
      final transcript2 = await transcripts.next.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('second transcript not emitted'),
      );
      expect(committed2.previousSegmentId, committed1.segmentId);
      expect(transcript2.transcript, '');
      expect(transcript2.language, 'ko');
      expect(transcript2.isLowConfidence, isTrue);
      expect(calls, 1);

      session.clear();
      session.close();
      session.commit();
      expect(
        await errors.next.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('closed error not emitted'),
        ),
        isA<StateError>(),
      );
      await errors.cancel(immediate: true);
      await commits.cancel(immediate: true);
      await transcripts.cancel(immediate: true);
    },
  );

  test(
    'STT session forwards request failures through its error stream',
    () async {
      final provider = OpenAiSpeechToTextProvider(
        const OpenAiSttConfig(apiKey: 'key'),
        client: MockClient((_) async => http.Response('failed', 500)),
      );
      final session = provider.createSession(
        const SpeechSessionParameters(logger: NullSpeechLogger()),
      );
      await session.connect();
      final error = session.errors.first;
      session.appendPcm16(const [0, 0]);
      session.commit();
      expect(await error, isA<StateError>());
    },
  );

  test('OpenAI TTS streams exact request and configured format', () async {
    late http.Request captured;
    final provider = OpenAiTextToSpeechProvider(
      const OpenAiTtsConfig(
        apiKey: 'sk-tts',
        baseUrl: 'https://speech.test/v1/',
        model: 'tts-1-hd',
        voice: 'nova',
        responseFormat: 'wav',
      ),
      client: MockClient((request) async {
        captured = request;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );

    final result = await provider.synthesizeSpeech('hello');

    expect(captured.url, Uri.parse('https://speech.test/v1/audio/speech'));
    expect(captured.headers['authorization'], 'Bearer sk-tts');
    expect(captured.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(captured.body), {
      'model': 'tts-1-hd',
      'voice': 'nova',
      'input': 'hello',
      'response_format': 'wav',
    });
    expect(result.format, 'wav');
    expect(await result.stream.expand((chunk) => chunk).toList(), [1, 2, 3]);
  });

  test('OpenAI TTS rejects blank input and wraps API failures', () async {
    final provider = OpenAiTextToSpeechProvider(
      const OpenAiTtsConfig(apiKey: 'key'),
      client: MockClient(
        (_) async => http.Response('{"error":{"message":"quota"}}', 429),
      ),
    );

    await expectLater(
      provider.synthesizeSpeech(' \n '),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Cannot synthesize empty text',
        ),
      ),
    );
    await expectLater(
      provider.synthesizeSpeech('hello'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(startsWith('TTS synthesis failed:'), contains('quota')),
        ),
      ),
    );
  });

  test('OpenAI TTS preserves plain and empty API errors', () async {
    Future<String> failureBody(String body) async {
      final provider = OpenAiTextToSpeechProvider(
        const OpenAiTtsConfig(apiKey: 'key'),
        client: MockClient((_) async => http.Response(body, 500)),
      );
      try {
        await provider.synthesizeSpeech('hello');
      } on StateError catch (error) {
        return error.message;
      }
      fail('Expected TTS failure');
    }

    expect(await failureBody('plain failure'), contains('plain failure'));
    expect(await failureBody(''), contains('empty response'));
  });

  test('OpenAI TTS wraps format and generic transport failures', () async {
    Future<String> failure(Object error) async {
      final provider = OpenAiTextToSpeechProvider(
        const OpenAiTtsConfig(apiKey: 'key'),
        client: MockClient((_) async => throw error),
      );
      try {
        await provider.synthesizeSpeech('hello');
      } on StateError catch (caught) {
        return caught.message;
      }
      fail('Expected TTS failure');
    }

    expect(
      await failure(const FormatException('bad transport')),
      contains('bad transport'),
    );
    expect(await failure(Exception('offline')), contains('offline'));
  });
}
