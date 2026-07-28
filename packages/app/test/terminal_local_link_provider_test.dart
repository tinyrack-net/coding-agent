import 'dart:async';

import 'package:coding_agent_app/terminal/terminal_local_link_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalLocalFileLinkProvider', () {
    test('resolves before exposing a local file link', () async {
      final terminal = _terminalWith('file.ts:42');
      TerminalLocalFileLinkSource? resolvedSource;
      final provider = TerminalLocalFileLinkProvider(
        terminal,
        resolveLink: (source) async {
          resolvedSource = source;
          return const TerminalLocalFileLinkTarget(
            path: '/repo/src/file.ts',
            lineStart: 42,
          );
        },
      );

      final links = await provider.provideLinks(1);

      expect(resolvedSource?.text, 'file.ts:42');
      expect(resolvedSource?.path, 'file.ts');
      expect(resolvedSource?.lineStart, 42);
      expect(links, hasLength(1));
      expect(links.single.source.text, 'file.ts:42');
    });

    test('decorates the full parsed link span', () async {
      final provider = TerminalLocalFileLinkProvider(
        _terminalWith('echo README.md:5'),
        resolveLink: (_) async =>
            const TerminalLocalFileLinkTarget(path: '/repo/README.md'),
      );

      final link = (await provider.provideLinks(1)).single;

      expect(link.range.start.x, 6);
      expect(link.range.start.y, 1);
      expect(link.range.end.x, 16);
      expect(link.range.end.y, 1);
      expect(link.range.containsCell(x: 5, y: 0), isTrue);
      expect(link.range.containsCell(x: 16, y: 0), isFalse);
    });

    test('does not expose unresolved candidates', () async {
      final provider = TerminalLocalFileLinkProvider(
        _terminalWith('missing.ts:42'),
        resolveLink: (_) async => null,
      );
      expect(await provider.provideLinks(1), isEmpty);
    });

    test('coalesces concurrent line resolutions', () async {
      final completer = Completer<TerminalLocalFileLinkTarget?>();
      var resolutions = 0;
      final provider = TerminalLocalFileLinkProvider(
        _terminalWith('src/file.ts:42'),
        resolveLink: (_) {
          resolutions += 1;
          return completer.future;
        },
      );
      final first = provider.provideLinks(1);
      final second = provider.provideLinks(1);
      completer.complete(
        const TerminalLocalFileLinkTarget(path: '/repo/src/file.ts'),
      );
      expect(await first, hasLength(1));
      expect(await second, hasLength(1));
      expect(resolutions, 1);
    });

    test('finds the resolved link at a tapped cell', () async {
      final provider = TerminalLocalFileLinkProvider(
        _terminalWith('echo src/file.ts:4'),
        resolveLink: (_) async =>
            const TerminalLocalFileLinkTarget(path: '/repo/src/file.ts'),
      );
      expect(
        (await provider.linkAtCell(x: 8, y: 0))?.target.path,
        '/repo/src/file.ts',
      );
      expect(await provider.linkAtCell(x: 0, y: 0), isNull);
    });

    test('rejects punctuation-tailed and oversized candidates', () async {
      var resolutions = 0;
      final punctuation = TerminalLocalFileLinkProvider(
        _terminalWith('open src/file.dart.'),
        resolveLink: (_) async {
          resolutions++;
          return const TerminalLocalFileLinkTarget(path: '/repo/src/file.dart');
        },
      );
      expect(await punctuation.provideLinks(1), isEmpty);
      expect(resolutions, 0);

      final oversized = TerminalLocalFileLinkProvider(
        _terminalWith(
          '${List.filled(terminalLocalLinkMaxLineLength + 1, 'x').join()}/file.dart',
        ),
        resolveLink: (_) async {
          resolutions++;
          return const TerminalLocalFileLinkTarget(path: '/never');
        },
      );
      expect(await oversized.provideLinks(1), isEmpty);
      expect(await oversized.provideLinks(999), isEmpty);
      expect(resolutions, 0);
    });

    test('normalizes valid line ranges and discards reversed ranges', () async {
      final sources = <TerminalLocalFileLinkSource>[];
      final terminal = Terminal();
      terminal
        ..write('src/a.dart:4:2-8.7')
        ..write('\r\n')
        ..write('src/b.dart lines 9-3');
      final provider = TerminalLocalFileLinkProvider(
        terminal,
        resolveLink: (source) async {
          sources.add(source);
          return TerminalLocalFileLinkTarget(
            path: '/repo/${source.path}',
            lineStart: source.lineStart,
            lineEnd: source.lineEnd,
          );
        },
      );

      expect(
        (await provider.provideLinks(1)).single.source.text,
        'src/a.dart:4:2-8:7',
      );
      expect(sources.first.lineEnd, 8);
      expect((await provider.provideLinks(2)).single.source.lineEnd, isNull);
    });

    test('limits resolved links per line', () async {
      final text = List.generate(12, (index) => 'd$index/f.dart').join(' ');
      var resolutions = 0;
      final provider = TerminalLocalFileLinkProvider(
        _terminalWith(text),
        resolveLink: (source) async {
          resolutions++;
          return TerminalLocalFileLinkTarget(path: '/repo/${source.path}');
        },
      );
      expect(
        await provider.provideLinks(1),
        hasLength(terminalLocalLinkMaxResolvedPerLine),
      );
      expect(resolutions, terminalLocalLinkMaxResolvedPerLine);
    });
  });
}

Terminal _terminalWith(String text) {
  final terminal = Terminal();
  terminal.write(text);
  return terminal;
}
