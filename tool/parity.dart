import 'dart:convert';
import 'dart:io';

const _baselinePath = 'parity/baseline.json';
const _inventoryPath = 'parity/upstream_inventory.json';
const _ledgerPath = 'parity/ledger.json';
const _validStatuses = {'not-started', 'partial', 'verified'};

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (!options.write && !options.check && options.markId == null) {
    _usage('Specify --write, --check, or --mark.');
  }

  final baseline = _readObject(_baselinePath);
  final expectedCommit = baseline['commit'] as String;

  Map<String, Object?>? generated;
  if (options.upstream != null) {
    final upstream = Directory(options.upstream!);
    if (!upstream.existsSync()) {
      _fail('Paseo checkout does not exist: ${upstream.path}');
    }
    await _verifyCommit(upstream.path, expectedCommit);
    generated = _buildInventory(upstream, baseline);
  } else if (options.write) {
    _usage('--write requires --upstream <path>.');
  }

  if (options.write) {
    _writeJson(_inventoryPath, generated!);
    _mergeLedger(generated);
    stdout.writeln(
      'Wrote ${_items(generated).length} frozen parity inventory items.',
    );
  }

  if (options.markId != null) {
    _markLedger(
      id: options.markId!,
      status: options.markStatus!,
      implementation: options.implementation,
      evidence: options.evidence,
      notes: options.notes,
    );
  }

  if (options.check) {
    _checkCommitted(
      expectedGenerated: generated,
      requireComplete: options.requireComplete,
    );
  }
}

void _markLedger({
  required String id,
  required String status,
  required String? implementation,
  required List<String> evidence,
  required String? notes,
}) {
  if (!_validStatuses.contains(status)) {
    _usage('--status must be not-started, partial, or verified.');
  }
  final ledger = _readObject(_ledgerPath);
  final entries = _items(ledger);
  final index = entries.indexWhere((entry) => entry['id'] == id);
  if (index < 0) _fail('Unknown parity item: $id');
  if (status == 'verified' &&
      ((implementation == null || implementation.trim().isEmpty) ||
          evidence.isEmpty)) {
    _usage('Verified items require --implementation and --evidence.');
  }
  final prior = entries[index];
  entries[index] = {
    ...prior,
    'status': status,
    'implementation': implementation,
    'evidence': evidence,
    'notes': notes,
  };
  _writeJson(_ledgerPath, ledger);
  stdout.writeln('Marked $id as $status.');
}

Map<String, Object?> _buildInventory(
  Directory upstream,
  Map<String, Object?> baseline,
) {
  final items = <Map<String, Object?>>[];
  final seen = <String>{};

  void add(String category, String key, String reference, [String? title]) {
    final id = '$category:${_normalizeKey(key)}';
    if (!seen.add(id)) return;
    items.add({
      'id': id,
      'category': category,
      'title': title ?? key,
      'reference': reference.replaceAll(r'\', '/'),
    });
  }

  const runtimeRoots = {
    'protocol': 'packages/protocol/src',
    'server': 'packages/server/src',
    'app': 'packages/app/src',
    'cli': 'packages/cli/src',
    'desktop': 'packages/desktop/src',
    'relay': 'packages/relay/src',
  };

  for (final root in runtimeRoots.entries) {
    final directory = Directory('${upstream.path}/${root.value}');
    if (!directory.existsSync()) {
      _fail('Missing baseline source directory: ${root.value}');
    }
    for (final file in _sourceFiles(directory)) {
      final relative = _relative(upstream.path, file.path);
      add('source-unit', relative, relative);
    }
  }

  final appRoutes = Directory('${upstream.path}/packages/app/src/app');
  for (final file in _sourceFiles(appRoutes)) {
    final relative = _relative(appRoutes.path, file.path);
    if (!relative.endsWith('.tsx') && !relative.endsWith('.ts')) continue;
    final route = relative
        .replaceFirst(RegExp(r'\.(tsx|ts)$'), '')
        .replaceFirst(RegExp(r'(^|/)(index|_layout)$'), r'$1')
        .replaceAll(RegExp(r'/+$'), '');
    add(
      'app-route',
      route.isEmpty ? '/' : '/$route',
      _relative(upstream.path, file.path),
    );
  }

  final protocolRoot = Directory('${upstream.path}/packages/protocol/src');
  final wirePattern = RegExp(
    r'''["']([a-z][a-z0-9]*(?:[._-][a-z0-9]+)*(?:_request|_response|_event|_update|_notification))["']''',
  );
  for (final file in _sourceFiles(protocolRoot)) {
    final text = file.readAsStringSync();
    for (final match in wirePattern.allMatches(text)) {
      add('wire-message', match.group(1)!, _relative(upstream.path, file.path));
    }
  }

  final commandRoot = Directory('${upstream.path}/packages/cli/src/commands');
  for (final file in _sourceFiles(commandRoot)) {
    final relative = _relative(commandRoot.path, file.path);
    final name = relative.replaceFirst(RegExp(r'\.ts$'), '');
    if (name.endsWith('/shared') ||
        name.endsWith('/schema') ||
        name.endsWith('/index')) {
      continue;
    }
    add(
      'cli-command',
      name.replaceAll('/', ' '),
      _relative(upstream.path, file.path),
    );
  }

  final actions = File('${upstream.path}/packages/app/src/keyboard/actions.ts');
  final actionPattern = RegExp(r'''\|\s*"([^"]+)"''');
  for (final match in actionPattern.allMatches(actions.readAsStringSync())) {
    final action = match.group(1)!;
    if (action.contains('.')) {
      add('keyboard-action', action, _relative(upstream.path, actions.path));
    }
  }

  final changelog = File('${upstream.path}/CHANGELOG.md');
  final releaseLines = _releaseSection(
    changelog.readAsLinesSync(),
    baseline['version'] as String,
  );
  var featureIndex = 0;
  for (final line in releaseLines.where((line) => line.startsWith('- '))) {
    featureIndex++;
    final title = line
        .substring(2)
        .replaceAll(RegExp(r'\s+\(\[#.*$'), '')
        .trim();
    add(
      'release-feature',
      '${(featureIndex).toString().padLeft(3, '0')}-$title',
      'CHANGELOG.md',
      title,
    );
  }

  final docs = Directory('${upstream.path}/public-docs');
  if (docs.existsSync()) {
    for (final entity in docs.listSync(recursive: true).whereType<File>()) {
      if (entity.path.endsWith('.md')) {
        final relative = _relative(upstream.path, entity.path);
        add('runtime-doc', relative, relative);
      }
    }
  }

  for (final platform in const [
    'windows',
    'macos',
    'linux',
    'ios',
    'android',
    'web',
  ]) {
    add('platform', platform, 'README.md');
  }

  items.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final counts = <String, int>{};
  for (final item in items) {
    final category = item['category'] as String;
    counts[category] = (counts[category] ?? 0) + 1;
  }

  return {
    'schemaVersion': 1,
    'baseline': {
      'product': baseline['product'],
      'version': baseline['version'],
      'commit': baseline['commit'],
    },
    'counts': Map.fromEntries(
      counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'items': items,
  };
}

Iterable<File> _sourceFiles(Directory root) sync* {
  if (!root.existsSync()) return;
  final files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (file) => file.path.endsWith('.ts') || file.path.endsWith('.tsx'),
          )
          .where((file) {
            final normalized = file.path.replaceAll(r'\', '/');
            return !normalized.contains('/node_modules/') &&
                !normalized.contains('/generated/') &&
                !RegExp(
                  r'(\.test|\.spec|\.e2e\.test)\.(ts|tsx)$',
                ).hasMatch(normalized);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  yield* files;
}

List<String> _releaseSection(List<String> lines, String version) {
  final start = lines.indexWhere((line) => line.startsWith('## $version '));
  if (start < 0) _fail('CHANGELOG.md has no $version release section.');
  final result = <String>[];
  for (var index = start + 1; index < lines.length; index++) {
    if (lines[index].startsWith('## ')) break;
    result.add(lines[index]);
  }
  return result;
}

void _mergeLedger(Map<String, Object?> inventory) {
  final existing = File(_ledgerPath).existsSync()
      ? _items(_readObject(_ledgerPath))
      : const <Map<String, Object?>>[];
  final byId = {for (final item in existing) item['id'] as String: item};
  final entries = <Map<String, Object?>>[];
  for (final item in _items(inventory)) {
    final id = item['id'] as String;
    final prior = byId[id];
    entries.add({
      'id': id,
      'status': prior?['status'] ?? 'not-started',
      'implementation': prior?['implementation'],
      'evidence': prior?['evidence'] ?? <Object?>[],
      'notes': prior?['notes'],
    });
  }
  _writeJson(_ledgerPath, {
    'schemaVersion': 1,
    'baselineCommit': (inventory['baseline'] as Map<String, Object?>)['commit'],
    'entries': entries,
  });
}

void _checkCommitted({
  Map<String, Object?>? expectedGenerated,
  required bool requireComplete,
}) {
  final inventory = _readObject(_inventoryPath);
  final ledger = _readObject(_ledgerPath);
  if (expectedGenerated != null &&
      const JsonEncoder().convert(inventory) !=
          const JsonEncoder().convert(expectedGenerated)) {
    _fail('Committed upstream inventory is stale; run --write.');
  }

  final inventoryIds = {
    for (final item in _items(inventory)) item['id'] as String,
  };
  final entries = _items(ledger);
  final ledgerIds = <String>{};
  var verified = 0;
  var partial = 0;
  var notStarted = 0;

  for (final entry in entries) {
    final id = entry['id'] as String;
    if (!ledgerIds.add(id)) _fail('Duplicate ledger entry: $id');
    final status = entry['status'];
    if (!_validStatuses.contains(status)) {
      _fail('Invalid status for $id: $status');
    }
    switch (status) {
      case 'verified':
        verified++;
        final implementation = entry['implementation'];
        final evidence = entry['evidence'];
        if (implementation is! String ||
            implementation.trim().isEmpty ||
            evidence is! List ||
            evidence.isEmpty) {
          _fail('Verified item lacks implementation/evidence: $id');
        }
      case 'partial':
        partial++;
      case 'not-started':
        notStarted++;
    }
  }

  final missing = inventoryIds.difference(ledgerIds);
  final stale = ledgerIds.difference(inventoryIds);
  if (missing.isNotEmpty) {
    _fail('Ledger is missing ${missing.length} inventory items.');
  }
  if (stale.isNotEmpty) {
    _fail('Ledger has ${stale.length} stale items.');
  }
  if (requireComplete && (partial > 0 || notStarted > 0)) {
    _fail(
      'Parity is incomplete: $verified verified, '
      '$partial partial, $notStarted not-started.',
    );
  }
  stdout.writeln(
    'Parity ledger valid: ${inventoryIds.length} total, '
    '$verified verified, $partial partial, $notStarted not-started.',
  );
}

List<Map<String, Object?>> _items(Map<String, Object?> document) {
  final raw = document['items'] ?? document['entries'];
  if (raw is! List) _fail('Document has no items/entries list.');
  return raw.cast<Map<String, Object?>>();
}

Map<String, Object?> _readObject(String path) {
  final file = File(path);
  if (!file.existsSync()) _fail('Missing $path.');
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, Object?>) _fail('$path is not a JSON object.');
  return value;
}

void _writeJson(String path, Object value) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

Future<void> _verifyCommit(String upstream, String expected) async {
  final result = await Process.run('git', [
    '-C',
    upstream,
    'rev-parse',
    'HEAD',
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    _fail('Unable to read Paseo commit: ${result.stderr}');
  }
  final actual = (result.stdout as String).trim();
  if (actual != expected) {
    _fail('Paseo checkout is $actual; expected frozen commit $expected.');
  }
}

String _relative(String root, String path) {
  final normalizedRoot = root
      .replaceAll(r'\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  final normalizedPath = path.replaceAll(r'\', '/');
  return normalizedPath.startsWith('$normalizedRoot/')
      ? normalizedPath.substring(normalizedRoot.length + 1)
      : normalizedPath;
}

String _normalizeKey(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(r'\', '/')
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp(r'[^a-z0-9._/[\]-]+'), '-')
    .replaceAll(RegExp(r'-+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage: dart run tool/parity.dart (--write|--check) '
    '[--upstream <path>] [--require-complete]',
  );
  exit(64);
}

Never _fail(String message) {
  stderr.writeln('Parity check failed: $message');
  exit(1);
}

final class _Options {
  const _Options({
    required this.write,
    required this.check,
    required this.requireComplete,
    required this.upstream,
    required this.markId,
    required this.markStatus,
    required this.implementation,
    required this.evidence,
    required this.notes,
  });

  final bool write;
  final bool check;
  final bool requireComplete;
  final String? upstream;
  final String? markId;
  final String? markStatus;
  final String? implementation;
  final List<String> evidence;
  final String? notes;

  static _Options parse(List<String> arguments) {
    var write = false;
    var check = false;
    var requireComplete = false;
    String? upstream;
    String? markId;
    String? markStatus;
    String? implementation;
    final evidence = <String>[];
    String? notes;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--write':
          write = true;
        case '--check':
          check = true;
        case '--require-complete':
          requireComplete = true;
        case '--upstream':
          if (index + 1 >= arguments.length) {
            _usage('--upstream requires a path.');
          }
          upstream = arguments[++index];
        case '--mark':
          if (index + 1 >= arguments.length) {
            _usage('--mark requires an inventory ID.');
          }
          markId = arguments[++index];
        case '--status':
          if (index + 1 >= arguments.length) {
            _usage('--status requires a value.');
          }
          markStatus = arguments[++index];
        case '--implementation':
          if (index + 1 >= arguments.length) {
            _usage('--implementation requires a path.');
          }
          implementation = arguments[++index];
        case '--evidence':
          if (index + 1 >= arguments.length) {
            _usage('--evidence requires a path or description.');
          }
          evidence.add(arguments[++index]);
        case '--notes':
          if (index + 1 >= arguments.length) {
            _usage('--notes requires text.');
          }
          notes = arguments[++index];
        default:
          _usage('Unknown argument: ${arguments[index]}');
      }
    }
    if (markId != null && markStatus == null) {
      _usage('--mark requires --status.');
    }
    return _Options(
      write: write,
      check: check,
      requireComplete: requireComplete,
      upstream: upstream,
      markId: markId,
      markStatus: markStatus,
      implementation: implementation,
      evidence: evidence,
      notes: notes,
    );
  }
}
