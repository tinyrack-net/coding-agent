import 'dart:io';

import 'package:path/path.dart' as p;

import 'silero_vad_session.dart';
import 'speech_provider.dart';
import 'turn_detection_provider.dart';

const String sileroVadDirectoryName = 'silero-vad';
const String sileroVadFileName = 'silero_vad.onnx';

Future<String> ensureSileroVadModel({
  required String modelsDirectory,
  required String bundledModelPath,
  required SpeechLogger logger,
}) async {
  final destinationDirectory = p.join(modelsDirectory, sileroVadDirectoryName);
  final destinationPath = p.join(destinationDirectory, sileroVadFileName);
  final destination = File(destinationPath);
  try {
    if (await destination.exists() && await destination.length() > 0) {
      return destinationPath;
    }
  } catch (_) {
    // Missing or unreadable destinations are replaced from the bundle.
  }

  await Directory(destinationDirectory).create(recursive: true);
  await File(bundledModelPath).copy(destinationPath);
  logger.info(
    'Copied Silero VAD model to models directory',
    fields: {'destPath': destinationPath},
  );
  return destinationPath;
}

final class SileroTurnDetectionProvider implements TurnDetectionProvider {
  SileroTurnDetectionProvider({
    required SileroVadSessionConfig config,
    required SpeechLogger logger,
    required SileroVadBackendFactory createBackend,
  }) : _config = config,
       _logger = logger.child({
         'module': 'speech',
         'provider': 'local',
         'component': 'silero-vad',
       }),
       _createBackend = createBackend;

  final SileroVadSessionConfig _config;
  final SpeechLogger _logger;
  final SileroVadBackendFactory _createBackend;

  @override
  String get id => 'local';

  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) {
    _logger.debug(
      'Creating Silero VAD turn-detection session',
      fields: {
        'sampleRate': _config.sampleRate,
        if (_config.modelPath != null) 'modelPath': _config.modelPath,
      },
    );
    return SileroVadSession(
      logger: parameters.logger.child({
        'provider': 'local',
        'component': 'silero-vad-session',
      }),
      createBackend: _createBackend,
      config: _config,
    );
  }
}
