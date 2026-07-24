import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/unified_diff_parser.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _git(List<String> args, String cwd, {bool check = true}) async {
  final result = await Process.run(
    'git',
    ['-c', 'core.quotepath=false', ...args],
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (check && result.exitCode != 0) {
    throw StateError('git $args failed (${result.exitCode}): ${result.stderr}');
  }
  return result.stdout as String;
}

Future<void> _commit(String cwd, String message) => _git(
      [
        '-c', 'user.email=test@example.com',
        '-c', 'user.name=Test',
        '-c', 'commit.gpgsign=false',
        'commit', '-m', message,
      ],
      cwd,
    );

void main() {
  late Directory tempDir;
  late String repo;
  late String capturedDiff;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('diff_parser_test_');
    repo = tempDir.resolveSymbolicLinksSync();
    await _git(['init', '-b', 'main'], repo);

    // Baseline commit.
    File(p.join(repo, 'modified.txt')).writeAsStringSync(
      List.generate(40, (i) => 'line ${i + 1}').join('\n') + '\n',
    );
    File(p.join(repo, 'deleted.txt')).writeAsStringSync('doomed 1\ndoomed 2\n');
    File(p.join(repo, 'renamed_old.txt')).writeAsStringSync(
      List.generate(10, (i) => 'stable ${i + 1}').join('\n') + '\n',
    );
    File(p.join(repo, 'no_newline.txt')).writeAsStringSync('alpha\nbeta');
    File(p.join(repo, 'binary.bin'))
        .writeAsBytesSync([0, 1, 2, 3, 0, 255, 254]);
    await _git(['add', '-A'], repo);
    await _commit(repo, 'baseline');

    // Second commit: modify (2 hunks), delete, rename, add, no-newline
    // change, binary change.
    final lines = List.generate(40, (i) => 'line ${i + 1}');
    lines[1] = 'line 2 CHANGED';
    lines.insert(38, 'inserted near bottom');
    File(p.join(repo, 'modified.txt'))
        .writeAsStringSync(lines.join('\n') + '\n');
    File(p.join(repo, 'deleted.txt')).deleteSync();
    await _git(['mv', 'renamed_old.txt', 'renamed_new.txt'], repo);
    File(p.join(repo, 'added.txt')).writeAsStringSync('fresh 1\nfresh 2\n');
    File(p.join(repo, 'no_newline.txt')).writeAsStringSync('alpha\ngamma');
    File(p.join(repo, 'binary.bin'))
        .writeAsBytesSync([9, 8, 0, 7, 6, 0, 250]);
    await _git(['add', '-A'], repo);
    await _commit(repo, 'changes');

    capturedDiff =
        await _git(['diff', '-M', '--no-color', 'HEAD~1', 'HEAD'], repo);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DiffFile fileFor(List<DiffFile> files, String path) =>
      files.firstWhere((f) => f.path == path,
          orElse: () => throw StateError(
              '$path not in ${files.map((f) => f.path).toList()}'));

  test('parses all files from a real multi-file git diff', () {
    final files = parseUnifiedDiff(capturedDiff);
    expect(files, hasLength(6));
    expect(
      files.map((f) => f.path).toSet(),
      {
        'modified.txt',
        'deleted.txt',
        'renamed_new.txt',
        'added.txt',
        'no_newline.txt',
        'binary.bin',
      },
    );
  });

  test('modified file: two hunks with correct line numbers and counts', () {
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'modified.txt');
    expect(file.status, DiffFileStatus.modified);
    expect(file.binary, isFalse);
    expect(file.hunks, hasLength(2));
    expect(file.additions, 2);
    expect(file.deletions, 1);

    // Hunk 1: line 2 changed.
    final h1 = file.hunks[0];
    final del = h1.lines.firstWhere((l) => l.type == DiffLineType.del);
    expect(del.text, 'line 2');
    expect(del.oldLineNo, 2);
    expect(del.newLineNo, isNull);
    final add = h1.lines.firstWhere((l) => l.type == DiffLineType.add);
    expect(add.text, 'line 2 CHANGED');
    expect(add.newLineNo, 2);
    expect(add.oldLineNo, isNull);
    final ctx = h1.lines.firstWhere((l) => l.type == DiffLineType.context);
    expect(ctx.oldLineNo, isNotNull);
    expect(ctx.newLineNo, isNotNull);

    // Hunk 2: insertion near the bottom.
    final h2 = file.hunks[1];
    expect(h2.header, startsWith('@@ '));
    final add2 = h2.lines.firstWhere((l) => l.type == DiffLineType.add);
    expect(add2.text, 'inserted near bottom');
    expect(add2.newLineNo, 39);
    // Context after the insertion is offset by one.
    final after = h2.lines
        .where((l) => l.type == DiffLineType.context && l.text == 'line 39')
        .single;
    expect(after.oldLineNo, 39);
    expect(after.newLineNo, 40);
  });

  test('deleted file', () {
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'deleted.txt');
    expect(file.status, DiffFileStatus.deleted);
    expect(file.additions, 0);
    expect(file.deletions, 2);
    expect(file.hunks, hasLength(1));
    expect(
      file.hunks[0].lines.map((l) => l.text).toList(),
      ['doomed 1', 'doomed 2'],
    );
    expect(file.hunks[0].lines.every((l) => l.type == DiffLineType.del), isTrue);
    expect(file.hunks[0].lines[0].oldLineNo, 1);
    expect(file.hunks[0].lines[1].oldLineNo, 2);
  });

  test('added file with all-add hunk', () {
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'added.txt');
    expect(file.status, DiffFileStatus.added);
    expect(file.additions, 2);
    expect(file.deletions, 0);
    expect(file.hunks[0].lines[0].newLineNo, 1);
    expect(file.hunks[0].lines[1].newLineNo, 2);
    expect(file.hunks[0].lines[1].text, 'fresh 2');
  });

  test('rename detection from diff headers', () {
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'renamed_new.txt');
    expect(file.status, DiffFileStatus.renamed);
    expect(file.oldPath, 'renamed_old.txt');
    // Pure rename: no content change.
    expect(file.additions, 0);
    expect(file.deletions, 0);
    expect(file.hunks, isEmpty);
  });

  test('no-newline-at-eof markers are skipped cleanly', () {
    expect(capturedDiff, contains('\\ No newline at end of file'));
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'no_newline.txt');
    expect(file.status, DiffFileStatus.modified);
    expect(file.additions, 1);
    expect(file.deletions, 1);
    for (final hunk in file.hunks) {
      for (final line in hunk.lines) {
        expect(line.text, isNot(contains('No newline')));
      }
    }
    final add = file.hunks[0].lines.firstWhere((l) => l.type == DiffLineType.add);
    expect(add.text, 'gamma');
    expect(add.newLineNo, 2);
  });

  test('binary file marker', () {
    final file = fileFor(parseUnifiedDiff(capturedDiff), 'binary.bin');
    expect(file.binary, isTrue);
    expect(file.status, DiffFileStatus.modified);
    expect(file.hunks, isEmpty);
  });

  test('empty input yields no files', () {
    expect(parseUnifiedDiff(''), isEmpty);
  });

  test('hunk header without counts (single-line file)', () {
    const diff = '''
diff --git a/one.txt b/one.txt
index 5626abf..f719efd 100644
--- a/one.txt
+++ b/one.txt
@@ -1 +1 @@
-one
+two
''';
    final files = parseUnifiedDiff(diff);
    expect(files, hasLength(1));
    final file = files[0];
    expect(file.additions, 1);
    expect(file.deletions, 1);
    expect(file.hunks[0].lines[0].oldLineNo, 1);
    expect(file.hunks[0].lines[1].newLineNo, 1);
  });
}
