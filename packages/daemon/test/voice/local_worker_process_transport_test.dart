import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('resolves configured, development, and bundled worker commands', () {
    final platformDefault = resolveLocalSpeechWorkerCommand();
    expect(platformDefault.executable, isNotEmpty);

    final configured = resolveLocalSpeechWorkerCommand(
      environment: const {
        localSpeechWorkerExecutableEnvironment: r'C:\voice\worker.exe',
      },
      resolvedExecutable: r'C:\dart\dart.exe',
      isWindows: true,
    );
    expect(configured.executable, r'C:\voice\worker.exe');
    expect(configured.arguments, isEmpty);

    final development = resolveLocalSpeechWorkerCommand(
      environment: const {},
      resolvedExecutable: r'C:\dart\dart.exe',
      isWindows: true,
    );
    expect(development.executable, r'C:\dart\dart.exe');
    expect(development.arguments, ['run', 'agent_daemon:local_speech_worker']);

    final bundled = resolveLocalSpeechWorkerCommand(
      environment: const {},
      resolvedExecutable: r'C:\app\coding-agent.exe',
      isWindows: true,
      fileExists: (path) => path == r'C:\app\coding-agent-voice.exe',
    );
    expect(bundled.executable, r'C:\app\coding-agent-voice.exe');

    expect(
      () => resolveLocalSpeechWorkerCommand(
        environment: const {},
        resolvedExecutable: r'C:\app\coding-agent.exe',
        isWindows: true,
        fileExists: (_) => false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains(localSpeechWorkerExecutableEnvironment),
        ),
      ),
    );
  });

  test('discovers a Nix-packaged worker and its native library path', () {
    final nixPaths = p.Context(style: p.Style.posix);
    const runtime = '/nix/store/tinyrack/bin/coding-agent';
    final worker = nixPaths.join(
      '/nix/store/tinyrack',
      'libexec',
      'tinyrack',
      'coding-agent-voice',
    );
    final nativeDirectory = nixPaths.join(
      '/nix/store/tinyrack',
      'lib',
      'tinyrack',
    );
    final command = resolveLocalSpeechWorkerCommand(
      environment: const {'LD_LIBRARY_PATH': '/nix/store/runtime/lib'},
      resolvedExecutable: runtime,
      operatingSystem: 'linux',
      fileExists: (path) =>
          path == worker ||
          path == nixPaths.join(nativeDirectory, 'libsherpa-onnx-c-api.so'),
    );

    expect(command.executable, nixPaths.normalize(worker));
    expect(
      command.environment?[sherpaLibraryDirectoryEnvironment],
      nixPaths.normalize(nativeDirectory),
    );
    expect(
      command.environment?['LD_LIBRARY_PATH'],
      '${nixPaths.normalize(nativeDirectory)}:/nix/store/runtime/lib',
    );
  });

  test('process transport exchanges JSON lines, bytes, and stderr', () async {
    final transport = await _startEchoWorker();
    final messages = <LocalSpeechWorkerMessage>[];
    final stderr = <int>[];
    final malformedError = Completer<Object>();
    final messageSubscription = transport.messages.listen(
      messages.add,
      onError: (Object error) {
        if (!malformedError.isCompleted) malformedError.complete(error);
      },
    );
    final stderrSubscription = transport.stderr.listen(stderr.addAll);
    expect(transport.connected, isTrue);
    expect(transport.killed, isFalse);
    expect(transport.pid, greaterThan(0));

    final requests = [
      for (var index = 0; index < 480; index++)
        LocalSpeechTtsSynthesizeRequest(
          requestId: 'r$index',
          config: _config,
          text: 'hello-$index',
        ),
    ];
    await Future.wait([
      for (final request in requests) transport.send(request),
    ]);
    await _waitUntil(() => messages.length == requests.length);

    expect(
      messages.whereType<LocalSpeechWorkerResponse>().map(
        (response) => response.requestId,
      ),
      [for (var index = 0; index < 480; index++) 'r$index'],
    );
    final first = messages.first as LocalSpeechWorkerResponse;
    expect(
      LocalSpeechTtsResult.fromJson(first.result).audio,
      'hello-0'.codeUnits,
    );
    await _waitUntil(() => stderr.isNotEmpty);
    expect(String.fromCharCodes(stderr), contains('received tts.synthesize'));

    await transport.send(
      const LocalSpeechTtsSynthesizeRequest(
        requestId: 'bad',
        config: _config,
        text: 'malformed',
      ),
    );
    expect(
      await malformedError.future.timeout(const Duration(seconds: 15)),
      isA<FormatException>(),
    );

    await transport.shutdown();
    final exit = await transport.exited.timeout(const Duration(seconds: 5));
    expect(exit.exitCode, isNotNull);
    expect(transport.connected, isFalse);
    expect(transport.killed, isTrue);
    await expectLater(
      transport.send(
        const LocalSpeechTtsSynthesizeRequest(
          requestId: 'late',
          config: _config,
          text: 'late',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    await messageSubscription.cancel();
    await stderrSubscription.cancel();
    await (transport as LocalSpeechWorkerProcessTransport).dispose();
  });
}

const LocalSpeechWorkerConfig _config = LocalSpeechWorkerConfig(
  modelsDirectory: 'models',
  voiceSttModel: 'parakeet-tdt-0.6b-v2-int8',
  dictationSttModel: 'parakeet-tdt-0.6b-v2-int8',
  voiceTtsModel: 'kokoro-en-v0_19',
);

Future<LocalSpeechWorkerTransport> _startEchoWorker() =>
    startLocalSpeechWorkerProcess(
      command: LocalSpeechWorkerCommand(
        executable: Platform.resolvedExecutable,
        arguments: const ['run', 'test/fixtures/local_speech_echo_worker.dart'],
        workingDirectory: _daemonDirectory(),
        environment: Platform.environment,
      ),
    );

String _daemonDirectory() {
  final nested = p.join(p.current, 'packages', 'daemon');
  return Directory(nested).existsSync() ? nested : p.current;
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
