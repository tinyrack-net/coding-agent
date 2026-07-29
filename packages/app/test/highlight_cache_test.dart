import 'package:coding_agent_app/core/highlight_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts normalized extensions from Unix and Windows paths', () {
    expect(extensionFromPath('/tmp/example.TS'), 'ts');
    expect(extensionFromPath(r'C:\repo\lib\main.DART'), 'dart');
    expect(extensionFromPath('.gitignore'), isNull);
    expect(extensionFromPath('/tmp/name.'), isNull);
    expect(extensionFromPath(null), isNull);
  });

  test('supports exactly Paseo highlighter extensions', () {
    expect(isHighlightLanguageSupported('tsx'), isTrue);
    expect(isHighlightLanguageSupported('mdx'), isTrue);
    expect(isHighlightLanguageSupported('sh'), isFalse);
    expect(tokenizeToLines('echo hi', 'sh'), isNull);
  });

  test('tokenizes whole documents and preserves multiline parser state', () {
    final lines = tokenizeToLines(
      'const first = 1;\n/* across\nlines */\nconst second = 2;',
      'ts',
    );

    expect(lines, hasLength(4));
    expect(lines![0].where((token) => token.style == 'keyword'), isNotEmpty);
    expect(lines[1].where((token) => token.style == 'comment'), isNotEmpty);
    expect(lines[2].where((token) => token.style == 'comment'), isNotEmpty);
    expect(
      lines.map((line) => line.map((token) => token.text).join()).toList(),
      ['const first = 1;', '/* across', 'lines */', 'const second = 2;'],
    );
  });

  test('caches tokenization and applies the size cap', () {
    final first = tokenizeToLines('const cached = true;', 'ts');
    final second = tokenizeToLines('const cached = true;', 'ts');
    expect(identical(first, second), isTrue);
    expect(tokenizeToLines('x' * (maxHighlightChars + 1), 'ts'), isNull);
  });

  test('creates stable line and token keys', () {
    final lines = highlightToKeyedLines('const value = 1;', 'ts');
    expect(lines, isNotNull);
    expect(lines!.single.key, 'line-0');
    expect(lines.single.tokens.first.key, '0-0');
  });
}
