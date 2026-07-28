import 'dart:convert';
import 'dart:io';

/// Deterministically merges `dart test --coverage` VM JSON files into LCOV.
///
/// package:coverage's global `format_coverage` command can stop making
/// progress on the daemon's many large per-suite records on Windows. The VM
/// records already contain executable line/count pairs, so this bounded
/// merger preserves their max hit count and the coverage ignore directives
/// needed by the repository gate without loading all records at once.
Future<void> main(List<String> arguments) async {
  final input = _option(arguments, '--in') ?? 'coverage';
  final output = _option(arguments, '--out') ?? '$input/lcov.info';
  final packageRoot = Directory.current.absolute.path;
  final packageName = _packageName(
    File('$packageRoot${Platform.pathSeparator}pubspec.yaml'),
  );
  final libRoot = _normalize(
    '$packageRoot${Platform.pathSeparator}lib',
  );
  final hitsBySource = <String, Map<int, int>>{};

  final records =
      Directory(input)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.vm.json'))
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  if (records.isEmpty) {
    stderr.writeln('No VM coverage records found under $input');
    exitCode = 1;
    return;
  }

  for (final record in records) {
    final decoded = jsonDecode(await record.readAsString());
    if (decoded is! Map || decoded['coverage'] is! List) continue;
    for (final value in decoded['coverage'] as List) {
      if (value is! Map) continue;
      final source = _sourcePath(
        value['source'],
        packageName: packageName,
        packageRoot: packageRoot,
      );
      if (source == null || !_isWithin(libRoot, source)) continue;
      final rawHits = value['hits'];
      if (rawHits is! List) continue;
      final hits = hitsBySource.putIfAbsent(source, () => {});
      for (var index = 0; index + 1 < rawHits.length; index += 2) {
        final line = rawHits[index];
        final count = rawHits[index + 1];
        if (line is! num || count is! num) continue;
        final lineNumber = line.toInt();
        final hitCount = count.toInt();
        final previous = hits[lineNumber] ?? 0;
        if (hitCount > previous || !hits.containsKey(lineNumber)) {
          hits[lineNumber] = hitCount;
        }
      }
    }
  }

  final buffer = StringBuffer();
  var totalFound = 0;
  var totalHit = 0;
  final sources = hitsBySource.keys.toList()..sort();
  for (final source in sources) {
    final ignored = await _ignoredLines(File(source));
    if (ignored == null) continue;
    final hits = hitsBySource[source]!;
    final lines = hits.keys.where((line) => !ignored.contains(line)).toList()
      ..sort();
    final hitLines = lines.where((line) => hits[line]! > 0).length;
    totalFound += lines.length;
    totalHit += hitLines;
    buffer
      ..writeln('TN:')
      ..writeln('SF:$source');
    for (final line in lines) {
      buffer.writeln('DA:$line,${hits[line]}');
    }
    buffer
      ..writeln('LF:${lines.length}')
      ..writeln('LH:$hitLines')
      ..writeln('end_of_record');
  }

  final destination = File(output);
  await destination.parent.create(recursive: true);
  await destination.writeAsString(buffer.toString(), flush: true);
  stdout.writeln(
    'Formatted ${records.length} VM records across ${sources.length} files '
    '($totalHit/$totalFound lines).',
  );
}

String? _option(List<String> arguments, String name) {
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
    if (argument == name && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
  }
  return null;
}

String _packageName(File pubspec) {
  for (final line in pubspec.readAsLinesSync()) {
    final match = RegExp(r'^name:\s*([A-Za-z0-9_]+)\s*$').firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  throw FormatException('Package name not found in ${pubspec.path}');
}

String? _sourcePath(
  Object? value, {
  required String packageName,
  required String packageRoot,
}) {
  if (value is! String) return null;
  final packagePrefix = 'package:$packageName/';
  if (value.startsWith(packagePrefix)) {
    final relative = value.substring(packagePrefix.length).replaceAll(
      '/',
      Platform.pathSeparator,
    );
    return _normalize(
      '$packageRoot${Platform.pathSeparator}lib'
      '${Platform.pathSeparator}$relative',
    );
  }
  if (value.startsWith('file:')) {
    try {
      return _normalize(Uri.parse(value).toFilePath(windows: Platform.isWindows));
    } on FormatException {
      return null;
    }
  }
  return null;
}

String _normalize(String value) => File(value).absolute.path;

bool _isWithin(String parent, String candidate) {
  final normalizedParent = Platform.isWindows
      ? parent.toLowerCase()
      : parent;
  final normalizedCandidate = Platform.isWindows
      ? candidate.toLowerCase()
      : candidate;
  return normalizedCandidate.startsWith(
    '$normalizedParent${Platform.pathSeparator}',
  );
}

Future<Set<int>?> _ignoredLines(File source) async {
  if (!await source.exists()) return null;
  final lines = await source.readAsLines();
  if (lines.any((line) => line.contains('coverage:ignore-file'))) {
    return null;
  }
  final ignored = <int>{};
  var ignoring = false;
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index];
    if (line.contains('coverage:ignore-start')) {
      ignoring = true;
      ignored.add(lineNumber);
    } else if (line.contains('coverage:ignore-end')) {
      ignored.add(lineNumber);
      ignoring = false;
    } else if (ignoring || line.contains('coverage:ignore-line')) {
      ignored.add(lineNumber);
    }
  }
  return ignored;
}
