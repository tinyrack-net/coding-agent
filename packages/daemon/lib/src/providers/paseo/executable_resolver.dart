import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef ExecutableProbe = Future<bool> Function(String path);
typedef ExecutableExists = bool Function(String path);

const executableProbeTimeout = Duration(seconds: 2);

final class ExecutableResolver {
  ExecutableResolver({
    Map<String, String>? environment,
    bool? isWindows,
    ExecutableProbe? probe,
    ExecutableExists? exists,
    this.probeTimeout = executableProbeTimeout,
  }) : environment = environment ?? Platform.environment,
       isWindows = isWindows ?? Platform.isWindows,
       _exists = exists ?? FileSystemEntity.isFileSync,
       _probe =
           probe ?? ((path) => probeExecutable(path, timeout: probeTimeout));

  final Map<String, String> environment;
  final bool isWindows;
  final Duration probeTimeout;
  final ExecutableProbe _probe;
  final ExecutableExists _exists;

  Future<String?> find(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;
    if (isWindows) return _findWindows(trimmed);
    if (_hasSeparator(trimmed)) {
      return await _probe(trimmed) ? trimmed : null;
    }
    for (final candidate in _pathCandidates(trimmed)) {
      if (await _probe(candidate)) return candidate;
    }
    return null;
  }

  Future<String?> findCodex() async {
    final resolved = await find('codex');
    if (resolved != null || !isWindows) return resolved;
    return _findCodexMicrosoftStoreBinary();
  }

  String? exists(String executablePath) =>
      executableExists(executablePath, isWindows: isWindows, exists: _exists);

  Future<String?> _findWindows(String input) async {
    if (_hasSeparator(input)) {
      return _findFirstProbeable(_literalWindowsCandidates(input));
    }
    return _findFirstProbeable([
      ..._pathCandidates(input),
      ..._wingetPackageCandidates(input),
    ]);
  }

  Future<String?> _findFirstProbeable(Iterable<String> candidates) async {
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate) || !_exists(candidate)) continue;
      if (await _probe(candidate)) return candidate;
    }
    return null;
  }

  Iterable<String> _pathCandidates(String command) sync* {
    for (final directory in _pathEntries()) {
      for (final name in _candidateNames(command)) {
        final candidate = isWindows
            ? p.windows.join(directory, name)
            : p.posix.join(directory, name);
        if (_exists(candidate)) yield candidate;
      }
    }
  }

  Iterable<String> _wingetPackageCandidates(String name) sync* {
    final localAppData = _environmentValue('LOCALAPPDATA');
    if (localAppData == null || localAppData.isEmpty) return;
    final packages = Directory(
      p.windows.join(localAppData, 'Microsoft', 'WinGet', 'Packages'),
    );
    List<FileSystemEntity> entries;
    try {
      entries = packages.listSync();
    } on FileSystemException {
      return;
    }
    for (final entry in entries.whereType<Directory>()) {
      final candidate = p.windows.join(entry.path, '$name.exe');
      if (_exists(candidate)) yield candidate;
    }
  }

  Future<String?> _findCodexMicrosoftStoreBinary() async {
    final localAppData = _environmentValue('LOCALAPPDATA');
    if (localAppData == null || localAppData.isEmpty) return null;
    final packages = Directory(p.windows.join(localAppData, 'Packages'));
    if (!packages.existsSync()) return null;
    final entries =
        packages
            .listSync()
            .whereType<Directory>()
            .where(
              (entry) =>
                  p.windows.basename(entry.path).startsWith('OpenAI.Codex_'),
            )
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    for (final entry in entries) {
      final candidate = p.windows.join(
        entry.path,
        'LocalCache',
        'Local',
        'OpenAI',
        'Codex',
        'bin',
        'codex.exe',
      );
      if (_exists(candidate) && await _probe(candidate)) return candidate;
    }
    return null;
  }

  Iterable<String> _pathEntries() sync* {
    final value = _environmentValue('PATH') ?? '';
    for (final entry in value.split(isWindows ? ';' : ':')) {
      final trimmed = entry.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  Iterable<String> _candidateNames(String command) sync* {
    final extension = isWindows
        ? p.windows.extension(command)
        : p.posix.extension(command);
    if (!isWindows || extension.isNotEmpty) {
      yield command;
      return;
    }
    final pathExt = _environmentValue('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD';
    for (final extension in pathExt.split(';')) {
      final normalized = extension.trim();
      if (normalized.isNotEmpty) yield '$command$normalized';
    }
  }

  String? _environmentValue(String name) {
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  bool _hasSeparator(String value) =>
      value.contains('/') || value.contains(r'\');
}

String? executableExists(
  String executablePath, {
  bool? isWindows,
  ExecutableExists? exists,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final fileExists = exists ?? FileSystemEntity.isFileSync;
  for (final candidate
      in windows
          ? _literalWindowsCandidates(executablePath)
          : [executablePath]) {
    if (fileExists(candidate)) return candidate;
  }
  return null;
}

Iterable<String> _literalWindowsCandidates(String executablePath) sync* {
  if (p.windows.extension(executablePath).isNotEmpty) {
    yield executablePath;
    return;
  }
  yield executablePath;
  yield '$executablePath.exe';
  yield '$executablePath.cmd';
}

Future<bool> probeExecutable(
  String executablePath, {
  Duration timeout = executableProbeTimeout,
}) async {
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
    process.stdout.listen((_) {});
    process.stderr.listen((_) {});
    await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process?.kill();
        return 0;
      },
    );
    return true;
  } on ProcessException {
    return false;
  } on FileSystemException {
    return false;
  }
}

String quoteWindowsCommand(String command, {bool? isWindows}) =>
    _escapeWindowsCmdValue(command, isWindows: isWindows ?? Platform.isWindows);

String quoteWindowsArgument(String argument, {bool? isWindows}) =>
    _escapeWindowsCmdValue(
      argument,
      isWindows: isWindows ?? Platform.isWindows,
    );

String _escapeWindowsCmdValue(String value, {required bool isWindows}) {
  if (!isWindows) return value;
  final isQuoted = value.startsWith('"') && value.endsWith('"');
  final unquoted = isQuoted
      ? (value.length == 1 ? '' : value.substring(1, value.length - 1))
      : value;
  final escaped = unquoted.replaceAllMapped(
    RegExp(r'[&|^<>()!]'),
    (match) => '^${match.group(0)}',
  );
  if (!isQuoted && !RegExp(r'[\s"]').hasMatch(unquoted)) return escaped;
  return '"${_quoteWindowsValue(escaped)}"';
}

String _quoteWindowsValue(String value) {
  final output = StringBuffer();
  var index = 0;
  while (index < value.length) {
    if (value[index] != r'\') {
      if (value[index] == '"')
        output.write(r'\"');
      else
        output.write(value[index]);
      index++;
      continue;
    }
    final start = index;
    while (index < value.length && value[index] == r'\') {
      index++;
    }
    final count = index - start;
    if (index == value.length) {
      output.write(r'\' * (count * 2));
    } else if (value[index] == '"') {
      output.write(r'\' * (count * 2 + 1));
      output.write('"');
      index++;
    } else {
      output.write(r'\' * count);
    }
  }
  return output.toString();
}
