import 'dart:io';

import 'package:agent_daemon/src/providers/native/tools/tool_executor.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ToolExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tool_executor_test_');
    executor = ToolExecutor(cwd: tempDir.path);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('read_file', () {
    test('reads an existing file', () async {
      File('${tempDir.path}/a.txt').writeAsStringSync('hello world');
      final result = await executor.execute('read_file', {'path': 'a.txt'});
      expect(result.isError, isFalse);
      expect(result.content, 'hello world');
      expect(result.detail, isA<ReadDetail>());
      expect((result.detail as ReadDetail).path, 'a.txt');
    });

    test('errors on a missing file', () async {
      final result = await executor.execute('read_file', {'path': 'nope.txt'});
      expect(result.isError, isTrue);
      expect(result.content, contains('not found'));
    });

    test('rejects path traversal outside the working directory', () async {
      final result =
          await executor.execute('read_file', {'path': '../outside.txt'});
      expect(result.isError, isTrue);
      expect(result.content, contains('escapes the working directory'));
    });

    test('errors when path is missing', () async {
      final result = await executor.execute('read_file', {});
      expect(result.isError, isTrue);
      expect(result.content, contains('"path" is required'));
    });
  });

  group('write_file', () {
    test('creates a new file with the given content', () async {
      final result = await executor.execute(
        'write_file',
        {'path': 'new.txt', 'content': 'created content'},
      );
      expect(result.isError, isFalse);
      expect(File('${tempDir.path}/new.txt').readAsStringSync(), 'created content');
      expect(result.detail, isA<WriteDetail>());
    });

    test('creates parent directories as needed', () async {
      final result = await executor.execute(
        'write_file',
        {'path': 'nested/dir/file.txt', 'content': 'x'},
      );
      expect(result.isError, isFalse);
      expect(File('${tempDir.path}/nested/dir/file.txt').existsSync(), isTrue);
    });

    test('rejects path traversal outside the working directory', () async {
      final result = await executor.execute(
        'write_file',
        {'path': '../escape.txt', 'content': 'x'},
      );
      expect(result.isError, isTrue);
      expect(
        File('${tempDir.parent.path}/escape.txt').existsSync(),
        isFalse,
      );
    });
  });

  group('edit_file', () {
    test('replaces a unique substring', () async {
      File('${tempDir.path}/e.txt').writeAsStringSync('foo bar baz');
      final result = await executor.execute('edit_file', {
        'path': 'e.txt',
        'old_string': 'bar',
        'new_string': 'qux',
      });
      expect(result.isError, isFalse);
      expect(File('${tempDir.path}/e.txt').readAsStringSync(), 'foo qux baz');
      expect((result.detail as EditDetail).diff, contains('-bar'));
      expect((result.detail as EditDetail).diff, contains('+qux'));
    });

    test('errors when old_string is not found', () async {
      File('${tempDir.path}/e.txt').writeAsStringSync('foo bar baz');
      final result = await executor.execute('edit_file', {
        'path': 'e.txt',
        'old_string': 'nope',
        'new_string': 'qux',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('not found'));
    });

    test('errors when old_string is not unique', () async {
      File('${tempDir.path}/e.txt').writeAsStringSync('foo foo foo');
      final result = await executor.execute('edit_file', {
        'path': 'e.txt',
        'old_string': 'foo',
        'new_string': 'qux',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('not unique'));
    });
  });

  group('bash', () {
    test('runs a command and captures stdout/exit code', () async {
      final result = await executor.execute('bash', {
        'command': Platform.isWindows ? 'echo hello' : 'echo hello',
      });
      expect(result.content, contains('hello'));
      expect((result.detail as ShellDetail).exitCode, 0);
      expect(result.isError, isFalse);
    });

    test('reports a non-zero exit code as an error', () async {
      final command = Platform.isWindows ? 'exit 3' : 'exit 3';
      final result = await executor.execute('bash', {'command': command});
      expect((result.detail as ShellDetail).exitCode, 3);
      expect(result.isError, isTrue);
    });
  });

  group('grep', () {
    test('finds matching lines with file:line prefixes', () async {
      File('${tempDir.path}/x.txt').writeAsStringSync('alpha\nneedle here\nbeta');
      final result = await executor.execute('grep', {'pattern': 'needle'});
      expect(result.isError, isFalse);
      expect(result.content, contains('x.txt:2'));
      expect(result.detail, isA<SearchDetail>());
    });

    test('returns "no matches" when nothing matches', () async {
      File('${tempDir.path}/x.txt').writeAsStringSync('alpha beta');
      final result = await executor.execute('grep', {'pattern': 'zzz'});
      expect(result.content, 'no matches');
    });

    test('errors on an invalid regular expression', () async {
      final result = await executor.execute('grep', {'pattern': '('});
      expect(result.isError, isTrue);
      expect(result.content, contains('invalid regular expression'));
    });
  });

  group('glob', () {
    test('finds files matching a pattern', () async {
      File('${tempDir.path}/a.dart').writeAsStringSync('');
      File('${tempDir.path}/b.txt').writeAsStringSync('');
      final result = await executor.execute('glob', {'pattern': '*.dart'});
      expect(result.content, contains('a.dart'));
      expect(result.content, isNot(contains('b.txt')));
    });
  });

  test('unknown tool name returns an error result', () async {
    final result = await executor.execute('teleport', {});
    expect(result.isError, isTrue);
    expect(result.content, contains('unknown tool'));
    expect(result.detail, isA<GenericDetail>());
  });
}
