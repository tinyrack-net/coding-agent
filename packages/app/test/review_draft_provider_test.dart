import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/review_draft_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryReviewStorage implements ReviewDraftStorage {
  _MemoryReviewStorage([this.value]);

  String? value;
  final writes = <String>[];

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
    writes.add(value);
  }
}

const _diff = DiffResponse(
  files: [
    DiffFile(
      path: 'lib/example.dart',
      status: DiffFileStatus.modified,
      hunks: [
        DiffHunk(
          header: '@@ -10,8 +10,8 @@',
          lines: [
            DiffLine(
              type: DiffLineType.context,
              text: 'one',
              oldLineNo: 10,
              newLineNo: 10,
            ),
            DiffLine(
              type: DiffLineType.context,
              text: 'two',
              oldLineNo: 11,
              newLineNo: 11,
            ),
            DiffLine(
              type: DiffLineType.context,
              text: 'three',
              oldLineNo: 12,
              newLineNo: 12,
            ),
            DiffLine(type: DiffLineType.del, text: 'old target', oldLineNo: 13),
            DiffLine(type: DiffLineType.add, text: 'new target', newLineNo: 13),
            DiffLine(
              type: DiffLineType.context,
              text: 'six',
              oldLineNo: 14,
              newLineNo: 14,
            ),
            DiffLine(
              type: DiffLineType.context,
              text: 'seven',
              oldLineNo: 15,
              newLineNo: 15,
            ),
            DiffLine(
              type: DiffLineType.context,
              text: 'eight',
              oldLineNo: 16,
              newLineNo: 16,
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  test('draft key matches the Paseo review scope contract', () {
    expect(
      buildReviewDraftKey(
        serverId: 'host a',
        workspaceId: 'workspace/one',
        cwd: r'C:\repo',
        mode: CheckoutDiffMode.base,
        baseRef: 'origin/main',
        ignoreWhitespace: true,
      ),
      'review:server=host%20a:workspace=workspace%2Fone:mode=base:'
      'base=origin%2Fmain:ignoreWhitespace=true',
    );
  });

  test('draft mutations trim, persist, update, delete, and clear', () async {
    final storage = _MemoryReviewStorage();
    final container = ProviderContainer(
      overrides: [reviewDraftStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(reviewDraftProvider.notifier);

    final comment = notifier.add(
      key: 'scope',
      filePath: 'lib/example.dart',
      side: ReviewAttachmentSide.newLine,
      lineNumber: 13,
      body: '  explain this  ',
      id: 'comment-1',
      createdAt: '2026-07-30T00:00:00.000Z',
    );
    expect(comment.body, 'explain this');
    notifier.updateComment(
      key: 'scope',
      id: 'comment-1',
      body: ' revised ',
      updatedAt: '2026-07-30T00:01:00.000Z',
    );
    final updated = container.read(reviewDraftProvider).drafts['scope']!.single;
    expect(updated.body, 'revised');
    expect(updated.createdAt, '2026-07-30T00:00:00.000Z');
    expect(updated.updatedAt, '2026-07-30T00:01:00.000Z');

    await Future<void>.delayed(Duration.zero);
    expect(
      jsonDecode(storage.writes.last)['drafts']['scope'].single['body'],
      'revised',
    );

    notifier.delete(key: 'scope', id: 'comment-1');
    expect(container.read(reviewDraftProvider).drafts, isEmpty);
    notifier.add(
      key: 'scope',
      filePath: 'lib/example.dart',
      side: ReviewAttachmentSide.old,
      lineNumber: 13,
      body: 'again',
    );
    notifier.clear('scope');
    expect(container.read(reviewDraftProvider).drafts, isEmpty);
  });

  test(
    'hydrate ignores malformed comments and restores valid drafts',
    () async {
      final storage = _MemoryReviewStorage(
        jsonEncode({
          'drafts': {
            'scope': [
              {
                'id': 'valid',
                'filePath': 'a.dart',
                'side': 'old',
                'lineNumber': 2,
                'body': 'body',
                'createdAt': 'created',
                'updatedAt': 'updated',
              },
              {'id': 'invalid', 'lineNumber': 0},
            ],
          },
        }),
      );
      final container = ProviderContainer(
        overrides: [reviewDraftStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      container.read(reviewDraftProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(reviewDraftProvider).drafts['scope'], hasLength(1));
      expect(
        container.read(reviewDraftProvider).drafts['scope']!.single.id,
        'valid',
      );
    },
  );

  test('attachment snapshot captures the target and a three-line radius', () {
    final attachment = buildReviewAttachment(
      cwd: r'C:\repo',
      mode: CheckoutDiffMode.base,
      baseRef: ' origin/main ',
      comments: const [
        ReviewDraftComment(
          id: 'old',
          filePath: 'lib/example.dart',
          side: ReviewAttachmentSide.old,
          lineNumber: 13,
          body: 'remove this?',
          createdAt: 'created',
          updatedAt: 'updated',
        ),
        ReviewDraftComment(
          id: 'missing',
          filePath: 'lib/example.dart',
          side: ReviewAttachmentSide.newLine,
          lineNumber: 99,
          body: 'missing',
          createdAt: 'created',
          updatedAt: 'updated',
        ),
      ],
      diff: _diff,
    );

    expect(attachment, isNotNull);
    expect(attachment!.mode, ReviewAttachmentMode.base);
    expect(attachment.baseRef, 'origin/main');
    expect(attachment.comments, hasLength(1));
    final comment = attachment.comments.single;
    expect(comment.side, ReviewAttachmentSide.old);
    expect(comment.context.targetLine.content, 'old target');
    expect(comment.context.lines.map((line) => line.content), [
      'one',
      'two',
      'three',
      'old target',
      'new target',
      'six',
      'seven',
    ]);
  });
}
