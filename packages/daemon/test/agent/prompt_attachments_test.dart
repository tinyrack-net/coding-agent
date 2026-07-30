import 'package:agent_daemon/src/agent/prompt_attachments.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('renders review attachments in the frozen Paseo prompt format', () {
    const attachment = ReviewAgentAttachment(
      cwd: '/tmp/repo',
      mode: ReviewAttachmentMode.base,
      baseRef: 'main',
      comments: [
        ReviewAttachmentComment(
          filePath: 'src/index.ts',
          side: ReviewAttachmentSide.newLine,
          lineNumber: 42,
          body: 'Please guard this nullable value.',
          context: ReviewAttachmentContext(
            hunkHeader: '@@ -40,3 +40,4 @@',
            targetLine: ReviewAttachmentContextLine(
              oldLineNumber: null,
              newLineNumber: 42,
              type: ReviewAttachmentLineType.add,
              content: 'const value = maybeNull.name;',
            ),
            lines: [
              ReviewAttachmentContextLine(
                oldLineNumber: 41,
                newLineNumber: 41,
                type: ReviewAttachmentLineType.context,
                content: 'const before = true;',
              ),
              ReviewAttachmentContextLine(
                oldLineNumber: null,
                newLineNumber: 42,
                type: ReviewAttachmentLineType.add,
                content: 'const value = maybeNull.name;',
              ),
            ],
          ),
        ),
      ],
    );

    expect(
      renderPromptAttachmentAsText(attachment),
      [
        'Paseo review attachment (base)',
        'CWD: /tmp/repo',
        'Base: main',
        '',
        'Comment 1: src/index.ts:new:42',
        'Please guard this nullable value.',
        '@@ -40,3 +40,4 @@',
        '  41 41  const before = true;',
        '>  - 42 +const value = maybeNull.name;',
      ].join('\n'),
    );
  });
}
