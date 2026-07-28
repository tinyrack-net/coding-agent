import 'dart:async';

import 'package:agent_daemon/src/workspace/workspace_service_port_registry.dart';
import 'package:test/test.dart';

void main() {
  test('plans explicit and unique dynamic service ports once', () async {
    final registry = WorkspaceServicePortRegistry();
    var calls = 0;
    final plan = await registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [
        WorkspaceServicePortDeclaration(scriptName: 'api', port: 4000),
        WorkspaceServicePortDeclaration(scriptName: 'web'),
        WorkspaceServicePortDeclaration(scriptName: 'worker'),
      ],
      allocatePort: (request) async {
        calls++;
        expect(request.reservedPorts, contains(4000));
        return request.scriptName == 'web' ? 4001 : 4002;
      },
    );
    expect(plan, {'api': 4000, 'web': 4001, 'worker': 4002});
    expect(registry.requirePlannedPort(plan, 'web'), 4001);
    final cached = await registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [],
      allocatePort: (_) async => 9999,
    );
    expect(cached, plan);
    expect(calls, 2);
  });

  test('serializes concurrent planning and returns defensive maps', () async {
    final registry = WorkspaceServicePortRegistry();
    final gate = Completer<void>();
    var calls = 0;
    Future<int> allocate(WorkspaceServicePortAllocationRequest request) async {
      calls++;
      await gate.future;
      return 4100;
    }

    final first = registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: allocate,
    );
    final second = registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'other')],
      allocatePort: allocate,
    );
    gate.complete();
    final plans = await Future.wait([first, second]);
    expect(plans[0], {'web': 4100});
    expect(plans[1], {'web': 4100});
    plans[0]['mutated'] = 1;
    expect(plans[1].containsKey('mutated'), isFalse);
    expect(calls, 1);
  });

  test('rejects duplicate explicit ports and missing plan entries', () async {
    final registry = WorkspaceServicePortRegistry();
    await expectLater(
      registry.ensurePlan(
        workspaceId: 'duplicate',
        services: const [
          WorkspaceServicePortDeclaration(scriptName: 'api', port: 4000),
          WorkspaceServicePortDeclaration(scriptName: 'web', port: 4000),
        ],
        allocatePort: (_) async => 4001,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains("Service 'web' has a duplicate port 4000"),
        ),
      ),
    );
    expect(() => registry.requirePlannedPort({}, 'missing'), throwsStateError);
  });

  test('dynamic ownership retries collisions across workspaces', () async {
    final registry = WorkspaceServicePortRegistry();
    await registry.ensurePlan(
      workspaceId: 'first',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (_) async => 4200,
    );
    var attempts = 0;
    final second = await registry.ensurePlan(
      workspaceId: 'second',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (request) async {
        attempts++;
        expect(request.reservedPorts, contains(4200));
        return attempts == 1 ? 4200 : 4201;
      },
    );
    expect(second['web'], 4201);
    expect(attempts, 2);

    registry.releasePlan('first');
    final third = await registry.ensurePlan(
      workspaceId: 'third',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (_) async => 4200,
    );
    expect(third['web'], 4200);
  });

  test(
    'refresh replaces dynamic ownership and preserves peer reservations',
    () async {
      final registry = WorkspaceServicePortRegistry();
      await registry.ensurePlan(
        workspaceId: 'workspace',
        services: const [
          WorkspaceServicePortDeclaration(scriptName: 'api', port: 4300),
          WorkspaceServicePortDeclaration(scriptName: 'web'),
        ],
        allocatePort: (_) async => 4301,
      );
      final refreshed = await registry.refreshPort(
        workspaceId: 'workspace',
        service: const WorkspaceServicePortDeclaration(scriptName: 'web'),
        allocatePort: (request) async {
          expect(request.reservedPorts, contains(4300));
          expect(request.reservedPorts, isNot(contains(4301)));
          return 4302;
        },
      );
      expect(refreshed, 4302);
      final plan = await registry.ensurePlan(
        workspaceId: 'workspace',
        services: const [],
        allocatePort: (_) async => 1,
      );
      expect(plan, {'api': 4300, 'web': 4302});
    },
  );

  test('release during pending plan rejects and allows recovery', () async {
    final registry = WorkspaceServicePortRegistry();
    final gate = Completer<void>();
    final pending = registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (_) async {
        await gate.future;
        return 4400;
      },
    );
    await Future<void>.delayed(Duration.zero);
    registry.releasePlan('workspace');
    gate.complete();
    await expectLater(pending, throwsStateError);
    final recovered = await registry.ensurePlan(
      workspaceId: 'workspace',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (_) async => 4401,
    );
    expect(recovered['web'], 4401);
  });

  test('fails after ten non-unique dynamic allocations', () async {
    final registry = WorkspaceServicePortRegistry();
    final plan = await registry.ensurePlan(
      workspaceId: 'first',
      services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
      allocatePort: (_) async => 4500,
    );
    expect(plan['web'], 4500);
    var attempts = 0;
    await expectLater(
      registry.ensurePlan(
        workspaceId: 'second',
        services: const [WorkspaceServicePortDeclaration(scriptName: 'web')],
        allocatePort: (_) async {
          attempts++;
          return 4500;
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('after 10 attempts'),
        ),
      ),
    );
    expect(
      attempts,
      WorkspaceServicePortRegistry.maxDynamicPortAllocationAttempts,
    );
  });
}
