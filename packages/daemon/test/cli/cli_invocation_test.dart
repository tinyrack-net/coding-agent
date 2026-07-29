import 'dart:io';

import 'package:agent_daemon/src/cli/cli_invocation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const knownCommands = {'ls', 'run', 'status', 'hooks'};

  test('keeps empty, flag, known, and missing invocations in CLI mode', () {
    for (final arguments in <List<String>>[
      [],
      ['--version'],
      ['ls', '--json'],
      ['missing'],
    ]) {
      final invocation = classifyCliInvocation(
        arguments: arguments,
        knownCommands: knownCommands,
        currentDirectory: r'C:\repo',
        directoryExists: (_) => false,
      );
      expect(invocation, isA<CommandCliInvocation>(), reason: '$arguments');
      expect(
        (invocation as CommandCliInvocation).arguments,
        arguments,
        reason: '$arguments',
      );
    }
  });

  test('classifies every frozen directory shape and resolves paths', () {
    final root = Directory.systemTemp.createTempSync('cli-invocation-');
    addTearDown(() => root.deleteSync(recursive: true));
    final child = Directory(p.join(root.path, 'child'))..createSync();
    final project = Directory(p.join(root.path, 'project'))..createSync();

    for (final testCase in <(String, String, String)>[
      ('.', project.path, project.path),
      ('..', child.path, root.path),
      ('./project', root.path, project.path),
      ('project', root.path, project.path),
      (project.path, root.path, project.path),
    ]) {
      final invocation = classifyCliInvocation(
        arguments: [testCase.$1],
        knownCommands: knownCommands,
        currentDirectory: testCase.$2,
      );
      expect(invocation, isA<OpenProjectCliInvocation>());
      expect(
        (invocation as OpenProjectCliInvocation).resolvedPath,
        p.normalize(testCase.$3),
        reason: testCase.$1,
      );
    }
  });

  test('expands home paths and preserves known command precedence', () {
    final home = p.normalize(r'C:\Users\fixture');
    expect(expandUserPath('~', environment: {'USERPROFILE': home}), home);
    expect(
      expandUserPath('~/project', environment: {'USERPROFILE': home}),
      p.join(home, 'project'),
    );
    expect(isPathLikeArgument(r'C:\project'), isTrue);
    expect(isPathLikeArgument('status'), isFalse);

    final invocation = classifyCliInvocation(
      arguments: const ['status'],
      knownCommands: knownCommands,
      currentDirectory: r'C:\repo',
      directoryExists: (_) => true,
    );
    expect(invocation, isA<CommandCliInvocation>());
  });

  test('isExistingDirectory uses the resolved absolute path', () {
    String? checked;
    expect(
      isExistingDirectory(
        pathArgument: 'project',
        currentDirectory: r'C:\repo',
        directoryExists: (path) {
          checked = path;
          return true;
        },
      ),
      isTrue,
    );
    expect(checked, p.normalize(r'C:\repo\project'));
  });
}
