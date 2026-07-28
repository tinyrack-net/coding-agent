import 'package:coding_agent_app/composer/file_mention_autocomplete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects mentions at start and in the middle from the cursor', () {
    const startText = '@src/components';
    final start = findActiveFileMention(
      text: startText,
      cursorIndex: startText.length,
    );
    expect(start?.start, 0);
    expect(start?.end, startText.length);
    expect(start?.query, 'src/components');

    const middleText = 'read "@src/com" before merging';
    final cursor = middleText.indexOf('"') + 9;
    final middle = findActiveFileMention(text: middleText, cursorIndex: cursor);
    expect(middle?.start, middleText.indexOf('@'));
    expect(middle?.end, cursor);
    expect(middle?.query, 'src/com');
  });

  test('rejects mentions when the cursor crosses a delimiter', () {
    const text = 'please review @src/components now';
    expect(findActiveFileMention(text: text, cursorIndex: text.length), isNull);
    expect(findActiveFileMention(text: '@ ', cursorIndex: 2), isNull);
    expect(findActiveFileMention(text: '@"x', cursorIndex: 3), isNull);
    expect(findActiveFileMention(text: "@'x", cursorIndex: 3), isNull);
  });

  test('clamps cursor and searches backwards across invalid mentions', () {
    expect(
      findActiveFileMention(text: '@good @bad value', cursorIndex: 99)?.query,
      isNull,
    );
    expect(
      findActiveFileMention(text: '@good @bad value', cursorIndex: 5)?.query,
      'good',
    );
    expect(
      findActiveFileMention(text: '@tail', cursorIndex: -10)?.query,
      isNull,
    );
  });

  test('quotes, escapes, and replaces only the active mention', () {
    expect(
      formatQuotedFileMentionPath('src/changed "file".ts'),
      r'"src/changed \"file\".ts"',
    );
    expect(
      applyFileMentionReplacement(
        text: 'open @src/com next',
        mention: const FileMentionRange(start: 5, end: 13, query: 'src/com'),
        relativePath: 'src/components/chat.tsx',
      ),
      'open "src/components/chat.tsx" next',
    );
    expect(
      applyFileMentionReplacement(
        text: '@foo',
        mention: const FileMentionRange(start: 0, end: 4, query: 'foo'),
        relativePath: 'src/"quoted".ts',
      ),
      r'"src/\"quoted\".ts"',
    );
  });
}
