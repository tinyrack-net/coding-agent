import 'package:coding_agent_app/terminal/terminal_local_link_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectTerminalLocalLinks', () {
    test('detects VS Code-style filename and line suffixes', () {
      final links = detectTerminalLocalLinks('file.ts:42');
      expect(links, hasLength(1));
      expect(links.single.path.index, 0);
      expect(links.single.path.text, 'file.ts');
      expect(links.single.suffix?.row, 42);
      expect(links.single.suffix?.col, isNull);
      expect(links.single.suffix?.rowEnd, isNull);
    });

    test('detects line and column suffixes', () {
      final link = detectTerminalLocalLinks('src/file.ts:42:7').single;
      expect(
        link.path,
        const TerminalLinkPartialRange(index: 0, text: 'src/file.ts'),
      );
      expect(link.suffix?.row, 42);
      expect(link.suffix?.col, 7);
    });

    test('detects quoted Python traceback paths', () {
      final link = detectTerminalLocalLinks(
        '  File "pkg/file.py", line 12',
      ).single;
      expect(
        link.path,
        const TerminalLinkPartialRange(index: 8, text: 'pkg/file.py'),
      );
      expect(link.suffix?.row, 12);
    });

    test('detects paths without suffixes', () {
      final link = detectTerminalLocalLinks(
        'changed packages/app/src/file.ts',
      ).single;
      expect(
        link.path,
        const TerminalLinkPartialRange(
          index: 8,
          text: 'packages/app/src/file.ts',
        ),
      );
      expect(link.suffix, isNull);
    });

    test('parses range, bracket, and human-readable suffix variants', () {
      var suffix = getTerminalLinkSuffix('src/a.ts:12:3-14.8');
      expect(
        [suffix?.row, suffix?.col, suffix?.rowEnd, suffix?.colEnd],
        [12, 3, 14, 8],
      );
      suffix = getTerminalLinkSuffix('src/a.ts lines 7-9, column 2-4');
      expect(
        [suffix?.row, suffix?.col, suffix?.rowEnd, suffix?.colEnd],
        [7, 2, 9, 4],
      );
      suffix = getTerminalLinkSuffix('src/a.ts (5, 6)');
      expect([suffix?.row, suffix?.col], [5, 6]);
    });

    test('normalizes git diff prefixes and avoids conflicting candidates', () {
      expect(
        detectTerminalLocalLinks('--- a/packages/app/file.dart').single.path,
        const TerminalLinkPartialRange(
          index: 6,
          text: 'packages/app/file.dart',
        ),
      );
      final links = detectTerminalLocalLinks('see src/file.dart:12');
      expect(links, hasLength(1));
      expect(links.single.path.text, 'src/file.dart');
    });

    test('supports Windows, file URI, and git header paths', () {
      expect(
        detectTerminalLocalLinks(
          r'open C:\repo\src\main.dart',
        ).single.path.text,
        r'C:\repo\src\main.dart',
      );
      expect(
        detectTerminalLocalLinks('open file:///tmp/main.dart').single.path.text,
        'file:///tmp/main.dart',
      );
      final diff = detectTerminalLocalLinks(
        'diff --git a/lib/old.dart b/lib/new.dart',
      );
      expect(diff.map((link) => link.path.text), [
        'lib/old.dart',
        'lib/new.dart',
      ]);
    });

    test('handles quoted prefixes, nested brackets, and empty input', () {
      expect(getTerminalLinkSuffix('not a suffix'), isNull);
      expect(detectTerminalLocalLinks(''), isEmpty);
      expect(detectTerminalLocalLinks("'' :12"), isEmpty);

      final quoted = detectTerminalLocalLinks(
        '''trace ""pkg/file.py", line 12''',
      );
      expect(quoted.first.path.text, 'pkg/file.py');
      expect(quoted.first.prefix?.text, '"');

      final nested = detectTerminalLocalLinks('(src/file.dart:9');
      expect(nested.map((link) => link.path.text), contains('src/file.dart'));
    });

    test('recognizes non-breaking-space suffix separators', () {
      final suffix = getTerminalLinkSuffix(
        'src/file.dart\u00a0on\u00a0line\u00a03',
      );
      expect(suffix?.row, 3);
    });
  });
}
