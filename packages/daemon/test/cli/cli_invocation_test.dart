import 'dart:io';

import 'package:agent_daemon/src/cli/cli_invocation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const knownCommands = {'ls', 'run', 'status', 'hooks', 'help'};

  test('root command catalog matches frozen registration exactly', () {
    expect(codingAgentKnownCommands, {
      'run',
      'import',
      'agent',
      'ls',
      'attach',
      'inspect',
      'logs',
      'stop',
      'send',
      'wait',
      'archive',
      'delete',
      'daemon',
      'start',
      'status',
      'restart',
      'onboard',
      'chat',
      'clone',
      'hub',
      'schedule',
      'heartbeat',
      'loop',
      'permit',
      'script',
      'provider',
      'speech',
      'terminal',
      'workspace',
      'worktree',
      'hooks',
      'help',
    });
  });

  test('keeps empty, flag, known, and missing invocations in CLI mode', () {
    for (final arguments in <List<String>>[
      [],
      ['--version'],
      ['ls', '--json'],
      ['help', 'run'],
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

  test('empty CLI argv defaults to the frozen onboard command', () {
    expect(defaultEmptyCliArguments(const []), const ['onboard']);
    final arguments = <String>['daemon', 'status'];
    expect(defaultEmptyCliArguments(arguments), same(arguments));
  });

  test('normalizes root output options before full-output commands', () {
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--json',
        '--quiet',
        '--no-headers',
        '--no-color',
        'provider',
        'ls',
      ]).forward(),
      const [
        'provider',
        'ls',
        '--format',
        'yaml',
        '--json',
        '--quiet',
        '--no-headers',
        '--no-color',
      ],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        'loop',
        'inspect',
        'loop-1',
      ]).forward(),
      const ['loop', 'inspect', 'loop-1', '--format', 'yaml', '--quiet'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--json',
        '--quiet',
        'loop',
        'logs',
        'loop-1',
      ]).forward(),
      const ['loop', 'logs', 'loop-1'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        'daemon',
        'status',
      ]).forward(),
      const ['daemon', 'status', '--format', 'yaml', '--quiet'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        'status',
      ]).forward(),
      const ['status', '--format', 'yaml', '--quiet'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--json',
        '--quiet',
        'daemon',
        'start',
      ]).forward(),
      const ['daemon', 'start'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--json',
        'daemon',
        'pair',
      ]).forward(),
      const ['daemon', 'pair', '--json'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format=json',
        'workspace',
        'ls',
      ]).forward(),
      const ['workspace', 'ls', '--format', 'json'],
    );
    expect(normalizeRootCliArguments(const ['-oyaml', 'ls']).forward(), const [
      'ls',
      '--format',
      'yaml',
    ]);
  });

  test('preserves command-local options and action output boundaries', () {
    expect(
      normalizeRootCliArguments(const [
        '--json',
        '--no-color',
        '--quiet',
        'terminal',
        'capture',
        'term',
      ]).forward(),
      const ['terminal', 'capture', 'term', '--json', '--no-color'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        '--no-headers',
        'terminal',
        'ls',
      ]).forward(),
      const ['terminal', 'ls', '--format', 'yaml', '--quiet', '--no-headers'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'json',
        'schedule',
        'ls',
      ]).forward(),
      const ['schedule', 'ls', '--format', 'json'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        '--no-headers',
        'schedule',
        'logs',
        'schedule-1',
      ]).forward(),
      const [
        'schedule',
        'logs',
        'schedule-1',
        '--format',
        'yaml',
        '--quiet',
        '--no-headers',
      ],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        'chat',
        'ls',
      ]).forward(),
      const ['chat', 'ls', '--format', 'yaml', '--quiet'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--quiet',
        '--no-headers',
        'hub',
        'status',
      ]).forward(),
      const ['hub', 'status', '--format', 'yaml', '--quiet', '--no-headers'],
    );
    expect(
      normalizeRootCliArguments(const [
        '--format',
        'yaml',
        '--no-headers',
        'heartbeat',
        'delete',
        'heartbeat-1',
      ]).forward(),
      const [
        'heartbeat',
        'delete',
        'heartbeat-1',
        '--format',
        'yaml',
        '--no-headers',
      ],
    );
    expect(
      normalizeRootCliArguments(const [
        '--json',
        'speech',
        'future-command',
      ]).forward(),
      const ['speech', 'future-command'],
    );
    expect(
      normalizeRootCliArguments(const [
        'provider',
        'ls',
        '--format',
        'yaml',
      ]).forward(),
      const ['provider', 'ls', '--format', 'yaml'],
    );
  });

  test('keeps malformed or root-only output invocations deterministic', () {
    final missingFormat = normalizeRootCliArguments(const ['--format']);
    expect(missingFormat.arguments, const ['--format']);
    expect(missingFormat.output.isEmpty, isTrue);

    final rootOnly = normalizeRootCliArguments(const ['--json', '--quiet']);
    expect(rootOnly.arguments, isEmpty);
    expect(rootOnly.output.json, isTrue);
    expect(rootOnly.output.quiet, isTrue);
    expect(rootOnly.forward(), isEmpty);
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
