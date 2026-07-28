import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../silero_vad_session.dart';
import 'runtime_env.dart';

final class SherpaOfflineRecognizerNativeConfig {
  const SherpaOfflineRecognizerNativeConfig({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    this.numThreads = 1,
    this.provider = 'cpu',
    this.debug = 0,
    this.sampleRate = 16000,
    this.featureDim = 80,
    this.decodingMethod = 'greedy_search',
    this.maxActivePaths = 4,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final int numThreads;
  final String provider;
  final int debug;
  final int sampleRate;
  final int featureDim;
  final String decodingMethod;
  final int maxActivePaths;
}

final class SherpaOfflineTtsNativeConfig {
  const SherpaOfflineTtsNativeConfig({
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDirectory,
    this.lengthScale = 1,
    this.numThreads = 2,
    this.provider = 'cpu',
    this.debug = 0,
    this.maxNumSentences = 1,
  });

  final String model;
  final String voices;
  final String tokens;
  final String dataDirectory;
  final double lengthScale;
  final int numThreads;
  final String provider;
  final int debug;
  final int maxNumSentences;
}

final class SherpaGeneratedAudio {
  const SherpaGeneratedAudio({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;
}

abstract interface class SherpaOfflineStreamHandle {
  void acceptWaveform({required Float32List samples, required int sampleRate});
  void free();
}

abstract interface class SherpaOfflineRecognizerHandle {
  SherpaOfflineStreamHandle createStream();
  void decode(SherpaOfflineStreamHandle stream);
  String getResultText(SherpaOfflineStreamHandle stream);
  void free();
}

abstract interface class SherpaOfflineTtsHandle {
  int get sampleRate;
  SherpaGeneratedAudio generate({
    required String text,
    required int speakerId,
    required double speed,
  });
  void free();
}

abstract interface class SherpaVadBackend implements SileroVadBackend {
  void free();
}

abstract interface class SherpaNativeFactory {
  void initialize([String? libraryDirectory]);
  SherpaOfflineRecognizerHandle createOfflineRecognizer(
    SherpaOfflineRecognizerNativeConfig config,
  );
  SherpaOfflineTtsHandle createOfflineTts(SherpaOfflineTtsNativeConfig config);
  SherpaVadBackend createVad(SileroVadBackendConfig config);
}

final class SherpaOnnxNativeFactory implements SherpaNativeFactory {
  SherpaOnnxNativeFactory();

  bool _initialized = false;

  @override
  void initialize([String? libraryDirectory]) {
    if (_initialized) return;
    configureSherpaNativeLoader(libraryDirectory);
    sherpa.initBindings(libraryDirectory);
    _initialized = true;
  }

  @override
  SherpaOfflineRecognizerHandle createOfflineRecognizer(
    SherpaOfflineRecognizerNativeConfig config,
  ) {
    _requireInitialized();
    final recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        feat: sherpa.FeatureConfig(
          sampleRate: config.sampleRate,
          featureDim: config.featureDim,
        ),
        model: sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: config.encoder,
            decoder: config.decoder,
            joiner: config.joiner,
          ),
          tokens: config.tokens,
          numThreads: config.numThreads,
          debug: config.debug != 0,
          provider: config.provider,
          modelType: 'nemo_transducer',
        ),
        decodingMethod: config.decodingMethod,
        maxActivePaths: config.maxActivePaths,
      ),
    );
    return _SherpaOfflineRecognizerHandle(recognizer);
  }

  @override
  SherpaOfflineTtsHandle createOfflineTts(SherpaOfflineTtsNativeConfig config) {
    _requireInitialized();
    final tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: config.model,
            voices: config.voices,
            tokens: config.tokens,
            dataDir: config.dataDirectory,
            lengthScale: config.lengthScale,
          ),
          numThreads: config.numThreads,
          debug: config.debug != 0,
          provider: config.provider,
        ),
        maxNumSenetences: config.maxNumSentences,
      ),
    );
    return _SherpaOfflineTtsHandle(tts);
  }

  @override
  SherpaVadBackend createVad(SileroVadBackendConfig config) {
    _requireInitialized();
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: config.modelPath ?? '',
          threshold: config.threshold,
          minSilenceDuration: config.minSilenceDuration,
          minSpeechDuration: config.minSpeechDuration,
          windowSize: config.windowSize,
        ),
        sampleRate: config.sampleRate,
        numThreads: config.numThreads,
        provider: config.provider,
        debug: config.debug != 0,
      ),
      bufferSizeInSeconds: config.bufferSizeSeconds.toDouble(),
    );
    return _SherpaSileroVadBackend(vad);
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Sherpa ONNX native bindings are not initialized');
    }
  }
}

final class _SherpaOfflineStreamHandle implements SherpaOfflineStreamHandle {
  _SherpaOfflineStreamHandle(this.stream);

  final sherpa.OfflineStream stream;

  @override
  void acceptWaveform({
    required Float32List samples,
    required int sampleRate,
  }) => stream.acceptWaveform(samples: samples, sampleRate: sampleRate);

  @override
  void free() => stream.free();
}

final class _SherpaOfflineRecognizerHandle
    implements SherpaOfflineRecognizerHandle {
  _SherpaOfflineRecognizerHandle(this.recognizer);

  final sherpa.OfflineRecognizer recognizer;

  @override
  SherpaOfflineStreamHandle createStream() =>
      _SherpaOfflineStreamHandle(recognizer.createStream());

  @override
  void decode(SherpaOfflineStreamHandle stream) =>
      recognizer.decode((stream as _SherpaOfflineStreamHandle).stream);

  @override
  String getResultText(SherpaOfflineStreamHandle stream) =>
      recognizer.getResult((stream as _SherpaOfflineStreamHandle).stream).text;

  @override
  void free() => recognizer.free();
}

final class _SherpaOfflineTtsHandle implements SherpaOfflineTtsHandle {
  _SherpaOfflineTtsHandle(this.tts);

  final sherpa.OfflineTts tts;

  @override
  int get sampleRate => tts.sampleRate;

  @override
  SherpaGeneratedAudio generate({
    required String text,
    required int speakerId,
    required double speed,
  }) {
    final audio = tts.generate(text: text, sid: speakerId, speed: speed);
    return SherpaGeneratedAudio(
      samples: Float32List.fromList(audio.samples),
      sampleRate: audio.sampleRate,
    );
  }

  @override
  void free() => tts.free();
}

final class _SherpaSileroVadBackend implements SherpaVadBackend {
  _SherpaSileroVadBackend(this.vad);

  final sherpa.VoiceActivityDetector vad;

  @override
  void acceptWaveform(Float32List samples) => vad.acceptWaveform(samples);

  @override
  bool get isDetected => vad.isDetected();

  @override
  void flush() => vad.flush();

  @override
  void reset() => vad.reset();

  @override
  void free() => vad.free();
}
