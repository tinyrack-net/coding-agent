import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef ExecutableProbe = Future<bool> Function(String path);

final class ExecutableResolver {
  ExecutableResolver({
    Map<String, String>? environment,
    bool? isWindows,
    ExecutableProbe? probe,
  }) : environment = environment ?? Platform.environment,
       isWindows = isWindows ?? Platform.isWindows,
       _probe = probe ?? probeExecutable;

  final Map<String, String> environment;
  final bool isWindows;
  final ExecutableProbe _probe;

  Future<String?> find(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;
    if (_hasSeparator(trimmed) || p.isAbsolute(trimmed)) {
      return await _probe(trimmed) ? trimmed : null;
    }
    for (final directory in _pathEntries()) {
      for (final name in _candidateNames(trimmed)) {
        final candidate = p.join(directory, name);
        if (await _probe(candidate)) return candidate;
      }
    }
    return null;
  }

  Future<String?> findCodex() async {
    final fromPath = await find('codex');
    if (fromPath != null || !isWindows) return fromPath;
    final localAppData = environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return null;
    final packages = Directory(p.join(localAppData, 'Packages'));
    if (!packages.existsSync()) return null;
    final entries =
        packages
            .listSync()
            .whereType<Directory>()
            .where(
              (entry) => p.basename(entry.path).startsWith('OpenAI.Codex_'),
            )
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    for (final entry in entries) {
      final candidate = p.join(
        entry.path,
        'LocalCache',
        'Local',
        'OpenAI',
        'Codex',
        'bin',
        'codex.exe',
      );
      if (await _probe(candidate)) return candidate;
    }
    return null;
  }

  Iterable<String> _pathEntries() sync* {
    final value = environment['PATH'] ?? environment['Path'] ?? '';
    for (final entry in value.split(isWindows ? ';' : ':')) {
      final trimmed = entry.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  Iterable<String> _candidateNames(String command) sync* {
    if (!isWindows || p.extension(command).isNotEmpty) {
      yield command;
      return;
    }
    final pathExt = environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD';
    for (final extension in pathExt.split(';')) {
      final normalized = extension.trim();
      if (normalized.isNotEmpty) yield '$command$normalized';
    }
  }

  bool _hasSeparator(String value) =>
      value.contains('/') || value.contains(r'\');
}

Future<bool> probeExecutable(String executablePath) async {
  Process? process;
  try {
    process = await Process.start(
      executablePath,
      const ['--version'],
      runInShell:
          Platform.isWindows &&
          const {
            '.cmd',
            '.bat',
          }.contains(p.extension(executablePath).toLowerCase()),
    );
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        process?.kill();
        return 0;
      },
    );
    return exitCode >= 0;
  } on ProcessException {
    return false;
  } on FileSystemException {
    return false;
  }
}
