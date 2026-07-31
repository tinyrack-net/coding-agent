// Port of the upstream Paseo 0.2.0 suites `assistant-file-links/parse.test.ts`
// and `assistant-file-links/resolver.test.ts`, plus the edge cases those suites
// leave unpinned.
//
// The expectations for every case not present upstream were produced by running
// the frozen TypeScript under Node (type-stripping mode) rather than reasoned
// out, because the interesting parts of this module ride on two JS engine
// behaviours Dart does not share: `String.prototype.trim()`'s whitespace set
// and the WHATWG `URL` constructor's percent-encoding / dot-segment / authority
// handling. The groups named "JS engine parity" exist specifically to lock
// those in.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/assistant_file_links/paseo_file_links.dart';
import 'package:flutter_test/flutter_test.dart';

const String root = '/Users/test/project';

InlinePathTarget target(
  String raw,
  String path, {
  int? lineStart,
  int? lineEnd,
}) => InlinePathTarget(
  raw: raw,
  path: path,
  lineStart: lineStart,
  lineEnd: lineEnd,
);

const AssistantFileLinkContext context = AssistantFileLinkContext(
  workspaceRoot: root,
);

/// Records every search issued so the tests can assert the exact daemon call,
/// the way the upstream suite's `suggestionsFromMap` helper does.
final class RecordingSuggestions {
  RecordingSuggestions(this._entriesByQuery, {this.error});

  final Map<String, List<DirectorySuggestionEntry>> _entriesByQuery;
  final String? error;
  final List<DirectorySuggestionQuery> searches = [];

  Future<DirectorySuggestionResult> call(DirectorySuggestionQuery input) async {
    searches.add(input);
    return DirectorySuggestionResult(
      entries: _entriesByQuery[input.query] ?? const [],
      error: error,
    );
  }
}

Future<DirectorySuggestionResult> unavailableSuggestions(
  DirectorySuggestionQuery input,
) async => throw StateError('daemon unavailable');

DirectorySuggestionEntry fileEntry(String path) =>
    DirectorySuggestionEntry(path: path, kind: DirectorySuggestionKind.file);

DirectorySuggestionEntry directoryEntry(String path) =>
    DirectorySuggestionEntry(
      path: path,
      kind: DirectorySuggestionKind.directory,
    );

void main() {
  group('parseInlinePathToken', () {
    test('returns null for plain paths without a line number', () {
      expect(parseInlinePathToken('src/app.ts'), isNull);
      expect(parseInlinePathToken('README.md'), isNull);
    });

    test('parses filename:line', () {
      expect(
        parseInlinePathToken('src/app.ts:12'),
        target('src/app.ts:12', 'src/app.ts', lineStart: 12),
      );
    });

    test('parses filename:lineStart-lineEnd', () {
      expect(
        parseInlinePathToken('src/app.ts:12-20'),
        target('src/app.ts:12-20', 'src/app.ts', lineStart: 12, lineEnd: 20),
      );
    });

    test('parses filename:line:column as a line target', () {
      expect(
        parseInlinePathToken('src/app.ts:12:4'),
        target('src/app.ts:12:4', 'src/app.ts', lineStart: 12),
      );
    });

    test('parses filename(line,column) as a line target', () {
      expect(
        parseInlinePathToken('src/app.ts(12,4)'),
        target('src/app.ts(12,4)', 'src/app.ts', lineStart: 12),
      );
    });

    test('parses filename(start,col-end,col) ranges', () {
      expect(
        parseInlinePathToken('src/app.ts(12,4-20,8)'),
        target(
          'src/app.ts(12,4-20,8)',
          'src/app.ts',
          lineStart: 12,
          lineEnd: 20,
        ),
      );
      expect(
        parseInlinePathToken('src/app.ts(12-20)'),
        target('src/app.ts(12-20)', 'src/app.ts', lineStart: 12, lineEnd: 20),
      );
    });

    test('parses filename lines lineStart-lineEnd', () {
      expect(
        parseInlinePathToken('src/app.ts lines 12-20'),
        target(
          'src/app.ts lines 12-20',
          'src/app.ts',
          lineStart: 12,
          lineEnd: 20,
        ),
      );
    });

    test('accepts the singular "line" keyword in any case', () {
      expect(
        parseInlinePathToken('src/app.ts line 12'),
        target('src/app.ts line 12', 'src/app.ts', lineStart: 12),
      );
      expect(
        parseInlinePathToken('src/app.ts LINES 12'),
        target('src/app.ts LINES 12', 'src/app.ts', lineStart: 12),
      );
      expect(
        parseInlinePathToken('src/app.ts Lines 5-9'),
        target('src/app.ts Lines 5-9', 'src/app.ts', lineStart: 5, lineEnd: 9),
      );
    });

    test('rejects range-only :line tokens', () {
      expect(parseInlinePathToken(':12'), isNull);
      expect(parseInlinePathToken(':12-20'), isNull);
    });

    test('keeps the untrimmed input as raw while trimming the path', () {
      expect(
        parseInlinePathToken('  src/app.ts:12  '),
        target('  src/app.ts:12  ', 'src/app.ts', lineStart: 12),
      );
    });

    test('strips one surrounding quote character from the path', () {
      expect(
        parseInlinePathToken("'src/app.ts':12"),
        target("'src/app.ts':12", 'src/app.ts', lineStart: 12),
      );
      expect(
        parseInlinePathToken('"src/app.ts":12'),
        target('"src/app.ts":12', 'src/app.ts', lineStart: 12),
      );
      expect(
        parseInlinePathToken('`src/app.ts`:12'),
        target('`src/app.ts`:12', 'src/app.ts', lineStart: 12),
      );
    });

    test('normalizes backslashes to forward slashes', () {
      expect(
        parseInlinePathToken(r'src\app.ts:12'),
        target(r'src\app.ts:12', 'src/app.ts', lineStart: 12),
      );
    });

    test('refuses URLs so https://x.dev/a.ts:12 is never a file', () {
      expect(parseInlinePathToken('https://x.dev/a.ts:12'), isNull);
    });

    test('rejects impossible line numbers and inverted ranges', () {
      expect(parseInlinePathToken('src/app.ts:0'), isNull);
      expect(parseInlinePathToken('src/app.ts:12-4'), isNull);
      expect(parseInlinePathToken('src/app.ts:5-0'), isNull);
    });

    test('parses zero-padded line numbers as decimal', () {
      expect(
        parseInlinePathToken('src/app.ts:0012'),
        target('src/app.ts:0012', 'src/app.ts', lineStart: 12),
      );
    });

    test('rejects a digit run too long to be a line number', () {
      // Upstream rejects this too, via `Number.isFinite(parseInt(...))`:
      // 400 nines parse to Infinity as a JS double.
      expect(parseInlinePathToken('file.ts:${'9' * 400}'), isNull);
    });

    test('deviation: rejects line numbers past the 64-bit int range', () {
      // JS parseInt yields a finite (imprecise) 1e23 here, so upstream accepts
      // the token with lineStart 1e23. Dart ints top out at 2^63-1, so the
      // token is rejected instead. Both engines agree on every line number a
      // real tool emits, and both reject the 309+ digit end of the range; only
      // this nonsense middle differs.
      expect(parseInlinePathToken('file.ts:99999999999999999999999'), isNull);
      expect(
        parseInlinePathToken('file.ts:9223372036854775807'),
        target(
          'file.ts:9223372036854775807',
          'file.ts',
          lineStart: 9223372036854775807,
        ),
      );
    });

    test('returns null for blank input', () {
      expect(parseInlinePathToken(''), isNull);
      expect(parseInlinePathToken('   '), isNull);
    });
  });

  group('parseFileProtocolUrl', () {
    test('parses file URLs with line fragments', () {
      expect(
        parseFileProtocolUrl('file:///Users/test/project/src/app.tsx#L81'),
        target(
          'file:///Users/test/project/src/app.tsx#L81',
          '/Users/test/project/src/app.tsx',
          lineStart: 81,
        ),
      );
    });

    test('parses file URLs with line-column fragments', () {
      expect(
        parseFileProtocolUrl(
          'file:///Users/test/project/src/app.tsx#L81C5-L83C2',
        ),
        target(
          'file:///Users/test/project/src/app.tsx#L81C5-L83C2',
          '/Users/test/project/src/app.tsx',
          lineStart: 81,
          lineEnd: 83,
        ),
      );
    });

    test('parses file URLs without line fragments', () {
      expect(
        parseFileProtocolUrl('file:///Users/test/project/src/app.tsx'),
        target(
          'file:///Users/test/project/src/app.tsx',
          '/Users/test/project/src/app.tsx',
        ),
      );
    });

    test('parses windows file URLs and line ranges', () {
      expect(
        parseFileProtocolUrl(
          'file:///C:/Users/test/project/src/app.tsx#L12-L20',
        ),
        target(
          'file:///C:/Users/test/project/src/app.tsx#L12-L20',
          'C:/Users/test/project/src/app.tsx',
          lineStart: 12,
          lineEnd: 20,
        ),
      );
    });

    test('rejects non-file URLs and invalid ranges', () {
      expect(parseFileProtocolUrl('https://example.com/test.ts#L10'), isNull);
      expect(
        parseFileProtocolUrl('file:///Users/test/project/src/app.tsx#L20-L12'),
        isNull,
      );
    });

    test('accepts every spelling of the line fragment', () {
      expect(parseFileProtocolUrl('file:///a.txt#L1-2')?.lineEnd, 2);
      expect(parseFileProtocolUrl('file:///a.txt#l1')?.lineStart, 1);
      expect(parseFileProtocolUrl('file:///a.txt#L1C2')?.lineStart, 1);
      expect(parseFileProtocolUrl('file:///a.txt#L1-L1')?.lineEnd, 1);
    });

    test('treats a non-line fragment as "no line", not as a failure', () {
      expect(
        parseFileProtocolUrl('file:///tmp/x.txt#nope'),
        target('file:///tmp/x.txt#nope', '/tmp/x.txt'),
      );
      expect(
        parseFileProtocolUrl('file:///tmp/x.txt#'),
        target('file:///tmp/x.txt#', '/tmp/x.txt'),
      );
    });

    test('rejects a zero line fragment', () {
      expect(parseFileProtocolUrl('file:///tmp/x.txt#L0'), isNull);
    });

    test('is case-insensitive about the scheme', () {
      expect(
        parseFileProtocolUrl('FILE:///tmp/a.txt'),
        target('FILE:///tmp/a.txt', '/tmp/a.txt'),
      );
    });

    test('normalizes the legacy C| drive spelling', () {
      expect(parseFileProtocolUrl('file:///C|/x.txt')?.path, 'C:/x.txt');
    });

    test('returns null for values that are not URLs at all', () {
      expect(parseFileProtocolUrl('src/app.ts:12'), isNull);
      expect(parseFileProtocolUrl(''), isNull);
      expect(parseFileProtocolUrl('   '), isNull);
    });

    test('drops the query string before the fragment', () {
      expect(
        parseFileProtocolUrl('file:///tmp/x.txt?q=1#L2'),
        target('file:///tmp/x.txt?q=1#L2', '/tmp/x.txt', lineStart: 2),
      );
    });
  });

  group('classifyAssistantFileLink', () {
    test('keeps explicit external URLs out of file parsing', () {
      expect(
        classifyAssistantFileLink('http://dumm.md', workspaceRoot: root),
        const ExternalFileLinkClassification('http://dumm.md'),
      );
      expect(
        classifyAssistantFileLink('mailto:test@example.com'),
        const ExternalFileLinkClassification('mailto:test@example.com'),
      );
    });

    test(
      'classifies bare workspace candidates separately from direct relative files',
      () {
        expect(
          classifyAssistantFileLink('dumm.md', workspaceRoot: root),
          AmbiguousFileCandidateClassification(
            target('dumm.md', '/Users/test/project/dumm.md'),
          ),
        );

        expect(
          classifyAssistantFileLink(
            'message-renderer.tsx',
            workspaceRoot: root,
          ),
          AmbiguousFileCandidateClassification(
            target(
              'message-renderer.tsx',
              '/Users/test/project/message-renderer.tsx',
            ),
          ),
        );

        expect(
          classifyAssistantFileLink(
            'src/components/message.tsx#L33',
            workspaceRoot: root,
          ),
          DirectFileLinkClassification(
            target(
              'src/components/message.tsx#L33',
              '/Users/test/project/src/components/message.tsx',
              lineStart: 33,
            ),
          ),
        );
      },
    );

    test('does not classify normal bare domains as file candidates', () {
      expect(
        classifyAssistantFileLink('google.com', workspaceRoot: root),
        isNull,
      );
      expect(
        classifyAssistantFileLink('example.com', workspaceRoot: root),
        isNull,
      );
      expect(
        classifyAssistantFileLink('openai.com/path', workspaceRoot: root),
        isNull,
      );
    });

    test(
      'does not classify plain inline code words or identifiers as file candidates',
      () {
        for (final value in [
          'main',
          'origin/main',
          '1f7fc232b',
          '25994904967',
          'babysit main 1f7fc232b',
        ]) {
          expect(
            classifyAssistantFileLink(value, workspaceRoot: root),
            isNull,
            reason: value,
          );
        }
      },
    );

    test(
      'does not classify shell commands containing path arguments as file candidates',
      () {
        expect(
          classifyAssistantFileLink(
            'npm run lint -- packages/app/src/stores/workspace-layout-actions.ts '
            'packages/app/src/stores/workspace-layout-store.ts '
            'packages/app/src/screens/workspace/workspace-screen.tsx',
            workspaceRoot: root,
          ),
          isNull,
        );
      },
    );

    test('rejects any token containing whitespace, even a valid one', () {
      // `src/app.ts lines 12-20` parses fine as a target, but the whitespace
      // guard runs first so it never becomes a link.
      expect(
        parseAssistantFileLink('src/app.ts lines 12-20', workspaceRoot: root),
        isNotNull,
      );
      expect(
        classifyAssistantFileLink(
          'src/app.ts lines 12-20',
          workspaceRoot: root,
        ),
        isNull,
      );
    });

    test('treats dotfiles and multi-segment paths correctly', () {
      expect(
        classifyAssistantFileLink('.env', workspaceRoot: root),
        AmbiguousFileCandidateClassification(
          target('.env', '/Users/test/project/.env'),
        ),
      );
      expect(
        classifyAssistantFileLink('sub/dumm.md', workspaceRoot: root),
        DirectFileLinkClassification(
          target('sub/dumm.md', '/Users/test/project/sub/dumm.md'),
        ),
      );
      expect(
        classifyAssistantFileLink('dumm.md:12', workspaceRoot: root),
        AmbiguousFileCandidateClassification(
          target('dumm.md:12', '/Users/test/project/dumm.md', lineStart: 12),
        ),
      );
    });

    test('keeps absolute, tilde and file URL links direct', () {
      expect(
        classifyAssistantFileLink('/tmp/outside.txt', workspaceRoot: root),
        DirectFileLinkClassification(
          target('/tmp/outside.txt', '/tmp/outside.txt'),
        ),
      );
      expect(
        classifyAssistantFileLink('~/.paseo/x.md', workspaceRoot: root),
        DirectFileLinkClassification(target('~/.paseo/x.md', '~/.paseo/x.md')),
      );
      expect(
        classifyAssistantFileLink(
          'file:///tmp/outside.txt',
          workspaceRoot: root,
        ),
        DirectFileLinkClassification(
          target('file:///tmp/outside.txt', '/tmp/outside.txt'),
        ),
      );
      expect(
        classifyAssistantFileLink(
          'C:/repo/src/app.tsx#L12-L20',
          workspaceRoot: root,
        ),
        DirectFileLinkClassification(
          target(
            'C:/repo/src/app.tsx#L12-L20',
            'C:/repo/src/app.tsx',
            lineStart: 12,
            lineEnd: 20,
          ),
        ),
      );
    });

    test('returns null for blank input', () {
      expect(classifyAssistantFileLink('', workspaceRoot: root), isNull);
      expect(classifyAssistantFileLink('   ', workspaceRoot: root), isNull);
    });

    test('needs a workspace root to classify relative links at all', () {
      expect(classifyAssistantFileLink('dumm.md'), isNull);
      expect(
        classifyAssistantFileLink('src/components/message.tsx#L33'),
        isNull,
      );
      expect(
        classifyAssistantFileLink('/tmp/a.txt'),
        DirectFileLinkClassification(target('/tmp/a.txt', '/tmp/a.txt')),
      );
      expect(
        classifyAssistantFileLink('http://x.dev'),
        const ExternalFileLinkClassification('http://x.dev'),
      );
    });
  });

  group('parseAssistantFileLink', () {
    test('resolves bare markdown filenames against the active workspace', () {
      expect(
        parseAssistantFileLink('dumm.md', workspaceRoot: root),
        target('dumm.md', '/Users/test/project/dumm.md'),
      );
    });

    test(
      'resolves bare source filenames with line suffixes against the active workspace',
      () {
        expect(
          parseAssistantFileLink('file.ts:12', workspaceRoot: root),
          target('file.ts:12', '/Users/test/project/file.ts', lineStart: 12),
        );
      },
    );

    test('rejects bare domains and domain-like paths', () {
      expect(parseAssistantFileLink('google.com', workspaceRoot: root), isNull);
      expect(
        parseAssistantFileLink('google.com:80', workspaceRoot: root),
        isNull,
      );
      expect(
        parseAssistantFileLink('openai.com/path', workspaceRoot: root),
        isNull,
      );
    });

    test('resolves relative paths against the active workspace', () {
      expect(
        parseAssistantFileLink(
          'src/components/message.tsx#L33',
          workspaceRoot: root,
        ),
        target(
          'src/components/message.tsx#L33',
          '/Users/test/project/src/components/message.tsx',
          lineStart: 33,
        ),
      );
    });

    test('parses absolute POSIX hrefs inside the active workspace', () {
      expect(
        parseAssistantFileLink(
          '/Users/test/project/src/app.tsx#L33',
          workspaceRoot: root,
        ),
        target(
          '/Users/test/project/src/app.tsx#L33',
          '/Users/test/project/src/app.tsx',
          lineStart: 33,
        ),
      );
    });

    test(
      'parses absolute POSIX hrefs with VS Code-style line suffixes inside the active workspace',
      () {
        expect(
          parseAssistantFileLink(
            '/Users/test/project/src/app.tsx:33',
            workspaceRoot: root,
          ),
          target(
            '/Users/test/project/src/app.tsx:33',
            '/Users/test/project/src/app.tsx',
            lineStart: 33,
          ),
        );
      },
    );

    test('parses absolute Windows hrefs inside the active workspace', () {
      expect(
        parseAssistantFileLink(
          'C:/repo/src/app.tsx#L12-L20',
          workspaceRoot: 'C:/repo',
        ),
        target(
          'C:/repo/src/app.tsx#L12-L20',
          'C:/repo/src/app.tsx',
          lineStart: 12,
          lineEnd: 20,
        ),
      );
    });

    test(
      'parses absolute Windows hrefs with VS Code-style line suffixes inside the active workspace',
      () {
        expect(
          parseAssistantFileLink(
            'C:/repo/src/app.tsx:12-20',
            workspaceRoot: 'C:/repo',
          ),
          target(
            'C:/repo/src/app.tsx:12-20',
            'C:/repo/src/app.tsx',
            lineStart: 12,
            lineEnd: 20,
          ),
        );
      },
    );

    test('parses backslash-spelled Windows hrefs', () {
      expect(
        parseAssistantFileLink(
          r'C:\repo\src\app.tsx#L3',
          workspaceRoot: 'C:/repo',
        ),
        target(r'C:\repo\src\app.tsx#L3', 'C:/repo/src/app.tsx', lineStart: 3),
      );
      expect(
        parseAssistantFileLink(
          r'C:\repo\src\app.tsx:3',
          workspaceRoot: 'C:/repo',
        ),
        target(r'C:\repo\src\app.tsx:3', 'C:/repo/src/app.tsx', lineStart: 3),
      );
    });

    test('allows file URLs even when they are outside the workspace root', () {
      expect(
        parseAssistantFileLink('file:///tmp/outside.txt', workspaceRoot: root),
        target('file:///tmp/outside.txt', '/tmp/outside.txt'),
      );
    });

    test('allows absolute hrefs outside the workspace root', () {
      expect(
        parseAssistantFileLink('/tmp/outside.txt', workspaceRoot: root),
        target('/tmp/outside.txt', '/tmp/outside.txt'),
      );
    });

    test('keeps tilde hrefs as direct home-relative file targets', () {
      expect(
        parseAssistantFileLink(
          '~/.paseo/plans/file-preview.md',
          workspaceRoot: root,
        ),
        target(
          '~/.paseo/plans/file-preview.md',
          '~/.paseo/plans/file-preview.md',
        ),
      );
      expect(
        parseAssistantFileLink(
          '~/.paseo/plans/file-preview.md:12',
          workspaceRoot: root,
        ),
        target(
          '~/.paseo/plans/file-preview.md:12',
          '~/.paseo/plans/file-preview.md',
          lineStart: 12,
        ),
      );
      expect(
        parseAssistantFileLink(
          r'~\.paseo\plans\file-preview.md',
          workspaceRoot: root,
        ),
        target(
          r'~\.paseo\plans\file-preview.md',
          '~/.paseo/plans/file-preview.md',
        ),
      );
    });

    test('rejects a bare tilde, which names no file', () {
      expect(parseAssistantFileLink('~', workspaceRoot: root), isNull);
    });

    test('rejects external URLs', () {
      expect(
        parseAssistantFileLink(
          'https://example.com/Users/test/project/src/app.tsx',
        ),
        isNull,
      );
      expect(
        parseAssistantFileLink('http://dumm.md', workspaceRoot: root),
        isNull,
      );
    });

    test('rejects invalid line fragments', () {
      expect(
        parseAssistantFileLink(
          '/Users/test/project/src/app.tsx#L20-L12',
          workspaceRoot: root,
        ),
        isNull,
      );
      expect(
        parseAssistantFileLink('src/app.ts#L5-L2', workspaceRoot: root),
        isNull,
      );
    });

    test(
      "does not throw when the input contains a literal '%' that is not a valid percent-escape",
      () {
        // Regressions for tool output strings like ping's "100% packet loss",
        // Windows "%PATH%" references, and percentages such as "0% off".
        // decodeURIComponent throws URIError on these; the parser must swallow
        // it and return null rather than crash the renderer.
        const cases = [
          '/tmp/100% packet loss',
          '/Users/test/project/0% off',
          '/var/log/%PATH%/x.log',
          'file:///tmp/100% packet loss',
        ];
        for (final value in cases) {
          expect(
            () => parseAssistantFileLink(value, workspaceRoot: root),
            returnsNormally,
            reason: value,
          );
        }
        expect(
          () => parseFileProtocolUrl('file:///tmp/100% packet loss'),
          returnsNormally,
        );
      },
    );

    test('trims before resolving, and records the trimmed value as raw', () {
      expect(
        parseAssistantFileLink('  dumm.md  ', workspaceRoot: root),
        target('dumm.md', '/Users/test/project/dumm.md'),
      );
    });

    test('lets an inline line marker win over a trailing #fragment', () {
      expect(
        parseAssistantFileLink('src/app.ts:12#L20', workspaceRoot: root),
        target(
          'src/app.ts:12#L20',
          '/Users/test/project/src/app.ts',
          lineStart: 12,
        ),
      );
    });

    test('treats an unparseable fragment as "no line"', () {
      expect(
        parseAssistantFileLink('src/app.ts#nope', workspaceRoot: root),
        target('src/app.ts#nope', '/Users/test/project/src/app.ts'),
      );
      expect(
        parseAssistantFileLink('src/app.ts#', workspaceRoot: root),
        target('src/app.ts#', '/Users/test/project/src/app.ts'),
      );
      expect(
        parseAssistantFileLink('/tmp/x.txt#nope', workspaceRoot: root),
        target('/tmp/x.txt#nope', '/tmp/x.txt'),
      );
    });

    test('resolves ./ and inner .. but refuses to escape the workspace', () {
      expect(
        parseAssistantFileLink('./inner.md', workspaceRoot: root),
        target('./inner.md', '/Users/test/project/inner.md'),
      );
      expect(
        parseAssistantFileLink('sub/../file.md', workspaceRoot: root),
        target('sub/../file.md', '/Users/test/project/file.md'),
      );
      expect(
        parseAssistantFileLink('../outside.md', workspaceRoot: root),
        isNull,
      );
      expect(parseAssistantFileLink('../../x.md', workspaceRoot: root), isNull);
    });

    test('accepts dotfiles anywhere in the path', () {
      expect(
        parseAssistantFileLink('.env', workspaceRoot: root),
        target('.env', '/Users/test/project/.env'),
      );
      expect(
        parseAssistantFileLink('docs/.env', workspaceRoot: root),
        target('docs/.env', '/Users/test/project/docs/.env'),
      );
    });

    test('rejects unknown extensions on bare tokens', () {
      expect(
        parseAssistantFileLink('a.unknownext', workspaceRoot: root),
        isNull,
      );
    });

    test('needs a workspace root for relative links', () {
      expect(parseAssistantFileLink('dumm.md'), isNull);
      expect(parseAssistantFileLink('src/a.ts'), isNull);
      expect(parseAssistantFileLink('dumm.md', workspaceRoot: ''), isNull);
      expect(
        parseAssistantFileLink('/tmp/a.txt'),
        target('/tmp/a.txt', '/tmp/a.txt'),
      );
      expect(parseAssistantFileLink('~/a.md'), target('~/a.md', '~/a.md'));
      expect(
        parseAssistantFileLink('file:///tmp/a.txt'),
        target('file:///tmp/a.txt', '/tmp/a.txt'),
      );
    });

    test('handles root shapes: bare slash, trailing slash, drive letter', () {
      expect(
        parseAssistantFileLink('dumm.md', workspaceRoot: '/')?.path,
        '/dumm.md',
      );
      expect(
        parseAssistantFileLink('dumm.md', workspaceRoot: '/a/b/')?.path,
        '/a/b/dumm.md',
      );
      expect(
        parseAssistantFileLink('dumm.md', workspaceRoot: r'C:\repo')?.path,
        'C:/repo/dumm.md',
      );
    });

    test('drops a query string, because a file path has none', () {
      expect(
        parseAssistantFileLink('/tmp/a?b.txt', workspaceRoot: root),
        target('/tmp/a?b.txt', '/tmp/a'),
      );
      // `C:` reads as a URL scheme once the Windows-path branch declines it, so
      // the drive letter is swallowed along with the query.
      expect(
        parseAssistantFileLink('C:/repo/a?b.txt', workspaceRoot: root),
        target('C:/repo/a?b.txt', '/repo/a'),
      );
      expect(
        parseAssistantFileLink('C:/repo/x#', workspaceRoot: root),
        target('C:/repo/x#', '/repo/x'),
      );
    });
  });

  group('isFileLookingAssistantToken', () {
    test('accepts paths and rejects prose', () {
      const accepted = [
        'dumm.md',
        'file.ts:12',
        'src/app.ts',
        '/tmp/x',
        '~/x.md',
        '.env',
        'x.md#L2',
        'x.md#nope',
      ];
      for (final value in accepted) {
        expect(isFileLookingAssistantToken(value), isTrue, reason: value);
      }

      const rejected = [
        'google.com',
        'main',
        'http://x.dev',
        'a b.md',
        'a?b.md',
        '',
        'x.md#L0',
      ];
      for (final value in rejected) {
        expect(isFileLookingAssistantToken(value), isFalse, reason: value);
      }
    });
  });

  group('normalizeInlinePathTarget', () {
    test('keeps relative file paths as file targets', () {
      expect(
        normalizeInlinePathTarget('packages/app/src/components/message.tsx'),
        const NormalizedInlinePathTarget(
          directory: 'packages/app/src/components',
          file: 'packages/app/src/components/message.tsx',
        ),
      );
    });

    test(
      'resolves absolute paths under cwd back to workspace-relative paths',
      () {
        expect(
          normalizeInlinePathTarget(
            '/Users/test/project/packages/app/src/components/message.tsx',
            cwd: root,
          ),
          const NormalizedInlinePathTarget(
            directory: 'packages/app/src/components',
            file: 'packages/app/src/components/message.tsx',
          ),
        );
      },
    );

    test('keeps absolute paths outside cwd as absolute file targets', () {
      expect(
        normalizeInlinePathTarget('/tmp/message.tsx', cwd: root),
        const NormalizedInlinePathTarget(
          directory: '/tmp',
          file: '/tmp/message.tsx',
        ),
      );
    });

    test('keeps tilde paths as home-relative file targets', () {
      expect(
        normalizeInlinePathTarget('~/.paseo/plans/file-preview.md', cwd: root),
        const NormalizedInlinePathTarget(
          directory: '~/.paseo/plans',
          file: '~/.paseo/plans/file-preview.md',
        ),
      );
    });

    test('treats cwd itself as the workspace root directory', () {
      expect(
        normalizeInlinePathTarget(root, cwd: root),
        const NormalizedInlinePathTarget(directory: '.'),
      );
      expect(
        normalizeInlinePathTarget('/Users/test/project/', cwd: root),
        const NormalizedInlinePathTarget(directory: '.'),
      );
      expect(
        normalizeInlinePathTarget('/tmp/', cwd: '/tmp'),
        const NormalizedInlinePathTarget(directory: '.'),
      );
    });

    test('keeps trailing-slash paths as directories', () {
      expect(
        normalizeInlinePathTarget(
          '/Users/test/project/packages/app/',
          cwd: root,
        ),
        const NormalizedInlinePathTarget(directory: 'packages/app'),
      );
      expect(
        normalizeInlinePathTarget('dir/'),
        const NormalizedInlinePathTarget(directory: 'dir'),
      );
      expect(
        normalizeInlinePathTarget('./'),
        const NormalizedInlinePathTarget(directory: '.'),
      );
    });

    test('strips a leading ./ and defaults the directory to .', () {
      expect(
        normalizeInlinePathTarget('./a.md'),
        const NormalizedInlinePathTarget(directory: '.', file: 'a.md'),
      );
      expect(
        normalizeInlinePathTarget('a.md'),
        const NormalizedInlinePathTarget(directory: '.', file: 'a.md'),
      );
    });

    test('returns null for an empty path', () {
      expect(normalizeInlinePathTarget(''), isNull);
    });

    test('compares Windows paths case-insensitively against cwd', () {
      expect(
        normalizeInlinePathTarget('C:/Repo/src/a.ts', cwd: 'c:/repo'),
        const NormalizedInlinePathTarget(directory: 'src', file: 'src/a.ts'),
      );
    });

    test('collapses repeated separators and strips surrounding quotes', () {
      expect(
        normalizeInlinePathTarget('/Users/test/project//a//b.md', cwd: root),
        const NormalizedInlinePathTarget(directory: 'a', file: 'a/b.md'),
      );
      expect(
        normalizeInlinePathTarget("'/tmp/a.md'"),
        const NormalizedInlinePathTarget(directory: '/tmp', file: '/tmp/a.md'),
      );
    });

    test('a bare / outside cwd still reports the root directory', () {
      expect(
        normalizeInlinePathTarget('/', cwd: root),
        const NormalizedInlinePathTarget(directory: '.'),
      );
    });
  });

  group('JS engine parity: whitespace', () {
    // Dart's String.trim() strips U+0085 NEL, JavaScript's does not, and Dart's
    // RegExp \s matches exactly JavaScript's set. Both facts are load-bearing:
    // trimming has to follow JS, and the whitespace *rejection* checks follow
    // the (identical) regex class.
    test('trims exactly the characters JavaScript trims', () {
      // U+00A0 and U+FEFF are whitespace to both engines.
      expect(
        parseInlinePathToken('a.ts:12\u00a0'),
        target('a.ts:12\u00a0', 'a.ts', lineStart: 12),
      );
      expect(
        parseInlinePathToken('a.ts:12\ufeff'),
        target('a.ts:12\ufeff', 'a.ts', lineStart: 12),
      );

      // U+0085 NEL is whitespace to Dart's trim() but not to JavaScript's, so
      // upstream leaves it attached and the token fails to parse. A naive
      // `.trim()` port would wrongly accept these.
      expect(parseInlinePathToken('a.ts:12\u0085'), isNull);
      expect(
        classifyAssistantFileLink('a.ts\u0085', workspaceRoot: root),
        isNull,
      );

      // U+200B ZWSP is whitespace to neither.
      expect(parseInlinePathToken('a.ts:12\u200b'), isNull);
    });

    test('a U+00A0-padded token trims down to a clean candidate', () {
      expect(
        classifyAssistantFileLink('a.ts\u00a0', workspaceRoot: root),
        AmbiguousFileCandidateClassification(
          target('a.ts', '/Users/test/project/a.ts'),
        ),
      );
    });

    test('the \\s word-suffix regex accepts non-breaking spaces', () {
      expect(
        parseInlinePathToken('src/app.ts\u00a0lines\u00a012'),
        target('src/app.ts\u00a0lines\u00a012', 'src/app.ts', lineStart: 12),
      );
    });
  });

  group('JS engine parity: WHATWG URL', () {
    test('percent-encodes then decodes, round-tripping most characters', () {
      // Spaces, non-ASCII, braces, carets and quotes all survive the
      // encode/decode round trip inside `new URL()`.
      expect(
        parseAssistantFileLink('/tmp/\u00e9.txt', workspaceRoot: root)?.path,
        '/tmp/\u00e9.txt',
      );
      expect(
        parseFileProtocolUrl('file:///tmp/\u00e9.txt')?.path,
        '/tmp/\u00e9.txt',
      );
      expect(
        parseAssistantFileLink('/tmp/a^b.txt', workspaceRoot: root)?.path,
        '/tmp/a^b.txt',
      );
      expect(
        parseAssistantFileLink('/tmp/{a}.txt', workspaceRoot: root)?.path,
        '/tmp/{a}.txt',
      );
      expect(
        parseAssistantFileLink("/tmp/a'b.txt", workspaceRoot: root)?.path,
        "/tmp/a'b.txt",
      );
      expect(
        parseAssistantFileLink('/tmp/a|b.txt', workspaceRoot: root)?.path,
        '/tmp/a|b.txt',
      );
      // An already-encoded escape decodes, which is the point of the round trip.
      expect(
        parseAssistantFileLink('/tmp/a%20b.txt', workspaceRoot: root)?.path,
        '/tmp/a b.txt',
      );
      expect(
        parseFileProtocolUrl('file:///tmp/a%20b.txt')?.path,
        '/tmp/a b.txt',
      );
    });

    test('a bare % survives encoding but breaks decoding, mangling the path', () {
      // This is the observable consequence of the encode/decode pair: the space
      // becomes %20, then decodeURIComponent chokes on the neighbouring bare %
      // and the whole encoded string is kept.
      expect(
        parseAssistantFileLink(
          '/tmp/100% packet loss',
          workspaceRoot: root,
        )?.path,
        '/tmp/100%%20packet%20loss',
      );
      expect(
        parseAssistantFileLink(
          '/Users/test/project/0% off',
          workspaceRoot: root,
        )?.path,
        '/Users/test/project/0%%20off',
      );
      expect(
        parseFileProtocolUrl('file:///tmp/100% packet loss')?.path,
        '/tmp/100%%20packet%20loss',
      );
      // With nothing to encode there is nothing to mangle.
      expect(
        parseAssistantFileLink(
          '/var/log/%PATH%/x.log',
          workspaceRoot: root,
        )?.path,
        '/var/log/%PATH%/x.log',
      );
      expect(
        parseAssistantFileLink('/tmp/50%', workspaceRoot: root)?.path,
        '/tmp/50%',
      );
    });

    test('collapses . and .. segments the way new URL() does', () {
      expect(
        parseAssistantFileLink('/tmp/../etc/passwd', workspaceRoot: root)?.path,
        '/etc/passwd',
      );
      expect(
        parseFileProtocolUrl('file:///tmp/../etc/x.txt')?.path,
        '/etc/x.txt',
      );
      expect(
        parseFileProtocolUrl('file:///tmp/a/./b/../c.txt')?.path,
        '/tmp/a/c.txt',
      );
    });

    test('reads the leading \\\\ of a UNC path as a URL authority', () {
      // Surprising but faithful: `\\server\share\x.txt` is absolute, reaches the
      // URL branch, and `new URL()` consumes `server` as the host.
      expect(
        parseAssistantFileLink(r'\\server\share\x.txt', workspaceRoot: root),
        target(r'\\server\share\x.txt', '/share/x.txt'),
      );
      expect(
        classifyAssistantFileLink(r'\\server\share\x.txt', workspaceRoot: root),
        DirectFileLinkClassification(
          target(r'\\server\share\x.txt', '/share/x.txt'),
        ),
      );
    });

    test('a file: URL host is swallowed the same way', () {
      expect(
        parseFileProtocolUrl('file://host/share/x.txt')?.path,
        '/share/x.txt',
      );
      expect(parseFileProtocolUrl('file://')?.path, '/');
      expect(parseFileProtocolUrl('file:///')?.path, '/');
      expect(parseFileProtocolUrl('file:./rel.txt')?.path, '/rel.txt');
      expect(parseFileProtocolUrl('file:/abs.txt')?.path, '/abs.txt');
    });
  });

  group('classifyForResolution', () {
    test('returns the directFile target synchronously', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(href: 'src/components/message.tsx#L33'),
          context,
        ),
        ResolvedFileLinkResolution(
          FileAssistantFileLink(
            target(
              'src/components/message.tsx#L33',
              '/Users/test/project/src/components/message.tsx',
              lineStart: 33,
            ),
          ),
        ),
      );
    });

    test('preserves line ranges on direct workspace files', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'src/components/message.tsx:33-40',
          ),
          context,
        ),
        ResolvedFileLinkResolution(
          FileAssistantFileLink(
            target(
              'src/components/message.tsx:33-40',
              '/Users/test/project/src/components/message.tsx',
              lineStart: 33,
              lineEnd: 40,
            ),
          ),
        ),
      );
    });

    test(
      'flags basename inline-code as a daemon lookup keyed by suggestion query',
      () {
        expect(
          classifyForResolution(
            const AssistantFileLinkSource(
              href: 'file.ts:12',
              text: 'file.ts:12',
              sourceType: AssistantFileLinkSourceType.inlineCode,
            ),
            context,
          ),
          NeedsLookupFileLinkResolution(
            ambiguousQuery: 'file.ts',
            token: 'file.ts:12',
            target: target(
              'file.ts:12',
              '/Users/test/project/file.ts',
              lineStart: 12,
            ),
          ),
        );
      },
    );

    test('routes relative inline-code paths through the daemon too', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'src/a.ts#L2',
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          context,
        ),
        NeedsLookupFileLinkResolution(
          ambiguousQuery: 'src/a.ts',
          token: 'src/a.ts#L2',
          target: target(
            'src/a.ts#L2',
            '/Users/test/project/src/a.ts',
            lineStart: 2,
          ),
        ),
      );
    });

    test('trusts unambiguous inline-code tokens without a lookup', () {
      for (final href in [
        '/Users/test/project/src/a.ts',
        'file:///Users/test/project/src/a.ts',
        'C:/x/a.ts',
        '~/a.md',
      ]) {
        final result = classifyForResolution(
          AssistantFileLinkSource(
            href: href,
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          context,
        );
        expect(result, isA<ResolvedFileLinkResolution>(), reason: href);
        expect(
          (result as ResolvedFileLinkResolution).value,
          isA<FileAssistantFileLink>(),
          reason: href,
        );
      }
    });

    test('keeps explicit external URLs external', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            text: 'dumm.md',
          ),
          context,
        ),
        const ResolvedFileLinkResolution(
          ExternalAssistantFileLink('http://dumm.md'),
        ),
      );
    });

    test(
      'keeps absolute paths outside the workspace as direct file targets',
      () {
        expect(
          classifyForResolution(
            const AssistantFileLinkSource(href: '/tmp/outside.txt'),
            context,
          ),
          ResolvedFileLinkResolution(
            FileAssistantFileLink(
              target('/tmp/outside.txt', '/tmp/outside.txt'),
            ),
          ),
        );
      },
    );

    test('keeps tilde paths as direct file targets', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(href: '~/.paseo/plans/file-preview.md'),
          context,
        ),
        ResolvedFileLinkResolution(
          FileAssistantFileLink(
            target(
              '~/.paseo/plans/file-preview.md',
              '~/.paseo/plans/file-preview.md',
            ),
          ),
        ),
      );
    });

    test('keeps auto-linkified normal domains external', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'http://google.com',
            text: 'google.com',
            markup: 'linkify',
          ),
          context,
        ),
        const ResolvedFileLinkResolution(
          ExternalAssistantFileLink('http://google.com'),
        ),
      );
    });

    test('recovers a file from an auto-linkified href via its text', () {
      final expected = NeedsLookupFileLinkResolution(
        ambiguousQuery: 'dumm.md',
        token: 'dumm.md',
        target: target('dumm.md', '/Users/test/project/dumm.md'),
      );
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            text: 'dumm.md',
            markup: 'linkify',
          ),
          context,
        ),
        expected,
      );
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            text: 'dumm.md',
            sourceInfo: 'auto',
          ),
          context,
        ),
        expected,
      );
    });

    test('falls back to the href when the linkified text is blank', () {
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            text: '   ',
            markup: 'linkify',
          ),
          context,
        ),
        const ResolvedFileLinkResolution(
          ExternalAssistantFileLink('http://dumm.md'),
        ),
      );
    });

    test('returns ignored for non-file-looking content', () {
      expect(
        classifyForResolution(const AssistantFileLinkSource(href: ''), context),
        const ResolvedFileLinkResolution(IgnoredAssistantFileLink()),
      );
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(href: '   '),
          context,
        ),
        const ResolvedFileLinkResolution(IgnoredAssistantFileLink()),
      );
      expect(
        classifyForResolution(
          const AssistantFileLinkSource(
            href: 'main',
            text: 'main',
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          context,
        ),
        const ResolvedFileLinkResolution(IgnoredAssistantFileLink()),
      );
    });

    test(
      'ignores relative links when there is no workspace root to search',
      () {
        for (final ctx in const [
          AssistantFileLinkContext(),
          AssistantFileLinkContext(workspaceRoot: '   '),
        ]) {
          expect(
            classifyForResolution(
              const AssistantFileLinkSource(href: 'dumm.md'),
              ctx,
            ),
            const ResolvedFileLinkResolution(IgnoredAssistantFileLink()),
          );
        }
        expect(
          classifyForResolution(
            const AssistantFileLinkSource(href: '/tmp/a.txt'),
            const AssistantFileLinkContext(),
          ),
          ResolvedFileLinkResolution(
            FileAssistantFileLink(target('/tmp/a.txt', '/tmp/a.txt')),
          ),
        );
      },
    );
  });

  group('fetchDaemonResolution', () {
    test('resolves daemon suggestions into workspace file targets', () async {
      final suggestions = RecordingSuggestions({
        'file.ts': [
          directoryEntry('dir'),
          fileEntry('packages/app/src/file.ts'),
        ],
      });

      final result = await fetchDaemonResolution(
        ambiguousQuery: 'file.ts',
        token: 'file.ts:12',
        target: target(
          'file.ts:12',
          '/Users/test/project/file.ts',
          lineStart: 12,
        ),
        workspaceRoot: root,
        getDirectorySuggestions: suggestions.call,
      );

      expect(suggestions.searches, hasLength(1));
      final search = suggestions.searches.single;
      expect(search.query, 'file.ts');
      expect(search.cwd, root);
      expect(search.matchMode, 'suffix');
      expect(search.limit, 1);
      expect(search.includeFiles, isTrue);
      expect(search.includeDirectories, isFalse);

      expect(
        result,
        target(
          'file.ts:12',
          '/Users/test/project/packages/app/src/file.ts',
          lineStart: 12,
        ),
      );
    });

    test('normalizes and trims the workspace root when joining', () async {
      final suggestions = RecordingSuggestions({
        'file.ts': [fileEntry('/sub/file.ts')],
      });

      final result = await fetchDaemonResolution(
        ambiguousQuery: 'file.ts',
        token: 't',
        target: target('t', 'x'),
        workspaceRoot: '  C:\\repo\\  ',
        getDirectorySuggestions: suggestions.call,
      );

      expect(result, target('t', 'C:/repo/sub/file.ts'));
      expect(suggestions.searches.single.cwd, r'C:\repo\');
    });

    test('treats an empty-string error as no error', () async {
      // Upstream tests `suggestions.error` for JS truthiness, so "" passes.
      final suggestions = RecordingSuggestions({
        'q': [fileEntry('a.ts')],
      }, error: '');

      expect(
        await fetchDaemonResolution(
          ambiguousQuery: 'q',
          token: 't',
          target: target('t', 'x', lineStart: 3, lineEnd: 5),
          workspaceRoot: '/root',
          getDirectorySuggestions: suggestions.call,
        ),
        target('t', '/root/a.ts', lineStart: 3, lineEnd: 5),
      );
    });

    test(
      'throws a typed unresolved error when the daemon finds no match',
      () async {
        final suggestions = RecordingSuggestions({});

        await expectLater(
          fetchDaemonResolution(
            ambiguousQuery: 'src/file.ts',
            token: 'src/file.ts',
            target: target('src/file.ts', '/Users/test/project/src/file.ts'),
            workspaceRoot: root,
            getDirectorySuggestions: suggestions.call,
          ),
          throwsA(UnresolvedFileLinkError('src/file.ts')),
        );
      },
    );

    test('throws a typed unresolved error when the daemon throws', () async {
      await expectLater(
        fetchDaemonResolution(
          ambiguousQuery: 'dumm.md',
          token: 'dumm.md',
          target: target('dumm.md', '/Users/test/project/dumm.md'),
          workspaceRoot: root,
          getDirectorySuggestions: unavailableSuggestions,
        ),
        throwsA(UnresolvedFileLinkError('dumm.md')),
      );
    });

    test('throws for directory-only matches and for reported errors', () async {
      await expectLater(
        fetchDaemonResolution(
          ambiguousQuery: 'q',
          token: 'tok',
          target: target('t', 'x'),
          workspaceRoot: '/root',
          getDirectorySuggestions: RecordingSuggestions({
            'q': [directoryEntry('d')],
          }).call,
        ),
        throwsA(UnresolvedFileLinkError('tok')),
      );

      await expectLater(
        fetchDaemonResolution(
          ambiguousQuery: 'q',
          token: 'tok',
          target: target('t', 'x'),
          workspaceRoot: '/root',
          getDirectorySuggestions: RecordingSuggestions({
            'q': [fileEntry('a.ts')],
          }, error: 'boom').call,
        ),
        throwsA(UnresolvedFileLinkError('tok')),
      );
    });

    test(
      'throws without ever calling the daemon when there is no root',
      () async {
        for (final workspaceRoot in [null, '   ']) {
          final suggestions = RecordingSuggestions({});
          await expectLater(
            fetchDaemonResolution(
              ambiguousQuery: 'q',
              token: 'tok',
              target: target('t', 'x'),
              workspaceRoot: workspaceRoot,
              getDirectorySuggestions: suggestions.call,
            ),
            throwsA(UnresolvedFileLinkError('tok')),
          );
          expect(suggestions.searches, isEmpty);
        }
      },
    );

    test('carries the English message by default and honours a translator', () {
      expect(
        UnresolvedFileLinkError('dumm.md').message,
        'No file found for dumm.md',
      );
      expect(
        UnresolvedFileLinkError(
          'dumm.md',
          describe: (token) => 'nope: $token',
        ).message,
        'nope: dumm.md',
      );
      expect(
        UnresolvedFileLinkError('a') == UnresolvedFileLinkError('a'),
        isTrue,
      );
      expect(
        UnresolvedFileLinkError('a') == UnresolvedFileLinkError('b'),
        isFalse,
      );
    });
  });

  group('getAssistantFileLinkToken', () {
    test(
      'uses rendered text for markdown-it linkified tokens and href for explicit links',
      () {
        expect(
          getAssistantFileLinkToken(
            const AssistantFileLinkSource(
              href: 'http://dumm.md',
              text: 'dumm.md',
              markup: 'linkify',
              sourceInfo: 'auto',
            ),
          ),
          'dumm.md',
        );
        expect(
          getAssistantFileLinkToken(
            const AssistantFileLinkSource(
              href: 'http://google.com',
              text: 'google.com',
              markup: 'linkify',
              sourceInfo: 'auto',
            ),
          ),
          'http://google.com',
        );
        expect(
          getAssistantFileLinkToken(
            const AssistantFileLinkSource(
              href: 'http://dumm.md',
              text: 'dumm.md',
              markup: '',
              sourceInfo: '',
            ),
          ),
          'http://dumm.md',
        );
        expect(
          getAssistantFileLinkToken(
            const AssistantFileLinkSource(
              href: 'workspace-git-service.ts:1553',
              text: 'workspace-git-service.ts:1553',
              sourceType: AssistantFileLinkSourceType.inlineCode,
            ),
          ),
          'workspace-git-service.ts:1553',
        );
      },
    );

    test('trims the rendered text and tolerates a missing one', () {
      expect(
        getAssistantFileLinkToken(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            text: '  dumm.md  ',
            markup: 'linkify',
          ),
        ),
        'dumm.md',
      );
      expect(
        getAssistantFileLinkToken(
          const AssistantFileLinkSource(
            href: 'http://dumm.md',
            markup: 'linkify',
          ),
        ),
        'http://dumm.md',
      );
      expect(
        getAssistantFileLinkToken(
          const AssistantFileLinkSource(
            href: 'abc',
            text: 'dumm.md',
            sourceInfo: 'auto',
          ),
        ),
        'dumm.md',
      );
    });
  });

  group('getAmbiguousSuggestionQuery', () {
    test('keeps the root-relative shape when the path is under the root', () {
      final inside = target('x', '/Users/test/project/src/a.ts');
      expect(getAmbiguousSuggestionQuery(inside, root), 'src/a.ts');
      expect(
        getAmbiguousSuggestionQuery(inside, '/Users/test/project///'),
        'src/a.ts',
      );
      expect(
        getAmbiguousSuggestionQuery(
          target('x', r'C:\repo\src\a.ts'),
          r'C:\repo',
        ),
        'src/a.ts',
      );
    });

    test('falls back to the basename otherwise', () {
      expect(
        getAmbiguousSuggestionQuery(target('x', '/tmp/a.ts'), root),
        'a.ts',
      );
      expect(getAmbiguousSuggestionQuery(target('x', 'a.ts'), root), 'a.ts');
    });

    test('an empty root makes the leading slash the prefix', () {
      expect(
        getAmbiguousSuggestionQuery(
          target('x', '/Users/test/project/src/a.ts'),
          '',
        ),
        'Users/test/project/src/a.ts',
      );
    });
  });

  group('shouldResolveDirectFileThroughSuggestions', () {
    test('only relative inline-code tokens inside the root are searched', () {
      bool check(AssistantFileLinkSource source, String path) =>
          shouldResolveDirectFileThroughSuggestions(
            context: context,
            source: source,
            token: source.href,
            target: target(source.href, path),
          );

      expect(
        check(
          const AssistantFileLinkSource(
            href: 'a.ts',
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          '/Users/test/project/a.ts',
        ),
        isTrue,
      );
      // Not inline code.
      expect(
        check(
          const AssistantFileLinkSource(href: 'a.ts'),
          '/Users/test/project/a.ts',
        ),
        isFalse,
      );
      // Written absolutely, so it is an instruction, not a guess.
      for (final href in ['/a.ts', 'file://x', r'C:\x']) {
        expect(
          check(
            AssistantFileLinkSource(
              href: href,
              sourceType: AssistantFileLinkSourceType.inlineCode,
            ),
            '/Users/test/project/a.ts',
          ),
          isFalse,
          reason: href,
        );
      }
      // Resolved outside the root.
      expect(
        check(
          const AssistantFileLinkSource(
            href: 'a.ts',
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          '/tmp/a.ts',
        ),
        isFalse,
      );
    });

    test('needs a workspace root', () {
      expect(
        shouldResolveDirectFileThroughSuggestions(
          context: const AssistantFileLinkContext(),
          source: const AssistantFileLinkSource(
            href: 'a.ts',
            sourceType: AssistantFileLinkSourceType.inlineCode,
          ),
          token: 'a.ts',
          target: target('a.ts', '/Users/test/project/a.ts'),
        ),
        isFalse,
      );
    });
  });
}
