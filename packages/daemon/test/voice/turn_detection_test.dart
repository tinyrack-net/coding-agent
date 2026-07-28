import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/silero_vad_provider.dart';
import 'package:agent_daemon/src/voice/silero_vad_session.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('confirms speech and stops after sustained silence', () async {
    final backend = _ScriptedBackend([true, true, true, false, false, false]);
    final session = _session(backend);
    var started = 0;
    var stopped = 0;
    final subscriptions = [
      session.speechStartedEvents.listen((_) => started += 1),
      session.speechStoppedEvents.listen((_) => stopped += 1),
    ];

    await session.connect();
    session.appendPcm16(_pcm16(List.filled(13, 100)));

    expect(started, 1);
    expect(stopped, 1);
    expect(backend.accepted, hasLength(6));
    expect(backend.accepted.every((window) => window.length == 2), isTrue);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('drops unconfirmed speech and supports speech resumption', () async {
    final dropped = _ScriptedBackend([true, false]);
    final droppedSession = _session(dropped);
    var droppedStarts = 0;
    droppedSession.speechStartedEvents.listen((_) => droppedStarts += 1);
    await droppedSession.connect();
    droppedSession.appendPcm16(_pcm16(List.filled(5, 100)));
    droppedSession.flush();
    expect(droppedStarts, 0);

    final resumed = _ScriptedBackend([true, true, false, true, false, false]);
    final resumedSession = _session(
      resumed,
      confirmDuration: const Duration(milliseconds: 2),
      silenceDuration: const Duration(milliseconds: 2),
    );
    var starts = 0;
    var stops = 0;
    resumedSession.speechStartedEvents.listen((_) => starts += 1);
    resumedSession.speechStoppedEvents.listen((_) => stops += 1);
    await resumedSession.connect();
    resumedSession.appendPcm16(_pcm16(List.filled(13, 100)));

    expect(starts, 1);
    expect(stops, 1);
  });

  test('flush forces a stop for confirmed speech', () async {
    final backend = _ScriptedBackend([true, true]);
    final session = _session(
      backend,
      confirmDuration: const Duration(milliseconds: 2),
    );
    var started = 0;
    var stopped = 0;
    session.speechStartedEvents.listen((_) => started += 1);
    session.speechStoppedEvents.listen((_) => stopped += 1);

    await session.connect();
    session.appendPcm16(_pcm16(List.filled(5, 100)));
    session.flush();

    expect(started, 1);
    expect(stopped, 1);
    expect(backend.flushCalls, 1);
  });

  test('flush discards confirming speech and stops the ending phase', () async {
    final confirmingBackend = _ScriptedBackend([true]);
    final confirming = _session(confirmingBackend);
    var confirmingStarts = 0;
    var confirmingStops = 0;
    confirming.speechStartedEvents.listen((_) => confirmingStarts += 1);
    confirming.speechStoppedEvents.listen((_) => confirmingStops += 1);
    await confirming.connect();
    confirming.appendPcm16(_pcm16(List.filled(3, 100)));
    confirming.flush();
    expect(confirmingStarts, 0);
    expect(confirmingStops, 0);

    final endingBackend = _ScriptedBackend([true, true, false]);
    final ending = _session(
      endingBackend,
      confirmDuration: const Duration(milliseconds: 2),
    );
    var endingStops = 0;
    ending.speechStoppedEvents.listen((_) => endingStops += 1);
    await ending.connect();
    ending.appendPcm16(_pcm16(List.filled(7, 100)));
    ending.flush();
    expect(endingStops, 1);
  });

  test('exactly one full window waits for another sample', () async {
    final backend = _ScriptedBackend([false]);
    final session = _session(backend);
    await session.connect();

    session.appendPcm16(_pcm16([1, 2]));
    expect(backend.accepted, isEmpty);
    session.appendPcm16(_pcm16([3]));
    expect(backend.accepted, hasLength(1));
  });

  test(
    'disconnected, malformed, and backend failures emit typed errors',
    () async {
      final backend = _ScriptedBackend([false], acceptError: 'native failure');
      final session = _session(backend);
      final errors = <Object?>[];
      session.errors.listen(errors.add);

      session.appendPcm16(_pcm16([1, 2, 3]));
      await session.connect();
      session.appendPcm16(Uint8List.fromList([1]));
      session.appendPcm16(_pcm16([1, 2, 3]));

      expect(errors, hasLength(3));
      expect(errors[0], isA<StateError>());
      expect(
        (errors[0]! as StateError).message,
        'Turn detection session not connected',
      );
      expect(errors[1], isA<FormatException>());
      expect(errors[2], isA<StateError>());
      expect((errors[2]! as StateError).message, 'native failure');
    },
  );

  test('flush errors emit and disconnected flush is a no-op', () async {
    final backend = _ScriptedBackend(const [], flushError: StateError('flush'));
    final session = _session(backend);
    final errors = <Object?>[];
    session.errors.listen(errors.add);

    session.flush();
    expect(backend.flushCalls, 0);
    await session.connect();
    session.flush();

    expect(backend.flushCalls, 1);
    expect(errors.single, isA<StateError>());
  });

  test(
    'reset and close clear phase while swallowing native reset failures',
    () async {
      final backend = _ScriptedBackend([
        true,
        true,
      ], resetError: StateError('cleanup'));
      final session = _session(
        backend,
        confirmDuration: const Duration(milliseconds: 2),
      );
      var starts = 0;
      session.speechStartedEvents.listen((_) => starts += 1);
      await session.connect();
      session.appendPcm16(_pcm16(List.filled(5, 100)));
      expect(starts, 1);

      expect(session.reset, returnsNormally);
      expect(session.close, returnsNormally);
      expect(backend.resetCalls, 2);
      session.appendPcm16(_pcm16([1, 2, 3]));
    },
  );

  test('successful reset clears pending samples', () async {
    final backend = _ScriptedBackend([false]);
    final session = _session(backend);
    await session.connect();
    session.appendPcm16(_pcm16([1, 2]));
    session.reset();
    session.appendPcm16(_pcm16([3]));

    expect(backend.resetCalls, 1);
    expect(backend.accepted, isEmpty);
  });

  test('large input compacts the internal sample buffer', () async {
    final backend = _ScriptedBackend(const []);
    final session = _session(backend, windowSize: 1);
    await session.connect();
    session.appendPcm16(_pcm16(List.filled(4100, 0)));

    expect(backend.accepted, hasLength(4099));
  });

  test('provider forwards config, logger context, and backend factory', () {
    final logger = _RecordingLogger();
    SileroVadBackendConfig? backendConfig;
    final backend = _ScriptedBackend(const []);
    final provider = SileroTurnDetectionProvider(
      config: const SileroVadSessionConfig(
        modelPath: 'model.onnx',
        sampleRate: 8000,
        threshold: 0.75,
        windowSize: 256,
        bufferSizeSeconds: 30,
      ),
      logger: logger,
      createBackend: (config) {
        backendConfig = config;
        return backend;
      },
    );

    final session = provider.createSession(
      TurnDetectionSessionParameters(logger: logger),
    );

    expect(provider.id, 'local');
    expect(session.requiredSampleRate, 8000);
    expect(backendConfig?.modelPath, 'model.onnx');
    expect(backendConfig?.threshold, 0.75);
    expect(backendConfig?.windowSize, 256);
    expect(backendConfig?.bufferSizeSeconds, 30);
    expect(backendConfig?.minSilenceDuration, 0.2);
    expect(backendConfig?.minSpeechDuration, 0.1);
    expect(backendConfig?.numThreads, 1);
    expect(backendConfig?.provider, 'cpu');
    expect(backendConfig?.debug, 0);
    expect(
      logger.childContexts,
      containsAll([
        {'module': 'speech', 'provider': 'local', 'component': 'silero-vad'},
        {'provider': 'local', 'component': 'silero-vad-session'},
      ]),
    );
  });

  test(
    'model deployment copies missing/empty model and preserves existing',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-silero-',
      );
      try {
        final source = File(p.join(temporary.path, 'bundled.onnx'));
        await source.writeAsBytes([1, 2, 3]);
        final models = p.join(temporary.path, 'models');
        final logger = _RecordingLogger();

        final destination = await ensureSileroVadModel(
          modelsDirectory: models,
          bundledModelPath: source.path,
          logger: logger,
        );
        expect(await File(destination).readAsBytes(), [1, 2, 3]);
        expect(logger.infoMessages, hasLength(1));

        await source.writeAsBytes([9]);
        final preserved = await ensureSileroVadModel(
          modelsDirectory: models,
          bundledModelPath: source.path,
          logger: logger,
        );
        expect(preserved, destination);
        expect(await File(destination).readAsBytes(), [1, 2, 3]);
        expect(logger.infoMessages, hasLength(1));

        await File(destination).writeAsBytes([]);
        await ensureSileroVadModel(
          modelsDirectory: models,
          bundledModelPath: source.path,
          logger: logger,
        );
        expect(await File(destination).readAsBytes(), [9]);
        expect(logger.infoMessages, hasLength(2));
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );
}

SileroVadSession _session(
  _ScriptedBackend backend, {
  Duration confirmDuration = const Duration(milliseconds: 4),
  Duration silenceDuration = const Duration(milliseconds: 4),
  int windowSize = 2,
}) {
  return SileroVadSession(
    logger: _RecordingLogger(),
    createBackend: (_) => backend,
    config: SileroVadSessionConfig(
      sampleRate: 1000,
      windowSize: windowSize,
      confirmDuration: confirmDuration,
      silenceDuration: silenceDuration,
    ),
  );
}

final class _ScriptedBackend implements SileroVadBackend {
  _ScriptedBackend(
    this.detections, {
    this.acceptError,
    this.flushError,
    this.resetError,
  });

  final List<bool> detections;
  final Object? acceptError;
  final Object? flushError;
  final Object? resetError;
  final List<Float32List> accepted = [];
  var _index = 0;
  var _detected = false;
  var flushCalls = 0;
  var resetCalls = 0;

  @override
  void acceptWaveform(Float32List samples) {
    if (acceptError != null) throw acceptError!;
    accepted.add(Float32List.fromList(samples));
    _detected = _index < detections.length ? detections[_index] : false;
    _index += 1;
  }

  @override
  bool get isDetected => _detected;

  @override
  void flush() {
    flushCalls += 1;
    if (flushError != null) throw flushError!;
  }

  @override
  void reset() {
    resetCalls += 1;
    if (resetError != null) throw resetError!;
    _index = 0;
    _detected = false;
  }
}

final class _RecordingLogger implements SpeechLogger {
  final List<Map<String, Object?>> childContexts = [];
  final List<String> infoMessages = [];

  @override
  SpeechLogger child(Map<String, Object?> context) {
    childContexts.add(context);
    return this;
  }

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {
    infoMessages.add(message);
  }

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}

Uint8List _pcm16(List<int> samples) {
  final output = Uint8List(samples.length * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index += 1) {
    bytes.setInt16(index * 2, samples[index], Endian.little);
  }
  return output;
}
