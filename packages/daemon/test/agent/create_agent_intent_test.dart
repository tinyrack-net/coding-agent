import 'package:agent_daemon/src/agent/create_agent_intent.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'keeps caller parentage when explicit workspace changes placement',
    () async {
      final intent = await resolveCreateAgentIntent(
        explicitWorkspaceId: 'workspace-isolated',
        caller: const CreateAgentCaller(
          id: 'parent-agent',
          cwd: '/parent',
          workspaceId: 'workspace-parent',
        ),
        labels: const {'purpose': 'review'},
        childAgentDefaultLabels: const {
          'purpose': 'default',
          'source': 'voice',
        },
        resolveWorkspace: (workspaceId) async =>
            CreateAgentPlacement(workspaceId: workspaceId, cwd: '/isolated'),
        createWorkspace: () async => const CreateAgentPlacement(
          workspaceId: 'workspace-created',
          cwd: '/created',
        ),
      );

      expect(intent.workspaceId, 'workspace-isolated');
      expect(intent.cwd, '/isolated');
      expect(intent.parentAgentId, 'parent-agent');
      expect(intent.labels, {
        'purpose': 'review',
        'source': 'voice',
        paseoParentAgentIdLabel: 'parent-agent',
      });
    },
  );

  test(
    'defaults an agent caller to its workspace without creating one',
    () async {
      var createCount = 0;
      final intent = await resolveCreateAgentIntent(
        caller: const CreateAgentCaller(
          id: 'parent-agent',
          cwd: '/parent',
          workspaceId: 'workspace-parent',
        ),
        resolveWorkspace: (workspaceId) async =>
            CreateAgentPlacement(workspaceId: workspaceId, cwd: '/unused'),
        createWorkspace: () async {
          createCount += 1;
          return const CreateAgentPlacement(
            workspaceId: 'workspace-created',
            cwd: '/created',
          );
        },
      );

      expect(intent.workspaceId, 'workspace-parent');
      expect(intent.cwd, '/parent');
      expect(intent.parentAgentId, 'parent-agent');
      expect(createCount, 0);
    },
  );

  test('creates a workspace for a human caller without context', () async {
    final intent = await resolveCreateAgentIntent(
      caller: null,
      resolveWorkspace: (workspaceId) async =>
          CreateAgentPlacement(workspaceId: workspaceId, cwd: '/unused'),
      createWorkspace: () async => const CreateAgentPlacement(
        workspaceId: 'workspace-created',
        cwd: '/created',
      ),
    );

    expect(intent.workspaceId, 'workspace-created');
    expect(intent.cwd, '/created');
    expect(intent.parentAgentId, isNull);
    expect(intent.labels, isEmpty);
  });

  test(
    'keeps legacy detached creation independent and strips spoofing',
    () async {
      final intent = await resolveCreateAgentIntent(
        caller: const CreateAgentCaller(
          id: 'parent-agent',
          cwd: '/parent',
          workspaceId: 'workspace-parent',
        ),
        labels: const {paseoParentAgentIdLabel: 'spoofed-parent'},
        legacyDetached: true,
        resolveWorkspace: (workspaceId) async =>
            CreateAgentPlacement(workspaceId: workspaceId, cwd: '/unused'),
        createWorkspace: () async => const CreateAgentPlacement(
          workspaceId: 'workspace-created',
          cwd: '/created',
        ),
      );

      expect(intent.workspaceId, 'workspace-parent');
      expect(intent.cwd, '/parent');
      expect(intent.parentAgentId, isNull);
      expect(intent.labels, isEmpty);
    },
  );

  test('rejects a caller without a workspace', () async {
    await expectLater(
      resolveCreateAgentIntent(
        caller: const CreateAgentCaller(
          id: 'parent-agent',
          cwd: '/parent',
          workspaceId: null,
        ),
        resolveWorkspace: (workspaceId) async =>
            CreateAgentPlacement(workspaceId: workspaceId, cwd: '/unused'),
        createWorkspace: () async => const CreateAgentPlacement(
          workspaceId: 'workspace-created',
          cwd: '/created',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Caller agent parent-agent has no workspace',
        ),
      ),
    );
  });
}
