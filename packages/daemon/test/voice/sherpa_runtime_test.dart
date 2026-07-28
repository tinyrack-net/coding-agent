import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/audio.dart';
import 'package:agent_daemon/src/voice/local/sherpa/native.dart';
import 'package:agent_daemon/src/voice/local/sherpa/offline_recognizer.dart';
import 'package:agent_daemon/src/voice/local/sherpa/parakeet_stt.dart';
import 'package:agent_daemon/src/voice/local/sherpa/tts.dart';
import 'package:agent_daemon/src/voice/silero_vad_session.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late _FakeNativeFactory native;
  late SherpaOfflineRecognizerEngine engine;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tinyrack-sherpa-test-');
    native = _FakeNativeFactory();
    engine = _createEngine(temporary.path, native);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('offline recognizer validates and maps frozen native config', () {
    expect(native.recognizerConfigs, hasLength(1));
    final config = native.recognizerConfigs.single;
    expect(config.encoder, p.join(temporary.path, 'encoder.int8.onnx'));
    expect(config.decoder, p.join(temporary.path, 'decoder.int8.onnx'));
    expect(config.joiner, p.join(temporary.path, 'joiner.int8.onnx'));
    expect(config.tokens, p.join(temporary.path, 'tokens.txt'));
    expect(config.sampleRate, 16000);
    expect(config.featureDim, 80);
    expect(config.numThreads, 2);
    expect(config.provider, 'cpu');
    expect(config.debug, 0);
    expect(config.decodingMethod, 'greedy_search');
    expect(config.maxActivePaths, 4);

    native.recognizer.resultText = '  hello world  ';
    expect(engine.decode(Float32List.fromList([0.1, -0.1])), 'hello world');
    final stream = native.recognizer.streams.single;
    expect(stream.sampleRate, 16000);
    expect(stream.samples, [closeTo(0.1, 0.0001), closeTo(-0.1, 0.0001)]);
    expect(stream.freed, isTrue);
    expect(native.recognizer.decodeCalls, 1);

    engine.free();
    expect(native.recognizer.freed, isTrue);
  });

  test(
    'offline recognizer reports missing files and tolerates cleanup errors',
    () {
      File(p.join(temporary.path, 'decoder.int8.onnx')).deleteSync();
      expect(
        () => SherpaOfflineRecognizerEngine(
          config: _engineConfig(temporary.path),
          nativeFactory: native,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Missing offline decoder'),
          ),
        ),
      );

      native.recognizer
        ..resultText = 'ok'
        ..streamFreeError = StateError('stream cleanup')
        ..freeError = StateError('recognizer cleanup');
      expect(engine.decode(Float32List(1)), 'ok');
      expect(engine.free, returnsNormally);
    },
  );

  test(
    'Parakeet transcribes PCM/WAV, resamples, gains, and detects silence',
    () async {
      final provider = SherpaOnnxParakeetStt(engine: engine);
      expect(provider.id, 'local');
      native.recognizer.resultText = ' transcript ';

      final pcm = _pcm16(
        List.generate(320, (index) => index.isEven ? 1000 : -1000),
      );
      final direct = await provider.transcribeAudio(
        pcm,
        'audio/pcm;rate=16000',
      );
      expect(direct.text, 'transcript');
      expect(direct.isLowConfidence, isNull);
      expect(native.recognizer.streams.last.sampleRate, 16000);
      expect(
        native.recognizer.streams.last.samples
            .map((value) => value.abs())
            .reduce((a, b) => a > b ? a : b),
        closeTo(0.6, 0.01),
      );

      final beforeResample = native.recognizer.streams.length;
      await provider.transcribeAudio(pcm, 'audio/pcm;rate=8000');
      expect(native.recognizer.streams, hasLength(beforeResample + 1));
      expect(native.recognizer.streams.last.sampleRate, 16000);
      expect(
        native.recognizer.streams.last.samples.length,
        greaterThan(pcm.length ~/ 2),
      );

      final wav = pcm16MonoToWav(pcm, 16000);
      expect(
        (await provider.transcribeAudio(wav, 'audio/wav')).text,
        'transcript',
      );

      final beforeSilence = native.recognizer.streams.length;
      final silence = await provider.transcribeAudio(
        _pcm16(List.filled(20, 100)),
        'audio/pcm',
      );
      expect(silence.text, isEmpty);
      expect(silence.isLowConfidence, isTrue);
      expect(native.recognizer.streams, hasLength(beforeSilence));

      native.recognizer.resultText = ' ';
      expect(
        (await provider.transcribeAudio(pcm, 'audio/pcm')).isLowConfidence,
        isTrue,
      );
      await expectLater(
        provider.transcribeAudio(pcm, 'audio/flac'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Unsupported audio format'),
          ),
        ),
      );
    },
  );

  test(
    'Parakeet voice session emits committed/final and connection errors',
    () async {
      native.recognizer.resultText = 'voice';
      final provider = SherpaOnnxParakeetStt(engine: engine);
      final session = provider.createSession(
        const SpeechSessionParameters(logger: NullSpeechLogger()),
      );
      final errors = <Object?>[];
      final errorSubscription = session.errors.listen(errors.add);
      session
        ..appendPcm16(_pcm16([1000]))
        ..commit();
      expect(errors, hasLength(2));

      await session.connect();
      final committedFuture = session.committedEvents.first;
      final transcriptFuture = session.transcriptEvents.first;
      session.appendPcm16(_pcm16(List.filled(20, 1000)));
      session.commit();
      final committed = await committedFuture;
      final transcript = await transcriptFuture;
      expect(committed.previousSegmentId, isNull);
      expect(transcript.segmentId, committed.segmentId);
      expect(transcript.transcript, 'voice');
      expect(transcript.isFinal, isTrue);

      session.clear();
      session.close();
      await errorSubscription.cancel();
    },
  );

  test(
    'Parakeet realtime session throttles partials and commits final text',
    () async {
      var now = DateTime.utc(2026);
      native.recognizer.resultText = 'partial';
      final session = SherpaParakeetRealtimeTranscriptionSession(
        engine: engine,
        now: () => now,
      );
      final errors = <Object?>[];
      final errorSubscription = session.errors.listen(errors.add);
      session
        ..appendPcm16(_pcm16([1000]))
        ..commit();
      expect(errors, hasLength(2));

      await session.connect();
      await session.connect();
      final events = <StreamingTranscriptionEvent>[];
      final transcriptSubscription = session.transcriptEvents.listen(
        events.add,
      );
      session.appendPcm16(_pcm16(List.filled(20, 1000)));
      await _pump();
      expect(events.single.transcript, 'partial');
      expect(events.single.isFinal, isFalse);
      final decodes = native.recognizer.decodeCalls;

      session.appendPcm16(_pcm16(List.filled(20, 1000)));
      await _pump();
      expect(native.recognizer.decodeCalls, decodes);

      now = now.add(const Duration(milliseconds: 400));
      native.recognizer.resultText = 'final';
      final committedFuture = session.committedEvents.first;
      session.commit();
      final committed = await committedFuture;
      await _pump();
      expect(events.last.segmentId, committed.segmentId);
      expect(events.last.transcript, 'final');
      expect(events.last.isFinal, isTrue);

      session.clear();
      session.close();
      await errorSubscription.cancel();
      await transcriptSubscription.cancel();
    },
  );

  test(
    'Kokoro TTS validates config, chunks PCM, and applies fallbacks',
    () async {
      _writeTtsModel(temporary.path);
      native.tts
        ..generated = SherpaGeneratedAudio(
          samples: Float32List.fromList(
            List.generate(2401, (index) => index.isEven ? 0.5 : -0.5),
          ),
          sampleRate: 24000,
        )
        ..reportedSampleRate = 22050;
      final tts = SherpaOnnxTts(
        config: SherpaTtsConfig(
          modelDirectory: temporary.path,
          speakerId: 3,
          speed: 1.25,
          lengthScale: 0.9,
          numThreads: 4,
        ),
        nativeFactory: native,
      );
      final config = native.ttsConfigs.single;
      expect(config.model, p.join(temporary.path, 'model.onnx'));
      expect(config.voices, p.join(temporary.path, 'voices.bin'));
      expect(config.tokens, p.join(temporary.path, 'tokens.txt'));
      expect(config.dataDirectory, p.join(temporary.path, 'espeak-ng-data'));
      expect(config.lengthScale, 0.9);
      expect(config.numThreads, 4);

      final speech = await tts.synthesizeSpeech('  hello  ');
      final chunks = await speech.stream.toList();
      expect(speech.format, 'pcm;rate=24000');
      expect(chunks, hasLength(3));
      expect(chunks.expand((chunk) => chunk), hasLength(4802));
      expect(native.tts.text, 'hello');
      expect(native.tts.speakerId, 3);
      expect(native.tts.speed, 1.25);

      native.tts.generated = SherpaGeneratedAudio(
        samples: Float32List(0),
        sampleRate: 0,
      );
      expect((await tts.synthesizeSpeech('fallback')).format, 'pcm;rate=22050');
      native.tts.reportedSampleRate = 0;
      expect((await tts.synthesizeSpeech('default')).format, 'pcm;rate=24000');
      await expectLater(
        tts.synthesizeSpeech('   '),
        throwsA(isA<StateError>()),
      );
      tts.free();
      expect(native.tts.freed, isTrue);
    },
  );

  test('Kokoro TTS reports missing model assets and ignores free failures', () {
    expect(
      () => SherpaOnnxTts(
        config: SherpaTtsConfig(modelDirectory: temporary.path),
        nativeFactory: native,
      ),
      throwsA(isA<StateError>()),
    );
    _writeTtsModel(temporary.path);
    final tts = SherpaOnnxTts(
      config: SherpaTtsConfig(modelDirectory: temporary.path),
      nativeFactory: native,
    );
    native.tts.freeError = StateError('cleanup');
    expect(tts.free, returnsNormally);
  });
}

SherpaOfflineRecognizerEngine _createEngine(
  String directory,
  _FakeNativeFactory native,
) {
  for (final name in [
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
  ]) {
    File(p.join(directory, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
  }
  return SherpaOfflineRecognizerEngine(
    config: _engineConfig(directory),
    nativeFactory: native,
  );
}

SherpaOfflineRecognizerConfig _engineConfig(String directory) =>
    SherpaOfflineRecognizerConfig(
      model: SherpaOfflineRecognizerModel(
        encoder: p.join(directory, 'encoder.int8.onnx'),
        decoder: p.join(directory, 'decoder.int8.onnx'),
        joiner: p.join(directory, 'joiner.int8.onnx'),
        tokens: p.join(directory, 'tokens.txt'),
      ),
      numThreads: 2,
    );

void _writeTtsModel(String directory) {
  for (final name in ['model.onnx', 'voices.bin', 'tokens.txt']) {
    File(p.join(directory, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
  }
  Directory(p.join(directory, 'espeak-ng-data')).createSync(recursive: true);
}

Uint8List _pcm16(List<int> samples) {
  final output = Uint8List(samples.length * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index++) {
    bytes.setInt16(index * 2, samples[index], Endian.little);
  }
  return output;
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _FakeNativeFactory implements SherpaNativeFactory {
  final recognizerConfigs = <SherpaOfflineRecognizerNativeConfig>[];
  final ttsConfigs = <SherpaOfflineTtsNativeConfig>[];
  final recognizer = _FakeRecognizer();
  final tts = _FakeTts();

  @override
  void initialize([String? libraryDirectory]) {}

  @override
  SherpaOfflineRecognizerHandle createOfflineRecognizer(
    SherpaOfflineRecognizerNativeConfig config,
  ) {
    recognizerConfigs.add(config);
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
  Float32List samples = Float32List(0);
  int? sampleRate;
  bool freed = false;
  Object? freeError;

  @override
  void acceptWaveform({required Float32List samples, required int sampleRate}) {
    this.samples = Float32List.fromList(samples);
    this.sampleRate = sampleRate;
  }

  @override
  void free() {
    freed = true;
    if (freeError != null) throw freeError!;
  }
}

final class _FakeRecognizer implements SherpaOfflineRecognizerHandle {
  final streams = <_FakeStream>[];
  String resultText = '';
  int decodeCalls = 0;
  bool freed = false;
  Object? streamFreeError;
  Object? freeError;

  @override
  SherpaOfflineStreamHandle createStream() {
    final stream = _FakeStream()..freeError = streamFreeError;
    streams.add(stream);
    return stream;
  }

  @override
  void decode(SherpaOfflineStreamHandle stream) => decodeCalls++;

  @override
  String getResultText(SherpaOfflineStreamHandle stream) => resultText;

  @override
  void free() {
    freed = true;
    if (freeError != null) throw freeError!;
  }
}

final class _FakeTts implements SherpaOfflineTtsHandle {
  SherpaGeneratedAudio generated = SherpaGeneratedAudio(
    samples: Float32List(0),
    sampleRate: 0,
  );
  int reportedSampleRate = 0;
  String? text;
  int? speakerId;
  double? speed;
  bool freed = false;
  Object? freeError;

  @override
  int get sampleRate => reportedSampleRate;

  @override
  SherpaGeneratedAudio generate({
    required String text,
    required int speakerId,
    required double speed,
  }) {
    this.text = text;
    this.speakerId = speakerId;
    this.speed = speed;
    return generated;
  }

  @override
  void free() {
    freed = true;
    if (freeError != null) throw freeError!;
  }
}

final class _FakeVad implements SherpaVadBackend {
  @override
  void acceptWaveform(Float32List samples) {}

  @override
  bool get isDetected => false;

  @override
  void flush() {}

  @override
  void reset() {}

  @override
  void free() {}
}
