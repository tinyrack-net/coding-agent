import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../audio.dart';
import '../../speech_provider.dart';
import 'native.dart';

final class SherpaTtsConfig {
  const SherpaTtsConfig({
    required this.modelDirectory,
    this.speakerId = 0,
    this.speed = 1,
    this.lengthScale = 1,
    this.numThreads = 2,
  });

  final String modelDirectory;
  final int speakerId;
  final double speed;
  final double lengthScale;
  final int numThreads;
}

final class SherpaOnnxTts implements TextToSpeechProvider {
  SherpaOnnxTts({
    required SherpaTtsConfig config,
    required SherpaNativeFactory nativeFactory,
    SpeechLogger logger = const NullSpeechLogger(),
  }) : _speakerId = config.speakerId,
       _speed = config.speed,
       _logger = logger.child({
         'module': 'speech',
         'provider': 'local',
         'component': 'tts',
       }),
       _tts = _create(config, nativeFactory) {
    _logger.info(
      'Sherpa offline TTS initialized',
      fields: {'preset': 'kokoro-en-v0_19', 'modelDir': config.modelDirectory},
    );
  }

  final SherpaOfflineTtsHandle _tts;
  final int _speakerId;
  final double _speed;
  final SpeechLogger _logger;

  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw StateError('Cannot synthesize empty text');
    }
    final audio = _tts.generate(
      text: trimmed,
      speakerId: _speakerId,
      speed: _speed,
    );
    final samples = Float32List.fromList(audio.samples);
    final sampleRate = audio.sampleRate > 0
        ? audio.sampleRate
        : (_tts.sampleRate > 0 ? _tts.sampleRate : 24000);
    final pcm16 = float32ToPcm16le(samples);
    final chunkBytes = (sampleRate * 0.05).round() * 2;
    return SpeechStreamResult(
      stream: Stream.fromIterable(
        chunkAudioBuffer(pcm16, chunkBytes < 2 ? 2 : chunkBytes),
      ),
      format: 'pcm;rate=$sampleRate',
    );
  }

  void free() {
    try {
      _tts.free();
    } on Object {
      // Frozen native cleanup is best effort.
    }
  }

  static SherpaOfflineTtsHandle _create(
    SherpaTtsConfig config,
    SherpaNativeFactory nativeFactory,
  ) {
    final model = p.join(config.modelDirectory, 'model.onnx');
    final voices = p.join(config.modelDirectory, 'voices.bin');
    final tokens = p.join(config.modelDirectory, 'tokens.txt');
    final dataDirectory = p.join(config.modelDirectory, 'espeak-ng-data');
    _assertFile(model, 'TTS model');
    _assertFile(voices, 'TTS voices');
    _assertFile(tokens, 'TTS tokens');
    if (!Directory(dataDirectory).existsSync()) {
      throw StateError('Missing TTS espeak-ng dataDir: $dataDirectory');
    }
    return nativeFactory.createOfflineTts(
      SherpaOfflineTtsNativeConfig(
        model: model,
        voices: voices,
        tokens: tokens,
        dataDirectory: dataDirectory,
        lengthScale: config.lengthScale,
        numThreads: config.numThreads,
      ),
    );
  }
}

void _assertFile(String path, String label) {
  if (!File(path).existsSync()) {
    throw StateError('Missing $label: $path');
  }
}
