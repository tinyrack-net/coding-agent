import 'dart:async';
import 'dart:typed_data';

import 'audio.dart';
import 'speech_provider.dart';
import 'turn_detection_provider.dart';

const int defaultSileroSampleRate = 16000;
const int defaultSileroBufferSizeSeconds = 60;
const double defaultSileroThreshold = 0.5;
const int defaultSileroWindowSize = 512;
const double defaultSileroMinSilenceDuration = 0.2;
const double defaultSileroMinSpeechDuration = 0.1;
const Duration defaultSileroConfirmDuration = Duration(milliseconds: 800);
const Duration defaultSileroSilenceDuration = Duration(milliseconds: 1000);

final class SileroVadSessionConfig {
  const SileroVadSessionConfig({
    this.modelPath,
    this.sampleRate = defaultSileroSampleRate,
    this.threshold = defaultSileroThreshold,
    this.windowSize = defaultSileroWindowSize,
    this.bufferSizeSeconds = defaultSileroBufferSizeSeconds,
    this.confirmDuration = defaultSileroConfirmDuration,
    this.silenceDuration = defaultSileroSilenceDuration,
  });

  final String? modelPath;
  final int sampleRate;
  final double threshold;
  final int windowSize;
  final int bufferSizeSeconds;
  final Duration confirmDuration;
  final Duration silenceDuration;
}

final class SileroVadBackendConfig {
  const SileroVadBackendConfig({
    required this.modelPath,
    required this.threshold,
    required this.minSilenceDuration,
    required this.minSpeechDuration,
    required this.windowSize,
    required this.sampleRate,
    required this.bufferSizeSeconds,
    required this.numThreads,
    required this.provider,
    required this.debug,
  });

  final String? modelPath;
  final double threshold;
  final double minSilenceDuration;
  final double minSpeechDuration;
  final int windowSize;
  final int sampleRate;
  final int bufferSizeSeconds;
  final int numThreads;
  final String provider;
  final int debug;
}

abstract interface class SileroVadBackend {
  void acceptWaveform(Float32List samples);
  bool get isDetected;
  void flush();
  void reset();
}

typedef SileroVadBackendFactory =
    SileroVadBackend Function(SileroVadBackendConfig config);

final class SileroVadSession implements TurnDetectionSession {
  SileroVadSession({
    required SpeechLogger logger,
    required SileroVadBackendFactory createBackend,
    SileroVadSessionConfig config = const SileroVadSessionConfig(),
  }) : _logger = logger,
       _config = config,
       _millisecondsPerWindow = (config.windowSize / config.sampleRate) * 1000,
       _backend = createBackend(
         SileroVadBackendConfig(
           modelPath: config.modelPath,
           threshold: config.threshold,
           minSilenceDuration: defaultSileroMinSilenceDuration,
           minSpeechDuration: defaultSileroMinSpeechDuration,
           windowSize: config.windowSize,
           sampleRate: config.sampleRate,
           bufferSizeSeconds: config.bufferSizeSeconds,
           numThreads: 1,
           provider: 'cpu',
           debug: 0,
         ),
       ) {
    _logger.debug(
      '[VAD] Initializing Silero VAD session',
      fields: {
        'threshold': config.threshold,
        'sileroMinSilenceDuration': defaultSileroMinSilenceDuration,
        'sileroMinSpeechDuration': defaultSileroMinSpeechDuration,
        'confirmMs': config.confirmDuration.inMilliseconds,
        'silenceMs': config.silenceDuration.inMilliseconds,
        'windowSize': config.windowSize,
        'msPerWindow': _millisecondsPerWindow,
        'sampleRate': config.sampleRate,
      },
    );
  }

  final SpeechLogger _logger;
  final SileroVadSessionConfig _config;
  final SileroVadBackend _backend;
  final double _millisecondsPerWindow;
  final _FloatSampleBuffer _inputBuffer = _FloatSampleBuffer();
  final StreamController<void> _speechStarted =
      StreamController<void>.broadcast(sync: true);
  final StreamController<void> _speechStopped =
      StreamController<void>.broadcast(sync: true);
  final StreamController<Object?> _errors = StreamController<Object?>.broadcast(
    sync: true,
  );
  _VadPhase _phase = const _VadIdle();
  bool _connected = false;
  double _windowTimestamp = 0;

  @override
  int get requiredSampleRate => _config.sampleRate;

  @override
  Stream<void> get speechStartedEvents => _speechStarted.stream;

  @override
  Stream<void> get speechStoppedEvents => _speechStopped.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  void appendPcm16(Uint8List pcm16le) {
    if (!_connected) {
      _errors.add(StateError('Turn detection session not connected'));
      return;
    }
    if (pcm16le.isEmpty) return;

    try {
      _inputBuffer.push(pcm16leToFloat32(pcm16le));
      while (_inputBuffer.size > _config.windowSize) {
        final window = _inputBuffer.take(_config.windowSize);
        _inputBuffer.pop(_config.windowSize);
        _backend.acceptWaveform(window);
        _windowTimestamp += _millisecondsPerWindow;
        _stepStateMachine();
      }
    } catch (error) {
      _errors.add(_normalizeError(error));
    }
  }

  @override
  void flush() {
    if (!_connected) return;
    try {
      _logger.debug(
        '[VAD] Flushing remaining audio',
        fields: {'phase': _phase.name},
      );
      _backend.flush();
      _stepStateMachine();
      switch (_phase) {
        case _VadSpeaking() || _VadEnding():
          _logger.debug('[VAD] Forcing speech_stopped after flush');
          _phase = const _VadIdle();
          _speechStopped.add(null);
        case _VadConfirming():
          _logger.debug('[VAD] Discarding unconfirmed speech on flush');
          _phase = const _VadIdle();
        case _VadIdle():
          break;
      }
    } catch (error) {
      _errors.add(_normalizeError(error));
    }
  }

  @override
  void reset() {
    try {
      _backend.reset();
      _inputBuffer.reset();
    } catch (_) {
      // Frozen native cleanup failures are deliberately ignored.
    } finally {
      _phase = const _VadIdle();
    }
  }

  @override
  void close() {
    reset();
    _connected = false;
    _windowTimestamp = 0;
  }

  void _stepStateMachine() {
    final detected = _backend.isDetected;
    final now = _windowTimestamp;
    switch (_phase) {
      case _VadIdle():
        if (detected) {
          _logger.debug(
            '[VAD] idle → confirming (detection started)',
            fields: {'now': now},
          );
          _phase = _VadConfirming(now);
        }
      case _VadConfirming(:final startedAt):
        if (!detected) {
          _logger.debug(
            '[VAD] confirming → idle (detection dropped before confirmation)',
            fields: {
              'elapsed': now - startedAt,
              'confirmMs': _config.confirmDuration.inMilliseconds,
            },
          );
          _phase = const _VadIdle();
          return;
        }
        final elapsed = now - startedAt;
        if (elapsed >= _config.confirmDuration.inMilliseconds) {
          _logger.debug(
            '[VAD] confirming → speaking (speech confirmed)',
            fields: {
              'elapsed': elapsed,
              'confirmMs': _config.confirmDuration.inMilliseconds,
            },
          );
          _phase = const _VadSpeaking();
          _speechStarted.add(null);
        }
      case _VadSpeaking():
        if (!detected) {
          _logger.debug(
            '[VAD] speaking → ending (silence started)',
            fields: {'now': now},
          );
          _phase = _VadEnding(now);
        }
      case _VadEnding(:final startedAt):
        if (detected) {
          _logger.debug(
            '[VAD] ending → speaking (speech resumed)',
            fields: {'elapsed': now - startedAt},
          );
          _phase = const _VadSpeaking();
          return;
        }
        final elapsed = now - startedAt;
        if (elapsed >= _config.silenceDuration.inMilliseconds) {
          _logger.debug(
            '[VAD] ending → idle (speech stopped)',
            fields: {
              'elapsed': elapsed,
              'silenceMs': _config.silenceDuration.inMilliseconds,
            },
          );
          _phase = const _VadIdle();
          _speechStopped.add(null);
        }
    }
  }
}

Object _normalizeError(Object error) =>
    error is Error || error is Exception ? error : StateError('$error');

sealed class _VadPhase {
  const _VadPhase();

  String get name;
}

final class _VadIdle extends _VadPhase {
  const _VadIdle();

  @override
  String get name => 'idle';
}

final class _VadConfirming extends _VadPhase {
  const _VadConfirming(this.startedAt);

  final double startedAt;

  @override
  String get name => 'confirming';
}

final class _VadSpeaking extends _VadPhase {
  const _VadSpeaking();

  @override
  String get name => 'speaking';
}

final class _VadEnding extends _VadPhase {
  const _VadEnding(this.startedAt);

  final double startedAt;

  @override
  String get name => 'ending';
}

final class _FloatSampleBuffer {
  final List<double> _samples = [];
  int _head = 0;

  int get size => _samples.length - _head;

  void push(Float32List samples) => _samples.addAll(samples);

  Float32List take(int count) =>
      Float32List.fromList(_samples.sublist(_head, _head + count));

  void pop(int count) {
    _head += count;
    if (_head > 4096 && _head * 2 >= _samples.length) {
      _samples.removeRange(0, _head);
      _head = 0;
    }
  }

  void reset() {
    _samples.clear();
    _head = 0;
  }
}
