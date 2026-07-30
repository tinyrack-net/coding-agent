import 'dart:io';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/git/unified_diff_parser.dart';
import 'package:agent_daemon/src/workspace/checkout_diff_highlighter.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('highlightCheckoutDiffFile', () {
    test('highlights reconstructed old and new TypeScript sides', () {
      final highlighted = highlightCheckoutDiffFile(_typescriptDiff());
      final lines = highlighted.hunks.single.lines;

      expect(_token(lines[0], 'const')?.style, 'keyword');
      expect(_token(lines[0], '1')?.style, 'number');
      expect(_token(lines[1], '2')?.style, 'number');
      expect(_token(lines[2], '3')?.style, 'number');
      expect(
        lines.every(
          (line) => line.tokens!.map((token) => token.text).join() == line.text,
        ),
        isTrue,
      );
    });

    test('uses full contents to preserve multiline parser context', () {
      const oldContent = '''
/*
comment 1
comment 2
comment 3
comment 4
comment 5
old comment
comment 7
*/
const value = 1;
''';
      const newContent = '''
/*
comment 1
comment 2
comment 3
comment 4
comment 5
new comment
comment 7
*/
const value = 1;
''';
      final file = DiffFile(
        path: 'example.ts',
        status: DiffFileStatus.modified,
        additions: 1,
        deletions: 1,
        hunks: const [
          DiffHunk(
            header: '@@ -7 +7 @@',
            lines: [
              DiffLine(
                type: DiffLineType.del,
                text: 'old comment',
                oldLineNo: 7,
              ),
              DiffLine(
                type: DiffLineType.add,
                text: 'new comment',
                newLineNo: 7,
              ),
            ],
          ),
        ],
      );

      final highlighted = highlightCheckoutDiffFile(
        file,
        oldFileContent: oldContent,
        newFileContent: newContent,
      );

      expect(_tokenPairs(highlighted.hunks.single.lines[0]), [
        ('old comment', 'comment'),
      ]);
      expect(_tokenPairs(highlighted.hunks.single.lines[1]), [
        ('new comment', 'comment'),
      ]);
    });

    test('returns unsupported, binary, and oversized files unchanged', () {
      final unsupported = _typescriptDiff(path: 'README.txt');
      final binary = DiffFile(
        path: 'image.ts',
        status: DiffFileStatus.modified,
        binary: true,
      );
      final tooLarge = DiffFile(
        path: 'large.ts',
        status: DiffFileStatus.modified,
        tooLarge: true,
      );

      expect(highlightCheckoutDiffFile(unsupported), same(unsupported));
      expect(highlightCheckoutDiffFile(binary), same(binary));
      expect(highlightCheckoutDiffFile(tooLarge), same(tooLarge));
    });

    test('supports the frozen extension catalog case-insensitively', () {
      for (final extension in [
        'js',
        'jsx',
        'ts',
        'tsx',
        'mjs',
        'cjs',
        'c',
        'h',
        'cc',
        'cpp',
        'cxx',
        'hpp',
        'hxx',
        'm',
        'mm',
        'json',
        'css',
        'scss',
        'html',
        'htm',
        'xml',
        'java',
        'py',
        'go',
        'php',
        'yaml',
        'yml',
        'rs',
        'swift',
        'dart',
        'cs',
        'ex',
        'exs',
        'md',
        'mdx',
      ]) {
        expect(
          isCheckoutHighlightLanguageSupported('src/file.$extension'),
          isTrue,
          reason: extension,
        );
      }
      expect(isCheckoutHighlightLanguageSupported('src/file.TS'), isTrue);
      expect(isCheckoutHighlightLanguageSupported('Makefile'), isFalse);
      expect(isCheckoutHighlightLanguageSupported('notes.txt'), isFalse);
    });

    test('tokenizes every frozen grammar family', () {
      const samples = {
        'js': 'const value = 1;',
        'ts': 'const value: number = 1;',
        'c': 'int value = 1;',
        'cpp': 'auto value = 1;',
        'json': '{"value": 1}',
        'css': '.value { color: red; }',
        'xml': '<value enabled="true">1</value>',
        'java': 'public int value = 1;',
        'py': 'value = 1',
        'go': 'value := 1',
        'php': r'<?php $value = 1;',
        'yaml': 'value: 1',
        'rs': 'let value = 1;',
        'swift': 'let value = 1',
        'dart': 'final value = 1;',
        'cs': 'var value = 1;',
        'ex': 'value = 1',
        'md': '# Value',
      };

      for (final entry in samples.entries) {
        final highlighted = highlightCheckoutDiffFile(
          DiffFile(
            path: 'sample.${entry.key}',
            status: DiffFileStatus.added,
            additions: 1,
            hunks: [
              DiffHunk(
                header: '@@ -0,0 +1 @@',
                lines: [
                  DiffLine(
                    type: DiffLineType.add,
                    text: entry.value,
                    newLineNo: 1,
                  ),
                ],
              ),
            ],
          ),
        );
        final tokens = highlighted.hunks.single.lines.single.tokens;

        expect(tokens, isNotNull, reason: entry.key);
        expect(
          tokens!.map((token) => token.text).join(),
          entry.value,
          reason: entry.key,
        );
        expect(
          tokens.any((token) => token.style != null),
          isTrue,
          reason: entry.key,
        );
      }
    });

    test('maps the complete frozen semantic scope catalog', () {
      const expected = {
        'keyword': 'keyword',
        'comment': 'comment',
        'doctag': 'comment',
        'string': 'string',
        'quote': 'string',
        'number': 'number',
        'literal': 'literal',
        'built_in': 'literal',
        'symbol': 'literal',
        'function': 'function',
        'class': 'class',
        'title': 'definition',
        'name': 'definition',
        'type': 'type',
        'tag': 'tag',
        'attr': 'attribute',
        'attribute': 'attribute',
        'property': 'property',
        'variable': 'variable',
        'params': 'variable',
        'subst': 'variable',
        'operator': 'operator',
        'punctuation': 'punctuation',
        'bullet': 'punctuation',
        'regexp': 'regexp',
        'escape': 'escape',
        'char': 'escape',
        'meta': 'meta',
        'section': 'heading',
        'link': 'link',
      };

      for (final entry in expected.entries) {
        expect(
          checkoutHighlightTokenStyleForScope('scope.${entry.key}'),
          entry.value,
          reason: entry.key,
        );
      }
      expect(checkoutHighlightTokenStyleForScope(null), isNull);
      expect(checkoutHighlightTokenStyleForScope(''), isNull);
      expect(checkoutHighlightTokenStyleForScope('unknown'), isNull);
    });
  });

  test(
    'uncommitted diff reads HEAD and the working file for parser state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'coding-agent-diff-highlight-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final runner = const GitRunner();
      final cwd = directory.path;

      await runner.run(['init'], cwd: cwd);
      await runner.run(['config', 'user.email', 'test@example.com'], cwd: cwd);
      await runner.run(['config', 'user.name', 'Test User'], cwd: cwd);
      final source = File(p.join(cwd, 'example.ts'));
      await source.writeAsString('''
/*
comment 1
comment 2
comment 3
comment 4
comment 5
old comment
comment 7
*/
const value = 1;
''');
      await runner.run(['add', 'example.ts'], cwd: cwd);
      await runner.run(['commit', '-m', 'initial'], cwd: cwd);
      await source.writeAsString('''
/*
comment 1
comment 2
comment 3
comment 4
comment 5
new comment
comment 7
*/
const value = 1;
''');
      final raw = await runner.run(['diff', 'HEAD', '--no-color'], cwd: cwd);
      final response = DiffResponse(files: parseUnifiedDiff(raw.stdout));

      final highlighted = await CheckoutDiffHighlighter(runner: runner)
          .highlight(
            response,
            cwd: cwd,
            compare: const CheckoutDiffCompare(
              mode: CheckoutDiffMode.uncommitted,
            ),
          );
      final changed = highlighted.files.single.hunks.single.lines
          .where((line) => line.type != DiffLineType.context)
          .toList();

      expect(_tokenPairs(changed[0]), [('old comment', 'comment')]);
      expect(_tokenPairs(changed[1]), [('new comment', 'comment')]);
    },
  );

  test(
    'base diff reads merge-base and HEAD using the renamed old path',
    () async {
      final runner = _RecordingGitRunner({
        'merge-base origin/main HEAD': const GitResult(
          exitCode: 0,
          stdout: 'abc123\n',
          stderr: '',
        ),
        'show abc123:old.ts': const GitResult(
          exitCode: 0,
          stdout: '/*\nold comment\n*/\n',
          stderr: '',
        ),
        'show HEAD:new.ts': const GitResult(
          exitCode: 0,
          stdout: '/*\nnew comment\n*/\n',
          stderr: '',
        ),
      });
      const file = DiffFile(
        path: 'new.ts',
        oldPath: 'old.ts',
        status: DiffFileStatus.renamed,
        additions: 1,
        deletions: 1,
        hunks: [
          DiffHunk(
            header: '@@ -2 +2 @@',
            lines: [
              DiffLine(
                type: DiffLineType.del,
                text: 'old comment',
                oldLineNo: 2,
              ),
              DiffLine(
                type: DiffLineType.add,
                text: 'new comment',
                newLineNo: 2,
              ),
            ],
          ),
        ],
      );

      final highlighted = await CheckoutDiffHighlighter(runner: runner)
          .highlight(
            const DiffResponse(files: [file]),
            cwd: r'C:\repo',
            compare: const CheckoutDiffCompare(
              mode: CheckoutDiffMode.base,
              baseRef: 'origin/main',
            ),
          );

      final changed = highlighted.files.single.hunks.single.lines;
      expect(_tokenPairs(changed[0]), [('old comment', 'comment')]);
      expect(_tokenPairs(changed[1]), [('new comment', 'comment')]);
      expect(runner.calls, [
        'merge-base origin/main HEAD',
        'show abc123:old.ts',
        'show HEAD:new.ts',
      ]);
    },
  );

  test('added and deleted files skip their unavailable content side', () async {
    final runner = _RecordingGitRunner({
      'merge-base main HEAD': const GitResult(
        exitCode: 0,
        stdout: 'base123\n',
        stderr: '',
      ),
      'show HEAD:added.ts': const GitResult(
        exitCode: 0,
        stdout: 'const added = 1;\n',
        stderr: '',
      ),
      'show base123:deleted.ts': const GitResult(
        exitCode: 0,
        stdout: 'const deleted = 2;\n',
        stderr: '',
      ),
    });
    const added = DiffFile(
      path: 'added.ts',
      status: DiffFileStatus.added,
      additions: 1,
      hunks: [
        DiffHunk(
          header: '@@ -0,0 +1 @@',
          lines: [
            DiffLine(
              type: DiffLineType.add,
              text: 'const added = 1;',
              newLineNo: 1,
            ),
          ],
        ),
      ],
    );
    const deleted = DiffFile(
      path: 'deleted.ts',
      status: DiffFileStatus.deleted,
      deletions: 1,
      hunks: [
        DiffHunk(
          header: '@@ -1 +0,0 @@',
          lines: [
            DiffLine(
              type: DiffLineType.del,
              text: 'const deleted = 2;',
              oldLineNo: 1,
            ),
          ],
        ),
      ],
    );

    final highlighted = await CheckoutDiffHighlighter(runner: runner).highlight(
      const DiffResponse(files: [added, deleted]),
      cwd: r'C:\repo',
      compare: const CheckoutDiffCompare(
        mode: CheckoutDiffMode.base,
        baseRef: 'main',
      ),
    );

    expect(
      _token(highlighted.files[0].hunks.single.lines.single, 'const')?.style,
      'keyword',
    );
    expect(
      _token(highlighted.files[1].hunks.single.lines.single, '2')?.style,
      'number',
    );
    expect(runner.calls, [
      'merge-base main HEAD',
      'show HEAD:added.ts',
      'show base123:deleted.ts',
    ]);
  });
}

DiffToken? _token(DiffLine line, String text) {
  for (final token in line.tokens ?? const <DiffToken>[]) {
    if (token.text == text) return token;
  }
  return null;
}

List<(String, String?)> _tokenPairs(DiffLine line) => [
  for (final token in line.tokens ?? const <DiffToken>[])
    (token.text, token.style),
];

DiffFile _typescriptDiff({String path = 'example.ts'}) => DiffFile(
  path: path,
  status: DiffFileStatus.modified,
  additions: 1,
  deletions: 1,
  hunks: const [
    DiffHunk(
      header: '@@ -1,2 +1,2 @@',
      lines: [
        DiffLine(
          type: DiffLineType.context,
          text: 'const foo = 1;',
          oldLineNo: 1,
          newLineNo: 1,
        ),
        DiffLine(type: DiffLineType.del, text: 'const bar = 2;', oldLineNo: 2),
        DiffLine(type: DiffLineType.add, text: 'const bar = 3;', newLineNo: 2),
      ],
    ),
  ],
);

final class _RecordingGitRunner extends GitRunner {
  _RecordingGitRunner(this.results);

  final Map<String, GitResult> results;
  final List<String> calls = [];

  @override
  Future<GitResult> run(
    List<String> args, {
    required String cwd,
    bool check = true,
  }) async {
    final key = args.join(' ');
    calls.add(key);
    final result = results[key];
    if (result == null) {
      throw StateError('Unexpected git command: $key');
    }
    return result;
  }
}
