import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  test(
    'workspace file context matches Paseo selection labels and wire text',
    () {
      final whole = workspaceFileContextAttachment('src/app.ts');
      final range = workspaceFileContextAttachment(
        r'.\src\app.ts',
        selection: ComposerWorkspaceFileSelection.lineRange(
          startLine: 12,
          endLine: 24,
        ),
      );

      expect(whole.title, 'app.ts');
      expect(whole.subtitle, 'src/app.ts');
      expect(whole.toAgentAttachment().toJson(), {
        'type': 'text',
        'mimeType': 'text/plain',
        'title': 'app.ts',
        'text': 'Workspace file: src/app.ts',
      });
      expect(range.title, 'app.ts');
      expect(range.subtitle, 'src/app.ts · 12-24');
      expect(range.toAgentAttachment().toJson(), {
        'type': 'text',
        'mimeType': 'text/plain',
        'title': 'app.ts',
        'text': 'Workspace file: src/app.ts\nLines: 12-24',
      });
    },
  );

  test('merge keeps whole-file and line-range attachments distinct', () {
    final whole = workspaceFileContextAttachment('src/app.ts');
    final range = workspaceFileContextAttachment(
      'src/app.ts',
      selection: ComposerWorkspaceFileSelection.lineRange(
        startLine: 1,
        endLine: 3,
      ),
    );

    final merged = mergeWorkspaceContextAttachments([whole], [range]);
    expect(merged, hasLength(2));
    expect(merged.map((attachment) => attachment.subtitle), [
      'src/app.ts',
      'src/app.ts · 1-3',
    ]);
  });

  test('notifier keeps different selections for the same workspace path', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = workspaceAttachmentsProvider('draft');
    final notifier = container.read(provider.notifier);

    notifier.add(workspaceFileContextAttachment('src/app.ts'));
    notifier.add(
      workspaceFileContextAttachment(
        'src/app.ts',
        selection: ComposerWorkspaceFileSelection.lineRange(
          startLine: 2,
          endLine: 5,
        ),
      ),
    );

    expect(container.read(provider), hasLength(2));
    notifier.removeAttachment(container.read(provider).first);
    expect(container.read(provider), hasLength(1));
    expect(container.read(provider).single.subtitle, 'src/app.ts · 2-5');
  });
}
