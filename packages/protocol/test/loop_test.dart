import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('loop wire models', () {
    test('record round-trips every Paseo field', () {
      final record = _record();

      expect(LoopRecord.fromJson(record.toJson()).toJson(), record.toJson());
      expect(
        LoopListItem.fromJson(
          const LoopListItem(
            id: 'abcd1234',
            name: 'ship it',
            status: LoopStatus.running,
            cwd: r'C:\repo',
            createdAt: '2026-07-30T00:00:00.000Z',
            updatedAt: '2026-07-30T00:00:01.000Z',
            activeIteration: 1,
          ).toJson(),
        ).activeIteration,
        1,
      );
    });

    test('request models use exact frozen message names and payloads', () {
      final run = LoopRunRequest.fromJson({
        'type': 'loop/run',
        'requestId': 'r1',
        'prompt': 'fix tests',
        'cwd': r'C:\repo',
        'provider': 'codex',
        'model': 'gpt-5.4',
        'modeId': 'full-access',
        'workerProvider': 'claude',
        'workerModel': 'opus',
        'verifierProvider': 'codex',
        'verifierModel': 'gpt-5.4-mini',
        'verifierModeId': 'read-only',
        'verifyPrompt': 'verify it',
        'verifyChecks': ['dart test'],
        'archive': true,
        'name': 'green',
        'sleepMs': 50,
        'maxIterations': 3,
        'maxTimeMs': 60000,
      });
      expect(run.toJson()['type'], 'loop/run');
      expect(run.workerProvider, 'claude');
      expect(run.verifyChecks, ['dart test']);

      expect(
        LoopListRequest.fromJson({
          'type': 'loop/list',
          'requestId': '',
        }).toJson(),
        {'type': 'loop/list', 'requestId': ''},
      );
      expect(
        LoopRunRequest.fromJson({
          'type': 'loop/run',
          'requestId': '',
          'prompt': ' go ',
          'cwd': '.',
          'provider': '',
        }).toJson(),
        {
          'type': 'loop/run',
          'requestId': '',
          'prompt': 'go',
          'cwd': '.',
          'provider': '',
        },
      );
      expect(
        LoopIdRequest.fromJson({
          'type': 'loop/logs',
          'requestId': 'r3',
          'id': 'abcd',
          'afterSeq': 4,
        }).toJson(),
        {'type': 'loop/logs', 'requestId': 'r3', 'id': 'abcd', 'afterSeq': 4},
      );
      expect(
        loopResponse(
          requestType: LoopIdRequest.stopType,
          requestId: 'r4',
          payload: {'loop': null, 'error': null},
        ),
        {
          'type': 'loop/stop/response',
          'payload': {'requestId': 'r4', 'loop': null, 'error': null},
        },
      );
    });

    test('schema boundaries reject invalid enums, ids, and integers', () {
      expect(
        () => LoopRunRequest.fromJson({
          'type': 'loop/run',
          'requestId': 'r',
          'prompt': ' ',
          'cwd': '.',
        }),
        throwsFormatException,
      );
      expect(
        () => LoopRunRequest.fromJson({
          'type': 'loop/run',
          'requestId': 'r',
          'prompt': 'go',
          'cwd': '.',
          'sleepMs': -1,
        }),
        throwsFormatException,
      );
      expect(
        () => LoopIdRequest.fromJson({
          'type': 'loop/stop',
          'requestId': 'r',
          'id': 'x',
          'afterSeq': 1,
        }),
        throwsFormatException,
      );
      final json = _record().toJson()..['status'] = 'paused';
      expect(() => LoopRecord.fromJson(json), throwsFormatException);
    });
  });
}

LoopRecord _record() => const LoopRecord(
  id: 'abcd1234',
  name: 'ship it',
  prompt: 'fix tests',
  cwd: r'C:\repo',
  provider: 'codex',
  model: 'gpt-5.4',
  modeId: 'full-access',
  workerProvider: 'claude',
  workerModel: 'opus',
  verifierProvider: 'codex',
  verifierModel: 'gpt-5.4-mini',
  verifierModeId: 'read-only',
  verifyPrompt: 'verify',
  verifyChecks: ['dart test'],
  archive: true,
  sleepMs: 25,
  maxIterations: 3,
  maxTimeMs: 60000,
  status: LoopStatus.running,
  createdAt: '2026-07-30T00:00:00.000Z',
  updatedAt: '2026-07-30T00:00:01.000Z',
  startedAt: '2026-07-30T00:00:00.000Z',
  completedAt: null,
  stopRequestedAt: null,
  iterations: [
    LoopIterationRecord(
      index: 1,
      workerAgentId: 'worker-1',
      workerStartedAt: '2026-07-30T00:00:00.000Z',
      workerCompletedAt: '2026-07-30T00:00:01.000Z',
      verifierAgentId: 'verifier-1',
      status: LoopIterationStatus.running,
      workerOutcome: LoopWorkerOutcome.completed,
      failureReason: null,
      verifyChecks: [
        LoopVerifyCheckResult(
          command: 'dart test',
          exitCode: 0,
          passed: true,
          stdout: 'ok',
          stderr: '',
          startedAt: '2026-07-30T00:00:00.000Z',
          completedAt: '2026-07-30T00:00:01.000Z',
        ),
      ],
      verifyPrompt: LoopVerifyPromptResult(
        passed: true,
        reason: 'green',
        verifierAgentId: 'verifier-1',
        startedAt: '2026-07-30T00:00:00.000Z',
        completedAt: '2026-07-30T00:00:01.000Z',
      ),
    ),
  ],
  logs: [
    LoopLogEntry(
      seq: 1,
      timestamp: '2026-07-30T00:00:00.000Z',
      iteration: null,
      source: LoopLogSource.loop,
      level: LoopLogLevel.info,
      text: 'created',
    ),
  ],
  nextLogSeq: 2,
  activeIteration: 1,
  activeWorkerAgentId: 'worker-1',
  activeVerifierAgentId: 'verifier-1',
);
