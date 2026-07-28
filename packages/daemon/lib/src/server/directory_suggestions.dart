import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

enum DirectorySuggestionPathFormat { absolute, relative }

enum PathQueryPolicy { rooted, slashes }

enum BlankQueryBehavior { none, children }

const workspaceSearchHiddenDirectories = <String>[
  '.agents',
  '.claude',
  '.codex',
  '.github',
  '.opencode',
  '.paseo',
  '.vscode',
];

const _ignoredDirectoryNames = <String>{
  'node_modules',
  'venv',
  'env',
  'virtualenv',
  'dist',
  'build',
  'target',
  'out',
  'coverage',
  'vendor',
  '__pycache__',
  '.git',
};

const _defaultLimit = 30;
const _maxLimit = 100;
const _defaultMaxDepth = 12;
const _defaultMaxEntriesScanned = 20000;
const _directoryListCacheTtl = Duration(seconds: 8);
const _directoryListCacheMaxEntries = 4000;
const _maxConfidentFuzzySkipsPerCharacter = 2;
const _noIndex = 0x3FFFFFFFFFFFFFFF;
const _noMatchTier = 5;

final _directoryListCache = <String, _DirectoryListCacheEntry>{};

final class SearchDirectoryEntriesOptions {
  const SearchDirectoryEntriesOptions({
    required this.root,
    required this.query,
    required this.pathFormat,
    this.includeFiles,
    this.includeDirectories,
    this.matchMode,
    this.pathQueryPolicy,
    this.rootAliases = const [],
    this.blankQueryBehavior,
    this.traversableHiddenDirectoryNames = const [],
    this.limit,
    this.maxDepth,
    this.maxEntriesScanned,
    this.confidentResultScanThreshold,
  });

  final String root;
  final String query;
  final DirectorySuggestionPathFormat pathFormat;
  final bool? includeFiles;
  final bool? includeDirectories;
  final DirectorySuggestionMatchMode? matchMode;
  final PathQueryPolicy? pathQueryPolicy;
  final List<String> rootAliases;
  final BlankQueryBehavior? blankQueryBehavior;
  final List<String> traversableHiddenDirectoryNames;
  final int? limit;
  final int? maxDepth;
  final int? maxEntriesScanned;
  final int? confidentResultScanThreshold;
}

Future<List<DirectorySuggestionEntry>> searchDirectoryEntries(
  SearchDirectoryEntriesOptions options,
) async {
  final root = await _resolveDirectory(options.root);
  if (root == null) return const [];
  final input = _buildSearchInput(options, root);
  if (input == null) return const [];

  final exact =
      input.plan.browseExactPath ||
          (input.matchMode == DirectorySuggestionMatchMode.suffix &&
              input.plan.isPathQuery)
      ? await _findExactEntry(input)
      : null;
  if (exact != null && input.limit == 1) return [exact];

  final browsesRoot =
      input.plan.isPathQuery && input.plan.normalizedQuery.isEmpty;
  final ranked =
      input.plan.isPathQuery &&
          (input.matchMode == DirectorySuggestionMatchMode.fuzzy || browsesRoot)
      ? await _searchChildren(input)
      : await _searchTree(input);
  final results = _sortAndFormat(
    ranked,
    input.root,
    input.pathFormat,
  ).take(input.limit).toList();
  if (exact == null) return results;
  return [
    exact,
    ...results.where((entry) => !_sameEntry(entry, exact)),
  ].take(input.limit).toList();
}

_SearchInput? _buildSearchInput(
  SearchDirectoryEntriesOptions options,
  String root,
) {
  final includeDirectories = options.includeDirectories ?? true;
  final includeFiles = options.includeFiles ?? false;
  if (!includeDirectories && !includeFiles) return null;
  final plan = _parseQuery(
    query: options.query,
    root: root,
    configuredRoot: p.absolute(options.root),
    policy: options.pathQueryPolicy ?? PathQueryPolicy.slashes,
    aliases: options.rootAliases,
    blankBehavior: options.blankQueryBehavior ?? BlankQueryBehavior.none,
  );
  if (plan == null) return null;
  return _SearchInput(
    root: root,
    plan: plan,
    includeDirectories: includeDirectories,
    includeFiles: includeFiles,
    matchMode: options.matchMode ?? DirectorySuggestionMatchMode.fuzzy,
    pathFormat: options.pathFormat,
    hiddenDirectoryNames: options.traversableHiddenDirectoryNames.toSet(),
    limit: _normalizeLimit(options.limit),
    maxDepth: options.maxDepth ?? _defaultMaxDepth,
    maxEntriesScanned: options.maxEntriesScanned ?? _defaultMaxEntriesScanned,
    confidentResultScanThreshold: options.confidentResultScanThreshold,
  );
}

Future<DirectorySuggestionEntry?> _findExactEntry(_SearchInput input) async {
  if (input.plan.normalizedQuery.isEmpty) return null;
  final visiblePath = p.absolute(
    p.join(input.root, input.plan.normalizedQuery),
  );
  final resolvedPath = await _resolvePath(visiblePath);
  if (resolvedPath == null || !_isPathInsideRoot(input.root, resolvedPath)) {
    return null;
  }
  final kind = await _entryKind(resolvedPath);
  if (kind == null ||
      (kind == DirectorySuggestionKind.directory &&
          !input.includeDirectories) ||
      (kind == DirectorySuggestionKind.file && !input.includeFiles)) {
    return null;
  }
  return _formatEntry(
    DirectorySuggestionEntry(path: visiblePath, kind: kind),
    input.root,
    input.pathFormat,
  );
}

Future<List<_RankedEntry>> _searchChildren(_SearchInput input) async {
  final visibleParent = p.absolute(
    p.join(
      input.root,
      input.plan.parentPart.isEmpty ? '.' : input.plan.parentPart,
    ),
  );
  final parent = await _resolvePath(visibleParent);
  if (parent == null || !_isPathInsideRoot(input.root, parent)) return const [];
  final entries = await _readChildren(parent);
  final result = <_RankedEntry>[];
  for (final entry in entries) {
    if (!_isPathInsideRoot(input.root, entry.resolvedPath) ||
        !_shouldDiscover(entry, input)) {
      continue;
    }
    final candidate = _TraversedEntry(
      name: entry.name,
      resolvedPath: entry.resolvedPath,
      kind: entry.kind,
      visiblePath: p.join(visibleParent, entry.name),
      depth: 1,
    );
    if (_shouldSuggest(candidate, input)) result.add(_rank(candidate, input));
  }
  return result;
}

Future<List<_RankedEntry>> _searchTree(_SearchInput input) async {
  if (input.maxEntriesScanned <= 0) return const [];
  final roots = (await _readChildren(input.root))
      .where((entry) => _isPathInsideRoot(input.root, entry.resolvedPath))
      .toList();
  final visited = <String>{_pathKey(input.root)};
  final branches = <Stream<_TraversedEntry>>[
    for (final entry in roots)
      if (_shouldDiscover(entry, input))
        _walkBranch(
          _TraversedEntry(
            name: entry.name,
            resolvedPath: entry.resolvedPath,
            kind: entry.kind,
            visiblePath: p.join(input.root, entry.name),
            depth: 1,
          ),
          input,
          visited,
        ),
  ];
  final ranked = <_RankedEntry>[];
  var scanned = 0;
  await for (final entry in _roundRobin(branches)) {
    scanned += 1;
    if (_shouldSuggest(entry, input)) ranked.add(_rank(entry, input));
    final threshold = input.confidentResultScanThreshold;
    if (scanned >= input.maxEntriesScanned ||
        (threshold != null &&
            threshold > 0 &&
            scanned >= threshold &&
            _hasConfidentResult(ranked, input.plan.searchTerm))) {
      break;
    }
  }
  return ranked;
}

Stream<_TraversedEntry> _walkBranch(
  _TraversedEntry entry,
  _SearchInput input,
  Set<String> visited,
) async* {
  yield entry;
  final key = _pathKey(entry.resolvedPath);
  if (entry.kind != DirectorySuggestionKind.directory ||
      visited.contains(key) ||
      entry.depth >= input.maxDepth) {
    return;
  }
  visited.add(key);
  final children = (await _readChildren(entry.resolvedPath))
      .where((child) => _isPathInsideRoot(input.root, child.resolvedPath))
      .toList();
  yield* _roundRobin([
    for (final child in children)
      if (_shouldDiscover(child, input))
        _walkBranch(
          _TraversedEntry(
            name: child.name,
            resolvedPath: child.resolvedPath,
            kind: child.kind,
            visiblePath: p.join(entry.visiblePath, child.name),
            depth: entry.depth + 1,
          ),
          input,
          visited,
        ),
  ]);
}

Stream<T> _roundRobin<T>(List<Stream<T>> branches) async* {
  var active = [for (final branch in branches) StreamIterator(branch)];
  try {
    while (active.isNotEmpty) {
      final nextRound = <StreamIterator<T>>[];
      for (final branch in active) {
        if (await branch.moveNext()) {
          nextRound.add(branch);
          yield branch.current;
        } else {
          await branch.cancel();
        }
      }
      active = nextRound;
    }
  } finally {
    for (final branch in active) {
      await branch.cancel();
    }
  }
}

bool _shouldDiscover(_ChildEntry entry, _SearchInput input) {
  if (entry.kind == DirectorySuggestionKind.file) {
    return input.includeFiles && !entry.name.startsWith('.');
  }
  if (_ignoredDirectoryNames.contains(entry.name)) return false;
  if (!entry.name.startsWith('.')) return true;
  return input.hiddenDirectoryNames.contains(entry.name);
}

bool _shouldSuggest(_TraversedEntry entry, _SearchInput input) {
  if (entry.name.startsWith('.')) return false;
  if (entry.kind == DirectorySuggestionKind.directory &&
      !input.includeDirectories) {
    return false;
  }
  if (entry.kind == DirectorySuggestionKind.file && !input.includeFiles) {
    return false;
  }
  if (input.plan.normalizedQuery.isEmpty) return true;
  if (input.matchMode == DirectorySuggestionMatchMode.suffix) {
    return _suffixMatches(
      entry.visiblePath,
      input.root,
      input.plan.normalizedQuery,
    );
  }
  return input.plan.searchTerm.isEmpty ||
      _rank(entry, input).matchTier != _noMatchTier;
}

_RankedEntry _rank(_TraversedEntry entry, _SearchInput input) {
  final relativePath = _normalizeRelativePath(input.root, entry.visiblePath);
  final lowerPath = relativePath.toLowerCase();
  final query = input.plan.searchTerm.toLowerCase();
  final segments = lowerPath == '.' ? const <String>[] : lowerPath.split('/');
  final exact = segments.indexWhere((segment) => segment == query);
  final prefix = segments.indexWhere((segment) => segment.startsWith(query));
  final substring = segments.indexWhere((segment) => segment.contains(query));
  final offset = lowerPath.indexOf(query);
  final fuzzyScore = _scoreFuzzySubsequence(
    query,
    segments.isEmpty ? '' : segments.last,
  );
  var matchTier = _noMatchTier;
  var segmentIndex = _noIndex;
  if (query.isEmpty) {
    matchTier = 3;
  } else if (exact >= 0) {
    matchTier = 0;
    segmentIndex = exact;
  } else if (prefix >= 0) {
    matchTier = 1;
    segmentIndex = prefix;
  } else if (substring >= 0) {
    matchTier = 2;
    segmentIndex = substring;
  } else if (input.pathFormat == DirectorySuggestionPathFormat.relative
      ? lowerPath.startsWith(query)
      : offset >= 0) {
    matchTier = 3;
  } else if (fuzzyScore != null) {
    matchTier = 4;
  }
  return _RankedEntry(
    path: entry.visiblePath,
    kind: entry.kind,
    matchTier: matchTier,
    segmentIndex: segmentIndex,
    matchOffset: offset >= 0 ? offset : _noIndex,
    fuzzyScore: fuzzyScore ?? _noIndex,
    depth: relativePath == '.' ? 0 : segments.length,
  );
}

List<DirectorySuggestionEntry> _sortAndFormat(
  List<_RankedEntry> entries,
  String root,
  DirectorySuggestionPathFormat format,
) {
  final unique = <String, _RankedEntry>{};
  for (final entry in entries) {
    final key = '${entry.kind.name}:${entry.path}';
    final existing = unique[key];
    if (existing == null || _compareRank(entry, existing) < 0) {
      unique[key] = entry;
    }
  }
  final values = unique.values.toList()..sort(_compareRank);
  return [
    for (final entry in values)
      _formatEntry(
        DirectorySuggestionEntry(path: entry.path, kind: entry.kind),
        root,
        format,
      ),
  ];
}

DirectorySuggestionEntry _formatEntry(
  DirectorySuggestionEntry entry,
  String root,
  DirectorySuggestionPathFormat format,
) => DirectorySuggestionEntry(
  path: format == DirectorySuggestionPathFormat.absolute
      ? entry.path
      : _normalizeRelativePath(root, entry.path),
  kind: entry.kind,
);

int _compareRank(_RankedEntry left, _RankedEntry right) {
  var result = left.matchTier.compareTo(right.matchTier);
  if (result != 0) return result;
  result = left.segmentIndex.compareTo(right.segmentIndex);
  if (result != 0) return result;
  result = left.matchOffset.compareTo(right.matchOffset);
  if (result != 0) return result;
  result = left.fuzzyScore.compareTo(right.fuzzyScore);
  if (result != 0) return result;
  result = left.depth.compareTo(right.depth);
  if (result != 0) return result;
  result = _compareKinds(left.kind, right.kind);
  if (result != 0) return result;
  return left.path.compareTo(right.path);
}

int _compareKinds(DirectorySuggestionKind left, DirectorySuggestionKind right) {
  if (left == right) return 0;
  return left == DirectorySuggestionKind.directory ? -1 : 1;
}

bool _hasConfidentResult(List<_RankedEntry> entries, String query) {
  final maxFuzzyScore = query.length * _maxConfidentFuzzySkipsPerCharacter;
  return entries.any(
    (entry) =>
        entry.matchTier < 4 ||
        (entry.matchTier == 4 && entry.fuzzyScore <= maxFuzzyScore),
  );
}

bool _suffixMatches(String visiblePath, String root, String query) {
  final querySegments = query
      .toLowerCase()
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (querySegments.isEmpty) return false;
  final pathSegments = _normalizeRelativePath(
    root,
    visiblePath,
  ).toLowerCase().split('/').where((segment) => segment.isNotEmpty).toList();
  final offset = pathSegments.length - querySegments.length;
  if (offset < 0) return false;
  for (var index = 0; index < querySegments.length; index += 1) {
    if (querySegments[index] != pathSegments[offset + index]) return false;
  }
  return true;
}

_QueryPlan? _parseQuery({
  required String query,
  required String root,
  required String configuredRoot,
  required PathQueryPolicy policy,
  required List<String> aliases,
  required BlankQueryBehavior blankBehavior,
}) {
  final normalizedInput = _normalizeQueryInput(
    query: query,
    root: root,
    configuredRoot: configuredRoot,
    aliases: aliases,
  );
  if (normalizedInput == null) return null;
  final typed = normalizedInput.typed;
  final normalized = normalizedInput.normalized;
  final rooted = normalizedInput.rooted;
  if (normalized.isEmpty) {
    final explicitlyBrowseRoot = rooted || typed == '.';
    if (!explicitlyBrowseRoot && blankBehavior != BlankQueryBehavior.children) {
      return null;
    }
    return const _QueryPlan(
      isPathQuery: true,
      parentPart: '',
      searchTerm: '',
      normalizedQuery: '',
    );
  }
  if (normalizedInput.isAbsolute &&
      _isFilesystemRoot(root) &&
      !normalized.contains('/')) {
    return _QueryPlan(
      isPathQuery: true,
      parentPart: normalized,
      searchTerm: '',
      normalizedQuery: normalized,
      browseExactPath: true,
    );
  }
  final isPathQuery =
      rooted || (policy == PathQueryPolicy.slashes && normalized.contains('/'));
  final slash = normalized.lastIndexOf('/');
  return _QueryPlan(
    isPathQuery: isPathQuery,
    parentPart: isPathQuery && slash >= 0 ? normalized.substring(0, slash) : '',
    searchTerm: isPathQuery && slash >= 0
        ? normalized.substring(slash + 1)
        : normalized,
    normalizedQuery: normalized,
  );
}

_NormalizedQueryInput? _normalizeQueryInput({
  required String query,
  required String root,
  required String configuredRoot,
  required List<String> aliases,
}) {
  final typed = query.trim().replaceAll(r'\', '/');
  var normalized = typed;
  var rooted = false;
  var isAbsolute = false;
  for (final alias in aliases) {
    if (normalized == alias || normalized.startsWith('$alias/')) {
      rooted = true;
      normalized = normalized
          .substring(alias.length)
          .replaceFirst(RegExp(r'^/+'), '');
      break;
    }
  }
  if (p.isAbsolute(normalized)) {
    isAbsolute = true;
    final browseAbsoluteDirectory = normalized.endsWith('/');
    final absolutePath = p.absolute(normalized);
    String? queryRoot;
    if (_isPathInsideRoot(root, absolutePath)) {
      queryRoot = root;
    } else if (_isPathInsideRoot(configuredRoot, absolutePath)) {
      queryRoot = configuredRoot;
    }
    if (queryRoot == null) return null;
    rooted = true;
    normalized = _normalizeRelativePath(queryRoot, absolutePath);
    if (browseAbsoluteDirectory && normalized != '.') {
      normalized = '$normalized/';
    }
  }
  if (normalized.startsWith('./')) rooted = true;
  normalized = normalized
      .replaceFirst(RegExp(r'^\./+'), '')
      .replaceAll(RegExp('/{2,}'), '/');
  if (normalized == '.' && (rooted || typed == '.')) normalized = '';
  return _NormalizedQueryInput(
    typed: typed,
    normalized: normalized,
    rooted: rooted,
    isAbsolute: isAbsolute,
  );
}

bool _isFilesystemRoot(String path) =>
    p.normalize(p.absolute(path)) == p.rootPrefix(p.absolute(path));

Future<String?> _resolveDirectory(String path) async {
  try {
    final resolved = await Directory(p.absolute(path)).resolveSymbolicLinks();
    final stat = await Directory(resolved).stat();
    return stat.type == FileSystemEntityType.directory ? resolved : null;
  } on FileSystemException {
    return null;
  }
}

Future<String?> _resolvePath(String path) async {
  try {
    return await File(path).resolveSymbolicLinks();
  } on FileSystemException {
    return null;
  }
}

Future<List<_ChildEntry>> _readChildren(String directory) async {
  FileStat directoryInfo;
  try {
    directoryInfo = await Directory(directory).stat();
  } on FileSystemException {
    return const [];
  }
  if (directoryInfo.type != FileSystemEntityType.directory) return const [];

  // Paseo deliberately disables directory metadata caching on Windows
  // because child changes do not reliably update directory mtime/ctime.
  // The cache branch is exercised by the macOS/Linux platform gate.
  final cached = Platform.isWindows
      ? null
      : _directoryListCache[directory]; // coverage:ignore-line
  List<_RawChildEntry> rawEntries;
  // coverage:ignore-start
  if (cached != null &&
      cached.expiresAt.isAfter(DateTime.now()) &&
      cached.modifiedAt == directoryInfo.modified &&
      cached.changedAt == directoryInfo.changed) {
    rawEntries = cached.entries;
  }
  // coverage:ignore-end
  else {
    try {
      rawEntries = [
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false))
          if (_rawChildEntry(entity) case final entry?) entry,
      ]..sort((left, right) => left.name.compareTo(right.name));
    } on FileSystemException {
      rawEntries = const [];
    }
    // coverage:ignore-start
    // This write-through branch is disabled on Windows for the same reason.
    if (!Platform.isWindows) {
      _directoryListCache[directory] = _DirectoryListCacheEntry(
        expiresAt: DateTime.now().add(_directoryListCacheTtl),
        modifiedAt: directoryInfo.modified,
        changedAt: directoryInfo.changed,
        entries: rawEntries,
      );
      _pruneCache();
    }
    // coverage:ignore-end
  }
  final entries = <_ChildEntry>[];
  for (final raw in rawEntries) {
    final resolved = await _resolveChild(directory, raw);
    if (resolved != null) entries.add(resolved);
  }
  entries.sort((left, right) => left.name.compareTo(right.name));
  return entries;
}

_RawChildEntry? _rawChildEntry(FileSystemEntity entity) => switch (entity) {
  Directory() => _RawChildEntry(
    name: p.basename(entity.path),
    kind: _RawEntryKind.directory,
  ),
  File() => _RawChildEntry(
    name: p.basename(entity.path),
    kind: _RawEntryKind.file,
  ),
  Link() => _RawChildEntry(
    name: p.basename(entity.path),
    kind: _RawEntryKind.symlink,
  ),
  _ => null,
};

Future<_ChildEntry?> _resolveChild(
  String directory,
  _RawChildEntry entry,
) async {
  final visiblePath = p.join(directory, entry.name);
  if (entry.kind != _RawEntryKind.symlink) {
    return _ChildEntry(
      name: entry.name,
      resolvedPath: visiblePath,
      kind: entry.kind == _RawEntryKind.directory
          ? DirectorySuggestionKind.directory
          : DirectorySuggestionKind.file,
    );
  }
  final resolvedPath = await _resolvePath(visiblePath);
  if (resolvedPath == null) return null;
  final kind = await _entryKind(resolvedPath);
  return kind == null
      ? null
      : _ChildEntry(name: entry.name, resolvedPath: resolvedPath, kind: kind);
}

Future<DirectorySuggestionKind?> _entryKind(String path) async {
  try {
    return switch (await FileSystemEntity.type(path, followLinks: true)) {
      FileSystemEntityType.directory => DirectorySuggestionKind.directory,
      FileSystemEntityType.file => DirectorySuggestionKind.file,
      _ => null,
    };
  } on FileSystemException {
    return null;
  }
}

// coverage:ignore-start
// This cache is unreachable on Windows; macOS/Linux platform tests cover it.
void _pruneCache() {
  if (_directoryListCache.length <= _directoryListCacheMaxEntries) return;
  final now = DateTime.now();
  _directoryListCache.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
  while (_directoryListCache.length > _directoryListCacheMaxEntries) {
    _directoryListCache.remove(_directoryListCache.keys.first);
  }
}
// coverage:ignore-end

int _normalizeLimit(int? limit) => (limit ?? _defaultLimit).clamp(1, _maxLimit);

String _normalizeRelativePath(String root, String absolutePath) {
  final relative = p.relative(absolutePath, from: root);
  return relative.isEmpty ? '.' : relative.replaceAll(r'\', '/');
}

int? _scoreFuzzySubsequence(String query, String candidate) {
  var queryIndex = 0;
  var first = -1;
  var previous = -1;
  var gaps = 0;
  for (
    var index = 0;
    index < candidate.length && queryIndex < query.length;
    index += 1
  ) {
    if (candidate[index] != query[queryIndex]) continue;
    if (first < 0) first = index;
    if (previous >= 0) gaps += index - previous - 1;
    previous = index;
    queryIndex += 1;
  }
  return queryIndex == query.length && first >= 0 ? first + gaps : null;
}

bool _sameEntry(
  DirectorySuggestionEntry left,
  DirectorySuggestionEntry right,
) => left.path == right.path && left.kind == right.kind;

bool _isPathInsideRoot(String root, String candidate) {
  final normalizedRoot = _pathKey(root);
  final normalizedCandidate = _pathKey(candidate);
  return normalizedCandidate == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedCandidate);
}

String _pathKey(String value) {
  final normalized = p.normalize(p.absolute(value));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

final class _SearchInput {
  const _SearchInput({
    required this.root,
    required this.plan,
    required this.includeDirectories,
    required this.includeFiles,
    required this.matchMode,
    required this.pathFormat,
    required this.hiddenDirectoryNames,
    required this.limit,
    required this.maxDepth,
    required this.maxEntriesScanned,
    required this.confidentResultScanThreshold,
  });

  final String root;
  final _QueryPlan plan;
  final bool includeDirectories;
  final bool includeFiles;
  final DirectorySuggestionMatchMode matchMode;
  final DirectorySuggestionPathFormat pathFormat;
  final Set<String> hiddenDirectoryNames;
  final int limit;
  final int maxDepth;
  final int maxEntriesScanned;
  final int? confidentResultScanThreshold;
}

final class _QueryPlan {
  const _QueryPlan({
    required this.isPathQuery,
    required this.parentPart,
    required this.searchTerm,
    required this.normalizedQuery,
    this.browseExactPath = false,
  });

  final bool isPathQuery;
  final String parentPart;
  final String searchTerm;
  final String normalizedQuery;
  final bool browseExactPath;
}

final class _NormalizedQueryInput {
  const _NormalizedQueryInput({
    required this.typed,
    required this.normalized,
    required this.rooted,
    required this.isAbsolute,
  });

  final String typed;
  final String normalized;
  final bool rooted;
  final bool isAbsolute;
}

class _ChildEntry {
  const _ChildEntry({
    required this.name,
    required this.resolvedPath,
    required this.kind,
  });

  final String name;
  final String resolvedPath;
  final DirectorySuggestionKind kind;
}

final class _TraversedEntry extends _ChildEntry {
  const _TraversedEntry({
    required super.name,
    required super.resolvedPath,
    required super.kind,
    required this.visiblePath,
    required this.depth,
  });

  final String visiblePath;
  final int depth;
}

final class _RankedEntry {
  const _RankedEntry({
    required this.path,
    required this.kind,
    required this.matchTier,
    required this.segmentIndex,
    required this.matchOffset,
    required this.fuzzyScore,
    required this.depth,
  });

  final String path;
  final DirectorySuggestionKind kind;
  final int matchTier;
  final int segmentIndex;
  final int matchOffset;
  final int fuzzyScore;
  final int depth;
}

enum _RawEntryKind { file, directory, symlink }

final class _RawChildEntry {
  const _RawChildEntry({required this.name, required this.kind});

  final String name;
  final _RawEntryKind kind;
}

final class _DirectoryListCacheEntry {
  const _DirectoryListCacheEntry({
    required this.expiresAt,
    required this.modifiedAt,
    required this.changedAt,
    required this.entries,
  });

  final DateTime expiresAt;
  final DateTime modifiedAt;
  final DateTime changedAt;
  final List<_RawChildEntry> entries;
}
