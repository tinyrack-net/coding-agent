import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/local/model_catalog.dart';
import 'package:agent_daemon/src/voice/local/model_downloader.dart';
import 'package:agent_daemon/src/voice/local/sherpa/native.dart';
import 'package:agent_daemon/src/voice/local/worker_dispatcher.dart';
import 'package:agent_daemon/src/voice/local/worker_protocol.dart';
import 'package:agent_daemon/src/voice/silero_vad_session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late String modelsDirectory;
  late String bundledVad;
  late _FakeNativeFactory native;
  late List<LocalSpeechWorkerMessage> messages;
  late LocalSpeechWorkerDispatcher dispatcher;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tinyrack-dispatcher-');
    modelsDirectory = p.join(temporary.path, 'models');
    _writeModel(modelsDirectory, 'parakeet-tdt-0.6b-v2-int8');
    _writeModel(modelsDirectory, 'kokoro-en-v0_19');
    bundledVad = p.join(temporary.path, 'silero_vad.onnx');
    File(bundledVad).writeAsBytesSync([1, 2, 3]);
    native = _FakeNativeFactory();
    messages = [];
    dispatcher = LocalSpeechWorkerDispatcher(
      send: messages.add,
      nativeFactory: native,
      sherpaLibraryDirectory: temporary.path,
      bundledSileroVadModelPath: bundledVad,
    );
  });

  tearDown(() async {
    await dispatcher.close();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('dispatches and caches TTS and one-shot STT providers', () async {
    await dispatcher.handle(
      const LocalSpeechTtsSynthesizeRequest(
        requestId: 'tts-1',
        config: _config,
        text: 'hello',
      ).withModelsDirectory(modelsDirectory),
    );
    await dispatcher.handle(
      const LocalSpeechTtsSynthesizeRequest(
        requestId: 'tts-2',
        config: _config,
        text: 'again',
      ).withModelsDirectory(modelsDirectory),
    );
    expect(native.initializeCalls, 1);
    expect(native.ttsConfigs, hasLength(1));
    final ttsResponse = _response(messages, 'tts-1');
    expect(ttsResponse.ok, isTrue);
    expect(LocalSpeechTtsResult.fromJson(ttsResponse.result).audio, [
      1,
      0,
      2,
      0,
      3,
      0,
      4,
      0,
    ]);

    await dispatcher.handle(
      LocalSpeechSttTranscribeRequest(
        requestId: 'stt-1',
        config: _config.withModelsDirectory(modelsDirectory),
        model: LocalSpeechTranscriptionModel.voice,
        audio: _pcm16(List.filled(20, 1000)),
        format: 'audio/pcm;rate=16000',
      ),
    );
    await dispatcher.handle(
      LocalSpeechSttTranscribeRequest(
        requestId: 'stt-2',
        config: _config.withModelsDirectory(modelsDirectory),
        model: LocalSpeechTranscriptionModel.dictation,
        audio: _pcm16(List.filled(20, 1000)),
        format: 'audio/pcm;rate=16000',
      ),
    );
    expect(native.recognizerConfigs, hasLength(1));
    expect(
      (_response(messages, 'stt-1').result as Map)['text'],
      'worker transcript',
    );

    await dispatcher.handle(
      LocalSpeechSttTranscribeRequest(
        requestId: 'bad-model',
        config: LocalSpeechWorkerConfig(
          modelsDirectory: modelsDirectory,
          voiceSttModel: 'unknown',
          dictationSttModel: _config.dictationSttModel,
          voiceTtsModel: _config.voiceTtsModel,
        ),
        model: LocalSpeechTranscriptionModel.voice,
        audio: _pcm16([1000]),
        format: 'audio/pcm',
      ),
    );
    expect(_response(messages, 'bad-model').ok, isFalse);
  });

  test('routes voice, realtime dictation, and VAD session events', () async {
    final config = _config.withModelsDirectory(modelsDirectory);
    await dispatcher.handle(
      LocalSpeechSessionCreateRequest(
        requestId: 'voice-create',
        config: config,
        sessionId: 'voice',
        kind: LocalSpeechSessionKind.voiceStt,
      ),
    );
    expect(
      LocalSpeechCreateSessionResult.fromJson(
        _response(messages, 'voice-create').result,
      ).requiredSampleRate,
      16000,
    );
    await dispatcher.handle(
      LocalSpeechSessionAppendRequest(
        requestId: 'voice-append',
        sessionId: 'voice',
        audio: _pcm16(List.filled(20, 1000)),
      ),
    );
    await dispatcher.handle(
      LocalSpeechSessionCommandRequest(
        requestId: 'voice-commit',
        sessionId: 'voice',
        type: 'session.commit',
      ),
    );
    await _pump();
    expect(
      messages.whereType<LocalSpeechWorkerEvent>().map(
        (event) => event.eventType,
      ),
      containsAll([
        LocalSpeechWorkerEventType.committed,
        LocalSpeechWorkerEventType.transcript,
      ]),
    );

    await dispatcher.handle(
      LocalSpeechSessionCreateRequest(
        requestId: 'dictation-create',
        config: config,
        sessionId: 'dictation',
        kind: LocalSpeechSessionKind.dictationStt,
      ),
    );
    await dispatcher.handle(
      LocalSpeechSessionAppendRequest(
        requestId: 'dictation-append',
        sessionId: 'dictation',
        audio: _pcm16(List.filled(20, 1000)),
      ),
    );
    await _pump();
    await dispatcher.handle(
      LocalSpeechSessionCommandRequest(
        requestId: 'dictation-commit',
        sessionId: 'dictation',
        type: 'session.commit',
      ),
    );
    await _pump();

    await dispatcher.handle(
      LocalSpeechSessionCreateRequest(
        requestId: 'vad-create',
        config: config,
        sessionId: 'vad',
        kind: LocalSpeechSessionKind.vad,
      ),
    );
    expect(
      File(
        p.join(modelsDirectory, 'silero-vad', 'silero_vad.onnx'),
      ).existsSync(),
      isTrue,
    );
    await dispatcher.handle(
      LocalSpeechSessionAppendRequest(
        requestId: 'vad-append',
        sessionId: 'vad',
        audio: _pcm16(List.filled(512 * 27, 1000)),
      ),
    );
    await dispatcher.handle(
      LocalSpeechSessionCommandRequest(
        requestId: 'vad-flush',
        sessionId: 'vad',
        type: 'session.flush',
      ),
    );
    await dispatcher.handle(
      LocalSpeechSessionCommandRequest(
        requestId: 'vad-reset',
        sessionId: 'vad',
        type: 'session.reset',
      ),
    );
    expect(
      messages.whereType<LocalSpeechWorkerEvent>().map(
        (event) => event.eventType,
      ),
      containsAll([
        LocalSpeechWorkerEventType.speechStarted,
        LocalSpeechWorkerEventType.speechStopped,
      ]),
    );

    for (final sessionId in ['voice', 'dictation', 'vad']) {
      await dispatcher.handle(
        LocalSpeechSessionCommandRequest(
          requestId: 'close-$sessionId',
          sessionId: sessionId,
          type: 'session.close',
        ),
      );
      expect(_response(messages, 'close-$sessionId').ok, isTrue);
    }
  });

  test(
    'normalizes request failures and releases cached native engines',
    () async {
      final config = _config.withModelsDirectory(modelsDirectory);
      await dispatcher.handle(
        LocalSpeechTtsSynthesizeRequest(
          requestId: 'tts',
          config: config,
          text: 'hello',
        ),
      );
      await dispatcher.handle(
        LocalSpeechSttTranscribeRequest(
          requestId: 'stt',
          config: config,
          model: LocalSpeechTranscriptionModel.voice,
          audio: _pcm16(List.filled(20, 1000)),
          format: 'audio/pcm',
        ),
      );
      await dispatcher.close();
      expect(native.tts.freed, isTrue);
      expect(native.recognizers.single.freed, isTrue);

      await dispatcher.handle(
        LocalSpeechTtsSynthesizeRequest(
          requestId: 'closed',
          config: config,
          text: 'nope',
        ),
      );
      expect(
        _response(messages, 'closed').error,
        'Local speech worker is closed',
      );
      await dispatcher.close();
    },
  );
}

const LocalSpeechWorkerConfig _config = LocalSpeechWorkerConfig(
  modelsDirectory: 'replaced',
  voiceSttModel: 'parakeet-tdt-0.6b-v2-int8',
  dictationSttModel: 'parakeet-tdt-0.6b-v2-int8',
  voiceTtsModel: 'kokoro-en-v0_19',
  voiceTtsSpeakerId: 2,
  voiceTtsSpeed: 1.2,
);

extension on LocalSpeechWorkerConfig {
  LocalSpeechWorkerConfig withModelsDirectory(String directory) =>
      LocalSpeechWorkerConfig(
        modelsDirectory: directory,
        voiceSttModel: voiceSttModel,
        dictationSttModel: dictationSttModel,
        voiceTtsModel: voiceTtsModel,
        voiceTtsSpeakerId: voiceTtsSpeakerId,
        voiceTtsSpeed: voiceTtsSpeed,
      );
}

extension on LocalSpeechTtsSynthesizeRequest {
  LocalSpeechTtsSynthesizeRequest withModelsDirectory(String directory) =>
      LocalSpeechTtsSynthesizeRequest(
        requestId: requestId,
        config: config.withModelsDirectory(directory),
        text: text,
      );
}

LocalSpeechWorkerResponse _response(
  List<LocalSpeechWorkerMessage> messages,
  String requestId,
) => messages.whereType<LocalSpeechWorkerResponse>().singleWhere(
  (message) => message.requestId == requestId,
);

void _writeModel(String root, String modelId) {
  final spec = getLocalSpeechModelSpec(modelId);
  final directory = getLocalSpeechModelDirectory(root, modelId);
  Directory(directory).createSync(recursive: true);
  for (final relative in spec.requiredFiles) {
    final path = p.join(directory, relative);
    if (relative == 'espeak-ng-data') {
      Directory(path).createSync(recursive: true);
    } else {
      File(path).writeAsStringSync('x');
    }
  }
}

Uint8List _pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return bytes;
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _FakeNativeFactory implements SherpaNativeFactory {
  int initializeCalls = 0;
  final recognizerConfigs = <SherpaOfflineRecognizerNativeConfig>[];
  final ttsConfigs = <SherpaOfflineTtsNativeConfig>[];
  final recognizers = <_FakeRecognizer>[];
  final tts = _FakeTts();

  @override
  void initialize([String? libraryDirectory]) => initializeCalls++;

  @override
  SherpaOfflineRecognizerHandle createOfflineRecognizer(
    SherpaOfflineRecognizerNativeConfig config,
  ) {
    recognizerConfigs.add(config);
    final recognizer = _FakeRecognizer();
    recognizers.add(recognizer);
    return recognizer;
  }

  @override
  SherpaOfflineTtsHandle createOfflineTts(SherpaOfflineTtsNativeConfig config) {
    ttsConfigs.add(config);
    return tts;
  }

  @override
  SherpaVadBackend createVad(SileroVadBackendConfig config) => _FakeVad();
}

final class _FakeStream implements SherpaOfflineStreamHandle {
  @override
  void acceptWaveform({
    required Float32List samples,
    required int sampleRate,
  }) {}

  @override
  void free() {}
}

final class _FakeRecognizer implements SherpaOfflineRecognizerHandle {
  bool freed = false;

  @override
  SherpaOfflineStreamHandle createStream() => _FakeStream();

  @override
  void decode(SherpaOfflineStreamHandle stream) {}

  @override
  String getResultText(SherpaOfflineStreamHandle stream) => 'worker transcript';

  @override
  void free() => freed = true;
}

final class _FakeTts implements SherpaOfflineTtsHandle {
  bool freed = false;

  @override
  int get sampleRate => 24000;

  @override
  SherpaGeneratedAudio generate({
    required String text,
    required int speakerId,
    required double speed,
  }) => SherpaGeneratedAudio(
    samples: Float32List.fromList([1 / 32767, 2 / 32767, 3 / 32767, 4 / 32767]),
    sampleRate: 24000,
  );

  @override
  void free() => freed = true;
}

final class _FakeVad implements SherpaVadBackend {
  @override
  void acceptWaveform(Float32List samples) {}

  @override
  bool get isDetected => true;

  @override
  void flush() {}

  @override
  void reset() {}

  @override
  void free() {}
}
