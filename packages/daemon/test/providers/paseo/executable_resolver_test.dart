import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/executable_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('executable-resolver-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('find searches PATH and PATHEXT in order on Windows', () async {
    final first = Directory(p.join(temp.path, 'first'))..createSync();
    final second = Directory(p.join(temp.path, 'second'))..createSync();
    final executable = File(p.join(second.path, 'codex.EXE'))
      ..writeAsStringSync('fake');
    final probed = <String>[];
    final resolver = ExecutableResolver(
      environment: {
        'PATH': '${first.path};${second.path}',
        'PATHEXT': '.CMD;.EXE',
      },
      isWindows: true,
      probe: (path) async {
        probed.add(path);
        return File(path).existsSync();
      },
    );

    expect(await resolver.find('codex'), executable.path);
    expect(probed.last, executable.path);
  });

  test(
    'find supports literal paths, empty commands, and Path casing',
    () async {
      final literal = File(p.join(temp.path, 'literal.exe'))
        ..writeAsStringSync('x');
      final executable = File(p.join(temp.path, 'tool.EXE'))
        ..writeAsStringSync('x');
      final resolver = ExecutableResolver(
        environment: {'Path': temp.path, 'PATHEXT': '.EXE'},
        isWindows: true,
        probe: (path) async => File(path).existsSync(),
      );

      expect(await resolver.find(literal.path), literal.path);
      expect(await resolver.find(' tool '), executable.path);
      expect(await resolver.find('   '), isNull);
      expect(await resolver.find('missing'), isNull);
    },
  );

  test('POSIX resolution probes literal and PATH candidates', () async {
    const executable = '/opt/bin/claude';
    final probes = <String>[];
    final resolver = ExecutableResolver(
      environment: const {'PATH': '/missing:/opt/bin'},
      isWindows: false,
      exists: (path) => path == executable,
      probe: (path) async {
        probes.add(path);
        return path == executable;
      },
    );

    expect(await resolver.find(executable), executable);
    expect(await resolver.find('claude'), executable);
    expect(probes, [executable, executable]);
  });

  test(
    'Windows literal resolution probes only existing .exe/.cmd candidates',
    () async {
      final literal = p.join(temp.path, 'codex');
      final command = File('$literal.cmd')..writeAsStringSync('@echo off\r\n');
      final probes = <String>[];
      final resolver = ExecutableResolver(
        environment: const {},
        isWindows: true,
        probe: (path) async {
          probes.add(path);
          return true;
        },
      );

      expect(await resolver.find(literal), command.path);
      expect(probes, [command.path]);

      probes.clear();
      expect(await resolver.find(p.join(temp.path, 'missing')), isNull);
      expect(probes, isEmpty);
    },
  );

  test('Windows skips a broken .exe and returns the later .cmd', () async {
    final executable = File(p.join(temp.path, 'tool.exe'))
      ..writeAsStringSync('');
    final command = File(p.join(temp.path, 'tool.cmd'))
      ..writeAsStringSync('@echo off\r\n');
    final resolver = ExecutableResolver(
      environment: {'PATH': temp.path, 'PATHEXT': '.EXE;.CMD'},
      isWindows: true,
      probe: (path) async => path.toLowerCase() == command.path.toLowerCase(),
    );

    expect(
      (await resolver.find('tool'))?.toLowerCase(),
      command.path.toLowerCase(),
    );
    expect(executable.existsSync(), isTrue);
  });

  test(
    'Windows finds generic WinGet portable executables outside PATH',
    () async {
      final package = Directory(
        p.join(
          temp.path,
          'Microsoft',
          'WinGet',
          'Packages',
          'Anthropic.ClaudeCode_abc',
        ),
      )..createSync(recursive: true);
      final executable = File(p.join(package.path, 'claude.exe'))
        ..writeAsStringSync('fake');
      final resolver = ExecutableResolver(
        environment: {
          'PATH': p.join(temp.path, 'empty'),
          'LOCALAPPDATA': temp.path,
        },
        isWindows: true,
        probe: (path) async => path == executable.path,
      );

      expect(await resolver.find('claude'), executable.path);
    },
  );

  test(
    'findCodex prefers PATH then uses Microsoft Store package fallback',
    () async {
      final pathDir = Directory(p.join(temp.path, 'path'))..createSync();
      final pathCodex = File(p.join(pathDir.path, 'codex.EXE'))
        ..writeAsStringSync('path');
      final fromPath = ExecutableResolver(
        environment: {'PATH': pathDir.path, 'PATHEXT': '.EXE'},
        isWindows: true,
        probe: (path) async => File(path).existsSync(),
      );
      expect(await fromPath.findCodex(), pathCodex.path);

      pathCodex.deleteSync();
      final storeCodex = File(
        p.join(
          temp.path,
          'Packages',
          'OpenAI.Codex_abc',
          'LocalCache',
          'Local',
          'OpenAI',
          'Codex',
          'bin',
          'codex.exe',
        ),
      )..createSync(recursive: true);
      final fallback = ExecutableResolver(
        environment: {
          'PATH': pathDir.path,
          'PATHEXT': '.EXE',
          'LOCALAPPDATA': temp.path,
        },
        isWindows: true,
        probe: (path) async => File(path).existsSync(),
      );

      expect(await fallback.findCodex(), storeCodex.path);
    },
  );

  test(
    'findCodex handles absent roots, non-Windows, and bad packages',
    () async {
      final missing = ExecutableResolver(
        environment: {'PATH': temp.path},
        isWindows: true,
        probe: (_) async => false,
      );
      expect(await missing.findCodex(), isNull);

      final packages = Directory(p.join(temp.path, 'Packages'))..createSync();
      Directory(p.join(packages.path, 'Other.Package')).createSync();
      expect(await missing.findCodex(), isNull);

      final posix = ExecutableResolver(
        environment: {'PATH': temp.path},
        isWindows: false,
        probe: (_) async => false,
      );
      expect(await posix.findCodex(), isNull);
    },
  );

  test('executableExists preserves frozen Windows literal extensions', () {
    final command = p.join(temp.path, 'codex');
    final executable = File('$command.cmd')..writeAsStringSync('x');

    expect(executableExists(command, isWindows: true), executable.path);
    expect(
      executableExists(
        command,
        isWindows: true,
        exists: (path) => path == '$command.ps1',
      ),
      isNull,
    );
    expect(
      executableExists(
        '/usr/local/bin/codex',
        isWindows: false,
        exists: (path) => path == '/usr/local/bin/codex',
      ),
      '/usr/local/bin/codex',
    );
  });

  test(
    'default platform dependencies resolve the running Dart executable',
    () async {
      final resolver = ExecutableResolver();

      expect(resolver.exists(Platform.resolvedExecutable), isNotNull);
      expect(await resolver.find(Platform.resolvedExecutable), isNotNull);
      expect(executableExists(Platform.resolvedExecutable), isNotNull);
    },
  );

  test(
    'probeExecutable accepts a real binary and rejects a missing one',
    () async {
      expect(await probeExecutable(Platform.resolvedExecutable), isTrue);
      expect(
        await probeExecutable(p.join(temp.path, 'definitely-missing')),
        isFalse,
      );
    },
  );

  test(
    'probeExecutable accepts a started non-zero command and rejects a directory',
    () async {
      final command = File(p.join(temp.path, 'non-zero.cmd'))
        ..writeAsStringSync('@echo off\r\nexit /b 7\r\n');
      final directory = Directory(p.join(temp.path, 'directory'))..createSync();

      expect(await probeExecutable(command.path), isTrue);
      expect(await probeExecutable(directory.path), isFalse);
    },
  );

  group('Windows command quoting', () {
    test('quotes paths and arguments with spaces exactly once', () {
      expect(
        quoteWindowsCommand(
          r'C:\Program Files\Anthropic\claude.exe',
          isWindows: true,
        ),
        r'"C:\Program Files\Anthropic\claude.exe"',
      );
      expect(
        quoteWindowsArgument(
          r'"C:\Program Files\Anthropic\cli.js"',
          isWindows: true,
        ),
        r'"C:\Program Files\Anthropic\cli.js"',
      );
      expect(
        quoteWindowsCommand(r'C:\nvm4w\nodejs\codex', isWindows: true),
        r'C:\nvm4w\nodejs\codex',
      );
    });

    test('escapes cmd metacharacters without corrupting percent atoms', () {
      expect(
        quoteWindowsCommand('feature&bugfix', isWindows: true),
        'feature^&bugfix',
      );
      expect(
        quoteWindowsCommand('feature|bugfix', isWindows: true),
        'feature^|bugfix',
      );
      expect(quoteWindowsCommand('100%', isWindows: true), '100%');
      expect(
        quoteWindowsCommand(
          '--format=%(refname)%09%(committerdate:unix)',
          isWindows: true,
        ),
        '--format=%^(refname^)%09%^(committerdate:unix^)',
      );
      expect(
        quoteWindowsCommand('build&(test|deploy)!<output>', isWindows: true),
        'build^&^(test^|deploy^)^!^<output^>',
      );
    });

    test('quotes after escaping and leaves non-Windows values unchanged', () {
      expect(
        quoteWindowsCommand(
          r'C:\Program Files\My Tool&Stuff\run 100%.cmd',
          isWindows: true,
        ),
        r'"C:\Program Files\My Tool^&Stuff\run 100%.cmd"',
      );
      expect(
        quoteWindowsArgument('/usr/local/bin/claude code', isWindows: false),
        '/usr/local/bin/claude code',
      );
    });

    test('applies Windows quote and backslash escaping rules', () {
      expect(quoteWindowsArgument('"', isWindows: true), '""');
      expect(
        quoteWindowsArgument('say "hello"', isWindows: true),
        r'"say \"hello\""',
      );
      expect(
        quoteWindowsArgument('C:\\Program Files\\', isWindows: true),
        '"C:\\Program Files\\\\"',
      );
      expect(
        quoteWindowsArgument('C:\\path\\\\"name"', isWindows: true),
        r'"C:\path\\\\\"name\""',
      );
      expect(
        quoteWindowsArgument('C:\\path\\file', isWindows: true),
        r'C:\path\file',
      );
    });
  });
}
