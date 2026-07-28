import 'dart:io';
import 'dart:typed_data';

import '../../speech_provider.dart';
import 'native.dart';

final class SherpaOfflineRecognizerModel {
  const SherpaOfflineRecognizerModel({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

final class SherpaOfflineRecognizerConfig {
  const SherpaOfflineRecognizerConfig({
    required this.model,
    this.numThreads = 1,
    this.provider = 'cpu',
    this.debug = 0,
    this.sampleRate = 16000,
    this.featureDim = 80,
    this.decodingMethod = 'greedy_search',
    this.maxActivePaths = 4,
  });

  final SherpaOfflineRecognizerModel model;
  final int numThreads;
  final String provider;
  final int debug;
  final int sampleRate;
  final int featureDim;
  final String decodingMethod;
  final int maxActivePaths;
}

final class SherpaOfflineRecognizerEngine {
  SherpaOfflineRecognizerEngine({
    required SherpaOfflineRecognizerConfig config,
    required SherpaNativeFactory nativeFactory,
    SpeechLogger logger = const NullSpeechLogger(),
  }) : sampleRate = config.sampleRate,
       _logger = logger.child({
         'module': 'speech',
         'provider': 'local',
         'component': 'offline-recognizer',
       }),
       _recognizer = _create(config, nativeFactory) {
    _logger.info(
      'Sherpa offline recognizer initialized',
      fields: {'sampleRate': sampleRate, 'numThreads': config.numThreads},
    );
  }

  final int sampleRate;
  final SpeechLogger _logger;
  final SherpaOfflineRecognizerHandle _recognizer;

  String decode(Float32List samples, {int? inputSampleRate}) {
    final stream = _recognizer.createStream();
    try {
      stream.acceptWaveform(
        samples: samples,
        sampleRate: inputSampleRate ?? sampleRate,
      );
      _recognizer.decode(stream);
      return _recognizer.getResultText(stream).trim();
    } finally {
      try {
        stream.free();
      } on Object {
        // Frozen stream cleanup is best effort.
      }
    }
  }

  void free() {
    try {
      _recognizer.free();
    } on Object catch (error) {
      _logger.warning(
        'Failed to free sherpa offline recognizer',
        fields: {'error': error},
      );
    }
  }

  static SherpaOfflineRecognizerHandle _create(
    SherpaOfflineRecognizerConfig config,
    SherpaNativeFactory nativeFactory,
  ) {
    _assertFile(config.model.encoder, 'offline encoder');
    _assertFile(config.model.decoder, 'offline decoder');
    _assertFile(config.model.joiner, 'offline joiner');
    _assertFile(config.model.tokens, 'tokens');
    return nativeFactory.createOfflineRecognizer(
      SherpaOfflineRecognizerNativeConfig(
        encoder: config.model.encoder,
        decoder: config.model.decoder,
        joiner: config.model.joiner,
        tokens: config.model.tokens,
        numThreads: config.numThreads,
        provider: config.provider,
        debug: config.debug,
        sampleRate: config.sampleRate,
        featureDim: config.featureDim,
        decodingMethod: config.decodingMethod,
        maxActivePaths: config.maxActivePaths,
      ),
    );
  }
}

void _assertFile(String path, String label) {
  if (!File(path).existsSync()) {
    throw StateError('Missing $label: $path');
  }
}
