import 'package:coding_agent_app/core/diff_highlighter.dart';
import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

const simpleDiff = '''
diff --git a/example.ts b/example.ts
index 1234567..abcdefg 100644
--- a/example.ts
+++ b/example.ts
@@ -1,5 +1,5 @@
 const foo = 1;
-const bar = 2;
+const bar = 3;
 const baz = foo + bar;

 export { foo, bar, baz };
''';

const multiHunkDiff = '''
diff --git a/example.ts b/example.ts
index 1234567..abcdefg 100644
--- a/example.ts
+++ b/example.ts
@@ -1,3 +1,3 @@
 const foo = 1;
-const bar = 2;
+const bar = 3;
 const baz = foo + bar;
@@ -10,3 +10,4 @@
 function greet(name: string) {
   return "Hello, " + name;
 }
+export { greet };
''';

const newFileDiff = '''
diff --git a/newfile.ts b/newfile.ts
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/newfile.ts
@@ -0,0 +1,3 @@
+const x = 1;
+const y = 2;
+export { x, y };
''';

const deletedFileDiff = '''
diff --git a/oldfile.ts b/oldfile.ts
deleted file mode 100644
index 1234567..0000000
--- a/oldfile.ts
+++ /dev/null
@@ -1,2 +0,0 @@
-const legacy = true;
-export { legacy };
''';

void main() {
  group('parseDiff', () {
    test('parses a simple diff with one hunk and statistics', () {
      final files = parseDiff(simpleDiff);

      expect(files, hasLength(1));
      final file = files.single;
      expect(file.path, 'example.ts');
      expect(file.isNew, isFalse);
      expect(file.isDeleted, isFalse);
      expect(file.additions, 1);
      expect(file.deletions, 1);
      expect(file.hunks, hasLength(1));
      final hunk = file.hunks.single;
      expect(
        (hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount),
        (1, 5, 1, 5),
      );
      expect(hunk.lines.first.type, ParsedDiffLineType.header);
      expect(hunk.lines.first.content, '@@ -1,5 +1,5 @@');
      expect(hunk.lines[1].content, 'const foo = 1;');
      expect(hunk.lines[2].type, ParsedDiffLineType.remove);
      expect(hunk.lines[3].type, ParsedDiffLineType.add);
    });

    test('parses no-prefix paths and paths containing spaces', () {
      final noPrefix = parseDiff(
        simpleDiff
            .replaceFirst('a/example.ts b/example.ts', 'example.ts example.ts')
            .replaceFirst('--- a/example.ts', '--- example.ts')
            .replaceFirst('+++ b/example.ts', '+++ example.ts'),
      );
      expect(noPrefix.single.path, 'example.ts');

      final spaced = parseDiff(
        simpleDiff.replaceAll('example.ts', 'file with space.ts'),
      );
      expect(spaced.single.path, 'file with space.ts');

      final spacedNoPrefix = parseDiff(
        simpleDiff
            .replaceAll('example.ts', 'file with space.ts')
            .replaceFirst(
              'a/file with space.ts b/file with space.ts',
              'file with space.ts file with space.ts',
            )
            .replaceFirst('--- a/file with space.ts', '--- file with space.ts')
            .replaceFirst('+++ b/file with space.ts', '+++ file with space.ts'),
      );
      expect(spacedNoPrefix.single.path, 'file with space.ts');
    });

    test('preserves no-prefix paths beginning with a or b', () {
      final first = simpleDiff
          .replaceFirst(
            'diff --git a/example.ts b/example.ts',
            'diff --git a/example.ts a/example.ts',
          )
          .replaceFirst(
            '--- a/example.ts\n+++ b/example.ts',
            '--- a/example.ts\n+++ a/example.ts',
          );
      final second = simpleDiff
          .replaceAll('example.ts', 'other.ts')
          .replaceFirst(
            'diff --git a/other.ts b/other.ts',
            'diff --git b/other.ts b/other.ts',
          )
          .replaceFirst(
            '--- a/other.ts\n+++ b/other.ts',
            '--- b/other.ts\n+++ b/other.ts',
          );

      expect(parseDiff('$first\n$second').map((file) => file.path), [
        'a/example.ts',
        'b/other.ts',
      ]);
    });

    test('parses multiple hunks and default hunk counts', () {
      final hunks = parseDiff(multiHunkDiff).single.hunks;
      expect(hunks, hasLength(2));
      expect((hunks[0].oldStart, hunks[0].newStart), (1, 1));
      expect((hunks[1].oldStart, hunks[1].newStart), (10, 10));

      final defaultCounts = parseDiff(
        simpleDiff.replaceFirst('@@ -1,5 +1,5 @@', '@@ -1 +1 @@ suffix'),
      ).single.hunks.single;
      expect((defaultCounts.oldCount, defaultCounts.newCount), (1, 1));
      expect(defaultCounts.lines.first.content, '@@ -1 +1 @@');
    });

    test('marks new and deleted files and handles empty input', () {
      final added = parseDiff(newFileDiff).single;
      expect(
        (added.path, added.isNew, added.isDeleted),
        ('newfile.ts', true, false),
      );
      expect((added.additions, added.deletions), (3, 0));

      final deleted = parseDiff(deletedFileDiff).single;
      expect(
        (deleted.path, deleted.isNew, deleted.isDeleted),
        ('oldfile.ts', false, true),
      );
      expect((deleted.additions, deleted.deletions), (0, 2));
      expect(parseDiff(''), isEmpty);
      expect(parseDiff('   '), isEmpty);
    });
  });

  group('file reconstruction', () {
    test('reconstructs new and old versions by hunk line numbers', () {
      final hunks = parseDiff(simpleDiff).single.hunks;
      final newFile = reconstructNewFile(hunks);
      final oldFile = reconstructOldFile(hunks);

      expect(newFile[1], 'const foo = 1;');
      expect(newFile[2], 'const bar = 3;');
      expect(newFile[4], 'export { foo, bar, baz };');
      expect(newFile.values, isNot(contains('const bar = 2;')));
      expect(oldFile[2], 'const bar = 2;');
      expect(oldFile.values, isNot(contains('const bar = 3;')));
    });

    test('handles all-addition and all-removal files', () {
      final added = reconstructNewFile(parseDiff(newFileDiff).single.hunks);
      expect(added, {
        1: 'const x = 1;',
        2: 'const y = 2;',
        3: 'export { x, y };',
      });

      final removed = reconstructOldFile(
        parseDiff(deletedFileDiff).single.hunks,
      );
      expect(removed, {1: 'const legacy = true;', 2: 'export { legacy };'});
    });
  });

  group('highlightDiffFile', () {
    test('maps TypeScript tokens to context, removed, and added lines', () {
      final highlighted = highlightDiffFile(parseDiff(simpleDiff).single);
      final lines = highlighted.hunks.single.lines;

      expect(
        lines[1].tokens,
        contains(
          isA<ToolDiffToken>().having(
            (token) => (token.text, token.style),
            'keyword token',
            ('const', 'keyword'),
          ),
        ),
      );
      final removed = lines.firstWhere(
        (line) => line.type == ParsedDiffLineType.remove,
      );
      final added = lines.firstWhere(
        (line) => line.type == ParsedDiffLineType.add,
      );
      expect(
        removed.tokens,
        contains(
          isA<ToolDiffToken>().having(
            (token) => (token.text, token.style),
            'old number',
            ('2', 'number'),
          ),
        ),
      );
      expect(
        added.tokens,
        contains(
          isA<ToolDiffToken>().having(
            (token) => (token.text, token.style),
            'new number',
            ('3', 'number'),
          ),
        ),
      );
    });

    test('returns the exact file unchanged for unsupported extensions', () {
      const file = ParsedDiffFile(
        path: 'README.txt',
        isNew: false,
        isDeleted: false,
        additions: 1,
        deletions: 0,
        hunks: [
          ParsedDiffHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 2,
            lines: [
              ParsedDiffLine(
                type: ParsedDiffLineType.header,
                content: '@@ -1,1 +1,2 @@',
              ),
              ParsedDiffLine(
                type: ParsedDiffLineType.context,
                content: 'Hello',
              ),
              ParsedDiffLine(type: ParsedDiffLineType.add, content: 'World'),
            ],
          ),
        ],
      );

      expect(identical(highlightDiffFile(file), file), isTrue);
    });

    for (final languageCase in const [
      (extension: 'rs', context: 'fn main() {', added: '    let version = 2;'),
      (extension: 'c', context: 'int main(void) {', added: ' int version = 2;'),
      (
        extension: 'java',
        context: 'public class Main {',
        added: ' int version = 2;',
      ),
      (extension: 'm', context: 'int main(void) {', added: ' int version = 2;'),
      (extension: 'go', context: 'package main', added: ' version := 2'),
      (extension: 'php', context: r'<?php', added: r'$version = 2;'),
      (extension: 'yaml', context: 'app: paseo', added: 'count: 2'),
      (extension: 'xml', context: '<config>', added: '<count>2</count>'),
    ]) {
      test('highlights ${languageCase.extension} source', () {
        final diff =
            '''
diff --git a/file.${languageCase.extension} b/file.${languageCase.extension}
--- a/file.${languageCase.extension}
+++ b/file.${languageCase.extension}
@@ -1,1 +1,2 @@
 ${languageCase.context}
+${languageCase.added}
''';
        final file = highlightDiffFile(parseDiff(diff).single);
        final added = file.hunks.single.lines.firstWhere(
          (line) => line.type == ParsedDiffLineType.add,
        );
        expect(added.tokens, isNotEmpty);
        expect(
          added.tokens!.map((token) => token.text).join(),
          languageCase.added,
        );
        if (languageCase.extension == 'xml') {
          expect(added.tokens!.any((token) => token.style == 'tag'), isTrue);
        }
      });
    }
  });

  test('parseAndHighlightDiff handles multiple files', () {
    final files = parseAndHighlightDiff('$simpleDiff\n$newFileDiff');
    expect(files.map((file) => file.path), ['example.ts', 'newfile.ts']);
    expect(files.first.hunks.first.lines[1].tokens, isNotEmpty);
  });
}
