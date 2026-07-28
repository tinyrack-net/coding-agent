import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/state/create_flow_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _image = AttachmentMetadata(
  id: 'image-1',
  mimeType: 'image/png',
  storageType: AttachmentStorageType.desktopFile,
  storageKey: 'image-1',
  fileName: 'context.png',
  byteSize: 12,
  createdAt: 123,
);

PendingCreateAttempt attempt({
  String draftId = 'draft-1',
  String serverId = 'server-1',
  String? agentId,
}) => PendingCreateAttempt(
  draftId: draftId,
  serverId: serverId,
  workspaceId: 'workspace-1',
  agentId: agentId,
  clientMessageId: 'message-1',
  text: 'build this',
  timestamp: 123,
  lifecycle: CreateFlowLifecycle.active,
  images: const [_image],
);

void main() {
  test(
    'create flow lifecycle, rekey, agent update, and reference ids match',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(createFlowProvider.notifier);

      notifier.setPending(attempt());
      expect(
        isActiveCreateFlowForDraft(
          pending: container.read(createFlowProvider)['draft-1'],
          serverId: 'server-1',
          draftId: ' draft-1 ',
        ),
        isTrue,
      );
      expect(notifier.activeAttachmentIds(), {'image-1'});

      notifier.updateAgentId(draftId: 'draft-1', agentId: 'agent-1');
      notifier.rekeyDraft(fromDraftId: 'draft-1', toDraftId: 'draft-2');
      expect(container.read(createFlowProvider), isNot(contains('draft-1')));
      expect(container.read(createFlowProvider)['draft-2']?.agentId, 'agent-1');
      expect(container.read(createFlowProvider)['draft-2']?.draftId, 'draft-2');

      notifier.markLifecycle(
        draftId: 'draft-2',
        lifecycle: CreateFlowLifecycle.sent,
      );
      expect(notifier.activeAttachmentIds(), isEmpty);
      notifier.clearByAgent(serverId: 'server-1', agentId: 'agent-1');
      expect(container.read(createFlowProvider), isEmpty);
    },
  );

  test('create flow ignores unmatched updates and supports clear all', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(createFlowProvider.notifier);

    notifier.updateAgentId(draftId: 'missing', agentId: 'agent');
    notifier.markLifecycle(
      draftId: 'missing',
      lifecycle: CreateFlowLifecycle.sent,
    );
    notifier.rekeyDraft(fromDraftId: 'missing', toDraftId: 'other');
    notifier.clear('missing');
    notifier.setPending(attempt());
    notifier.setPending(attempt(draftId: 'draft-2', serverId: 'server-2'));
    notifier.clearByAgent(serverId: 'other', agentId: 'missing');
    expect(container.read(createFlowProvider), hasLength(2));

    notifier.clearAll();
    expect(container.read(createFlowProvider), isEmpty);
  });

  test('workspace submission consumption is exact and one-shot', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceDraftSubmissionProvider.notifier);
    const submission = PendingWorkspaceDraftSubmission(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
      workspaceDirectory: '/repo',
      draftId: 'draft-1',
      text: 'build this',
      images: [_image],
      cwd: '/repo',
      provider: 'openai',
      model: 'gpt-5',
      modeId: 'plan',
      clientMessageId: 'message-1',
      timestamp: 123,
      allowEmptyText: true,
    );

    notifier.setPending(submission);
    expect(
      notifier.consume(
        serverId: 'wrong',
        workspaceId: 'workspace-1',
        draftId: 'draft-1',
      ),
      isNull,
    );
    expect(
      notifier.consume(
        serverId: 'server-1',
        workspaceId: 'workspace-1',
        draftId: 'draft-1',
      ),
      same(submission),
    );
    expect(
      notifier.consume(
        serverId: 'server-1',
        workspaceId: 'workspace-1',
        draftId: 'draft-1',
      ),
      isNull,
    );

    notifier.setPending(submission);
    notifier.clear('draft-1');
    notifier.clear('missing');
    expect(container.read(workspaceDraftSubmissionProvider), isEmpty);
  });
}
