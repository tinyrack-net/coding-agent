import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/loop/loop_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory cwd;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('tinyrack_loop_home_');
    cwd = await Directory.systemTemp.createTemp('tinyrack_loop_cwd_');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
    if (await cwd.exists()) await cwd.delete(recursive: true);
  });

  group('LoopService', () {
    test(
      'runs worker and shell checks to success and persists records',
      () async {
        final factory = _FakeSessionFactory();
        final service = LoopService(
          home: home.path,
          createAgentSession: factory.call,
          idFactory: () => 'abcd1234',
          runVerifyCheck: (cwd, command) async => _check(command, passed: true),
        );

        final created = await service.runLoop(
          LoopRunRequest(
            requestId: 'r1',
            prompt: 'fix it',
            cwd: cwd.path,
            provider: 'codex',
            model: 'gpt-5.4',
            verifyChecks: const ['dart test'],
            archive: true,
            name: 'green',
          ),
        );
        expect(created.id, 'abcd1234');
        expect(created.status, LoopStatus.running);

        final completed = await _waitForTerminal(service, created.id);
        expect(completed.status, LoopStatus.succeeded);
        expect(completed.iterations, hasLength(1));
        expect(
          completed.iterations.single.workerOutcome,
          LoopWorkerOutcome.completed,
        );
        expect(completed.iterations.single.verifyChecks.single.passed, isTrue);
        expect(factory.specs.single.provider, 'codex');
        expect(factory.disposals, [(id: 'agent-1', archive: true)]);

        final listed = await service.listLoops();
        expect(listed.single.id, created.id);
        final logs = await service.getLoopLogs(created.id, afterSeq: 1);
        expect(logs.entries, isNotEmpty);
        expect(logs.nextCursor, completed.nextLogSeq - 1);
        expect((await service.inspectLoop('abcd')).id, created.id);

        final restored = LoopService(
          home: home.path,
          createAgentSession: factory.call,
        );
        await restored.initialize();
        expect(
          (await restored.inspectLoop(created.id)).status,
          LoopStatus.succeeded,
        );
      },
    );

    test('repeats failed checks and enforces max iterations', () async {
      final factory = _FakeSessionFactory();
      final service = LoopService(
        home: home.path,
        createAgentSession: factory.call,
        idFactory: () => 'deadbeef',
        runVerifyCheck: (cwd, command) async => _check(command, passed: false),
      );

      await service.runLoop(
        LoopRunRequest(
          requestId: 'r1',
          prompt: 'keep trying',
          cwd: cwd.path,
          verifyChecks: const ['exit 1'],
          maxIterations: 2,
        ),
      );
      final completed = await _waitForTerminal(service, 'dead');

      expect(completed.status, LoopStatus.failed);
      expect(completed.iterations, hasLength(2));
      expect(
        completed.iterations.map((iteration) => iteration.failureReason),
        everyElement('Verify check failed: exit 1'),
      );
      expect(completed.logs.last.text, 'Reached max iterations (2).');
      expect(factory.specs, hasLength(2));
    });

    test('uses one verifier session across structured retries', () async {
      final factory = _FakeSessionFactory(
        verifierOutputs: ['not json', '{"passed":true,"reason":"all green"}'],
      );
      final service = LoopService(
        home: home.path,
        createAgentSession: factory.call,
        idFactory: () => '11223344',
      );

      await service.runLoop(
        LoopRunRequest(
          requestId: 'r1',
          prompt: 'implement',
          cwd: cwd.path,
          verifyPrompt: 'review the result',
        ),
      );
      final completed = await _waitForTerminal(service, '1122');

      expect(completed.status, LoopStatus.succeeded);
      final result = completed.iterations.single.verifyPrompt!;
      expect(result.passed, isTrue);
      expect(result.reason, 'all green');
      expect(factory.specs, hasLength(2));
      expect(factory.sessions.last.prompts, hasLength(2));
    });

    test('stop cancels active worker and records stopped state', () async {
      final started = Completer<void>();
      final factory = _FakeSessionFactory(
        blockWorker: true,
        onWorkerStarted: () => started.complete(),
      );
      final service = LoopService(
        home: home.path,
        createAgentSession: factory.call,
        idFactory: () => '55667788',
      );
      await service.runLoop(
        LoopRunRequest(
          requestId: 'r1',
          prompt: 'long task',
          cwd: cwd.path,
          verifyChecks: const ['true'],
        ),
      );
      await started.future.timeout(const Duration(seconds: 2));

      final stopped = await service.stopLoop('5566');

      expect(stopped.status, LoopStatus.stopped);
      expect(stopped.stopRequestedAt, isNotNull);
      expect(stopped.iterations.single.status, LoopIterationStatus.stopped);
      expect(
        stopped.iterations.single.workerOutcome,
        LoopWorkerOutcome.canceled,
      );
      expect(factory.sessions.single.cancelled, isTrue);
    });

    test(
      'restart recovery stops durable running loops and active iteration',
      () async {
        final file = File(
          '${home.path}${Platform.pathSeparator}loops'
          '${Platform.pathSeparator}loops.json',
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode([_runningRecord(cwd.path).toJson()]),
        );
        final errors = <Object>[];
        final service = LoopService(
          home: home.path,
          createAgentSession: _FakeSessionFactory().call,
          onError: (error, _) => errors.add(error),
        );

        await service.initialize();
        final recovered = await service.inspectLoop('restart');

        expect(errors, isEmpty);
        expect(recovered.status, LoopStatus.stopped);
        expect(recovered.completedAt, isNotNull);
        expect(recovered.stopRequestedAt, isNotNull);
        expect(recovered.activeIteration, isNull);
        expect(recovered.iterations.single.status, LoopIterationStatus.stopped);
        expect(recovered.iterations.single.failureReason, 'Daemon restarted');
        expect(
          recovered.logs.last.text,
          'Loop was interrupted by daemon restart.',
        );
      },
    );

    test(
      'daemon shutdown preserves running state for restart recovery',
      () async {
        final started = Completer<void>();
        final factory = _FakeSessionFactory(
          blockWorker: true,
          onWorkerStarted: () => started.complete(),
        );
        final service = LoopService(
          home: home.path,
          createAgentSession: factory.call,
          idFactory: () => 'shutdown',
        );
        await service.runLoop(
          LoopRunRequest(
            requestId: 'r1',
            prompt: 'still running',
            cwd: cwd.path,
            verifyChecks: const ['ok'],
          ),
        );
        await started.future.timeout(const Duration(seconds: 2));

        await service.prepareForDaemonShutdown();
        expect(
          (await service.inspectLoop('shutdown')).status,
          LoopStatus.running,
        );

        final recovered = LoopService(
          home: home.path,
          createAgentSession: _FakeSessionFactory().call,
        );
        await recovered.initialize();
        final record = await recovered.inspectLoop('shutdown');
        expect(record.status, LoopStatus.stopped);
        expect(
          record.logs.last.text,
          'Loop was interrupted by daemon restart.',
        );
      },
    );

    test(
      'wire handler returns exact response shapes and contained errors',
      () async {
        final service = LoopService(
          home: home.path,
          createAgentSession: _FakeSessionFactory().call,
          idFactory: () => 'cafefeed',
          runVerifyCheck: (cwd, command) async => _check(command, passed: true),
        );
        final run = await service.handle({
          'type': 'loop/run',
          'requestId': 'r1',
          'prompt': 'go',
          'cwd': cwd.path,
          'verifyChecks': ['ok'],
        });
        expect(run!['type'], 'loop/run/response');
        expect((run['payload'] as Map)['requestId'], 'r1');
        await _waitForTerminal(service, 'cafe');

        final list = await service.handle({
          'type': 'loop/list',
          'requestId': 'r2',
        });
        expect(((list!['payload'] as Map)['loops'] as List), hasLength(1));

        final logs = await service.handle({
          'type': 'loop/logs',
          'requestId': 'r3',
          'id': 'cafe',
          'afterSeq': 0,
        });
        expect((logs!['payload'] as Map)['nextCursor'], greaterThan(0));

        final missing = await service.handle({
          'type': 'loop/inspect',
          'requestId': 'r4',
          'id': 'missing',
        });
        expect((missing!['payload'] as Map)['loop'], isNull);
        expect((missing['payload'] as Map)['error'], 'Loop not found: missing');
        expect(await service.handle({'type': 'agent/list'}), isNull);
      },
    );

    test('validates verifier, cwd, and ambiguous id requirements', () async {
      final ids = ['abc11111', 'abc22222'].iterator;
      final service = LoopService(
        home: home.path,
        createAgentSession: _FakeSessionFactory().call,
        idFactory: () {
          ids.moveNext();
          return ids.current;
        },
      );
      expect(
        () => service.runLoop(
          LoopRunRequest(requestId: 'r', prompt: 'go', cwd: cwd.path),
        ),
        throwsA(isA<StateError>()),
      );
      for (var index = 0; index < 2; index++) {
        await service.runLoop(
          LoopRunRequest(
            requestId: '$index',
            prompt: 'go',
            cwd: cwd.path,
            verifyChecks: const ['ok'],
            maxIterations: 1,
          ),
        );
      }
      await _waitForTerminal(service, 'abc11111');
      await _waitForTerminal(service, 'abc22222');
      expect(() => service.inspectLoop('abc'), throwsA(isA<StateError>()));
      expect(
        () => service.getLoopLogs('abc11111', afterSeq: -1),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('runLoopVerifyCheck captures success and failure', () async {
    final success = await runLoopVerifyCheck(
      cwd.path,
      Platform.isWindows ? 'echo ok' : 'printf ok',
    );
    expect(success.passed, isTrue);
    expect(success.stdout, contains('ok'));

    final failure = await runLoopVerifyCheck(
      cwd.path,
      Platform.isWindows ? 'exit /b 7' : 'exit 7',
    );
    expect(failure.passed, isFalse);
    expect(failure.exitCode, 7);
  });
}

Future<LoopRecord> _waitForTerminal(LoopService service, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (true) {
    final loop = await service.inspectLoop(id);
    if (loop.status != LoopStatus.running) return loop;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('loop $id did not finish');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

LoopVerifyCheckResult _check(String command, {required bool passed}) =>
    LoopVerifyCheckResult(
      command: command,
      exitCode: passed ? 0 : 1,
      passed: passed,
      stdout: passed ? 'ok' : '',
      stderr: passed ? '' : 'failed',
      startedAt: '2026-07-30T00:00:00.000Z',
      completedAt: '2026-07-30T00:00:01.000Z',
    );

final class _FakeSessionFactory {
  _FakeSessionFactory({
    this.verifierOutputs = const ['{"passed":true,"reason":"ok"}'],
    this.blockWorker = false,
    this.onWorkerStarted,
  });

  final List<String> verifierOutputs;
  final bool blockWorker;
  final void Function()? onWorkerStarted;
  final List<LoopAgentSpec> specs = [];
  final List<_FakeSession> sessions = [];
  final List<({String id, bool archive})> disposals = [];

  Future<LoopAgentSession> call(LoopAgentSpec spec) async {
    specs.add(spec);
    final verifier = spec.title.endsWith('verifier]');
    final session = _FakeSession(
      id: 'agent-${sessions.length + 1}',
      outputs: verifier ? [...verifierOutputs] : const ['worker done'],
      block: blockWorker && !verifier,
      onStarted: verifier ? null : onWorkerStarted,
      onDispose: (id, archive) => disposals.add((id: id, archive: archive)),
    );
    sessions.add(session);
    return session;
  }
}

final class _FakeSession implements LoopAgentSession {
  _FakeSession({
    required String id,
    required List<String> outputs,
    required this.block,
    required this.onStarted,
    required this.onDispose,
  }) : agentId = id,
       _outputs = List<String>.of(outputs);

  @override
  final String agentId;
  final List<String> _outputs;
  final bool block;
  final void Function()? onStarted;
  final void Function(String id, bool archive) onDispose;
  final List<String> prompts = [];
  final Completer<void> _blocked = Completer<void>();
  bool cancelled = false;

  @override
  Future<String> run(String prompt) async {
    prompts.add(prompt);
    onStarted?.call();
    if (block) {
      await _blocked.future;
      throw StateError('cancelled');
    }
    if (_outputs.isEmpty) return '';
    return _outputs.removeAt(0);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!_blocked.isCompleted) _blocked.complete();
  }

  @override
  Future<void> dispose({required bool archive}) async {
    onDispose(agentId, archive);
  }
}

LoopRecord _runningRecord(String cwd) => LoopRecord(
  id: 'restart1',
  name: null,
  prompt: 'go',
  cwd: cwd,
  provider: 'claude',
  model: null,
  modeId: null,
  workerProvider: null,
  workerModel: null,
  verifierProvider: null,
  verifierModel: null,
  verifierModeId: null,
  verifyPrompt: null,
  verifyChecks: const ['ok'],
  archive: false,
  sleepMs: 0,
  maxIterations: null,
  maxTimeMs: null,
  status: LoopStatus.running,
  createdAt: '2026-07-30T00:00:00.000Z',
  updatedAt: '2026-07-30T00:00:00.000Z',
  startedAt: '2026-07-30T00:00:00.000Z',
  completedAt: null,
  stopRequestedAt: null,
  iterations: const [
    LoopIterationRecord(
      index: 1,
      workerAgentId: 'worker',
      workerStartedAt: '2026-07-30T00:00:00.000Z',
      workerCompletedAt: null,
      verifierAgentId: null,
      status: LoopIterationStatus.running,
      workerOutcome: null,
      failureReason: null,
      verifyChecks: [],
      verifyPrompt: null,
    ),
  ],
  logs: const [],
  nextLogSeq: 1,
  activeIteration: 1,
  activeWorkerAgentId: 'worker',
  activeVerifierAgentId: null,
);
