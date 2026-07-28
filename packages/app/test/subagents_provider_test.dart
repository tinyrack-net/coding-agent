import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/provider_subagents_provider.dart';
import 'package:coding_agent_app/state/subagents_provider.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSummary _agent({
  required String id,
  String? parentAgentId,
  String? archivedAt,
  AgentRunState runState = AgentRunState.idle,
  bool requiresAttention = false,
  int createdAtMs = 0,
  String title = 'Child',
  String? workspaceId,
}) => AgentSummary(
  agentId: id,
  title: title,
  cwd: '/workspace',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: runState,
  createdAtMs: createdAtMs,
  workspaceId: workspaceId,
  parentAgentId: parentAgentId,
  archivedAt: archivedAt,
  requiresAttention: requiresAttention,
);

ProviderSubagentDescriptor _providerChild({
  required String id,
  required String createdAt,
  ProviderSubagentStatus status = ProviderSubagentStatus.running,
  String? title = 'Provider child',
  String? description,
}) => ProviderSubagentDescriptor(
  id: id,
  parentAgentId: 'parent',
  provider: 'codex',
  title: title,
  description: description,
  status: status,
  createdAt: createdAt,
  updatedAt: createdAt,
);

void main() {
  test('normalizes labels like Paseo track presentation', () {
    expect(resolveSubagentLabel(null), isNull);
    expect(resolveSubagentLabel('   '), isNull);
    expect(resolveSubagentLabel(' New Agent '), isNull);
    expect(resolveSubagentLabel('  Research API  '), 'Research API');
  });

  test('formats singular, plural, and running header counts', () {
    final idle = PaseoSubagentRow(_agent(id: 'idle'));
    final running = PaseoSubagentRow(
      _agent(id: 'running', runState: AgentRunState.running),
    );

    expect(formatSubagentsHeader([idle]), '1 subagent');
    expect(formatSubagentsHeader([idle, running]), '2 subagents · 1 running');
  });

  test('resolves exact archive and detach confirmation copy', () {
    final running = PaseoSubagentRow(
      _agent(
        id: 'running',
        title: ' New Agent ',
        runState: AgentRunState.running,
      ),
    );
    final idle = PaseoSubagentRow(_agent(id: 'idle', title: ' Research API '));

    final runningArchive = resolveArchiveSubagentConfirmation(running);
    expect(runningArchive.title, 'Archive running subagent?');
    expect(
      runningArchive.message,
      'this subagent is still running. Archiving it will stop the '
      'subagent and remove it from the track.',
    );
    expect(runningArchive.confirmLabel, 'Archive');
    expect(runningArchive.destructive, isTrue);

    final idleArchive = resolveArchiveSubagentConfirmation(idle);
    expect(idleArchive.title, 'Archive subagent?');
    expect(
      idleArchive.message,
      'Remove Research API from the track. The subagent will be archived.',
    );

    final detach = resolveDetachSubagentConfirmation(idle);
    expect(detach.title, 'Detach subagent?');
    expect(
      detach.message,
      'Research API will leave this track and continue as a standalone agent.',
    );
    expect(detach.confirmLabel, 'Detach');
    expect(detach.destructive, isFalse);
  });

  test('resolves managed tab close and workspace root policies', () {
    final parent = _agent(id: 'parent', workspaceId: ' workspace-a ');
    final sameWorkspaceChild = _agent(
      id: 'same',
      parentAgentId: 'parent',
      workspaceId: 'workspace-a',
    );
    final otherWorkspaceChild = _agent(
      id: 'other',
      parentAgentId: 'parent',
      workspaceId: 'workspace-b',
    );
    final unknownWorkspaceChild = _agent(
      id: 'unknown',
      parentAgentId: 'missing',
    );

    expect(
      resolveCloseAgentTabPolicy(parent),
      CloseAgentTabPolicy.archiveOnClose,
    );
    expect(
      resolveCloseAgentTabPolicy(sameWorkspaceChild),
      CloseAgentTabPolicy.layoutOnly,
    );
    expect(
      resolveCloseAgentTabPolicy(null),
      CloseAgentTabPolicy.archiveOnClose,
    );
    expect(isWorkspaceRootAgent(parent, null), isTrue);
    expect(isWorkspaceRootAgent(sameWorkspaceChild, parent), isFalse);
    expect(isWorkspaceRootAgent(otherWorkspaceChild, parent), isTrue);
    expect(isWorkspaceRootAgent(unknownWorkspaceChild, null), isFalse);
  });

  test('selects visible managed and provider children in creation order', () {
    final rows = selectSubagentsForParent(
      parentAgentId: 'parent',
      agents: [
        _agent(id: 'other', parentAgentId: 'other', createdAtMs: 1),
        _agent(
          id: 'archived',
          parentAgentId: 'parent',
          archivedAt: '2026-07-26T00:00:00.000Z',
          createdAtMs: 2,
        ),
        _agent(id: 'managed', parentAgentId: 'parent', createdAtMs: 4),
      ],
      providerSubagents: ProviderSubagentsState(
        descriptors: {
          'hidden': _providerChild(
            id: 'hidden',
            createdAt: '1970-01-01T00:00:00.003Z',
          ),
          'provider': _providerChild(
            id: 'provider',
            createdAt: '1970-01-01T00:00:00.002Z',
          ),
        },
        hiddenFromTrack: const {'hidden'},
      ),
    );

    expect(rows.map((row) => row.id), ['provider', 'managed']);
    expect(rows.first, isA<ProviderSubagentRow>());
    expect(rows.last, isA<PaseoSubagentRow>());
  });

  test('derives status, attention, labels, and finished provider count', () {
    final managed = PaseoSubagentRow(
      _agent(
        id: 'managed',
        runState: AgentRunState.awaitingPermission,
        requiresAttention: true,
      ),
    );
    final failed = ProviderSubagentRow(
      'parent',
      _providerChild(
        id: 'failed',
        createdAt: '2026-07-26T00:00:00.000Z',
        status: ProviderSubagentStatus.failed,
        title: null,
        description: 'Fallback',
      ),
    );
    final running = ProviderSubagentRow(
      'parent',
      _providerChild(id: 'running', createdAt: '2026-07-26T00:00:01.000Z'),
    );

    expect(managed.requiresAttention, isTrue);
    expect(managed.running, isFalse);
    expect(failed.title, 'Fallback');
    expect(failed.requiresAttention, isTrue);
    expect(running.running, isTrue);
    expect(countFinishedProviderSubagents([managed, failed, running]), 1);
  });
}
