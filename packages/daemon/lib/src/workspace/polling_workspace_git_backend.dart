import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../forge/forge_models.dart';
import '../forge/workspace_forge_status_service.dart';
import '../git/git_runner.dart';
import 'workspace_git_observer_service.dart';

/// The local Git portion of Paseo's `WorkspaceGitRuntimeSnapshot`.
///
/// The backend caches local and forge snapshots separately, then emits their
/// combined fingerprint. This preserves Paseo's faster refresh cadence while
/// CI checks are pending without re-running rich probes on every status poll.
final class WorkspaceLocalGitSnapshot {
  const WorkspaceLocalGitSnapshot({
    required this.cwd,
    required this.repoRoot,
    required this.mainRepoRoot,
    required this.currentBranch,
    required this.headSha,
    required this.remoteUrl,
    required this.isDirty,
    required this.baseRef,
    required this.aheadBehind,
    required this.aheadOfOrigin,
    required this.behindOfOrigin,
    required this.diffStat,
  });

  final String cwd;
  final String repoRoot;
  final String? mainRepoRoot;
  final String? currentBranch;
  final String? headSha;
  final String? remoteUrl;
  final bool isDirty;
  final String? baseRef;
  final WorkspaceAheadBehind? aheadBehind;
  final num? aheadOfOrigin;
  final num? behindOfOrigin;
  final WorkspaceDiffStat diffStat;

  bool get hasRemote => remoteUrl != null;

  WorkspaceGitRuntime toWire({required bool isPaseoOwnedWorktree}) =>
      WorkspaceGitRuntime(
        currentBranch: currentBranch,
        remoteUrl: remoteUrl,
        isPaseoOwnedWorktree: isPaseoOwnedWorktree,
        isDirty: isDirty,
        aheadBehind: aheadBehind,
        aheadOfOrigin: aheadOfOrigin,
        behindOfOrigin: behindOfOrigin,
      );

  String get fingerprint => jsonEncode([
    repoRoot,
    mainRepoRoot,
    currentBranch,
    headSha,
    remoteUrl,
    isDirty,
    baseRef,
    aheadBehind?.ahead,
    aheadBehind?.behind,
    aheadOfOrigin,
    behindOfOrigin,
    diffStat.additions,
    diffStat.deletions,
  ]);
}

final class PollingWorkspaceGitBackend implements WorkspaceGitObserverBackend {
  PollingWorkspaceGitBackend({
    GitRunner? runner,
    this.forgeStatus,
    this.pollInterval = const Duration(seconds: 5),
    this.richRefreshInterval = const Duration(minutes: 2),
    this.pendingForgeRefreshInterval = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _runner = runner ?? const GitRunner(),
       _now = now ?? DateTime.now;

  final GitRunner _runner;
  final WorkspaceForgeStatusService? forgeStatus;
  final Duration pollInterval;
  final Duration richRefreshInterval;
  final Duration pendingForgeRefreshInterval;
  final DateTime Function() _now;
  final Map<String, _PollingGitTarget> _targets = {};
  final List<Future<void>> _disposeFutures = [];
  bool _disposed = false;

  WorkspaceLocalGitSnapshot? peekSnapshot(String cwd) =>
      _targets[p.normalize(p.absolute(cwd))]?.snapshot;

  WorkspaceForgeSnapshot? peekForgeSnapshot(String cwd) =>
      _targets[p.normalize(p.absolute(cwd))]?.forgeSnapshot;

  void setBaseRef(String cwd, String? baseRef) {
    final normalized = p.normalize(p.absolute(cwd));
    final target = _targets.putIfAbsent(
      normalized,
      () => _PollingGitTarget(cwd: normalized),
    );
    final next = baseRef?.trim();
    target.baseRef = next == null || next.isEmpty ? null : next;
    unawaited(refreshNow(normalized));
  }

  @override
  WorkspaceGitSubscription registerWorkspace(
    String cwd,
    void Function(WorkspaceGitObserverSnapshot snapshot) onSnapshot,
  ) {
    if (_disposed) throw StateError('Workspace Git backend is disposed');
    final normalized = p.normalize(p.absolute(cwd));
    final target = _targets.putIfAbsent(
      normalized,
      () => _PollingGitTarget(cwd: normalized),
    );
    target.listeners.add(onSnapshot);
    target.timer ??= Timer.periodic(
      pollInterval,
      (_) => unawaited(refreshNow(normalized, force: false)),
    );
    unawaited(refreshNow(normalized));
    var subscribed = true;
    Future<void>? inFlightAtUnsubscribe;
    void unsubscribe() {
      if (!subscribed) return;
      subscribed = false;
      target.listeners.remove(onSnapshot);
      if (target.listeners.isEmpty) {
        target.timer?.cancel();
        inFlightAtUnsubscribe = target.refreshInFlight;
        _targets.remove(normalized);
      }
    }

    return WorkspaceGitSubscription(
      unsubscribe: unsubscribe,
      unsubscribeAndWait: () async {
        unsubscribe();
        try {
          await inFlightAtUnsubscribe;
        } on Object {
          // The target may disappear while its final snapshot is settling.
        }
      },
    );
  }

  Future<void> refreshNow(String cwd, {bool force = true}) async {
    final normalized = p.normalize(p.absolute(cwd));
    final target = _targets[normalized];
    if (target == null) return;
    final existing = target.refreshInFlight;
    if (existing != null) return existing;
    final refresh = _refreshTarget(normalized, target, force: force);
    target.refreshInFlight = refresh;
    try {
      await refresh;
    } finally {
      if (identical(target.refreshInFlight, refresh)) {
        target.refreshInFlight = null;
      }
    }
  }

  Future<void> _refreshTarget(
    String normalized,
    _PollingGitTarget target, {
    required bool force,
  }) async {
    final status = await _runner.run(
      ['status', '--porcelain=v1', '--branch'],
      cwd: normalized,
      check: false,
    );
    if (!status.ok) return;
    final now = _now();
    final refreshInterval =
        target.forgeSnapshot?.pullRequest?.checksStatus ==
            ForgeChecksStatus.pending
        ? pendingForgeRefreshInterval
        : richRefreshInterval;
    if (!force &&
        target.statusFingerprint == status.stdout &&
        target.lastRichRefreshAt != null &&
        now.difference(target.lastRichRefreshAt!) < refreshInterval) {
      return;
    }
    target.statusFingerprint = status.stdout;
    final snapshot = await _loadSnapshot(
      normalized,
      status.stdout,
      target.baseRef,
    );
    target.lastRichRefreshAt = now;
    final forgeSnapshot = await forgeStatus?.load(
      cwd: normalized,
      remoteUrl: snapshot.remoteUrl,
      headRef: snapshot.currentBranch,
      headSha: snapshot.headSha,
      force: force,
    );
    final fingerprint = jsonEncode([
      snapshot.fingerprint,
      forgeSnapshot?.forge,
      forgeSnapshot?.authState.wireName,
      forgeSnapshot?.featuresEnabled,
      forgeSnapshot?.pullRequest?.toJson(),
      forgeSnapshot?.error,
    ]);
    if (target.fingerprint == fingerprint) return;
    target.fingerprint = fingerprint;
    target.snapshot = snapshot;
    target.forgeSnapshot = forgeSnapshot;
    final observerSnapshot = WorkspaceGitObserverSnapshot(
      currentBranch: snapshot.currentBranch,
      value: snapshot,
    );
    for (final listener in target.listeners.toList(growable: false)) {
      listener(observerSnapshot);
    }
  }

  Future<WorkspaceLocalGitSnapshot> _loadSnapshot(
    String cwd,
    String porcelain,
    String? baseRef,
  ) async {
    final repoRoot = await _gitOutput(cwd, ['rev-parse', '--show-toplevel']);
    final commonDirRaw = await _gitOutput(cwd, [
      'rev-parse',
      '--git-common-dir',
    ]);
    final commonDir = commonDirRaw == null
        ? null
        : p.normalize(
            p.isAbsolute(commonDirRaw)
                ? commonDirRaw
                : p.join(cwd, commonDirRaw),
          );
    final inferredMainRoot = commonDir == null
        ? null
        : p.basename(commonDir) == '.git'
        ? p.dirname(commonDir)
        : null;
    final effectiveRepoRoot = repoRoot ?? cwd;
    final mainRepoRoot =
        inferredMainRoot != null &&
            !_sameDirectory(inferredMainRoot, effectiveRepoRoot)
        ? inferredMainRoot
        : null;
    final currentBranch = await _gitOutput(cwd, [
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ]);
    final headSha = await _gitOutput(cwd, ['rev-parse', 'HEAD']);
    final remoteUrl = await _gitOutput(cwd, [
      'config',
      '--get',
      'remote.origin.url',
    ]);
    final originCounts = await _gitOutput(cwd, [
      'rev-list',
      '--left-right',
      '--count',
      'HEAD...@{upstream}',
    ]);
    final (aheadOfOrigin, behindOfOrigin) = _parseAheadBehind(originCounts);
    final baseCounts =
        baseRef == null ||
            currentBranch == null ||
            _normalizeLocalBranch(baseRef) == currentBranch
        ? null
        : await _gitOutput(cwd, [
            'rev-list',
            '--left-right',
            '--count',
            '$baseRef...$currentBranch',
          ]);
    final (behindBase, aheadBase) = _parseAheadBehind(baseCounts);
    final diffStat = await _loadDiffStat(cwd);
    return WorkspaceLocalGitSnapshot(
      cwd: cwd,
      repoRoot: effectiveRepoRoot,
      mainRepoRoot: mainRepoRoot,
      currentBranch: currentBranch,
      headSha: headSha,
      remoteUrl: remoteUrl,
      isDirty: porcelain
          .split(RegExp(r'\r?\n'))
          .any((line) => line.isNotEmpty && !line.startsWith('## ')),
      baseRef: baseRef,
      aheadBehind: aheadBase == null || behindBase == null
          ? null
          : WorkspaceAheadBehind(ahead: aheadBase, behind: behindBase),
      aheadOfOrigin: aheadOfOrigin,
      behindOfOrigin: behindOfOrigin,
      diffStat: diffStat,
    );
  }

  Future<WorkspaceDiffStat> _loadDiffStat(String cwd) async {
    var additions = 0;
    var deletions = 0;
    final tracked = await _gitOutput(cwd, ['diff', '--numstat', 'HEAD']);
    for (final line in (tracked ?? '').split(RegExp(r'\r?\n'))) {
      final fields = line.split('\t');
      if (fields.length < 3) continue;
      additions += int.tryParse(fields[0]) ?? 0;
      deletions += int.tryParse(fields[1]) ?? 0;
    }
    final untracked = await _gitOutput(cwd, [
      'ls-files',
      '--others',
      '--exclude-standard',
      '-z',
    ]);
    for (final relativePath in (untracked ?? '').split('\x00')) {
      if (relativePath.isEmpty) continue;
      final file = File(p.join(cwd, relativePath));
      if (!file.existsSync() || await file.length() > 1024 * 1024) continue;
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) continue;
      if (bytes.isEmpty) continue;
      additions += bytes.where((byte) => byte == 10).length;
      if (bytes.last != 10) additions += 1;
    }
    return WorkspaceDiffStat(additions: additions, deletions: deletions);
  }

  Future<String?> _gitOutput(String cwd, List<String> args) async {
    final result = await _runner.run(args, cwd: cwd, check: false);
    if (!result.ok) return null;
    final value = result.stdout.trim();
    return value.isEmpty ? null : value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final target in _targets.values) {
      target.timer?.cancel();
      final refresh = target.refreshInFlight;
      if (refresh != null) {
        _disposeFutures.add(() async {
          try {
            await refresh;
          } on Object {
            // Shutdown is best-effort, but the in-flight process must settle
            // before callers remove its working directory.
          }
        }());
      }
    }
    _targets.clear();
  }

  /// Stops future polls and waits for Git processes already in flight.
  ///
  /// Daemon shutdown uses this stronger boundary so tests and production
  /// cleanup cannot delete a workspace while a poll still uses it as cwd.
  Future<void> disposeAndWait() async {
    dispose();
    if (_disposeFutures.isEmpty) return;
    await Future.wait(_disposeFutures);
    _disposeFutures.clear();
  }
}

final class _PollingGitTarget {
  _PollingGitTarget({required this.cwd});

  final String cwd;
  final Set<void Function(WorkspaceGitObserverSnapshot)> listeners = {};
  Timer? timer;
  String? statusFingerprint;
  String? fingerprint;
  WorkspaceLocalGitSnapshot? snapshot;
  WorkspaceForgeSnapshot? forgeSnapshot;
  String? baseRef;
  DateTime? lastRichRefreshAt;
  Future<void>? refreshInFlight;
}

(num?, num?) _parseAheadBehind(String? value) {
  if (value == null) return (null, null);
  final fields = value.trim().split(RegExp(r'\s+'));
  if (fields.length != 2) return (null, null);
  return (int.tryParse(fields[0]), int.tryParse(fields[1]));
}

bool _sameDirectory(String left, String right) {
  try {
    return p.equals(
      Directory(left).resolveSymbolicLinksSync(),
      Directory(right).resolveSymbolicLinksSync(),
    );
  } on FileSystemException {
    return p.equals(left, right);
  }
}

String _normalizeLocalBranch(String value) => value
    .replaceFirst(RegExp(r'^refs/remotes/origin/'), '')
    .replaceFirst(RegExp(r'^refs/heads/'), '')
    .replaceFirst(RegExp(r'^origin/'), '');
