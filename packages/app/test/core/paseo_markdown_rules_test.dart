// Ports of the upstream test suites for Paseo's markdown-shaped rules:
// markdown-ast and workspace-empty-draft-seed. split-markdown-blocks ships
// without an upstream suite, so its cases here were derived by running the
// frozen TypeScript implementation and pinning its exact output — the block
// boundaries are depended on by the assistant height estimate.
import 'package:coding_agent_app/core/paseo_markdown_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the upstream `readyEmptyWorkspace` fixture, with overrides taking
/// the place of TypeScript object spread.
bool seedDraft({
  bool isRouteFocused = true,
  bool hasPersistenceKey = true,
  bool hasWorkspaceDirectory = true,
  bool hasHydratedWorkspaceLayoutStore = true,
  bool hasHydratedAgents = true,
  bool hasLoadedTerminals = true,
  int activeAgentCount = 0,
  int terminalCount = 0,
  int tabCount = 0,
}) => shouldSeedEmptyWorkspaceDraft(
  isRouteFocused: isRouteFocused,
  hasPersistenceKey: hasPersistenceKey,
  hasWorkspaceDirectory: hasWorkspaceDirectory,
  hasHydratedWorkspaceLayoutStore: hasHydratedWorkspaceLayoutStore,
  hasHydratedAgents: hasHydratedAgents,
  hasLoadedTerminals: hasLoadedTerminals,
  activeAgentCount: activeAgentCount,
  terminalCount: terminalCount,
  tabCount: tabCount,
);

void main() {
  group('markdownNodeContainsType', () {
    test('matches the node itself', () {
      expect(
        markdownNodeContainsType(
          node: const MarkdownAstNodeWithChildren(type: 'image'),
          type: 'image',
        ),
        isTrue,
      );
    });

    test('matches descendants', () {
      const paragraph = MarkdownAstNodeWithChildren(
        type: 'paragraph',
        children: [
          MarkdownAstNodeWithChildren(type: 'text'),
          MarkdownAstNodeWithChildren(
            type: 'link',
            children: [MarkdownAstNodeWithChildren(type: 'image')],
          ),
        ],
      );

      expect(markdownNodeContainsType(node: paragraph, type: 'image'), isTrue);
    });

    test('returns false when the type is absent', () {
      const paragraph = MarkdownAstNodeWithChildren(
        type: 'paragraph',
        children: [
          MarkdownAstNodeWithChildren(type: 'text'),
          MarkdownAstNodeWithChildren(
            type: 'strong',
            children: [MarkdownAstNodeWithChildren(type: 'text')],
          ),
        ],
      );

      expect(markdownNodeContainsType(node: paragraph, type: 'image'), isFalse);
    });

    test('walks arbitrarily deep before giving up', () {
      const deep = MarkdownAstNodeWithChildren(
        type: 'root',
        children: [
          MarkdownAstNodeWithChildren(
            type: 'list',
            children: [
              MarkdownAstNodeWithChildren(
                type: 'listItem',
                children: [
                  MarkdownAstNodeWithChildren(
                    type: 'paragraph',
                    children: [MarkdownAstNodeWithChildren(type: 'inlineCode')],
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      expect(markdownNodeContainsType(node: deep, type: 'inlineCode'), isTrue);
      expect(markdownNodeContainsType(node: deep, type: 'image'), isFalse);
    });
  });

  group('splitMarkdownBlocks', () {
    test('returns nothing for empty or blank-only text', () {
      expect(splitMarkdownBlocks(''), isEmpty);
      expect(splitMarkdownBlocks('\n\n  \n\t\n'), isEmpty);
    });

    test('keeps a single paragraph whole', () {
      expect(splitMarkdownBlocks('hello world'), ['hello world']);
      expect(splitMarkdownBlocks('solo\n'), ['solo']);
    });

    test('splits paragraphs on a blank line', () {
      expect(splitMarkdownBlocks('first paragraph\n\nsecond paragraph'), [
        'first paragraph',
        'second paragraph',
      ]);
    });

    test('treats a run of blank lines as one boundary', () {
      expect(splitMarkdownBlocks('alpha\n\n\n\n   \n\nbeta'), [
        'alpha',
        'beta',
      ]);
      expect(splitMarkdownBlocks('a\n \nb'), ['a', 'b']);
    });

    test('drops leading and trailing blank lines without emitting blocks', () {
      expect(splitMarkdownBlocks('\n\n  intro\n\n\noutro\n\n'), [
        '  intro',
        'outro',
      ]);
    });

    test('keeps blank lines inside a fenced code block', () {
      expect(
        splitMarkdownBlocks(
          'before\n\n```js\nconst a = 1;\n\nconst b = 2;\n```\n\nafter',
        ),
        ['before', '```js\nconst a = 1;\n\nconst b = 2;\n```', 'after'],
      );
    });

    test('recognises fences indented by up to three spaces', () {
      expect(splitMarkdownBlocks('   ```\ncode\n   ```\ntrailer'), [
        '   ```\ncode\n   ```\ntrailer',
      ]);
    });

    test('does not treat a four-space indented run as a fence', () {
      expect(splitMarkdownBlocks('para\n\n    ```\n    not a fence'), [
        'para',
        '    ```\n    not a fence',
      ]);
    });

    test('closes only on a run at least as long as the opener', () {
      expect(splitMarkdownBlocks('````\n```\nstill inside\n````\nafter'), [
        '````\n```\nstill inside\n````\nafter',
      ]);
      expect(splitMarkdownBlocks('````\n```\nstill inside\n```\nalso inside'), [
        '````\n```\nstill inside\n```\nalso inside',
      ]);
    });

    test('closes only on the fence character that opened the block', () {
      expect(splitMarkdownBlocks('```\ninside\n~~~\nstill inside\n```\nout'), [
        '```\ninside\n~~~\nstill inside\n```\nout',
      ]);
      expect(splitMarkdownBlocks('~~~\ncode\n\nmore\n~~~'), [
        '~~~\ncode\n\nmore\n~~~',
      ]);
    });

    test('lets an unterminated fence swallow the rest of the text', () {
      expect(
        splitMarkdownBlocks('intro\n\n```\nnever closed\n\nstill inside'),
        ['intro', '```\nnever closed\n\nstill inside'],
      );
      expect(splitMarkdownBlocks('```'), ['```']);
    });

    test('continues the same block after a fence closes without a blank', () {
      expect(splitMarkdownBlocks('```\n```\nafter'), ['```\n```\nafter']);
    });

    test('keeps a nested list together until a blank line', () {
      expect(splitMarkdownBlocks('- one\n- two\n  - nested\n\n- after blank'), [
        '- one\n- two\n  - nested',
        '- after blank',
      ]);
    });

    test('keeps a heading attached to the lines that follow it', () {
      expect(
        splitMarkdownBlocks('# Title\ntext under heading\n\n## Second\nmore'),
        ['# Title\ntext under heading', '## Second\nmore'],
      );
    });

    test('splits on CRLF blank lines but preserves the carriage returns', () {
      expect(splitMarkdownBlocks('alpha\r\n\r\nbeta\r\n'), [
        'alpha\r',
        'beta\r',
      ]);
    });
  });

  group('shouldSeedEmptyWorkspaceDraft', () {
    test('waits for refresh-time hydration before seeding a draft', () {
      expect(seedDraft(hasHydratedWorkspaceLayoutStore: false), isFalse);
      expect(seedDraft(hasHydratedAgents: false), isFalse);
      expect(seedDraft(hasLoadedTerminals: false), isFalse);
    });

    test('does not seed when existing workspace content is known', () {
      expect(seedDraft(activeAgentCount: 1), isFalse);
      expect(seedDraft(terminalCount: 1), isFalse);
      expect(seedDraft(tabCount: 1), isFalse);
    });

    test('does not seed an unfocused or unidentified workspace', () {
      expect(seedDraft(isRouteFocused: false), isFalse);
      expect(seedDraft(hasPersistenceKey: false), isFalse);
      expect(seedDraft(hasWorkspaceDirectory: false), isFalse);
    });

    test('seeds once an empty focused workspace is fully known', () {
      expect(seedDraft(), isTrue);
    });
  });
}
