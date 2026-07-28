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
}
