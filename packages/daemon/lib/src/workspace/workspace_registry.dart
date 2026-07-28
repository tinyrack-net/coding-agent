/// Paseo-compatible project and workspace registries.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

enum PersistedProjectKind {
  git,
  nonGit;

  static PersistedProjectKind fromWire(Object? value) => switch (value) {
    'git' => git,
    'non_git' => nonGit,
    _ => throw FormatException('Unknown persisted project kind: $value'),
  };

  String get wireName => this == git ? 'git' : 'non_git';
}

enum PersistedWorkspaceKind {
  localCheckout,
  worktree,
  directory;

  static PersistedWorkspaceKind fromWire(Object? value) => switch (value) {
    'local_checkout' => localCheckout,
    'worktree' => worktree,
    'directory' => directory,
    _ => throw FormatException('Unknown persisted workspace kind: $value'),
  };

  String get wireName => switch (this) {
    localCheckout => 'local_checkout',
    worktree => 'worktree',
    directory => 'directory',
  };
}

final class PersistedProjectRecord {
  const PersistedProjectRecord({
    required this.projectId,
    required this.rootPath,
    required this.kind,
    required this.displayName,
    required this.customName,
    required this.createdAt,
    required this.updatedAt,
    required this.archivedAt,
  });

  final String projectId;
  final String rootPath;
  final PersistedProjectKind kind;
  final String displayName;
  final String? customName;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;

  factory PersistedProjectRecord.fromJson(Map<String, Object?> json) =>
      PersistedProjectRecord(
        projectId: _string(json, 'projectId'),
        rootPath: _string(json, 'rootPath'),
        kind: PersistedProjectKind.fromWire(json['kind']),
        displayName: _string(json, 'displayName'),
        customName: _nullableString(json, 'customName'),
        createdAt: _string(json, 'createdAt'),
        updatedAt: _string(json, 'updatedAt'),
        archivedAt: _nullableString(json, 'archivedAt'),
      );

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'rootPath': rootPath,
    'kind': kind.wireName,
    'displayName': displayName,
    'customName': customName,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'archivedAt': archivedAt,
  };

  PersistedProjectRecord copyWith({
    PersistedProjectKind? kind,
    String? displayName,
    Object? customName = _absent,
    String? updatedAt,
    Object? archivedAt = _absent,
  }) => PersistedProjectRecord(
    projectId: projectId,
    rootPath: rootPath,
    kind: kind ?? this.kind,
    displayName: displayName ?? this.displayName,
    customName: identical(customName, _absent)
        ? this.customName
        : customName as String?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    archivedAt: identical(archivedAt, _absent)
        ? this.archivedAt
        : archivedAt as String?,
  );
}

final class PersistedWorkspaceRecord {
  const PersistedWorkspaceRecord({
    required this.workspaceId,
    required this.projectId,
    required this.cwd,
    required this.kind,
    required this.displayName,
    required this.title,
    required this.branch,
    required this.worktreeRoot,
    required this.baseBranch,
    required this.isPaseoOwnedWorktree,
    required this.mainRepoRoot,
    required this.createdAt,
    required this.updatedAt,
    required this.archivedAt,
    required this.pinnedAt,
  });

  final String workspaceId;
  final String projectId;
  final String cwd;
  final PersistedWorkspaceKind kind;
  final String displayName;
  final String? title;
  final String? branch;
  final String? worktreeRoot;
  final String? baseBranch;
  final bool isPaseoOwnedWorktree;
  final String? mainRepoRoot;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
  final String? pinnedAt;

  factory PersistedWorkspaceRecord.fromJson(Map<String, Object?> json) =>
      PersistedWorkspaceRecord(
        workspaceId: _string(json, 'workspaceId'),
        projectId: _string(json, 'projectId'),
        cwd: _string(json, 'cwd'),
        kind: PersistedWorkspaceKind.fromWire(json['kind']),
        displayName: _string(json, 'displayName'),
        title: _nullableString(json, 'title'),
        branch: _nullableString(json, 'branch'),
        worktreeRoot: _nullableString(json, 'worktreeRoot'),
        baseBranch: _nullableString(json, 'baseBranch'),
        isPaseoOwnedWorktree: _boolWithDefault(
          json,
          'isPaseoOwnedWorktree',
          false,
        ),
        mainRepoRoot: _nullableString(json, 'mainRepoRoot'),
        createdAt: _string(json, 'createdAt'),
        updatedAt: _string(json, 'updatedAt'),
        archivedAt: _nullableString(json, 'archivedAt'),
        pinnedAt: _nullableString(json, 'pinnedAt'),
      );

  Map<String, Object?> toJson() => {
    'workspaceId': workspaceId,
    'projectId': projectId,
    'cwd': cwd,
    'kind': kind.wireName,
    'displayName': displayName,
    'title': title,
    'branch': branch,
    'worktreeRoot': worktreeRoot,
    'baseBranch': baseBranch,
    'isPaseoOwnedWorktree': isPaseoOwnedWorktree,
    'mainRepoRoot': mainRepoRoot,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'archivedAt': archivedAt,
    'pinnedAt': pinnedAt,
  };

  PersistedWorkspaceRecord copyWith({
    String? projectId,
    String? cwd,
    PersistedWorkspaceKind? kind,
    String? displayName,
    Object? title = _absent,
    Object? branch = _absent,
    Object? worktreeRoot = _absent,
    Object? baseBranch = _absent,
    bool? isPaseoOwnedWorktree,
    Object? mainRepoRoot = _absent,
    String? updatedAt,
    Object? archivedAt = _absent,
    Object? pinnedAt = _absent,
  }) => PersistedWorkspaceRecord(
    workspaceId: workspaceId,
    projectId: projectId ?? this.projectId,
    cwd: cwd ?? this.cwd,
    kind: kind ?? this.kind,
    displayName: displayName ?? this.displayName,
    title: identical(title, _absent) ? this.title : title as String?,
    branch: identical(branch, _absent) ? this.branch : branch as String?,
    worktreeRoot: identical(worktreeRoot, _absent)
        ? this.worktreeRoot
        : worktreeRoot as String?,
    baseBranch: identical(baseBranch, _absent)
        ? this.baseBranch
        : baseBranch as String?,
    isPaseoOwnedWorktree: isPaseoOwnedWorktree ?? this.isPaseoOwnedWorktree,
    mainRepoRoot: identical(mainRepoRoot, _absent)
        ? this.mainRepoRoot
        : mainRepoRoot as String?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    archivedAt: identical(archivedAt, _absent)
        ? this.archivedAt
        : archivedAt as String?,
    pinnedAt: identical(pinnedAt, _absent)
        ? this.pinnedAt
        : pinnedAt as String?,
  );
}

const Object _absent = Object();

enum RegistryMutationKind { upsert, archive, remove }

final class ProjectMutation {
  const ProjectMutation({
    required this.kind,
    required this.projectId,
    required this.project,
  });

  final RegistryMutationKind kind;
  final String projectId;
  final PersistedProjectRecord? project;
}

final class WorkspaceMutation {
  const WorkspaceMutation({
    required this.kind,
    required this.workspaceId,
    required this.workspace,
    this.expectsInitialAgent = false,
    this.removedProjectId,
  });

  final RegistryMutationKind kind;
  final String workspaceId;
  final PersistedWorkspaceRecord? workspace;
  final bool expectsInitialAgent;
  final String? removedProjectId;
}

typedef ProjectMutationListener =
    FutureOr<void> Function(ProjectMutation mutation);
typedef WorkspaceMutationListener =
    FutureOr<void> Function(WorkspaceMutation mutation);

final class FileBackedProjectRegistry {
  FileBackedProjectRegistry({
    required String filePath,
    String Function()? projectIdFactory,
  }) : _registry = _FileRegistry<PersistedProjectRecord>(
         filePath: filePath,
         getId: (record) => record.projectId,
         decode: PersistedProjectRecord.fromJson,
         encode: (record) => record.toJson(),
       ),
       _projectIdFactory = projectIdFactory ?? generateProjectId;

  final _FileRegistry<PersistedProjectRecord> _registry;
  final String Function() _projectIdFactory;
  final _SerialQueue _allocationQueue = _SerialQueue();
  final Set<ProjectMutationListener> _listeners = {};

  Future<void> initialize() => _registry.initialize();
  Future<bool> existsOnDisk() => _registry.existsOnDisk();
  Future<List<PersistedProjectRecord>> list() => _registry.list();
  Future<PersistedProjectRecord?> get(String projectId) =>
      _registry.get(projectId);

  Future<PersistedProjectRecord> getOrCreateActiveByRoot({
    required String rootPath,
    required PersistedProjectKind kind,
    required String displayName,
    required String timestamp,
  }) => _allocationQueue.run(() async {
    final active =
        (await list())
            .where(
              (project) =>
                  project.archivedAt == null &&
                  areEquivalentPaths(project.rootPath, rootPath),
            )
            .toList()
          ..sort((left, right) {
            final byCreated = left.createdAt.compareTo(right.createdAt);
            return byCreated != 0
                ? byCreated
                : left.projectId.compareTo(right.projectId);
          });
    if (active.isNotEmpty) {
      final existing = active.first;
      if (existing.kind == kind) return existing;
      final refreshed = existing.copyWith(kind: kind, updatedAt: timestamp);
      await upsert(refreshed);
      return refreshed;
    }

    while (true) {
      final projectId = _projectIdFactory();
      if (await get(projectId) != null) continue;
      final record = createPersistedProjectRecord(
        projectId: projectId,
        rootPath: rootPath,
        kind: kind,
        displayName: displayName,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      await upsert(record);
      return record;
    }
  });

  Future<void> upsert(PersistedProjectRecord record) async {
    await _registry.upsert(record);
    await _notify(
      ProjectMutation(
        kind: RegistryMutationKind.upsert,
        projectId: record.projectId,
        project: record,
      ),
    );
  }

  Future<void> archive(String projectId, String archivedAt) async {
    final archived = await _registry.update(projectId, (record) {
      if (record.archivedAt != null) return null;
      return record.copyWith(updatedAt: archivedAt, archivedAt: archivedAt);
    });
    if (archived == null) return;
    await _notify(
      ProjectMutation(
        kind: RegistryMutationKind.archive,
        projectId: projectId,
        project: archived,
      ),
    );
  }

  Future<void> remove(String projectId) async {
    final removed = await _registry.remove(projectId);
    if (removed == null) return;
    await _notify(
      ProjectMutation(
        kind: RegistryMutationKind.remove,
        projectId: projectId,
        project: null,
      ),
    );
  }

  void Function() subscribeToMutations(ProjectMutationListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  Future<void> _notify(ProjectMutation mutation) =>
      Future.wait(_listeners.map((listener) async => listener(mutation)));
}

final class FileBackedWorkspaceRegistry {
  FileBackedWorkspaceRegistry({required String filePath})
    : _registry = _FileRegistry<PersistedWorkspaceRecord>(
        filePath: filePath,
        getId: (record) => record.workspaceId,
        decode: PersistedWorkspaceRecord.fromJson,
        encode: (record) => record.toJson(),
      );

  final _FileRegistry<PersistedWorkspaceRecord> _registry;
  final Set<WorkspaceMutationListener> _listeners = {};

  Future<void> initialize() => _registry.initialize();
  Future<bool> existsOnDisk() => _registry.existsOnDisk();
  Future<List<PersistedWorkspaceRecord>> list() => _registry.list();
  Future<PersistedWorkspaceRecord?> get(String workspaceId) =>
      _registry.get(workspaceId);

  Future<void> upsert(
    PersistedWorkspaceRecord record, {
    bool expectsInitialAgent = false,
  }) async {
    await _registry.upsert(record);
    await _notify(
      WorkspaceMutation(
        kind: RegistryMutationKind.upsert,
        workspaceId: record.workspaceId,
        workspace: record,
        expectsInitialAgent: expectsInitialAgent,
      ),
    );
  }

  Future<PersistedWorkspaceRecord?> update(
    String workspaceId,
    PersistedWorkspaceRecord Function(PersistedWorkspaceRecord) updater,
  ) async {
    final updated = await _registry.update(
      workspaceId,
      (record) => updater(record),
    );
    if (updated != null) {
      await _notify(
        WorkspaceMutation(
          kind: RegistryMutationKind.upsert,
          workspaceId: workspaceId,
          workspace: updated,
        ),
      );
    }
    return updated;
  }

  /// Paseo archives an existing workspace even when it was already archived.
  Future<void> archive(
    String workspaceId,
    String archivedAt, {
    String? removedProjectId,
  }) async {
    final archived = await _registry.update(
      workspaceId,
      (record) =>
          record.copyWith(updatedAt: archivedAt, archivedAt: archivedAt),
    );
    if (archived == null) return;
    await _notify(
      WorkspaceMutation(
        kind: RegistryMutationKind.archive,
        workspaceId: workspaceId,
        workspace: archived,
        removedProjectId: removedProjectId,
      ),
    );
  }

  Future<PersistedWorkspaceRecord?> restore(
    String workspaceId,
    String restoredAt,
  ) async {
    final restored = await _registry.update(
      workspaceId,
      (record) => record.copyWith(updatedAt: restoredAt, archivedAt: null),
    );
    if (restored != null) {
      await _notify(
        WorkspaceMutation(
          kind: RegistryMutationKind.upsert,
          workspaceId: workspaceId,
          workspace: restored,
        ),
      );
    }
    return restored;
  }

  Future<void> remove(String workspaceId) async {
    final removed = await _registry.remove(workspaceId);
    if (removed == null) return;
    await _notify(
      WorkspaceMutation(
        kind: RegistryMutationKind.remove,
        workspaceId: workspaceId,
        workspace: null,
      ),
    );
  }

  Future<List<PersistedWorkspaceRecord>> activeSharingWorktreeRoot(
    String worktreeRoot,
  ) async => [
    for (final workspace in await list())
      if (workspace.archivedAt == null &&
          workspace.worktreeRoot != null &&
          areEquivalentPaths(workspace.worktreeRoot!, worktreeRoot))
        workspace,
  ];

  Future<int> activeWorktreeReferenceCount(String worktreeRoot) async =>
      (await activeSharingWorktreeRoot(worktreeRoot)).length;

  void Function() subscribeToMutations(WorkspaceMutationListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  Future<void> _notify(WorkspaceMutation mutation) =>
      Future.wait(_listeners.map((listener) async => listener(mutation)));
}

final class WorkspaceRegistries {
  WorkspaceRegistries({
    required String dataDir,
    String Function()? projectIdFactory,
  }) : projects = FileBackedProjectRegistry(
         filePath: p.join(dataDir, 'projects.json'),
         projectIdFactory: projectIdFactory,
       ),
       workspaces = FileBackedWorkspaceRegistry(
         filePath: p.join(dataDir, 'workspaces.json'),
       );

  final FileBackedProjectRegistry projects;
  final FileBackedWorkspaceRegistry workspaces;

  Future<void> initialize() async {
    await Future.wait([projects.initialize(), workspaces.initialize()]);
  }
}

PersistedProjectRecord createPersistedProjectRecord({
  required String projectId,
  required String rootPath,
  required PersistedProjectKind kind,
  required String displayName,
  String? customName,
  required String createdAt,
  required String updatedAt,
  String? archivedAt,
}) => PersistedProjectRecord(
  projectId: projectId,
  rootPath: rootPath,
  kind: kind,
  displayName: displayName,
  customName: customName,
  createdAt: createdAt,
  updatedAt: updatedAt,
  archivedAt: archivedAt,
);

PersistedWorkspaceRecord createPersistedWorkspaceRecord({
  required String workspaceId,
  required String projectId,
  required String cwd,
  required PersistedWorkspaceKind kind,
  required String displayName,
  String? title,
  String? branch,
  String? worktreeRoot,
  String? baseBranch,
  bool isPaseoOwnedWorktree = false,
  String? mainRepoRoot,
  required String createdAt,
  required String updatedAt,
  String? archivedAt,
  String? pinnedAt,
}) => PersistedWorkspaceRecord(
  workspaceId: workspaceId,
  projectId: projectId,
  cwd: cwd,
  kind: kind,
  displayName: displayName,
  title: title,
  branch: branch,
  worktreeRoot: worktreeRoot,
  baseBranch: baseBranch,
  isPaseoOwnedWorktree: isPaseoOwnedWorktree,
  mainRepoRoot: mainRepoRoot,
  createdAt: createdAt,
  updatedAt: updatedAt,
  archivedAt: archivedAt,
  pinnedAt: pinnedAt,
);

String resolveProjectDisplayName(PersistedProjectRecord record) =>
    record.customName ?? record.displayName;

String resolveWorkspaceDisplayName(PersistedWorkspaceRecord record) =>
    record.title ?? record.displayName;

String generateProjectId() => _generateId('prj_');
String generateWorkspaceId() => _generateId('wks_');

String _generateId(String prefix) {
  final random = Random.secure();
  final bytes = List<int>.generate(8, (_) => random.nextInt(256));
  return '$prefix${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}

bool areEquivalentPaths(String left, String right) {
  String normalize(String value) {
    var normalized = p.normalize(p.absolute(value));
    if (Platform.isWindows) normalized = normalized.toLowerCase();
    return normalized;
  }

  return normalize(left) == normalize(right);
}

final class _FileRegistry<T> {
  _FileRegistry({
    required this.filePath,
    required this.getId,
    required this.decode,
    required this.encode,
  });

  final String filePath;
  final String Function(T record) getId;
  final T Function(Map<String, Object?> json) decode;
  final Map<String, Object?> Function(T record) encode;
  final Map<String, T> _cache = {};
  final _SerialQueue _queue = _SerialQueue();
  bool _loaded = false;

  Future<void> initialize() => _ensureLoaded();
  Future<bool> existsOnDisk() => File(filePath).exists();

  Future<List<T>> list() async {
    await _ensureLoaded();
    return List.unmodifiable(_cache.values);
  }

  Future<T?> get(String id) async {
    await _ensureLoaded();
    return _cache[id];
  }

  Future<void> upsert(T record) => _queue.run(() async {
    await _ensureLoaded();
    _cache[getId(record)] = record;
    await _persist();
  });

  Future<T?> update(String id, T? Function(T record) updater) =>
      _queue.run(() async {
        await _ensureLoaded();
        final existing = _cache[id];
        if (existing == null) return null;
        final next = updater(existing);
        if (next == null) return null;
        _cache[id] = next;
        await _persist();
        return next;
      });

  Future<T?> remove(String id) => _queue.run(() async {
    await _ensureLoaded();
    final removed = _cache.remove(id);
    if (removed != null) await _persist();
    return removed;
  });

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final file = File(filePath);
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! List) {
          throw const FormatException('Registry root must be an array');
        }
        for (final item in decoded) {
          if (item is! Map) {
            throw const FormatException('Registry entries must be objects');
          }
          final record = decode(item.cast<String, Object?>());
          _cache[getId(record)] = record;
        }
      } on FileSystemException {
        // Match Paseo: a registry read failure leaves the in-memory store empty.
      } on FormatException {
        // Match Paseo: invalid registry content is logged upstream and ignored.
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final temp = File('$filePath.tmp');
    await temp.writeAsString(
      jsonEncode(_cache.values.map(encode).toList()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}

final class _SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

bool _boolWithDefault(
  Map<String, Object?> json,
  String key,
  bool defaultValue,
) {
  final value = json[key];
  if (value == null) return defaultValue;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}
