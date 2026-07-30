/// Git operations backing the M4 workspace RPCs: worktree management and
/// structured diffs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../forge/git_remote.dart';
import 'git_runner.dart';
import 'unified_diff_parser.dart';
import 'worktree_metadata.dart';

/// Untracked files larger than this are reported as binary without content.
const int _maxUntrackedBytes = 1024 * 1024;
const int _perFileDiffMaxBytes = 1024 * 1024;
const int _totalDiffMaxBytes = 2 * 1024 * 1024;
const int _checkoutBaseCommitLimit = 10;
const String _commitFieldSeparator = '\x00';
const String _commitRecordSeparator = '\x1e';
const String _commitLogFormat = '%x1e%H%x00%h%x00%an%x00%aI%x00%s';

class GitService {
  GitService({required this.dataDir, GitRunner? runner})
    : runner = runner ?? const GitRunner();

  /// Root data directory; new worktrees live under `<dataDir>/worktrees/`.
  final String dataDir;
  final GitRunner runner;

  /// True when [path] is inside a git working tree.
  Future<bool> isGitRepo(String path) async {
    if (!Directory(path).existsSync()) return false;
    final result = await runner.run(
      ['rev-parse', '--is-inside-work-tree'],
      cwd: path,
      check: false,
    );
    return result.ok && result.stdout.trim() == 'true';
  }

  /// Top-level checkout directory containing [path].
  Future<String> repositoryRoot(String path) async {
    final result = await runner.run([
      'rev-parse',
      '--show-toplevel',
    ], cwd: path);
    return p.normalize(result.stdout.trim());
  }

  /// Lists all worktrees of the repository containing [projectPath].
  Future<List<WorktreeInfo>> listWorktrees(String projectPath) async {
    final result = await runner.run([
      'worktree',
      'list',
      '--porcelain',
    ], cwd: projectPath);
    return _parseWorktreePorcelain(result.stdout);
  }

  /// Local branches of [projectPath], most recently committed first.
  Future<List<String>> listBranches(String projectPath) async {
    final result = await runner.run([
      'for-each-ref',
      '--sort=-committerdate',
      '--format=%(refname:short)',
      'refs/heads/',
    ], cwd: projectPath);
    return result.stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// The branch currently checked out at [projectPath], or `'main'` if HEAD
  /// is detached or the repo has no commits yet.
  Future<String> currentBranch(String projectPath) async {
    final result = await runner.run(
      ['rev-parse', '--abbrev-ref', 'HEAD'],
      cwd: projectPath,
      check: false,
    );
    final name = result.stdout.trim();
    return (!result.ok || name.isEmpty || name == 'HEAD') ? 'main' : name;
  }

  /// The symbolic branch checked out at [cwd], or null for detached/unborn
  /// HEAD. Commit history intentionally does not invent a branch in this case.
  Future<String?> checkoutCurrentBranch(String cwd) async {
    final result = await runner.run(
      ['rev-parse', '--abbrev-ref', 'HEAD'],
      cwd: cwd,
      check: false,
    );
    final branch = result.stdout.trim();
    return result.ok && branch.isNotEmpty && branch != 'HEAD' ? branch : null;
  }

  Future<bool> localBranchExists(String projectPath, String branch) async {
    final result = await runner.run(
      ['show-ref', '--verify', '--quiet', 'refs/heads/$branch'],
      cwd: projectPath,
      check: false,
    );
    return result.ok;
  }

  Future<String> renameCurrentBranch(String projectPath, String branch) async {
    await runner.run(['branch', '-m', branch], cwd: projectPath);
    return currentBranch(projectPath);
  }

  Future<void> createBranchFromBase({
    required String cwd,
    required String baseBranch,
    required String newBranchName,
  }) async {
    await runner.run(['checkout', '-b', newBranchName, baseBranch], cwd: cwd);
  }

  Future<void> checkoutExistingBranch(String cwd, String branch) async {
    await runner.run(['checkout', branch], cwd: cwd);
  }

  /// Resolves the repository's default branch using Paseo's precedence:
  /// origin/HEAD first, then local `main`, then local `master`.
  Future<String> resolveDefaultBranch(String projectPath) async {
    final symbolic = await runner.run(
      ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'],
      cwd: projectPath,
      check: false,
    );
    if (symbolic.ok && symbolic.stdout.trim().isNotEmpty) {
      final ref = symbolic.stdout.trim();
      final remoteShort = ref.startsWith('refs/remotes/')
          ? ref.substring('refs/remotes/'.length)
          : ref;
      final localName = remoteShort.startsWith('origin/')
          ? remoteShort.substring('origin/'.length)
          : remoteShort;
      final localExists = await runner.run(
        ['show-ref', '--verify', '--quiet', 'refs/heads/$localName'],
        cwd: projectPath,
        check: false,
      );
      return localExists.ok ? localName : remoteShort;
    }

    final branches = (await listBranches(projectPath)).toSet();
    if (branches.contains('main')) return 'main';
    if (branches.contains('master')) return 'master';
    throw StateError('Unable to resolve repository default branch');
  }

  /// Returns the registered worktree occupying the exact managed slug.
  Future<WorktreeInfo?> findWorktreeBySlug(
    String projectPath,
    String worktreeSlug,
  ) async {
    final expected = _canonical(
      p.join(dataDir, 'worktrees', sanitizeBranch(worktreeSlug)),
    );
    for (final worktree in await listWorktrees(projectPath)) {
      if (!worktree.isMain && p.equals(_canonical(worktree.path), expected)) {
        return worktree;
      }
    }
    return null;
  }

  /// Creates a worktree for [branch] under `<dataDir>/worktrees/`. If the
  /// branch already exists it is checked out; otherwise it is created,
  /// branching off [baseRef] (defaults to the project's current HEAD).
  Future<WorktreeInfo> createWorktree(
    String projectPath,
    String branch, {
    String? baseRef,
    String? worktreeSlug,
    bool requireExistingBranch = false,
    String? fetchRef,
    bool branchOff = false,
  }) async {
    final metadataBaseRef = baseRef ?? await currentBranch(projectPath);
    final projectName = p.basename(p.normalize(projectPath));
    final sanitized = sanitizeBranch(worktreeSlug ?? branch);
    final worktreesDir = Directory(p.join(dataDir, 'worktrees'));
    await worktreesDir.create(recursive: true);

    final targetName = worktreeSlug == null
        ? '$projectName-$sanitized'
        : sanitized;
    var target = p.join(worktreesDir.path, targetName);
    var suffix = worktreeSlug == null ? 2 : 1;
    while (Directory(target).existsSync() || File(target).existsSync()) {
      target = p.join(worktreesDir.path, '$targetName-$suffix');
      suffix++;
    }

    var effectiveBranch = branch;
    if (fetchRef != null) {
      effectiveBranch = await _uniqueLocalBranch(projectPath, branch);
      await runner.run([
        'fetch',
        'origin',
        '$fetchRef:refs/heads/$effectiveBranch',
      ], cwd: projectPath);
    }

    var branchExists = (await runner.run(
      ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'],
      cwd: projectPath,
      check: false,
    )).ok;
    if (fetchRef != null) {
      branchExists = true;
    } else if (!branchExists && requireExistingBranch) {
      await runner.run([
        'fetch',
        'origin',
        'refs/heads/$branch:refs/heads/$branch',
      ], cwd: projectPath);
      branchExists = true;
    }

    if (branchOff) {
      final branchBase = branchExists ? branch : metadataBaseRef;
      final candidate = branchExists ? (worktreeSlug ?? branch) : branch;
      effectiveBranch = await _uniqueLocalBranch(projectPath, candidate);
      await runner.run([
        'worktree',
        'add',
        target,
        '-b',
        effectiveBranch,
        '--no-track',
        branchBase,
      ], cwd: projectPath);
    } else if (branchExists) {
      await runner.run([
        'worktree',
        'add',
        target,
        effectiveBranch,
      ], cwd: projectPath);
    } else {
      await runner.run([
        'worktree',
        'add',
        target,
        '-b',
        effectiveBranch,
        if (baseRef != null) baseRef,
      ], cwd: projectPath);
    }

    final canonicalTarget = _canonical(target);
    final created = (await listWorktrees(projectPath)).firstWhere(
      (w) => p.equals(_canonical(w.path), canonicalTarget),
      orElse: () => WorktreeInfo(
        path: p.normalize(target),
        branch: effectiveBranch,
        projectPath: p.normalize(projectPath),
      ),
    );
    writeWorktreeBaseMetadata(created.path, baseRefName: metadataBaseRef);
    return created;
  }

  Future<String> _uniqueLocalBranch(
    String projectPath,
    String candidate,
  ) async {
    var result = candidate;
    var suffix = 2;
    while ((await runner.run(
      ['rev-parse', '--verify', '--quiet', 'refs/heads/$result'],
      cwd: projectPath,
      check: false,
    )).ok) {
      result = '$candidate-$suffix';
      suffix++;
    }
    return result;
  }

  Future<String?> resolveOriginForge(String projectPath) async {
    final remote = await runner.run(
      ['config', '--get', 'remote.origin.url'],
      cwd: projectPath,
      check: false,
    );
    if (!remote.ok || remote.stdout.trim().isEmpty) return null;
    final location = parseGitRemoteLocation(remote.stdout.trim());
    return location == null ? null : forgeForKnownHost(location.host);
  }

  /// Recreates an archived worktree at its original durable path.
  Future<void> restoreWorktree({
    required String projectPath,
    required String worktreePath,
    required String branch,
  }) async {
    await runner.run(['worktree', 'prune'], cwd: projectPath, check: false);
    await Directory(worktreePath).parent.create(recursive: true);
    await runner.run([
      'worktree',
      'add',
      worktreePath,
      branch,
    ], cwd: projectPath);
  }

  /// Paths (relative to [worktreePath]) with uncommitted working-tree
  /// changes, tracked or untracked. Empty means the worktree is clean.
  Future<List<String>> uncommittedPaths(String worktreePath) async {
    final result = await runner.run([
      'status',
      '--porcelain',
      '--untracked-files=all',
    ], cwd: worktreePath);
    final paths = <String>[];
    for (final rawLine in result.stdout.split('\n')) {
      if (rawLine.length < 4) continue;
      paths.add(rawLine.substring(3));
    }
    return paths;
  }

  /// Removes the worktree at [path] (`git worktree remove --force`). The main
  /// checkout cannot be archived. Unless [force] is true, refuses to remove a
  /// worktree with uncommitted changes (throws [GitDirtyWorktreeException]).
  Future<void> archiveWorktree(String path, {bool force = false}) async {
    if (!Directory(path).existsSync()) {
      throw GitException(
        args: ['worktree', 'remove', '--force', path],
        exitCode: 1,
        stderr: 'worktree path does not exist: $path',
      );
    }
    final worktrees = await listWorktrees(path);
    final wanted = _canonical(path);
    final match = worktrees
        .where((w) => p.equals(_canonical(w.path), wanted))
        .toList();
    if (match.isEmpty) {
      throw GitException(
        args: ['worktree', 'remove', '--force', path],
        exitCode: 1,
        stderr: 'not a worktree: $path',
      );
    }
    final info = match.first;
    if (info.isMain) {
      throw StateError('cannot archive the main worktree: $path');
    }
    if (!force) {
      final dirty = await uncommittedPaths(path);
      if (dirty.isNotEmpty) {
        throw GitDirtyWorktreeException(path: path, uncommittedPaths: dirty);
      }
    }
    // Run from the main checkout so we are not deleting our own cwd. Windows
    // can transiently keep a file handle after git unregisters the worktree;
    // Paseo retries that partial-removal state before reporting failure.
    GitException? lastError;
    for (final delay in const [
      Duration.zero,
      Duration(milliseconds: 50),
      Duration(milliseconds: 150),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
    ]) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      try {
        await runner.run([
          'worktree',
          'remove',
          '--force',
          path,
        ], cwd: info.projectPath);
        return;
      } on GitException catch (error) {
        lastError = error;
        final stillRegistered = (await listWorktrees(
          info.projectPath,
        )).any((worktree) => p.equals(_canonical(worktree.path), wanted));
        if (!stillRegistered) {
          if (await _deleteWorktreeDirectoryWithRetries(path)) {
            await runner.run(
              ['worktree', 'prune'],
              cwd: info.projectPath,
              check: false,
            );
            return;
          }
        }
      }
    }
    throw lastError!;
  }

  Future<bool> _deleteWorktreeDirectoryWithRetries(String path) async {
    for (final delay in const [
      Duration.zero,
      Duration(milliseconds: 100),
      Duration(milliseconds: 300),
      Duration(milliseconds: 700),
      Duration(milliseconds: 1500),
    ]) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      final directory = Directory(path);
      if (!directory.existsSync()) return true;
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // A short-lived editor, antivirus, or process cwd handle can race the
        // removal on Windows. The bounded retry keeps failures deterministic.
      }
    }
    return !Directory(path).existsSync();
  }

  /// Structured diff. Without [baseRef]: working tree vs HEAD plus untracked
  /// files synthesized as added. With [baseRef]: `git diff <baseRef>`.
  Future<DiffResponse> diff(
    String cwd, {
    String? baseRef,
    bool ignoreWhitespace = false,
  }) async {
    if (baseRef != null) {
      final result = await runner.run([
        'diff',
        if (ignoreWhitespace) '-w',
        baseRef,
        '--no-color',
      ], cwd: cwd);
      return DiffResponse(files: parseUnifiedDiff(result.stdout));
    }

    final files = <DiffFile>[];

    // Tracked changes vs HEAD (skip when the repo has no commits yet).
    final hasHead = (await runner.run(
      ['rev-parse', '--verify', '--quiet', 'HEAD'],
      cwd: cwd,
      check: false,
    )).ok;
    if (hasHead) {
      final result = await runner.run([
        'diff',
        if (ignoreWhitespace) '-w',
        'HEAD',
        '--no-color',
      ], cwd: cwd);
      files.addAll(parseUnifiedDiff(result.stdout));
    }

    files.addAll(await _untrackedAsAdded(cwd));
    return DiffResponse(files: files);
  }

  /// Frozen checkout-diff semantics. Base mode compares the merge base to
  /// HEAD and deliberately excludes untracked working-tree files.
  Future<DiffResponse> checkoutDiff(
    String cwd,
    CheckoutDiffCompare compare,
  ) async {
    final normalized = compare.normalized();
    if (normalized.mode == CheckoutDiffMode.uncommitted) {
      return applyCheckoutDiffBudgets(
        await diff(cwd, ignoreWhitespace: normalized.ignoreWhitespace),
      );
    }
    final baseRef = normalized.baseRef ?? 'HEAD';
    final mergeBase = await runner.run(
      ['merge-base', baseRef, 'HEAD'],
      cwd: cwd,
      check: false,
    );
    final resolved = mergeBase.ok && mergeBase.stdout.trim().isNotEmpty
        ? mergeBase.stdout.trim()
        : baseRef;
    final result = await runner.run([
      'diff',
      if (normalized.ignoreWhitespace) '-w',
      resolved,
      'HEAD',
      '--no-color',
    ], cwd: cwd);
    return applyCheckoutDiffBudgets(
      DiffResponse(files: parseUnifiedDiff(result.stdout)),
    );
  }

  /// Frozen Paseo 0.2.0 checkout history: every commit ahead of the resolved
  /// base followed by at most ten commits of base context.
  Future<CheckoutCommitsResult> listCheckoutCommits(
    String cwd, {
    String? storedBaseRef,
  }) async {
    final current = await checkoutCurrentBranch(cwd);
    if (current == null) {
      return const CheckoutCommitsResult(baseRef: null, commits: []);
    }

    final fallbackBase = await _tryResolveDefaultBranch(cwd);
    final preferredBase = switch (storedBaseRef?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => fallbackBase,
    };
    var comparisonBase = await _tryResolveCommitsBase(
      cwd,
      preferredBase,
      current,
    );
    final normalizedPreferred = preferredBase == null
        ? null
        : _normalizeLocalBranchRef(preferredBase);
    if (comparisonBase == null &&
        normalizedPreferred != null &&
        normalizedPreferred != current &&
        fallbackBase != null &&
        _normalizeLocalBranchRef(fallbackBase) != normalizedPreferred) {
      comparisonBase = await _tryResolveCommitsBase(cwd, fallbackBase, current);
    }

    var workspaceRecords = const <_ParsedCheckoutCommit>[];
    var baseRevision = 'HEAD';
    if (comparisonBase != null) {
      final results = await Future.wait<Object?>([
        _checkoutCommitRecords(cwd, '$comparisonBase..HEAD'),
        _tryMergeBase(cwd, comparisonBase),
      ]);
      workspaceRecords = results[0] as List<_ParsedCheckoutCommit>;
      baseRevision = results[1] as String? ?? '';
    }
    final baseRecords = baseRevision.isEmpty
        ? const <_ParsedCheckoutCommit>[]
        : await _checkoutCommitRecords(
            cwd,
            baseRevision,
            maxCount: _checkoutBaseCommitLimit,
          );
    final records = [...workspaceRecords, ...baseRecords];
    if (records.isEmpty) {
      return CheckoutCommitsResult(baseRef: comparisonBase, commits: const []);
    }

    final unpushed = await _unpushedCommitShas(cwd);
    final workspaceShas = workspaceRecords.map((record) => record.sha).toSet();
    return CheckoutCommitsResult(
      baseRef: comparisonBase,
      commits: [
        for (final record in records)
          CheckoutCommit(
            sha: record.sha,
            shortSha: record.shortSha,
            subject: record.subject,
            authorName: record.authorName,
            authorDate: record.authorDate,
            isOnRemote: !unpushed.contains(record.sha),
            isOnBase: !workspaceShas.contains(record.sha),
            files: record.files,
          ),
      ],
    );
  }

  /// Unified textual diff for one file introduced by [sha]. Binary-only
  /// changes deliberately resolve to null so the client can synthesize the
  /// stat-only binary row from commit metadata.
  Future<DiffFile?> commitFileDiff(
    String cwd, {
    required String sha,
    required String path,
  }) async {
    final result = await runner.run([
      'show',
      sha,
      '--format=',
      '--diff-merges=first-parent',
      '--',
      path,
    ], cwd: cwd);
    if (result.stdout.trim().isEmpty) return null;
    final parsed = parseUnifiedDiff(result.stdout);
    final file = parsed
        .where((candidate) => candidate.path == path)
        .firstOrNull;
    if (file == null) return null;
    if (file.hunks.isEmpty &&
        RegExp(
          r'^Binary files .* differ$',
          multiLine: true,
        ).hasMatch(result.stdout)) {
      return null;
    }
    return file;
  }

  Future<String?> readFileAtRef(
    String cwd, {
    required String ref,
    required String path,
  }) async {
    final result = await runner.run(
      ['show', '$ref:$path'],
      cwd: cwd,
      check: false,
    );
    return result.ok ? result.stdout : null;
  }

  Future<String?> _tryResolveDefaultBranch(String cwd) async {
    try {
      return await resolveDefaultBranch(cwd);
    } on Object {
      return null;
    }
  }

  Future<String?> _tryResolveCommitsBase(
    String cwd,
    String? baseRef,
    String currentBranch,
  ) async {
    if (baseRef == null) return null;
    final normalized = _normalizeLocalBranchRef(baseRef);
    if (normalized.isEmpty || normalized == currentBranch) return null;
    try {
      final local = await _refExists(cwd, 'refs/heads/$normalized');
      final origin = await _refExists(cwd, 'refs/remotes/origin/$normalized');
      if (local && !origin) return normalized;
      if (!local && origin) return 'origin/$normalized';
      if (!local && !origin) return null;
      final counts = await runner.run([
        'rev-list',
        '--left-right',
        '--count',
        '$normalized...origin/$normalized',
      ], cwd: cwd);
      final parts = counts.stdout.trim().split(RegExp(r'\s+'));
      final localOnly = int.tryParse(parts.isEmpty ? '0' : parts[0]) ?? 0;
      final originOnly = int.tryParse(parts.length < 2 ? '0' : parts[1]) ?? 0;
      return originOnly > localOnly ? 'origin/$normalized' : normalized;
    } on Object {
      return null;
    }
  }

  Future<bool> _refExists(String cwd, String fullRef) async =>
      (await runner.run(
        ['show-ref', '--verify', '--quiet', fullRef],
        cwd: cwd,
        check: false,
      )).ok;

  Future<String?> _tryMergeBase(String cwd, String baseRef) async {
    final result = await runner.run(
      ['merge-base', baseRef, 'HEAD'],
      cwd: cwd,
      check: false,
    );
    final value = result.stdout.trim();
    return result.ok && value.isNotEmpty ? value : null;
  }

  Future<Set<String>> _unpushedCommitShas(String cwd) async {
    final result = await runner.run([
      'rev-list',
      'HEAD',
      '--not',
      '--remotes',
    ], cwd: cwd);
    return result.stdout
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  Future<List<_ParsedCheckoutCommit>> _checkoutCommitRecords(
    String cwd,
    String revision, {
    int? maxCount,
  }) async {
    final args = [
      'log',
      revision,
      if (maxCount != null) '--max-count=$maxCount',
      '--diff-merges=first-parent',
      '--format=$_commitLogFormat',
      '--raw',
      '--numstat',
      '-M',
    ];
    final result = await runner.run(args, cwd: cwd);
    return _parseCheckoutCommitRecords(result.stdout);
  }

  /// Applies Paseo's 1 MiB per-file and 2 MiB aggregate structured-diff
  /// budgets, preserving stats while omitting oversized hunks.
  DiffResponse applyCheckoutDiffBudgets(DiffResponse response) {
    var totalBytes = 0;
    final files = <DiffFile>[];
    for (final file in response.files) {
      if (file.binary || file.tooLarge) {
        files.add(file);
        continue;
      }
      var fileBytes = 0;
      for (final hunk in file.hunks) {
        fileBytes += utf8.encode('${hunk.header}\n').length;
        for (final line in hunk.lines) {
          fileBytes += utf8.encode('${line.text}\n').length + 1;
        }
      }
      if (fileBytes > _perFileDiffMaxBytes ||
          totalBytes + fileBytes > _totalDiffMaxBytes) {
        files.add(
          DiffFile(
            path: file.path,
            status: file.status,
            oldPath: file.oldPath,
            tooLarge: true,
            additions: file.additions,
            deletions: file.deletions,
          ),
        );
        continue;
      }
      totalBytes += fileBytes;
      files.add(file);
    }
    return DiffResponse(files: files);
  }

  /// Synthesizes an all-added [DiffFile] for every untracked file.
  Future<List<DiffFile>> _untrackedAsAdded(String cwd) async {
    final root = (await runner.run([
      'rev-parse',
      '--show-toplevel',
    ], cwd: cwd)).stdout.trim();

    final status = await runner.run([
      'status',
      '--porcelain=v2',
      '--untracked-files=all',
      '-z',
    ], cwd: cwd);

    final untracked = <String>[];
    for (final entry in status.stdout.split('\x00')) {
      if (entry.startsWith('? ')) {
        untracked.add(entry.substring(2));
      }
    }
    untracked.sort();

    final files = <DiffFile>[];
    for (final relPath in untracked) {
      final file = File(p.join(root, relPath));
      if (!file.existsSync()) continue;
      files.add(await _synthesizeAdded(relPath, file));
    }
    return files;
  }

  Future<DiffFile> _synthesizeAdded(String relPath, File file) async {
    final length = await file.length();
    if (length > _maxUntrackedBytes) {
      return DiffFile(
        path: relPath,
        status: DiffFileStatus.added,
        tooLarge: true,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) {
      return DiffFile(
        path: relPath,
        status: DiffFileStatus.added,
        binary: true,
      );
    }

    final content = utf8.decode(bytes, allowMalformed: true);
    var lines = content.split('\n');
    // A trailing newline yields a spurious empty last element.
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines = lines.sublist(0, lines.length - 1);
    }
    final diffLines = <DiffLine>[
      for (var i = 0; i < lines.length; i++)
        DiffLine(
          type: DiffLineType.add,
          text: lines[i].endsWith('\r')
              ? lines[i].substring(0, lines[i].length - 1)
              : lines[i],
          newLineNo: i + 1,
        ),
    ];
    return DiffFile(
      path: relPath,
      status: DiffFileStatus.added,
      additions: diffLines.length,
      hunks: diffLines.isEmpty
          ? const []
          : [
              DiffHunk(
                header: '@@ -0,0 +1,${diffLines.length} @@',
                lines: diffLines,
              ),
            ],
    );
  }

  /// Canonicalizes a path for comparison: resolves symlinks and, on Windows,
  /// expands 8.3 short names (`WINETR~1`) so short- and long-form paths of the
  /// same directory compare equal.
  static String _canonical(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(path);
    }
  }

  /// Filesystem-safe directory fragment for a branch name.
  static String sanitizeBranch(String branch) {
    var safe = branch.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    if (safe.length > 60) safe = safe.substring(0, 60);
    return safe.isEmpty ? 'branch' : safe;
  }

  /// Parses `git worktree list --porcelain` output. The first entry is the
  /// main checkout; its path becomes `projectPath` for every entry.
  static List<WorktreeInfo> _parseWorktreePorcelain(String output) {
    final blocks = output
        .split(RegExp(r'\r?\n\r?\n'))
        .where((b) => b.trim().isNotEmpty)
        .toList();

    String? mainPath;
    final infos = <WorktreeInfo>[];
    for (var idx = 0; idx < blocks.length; idx++) {
      String? path;
      var branch = '';
      var isDetached = false;
      for (final rawLine in blocks[idx].split(RegExp(r'\r?\n'))) {
        final line = rawLine.trimRight();
        if (line.startsWith('worktree ')) {
          path = p.normalize(line.substring('worktree '.length));
        } else if (line.startsWith('branch ')) {
          branch = line.substring('branch '.length);
          if (branch.startsWith('refs/heads/')) {
            branch = branch.substring('refs/heads/'.length);
          }
        } else if (line == 'detached') {
          isDetached = true;
        }
      }
      if (path == null) continue;
      mainPath ??= path;
      infos.add(
        WorktreeInfo(
          path: path,
          branch: isDetached && branch.isEmpty ? '(detached)' : branch,
          projectPath: mainPath,
          isMain: idx == 0,
        ),
      );
    }
    return infos;
  }
}

final class CheckoutCommitsResult {
  const CheckoutCommitsResult({required this.baseRef, required this.commits});

  final String? baseRef;
  final List<CheckoutCommit> commits;
}

final class _ParsedCheckoutCommit {
  const _ParsedCheckoutCommit({
    required this.sha,
    required this.shortSha,
    required this.authorName,
    required this.authorDate,
    required this.subject,
    required this.files,
  });

  final String sha;
  final String shortSha;
  final String authorName;
  final String authorDate;
  final String subject;
  final List<CheckoutCommitFile> files;
}

List<_ParsedCheckoutCommit> _parseCheckoutCommitRecords(String output) {
  final commits = <_ParsedCheckoutCommit>[];
  for (final rawRecord in output.split(_commitRecordSeparator)) {
    final record = rawRecord.replaceFirst(RegExp(r'^[\r\n]+'), '');
    if (record.isEmpty) continue;
    final lines = record.split(RegExp(r'\r?\n'));
    final fields = lines.first.split(_commitFieldSeparator);
    if (fields.length < 5) continue;
    final sha = fields[0].trim();
    if (sha.isEmpty) continue;

    final stats = <String, ({int additions, int deletions})>{};
    final statuses = <String, CheckoutCommitFileStatus>{};
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      if (line.startsWith(':')) {
        _parseCheckoutRawStatus(line, statuses);
      } else {
        _parseCheckoutNumstat(line, stats);
      }
    }
    commits.add(
      _ParsedCheckoutCommit(
        sha: sha,
        shortSha: fields[1].trim(),
        authorName: fields[2],
        authorDate: fields[3].trim(),
        subject: fields[4],
        files: [
          for (final entry in stats.entries)
            CheckoutCommitFile(
              path: entry.key,
              additions: entry.value.additions,
              deletions: entry.value.deletions,
              status: statuses[entry.key],
            ),
        ],
      ),
    );
  }
  return commits;
}

void _parseCheckoutRawStatus(
  String line,
  Map<String, CheckoutCommitFileStatus> statuses,
) {
  final parts = line.split('\t');
  final metadata = parts.first;
  final statusToken = metadata.substring(metadata.lastIndexOf(' ') + 1);
  if (statusToken.isEmpty) return;
  final letter = statusToken[0];
  final status = switch (letter) {
    'A' || 'C' => CheckoutCommitFileStatus.added,
    'M' || 'T' => CheckoutCommitFileStatus.modified,
    'D' => CheckoutCommitFileStatus.deleted,
    'R' => CheckoutCommitFileStatus.renamed,
    _ => null,
  };
  if (status == null || parts.length < 2) return;
  final path = letter == 'R' || letter == 'C' ? parts.last : parts[1];
  if (path.isNotEmpty) statuses[path] = status;
}

void _parseCheckoutNumstat(
  String line,
  Map<String, ({int additions, int deletions})> stats,
) {
  final parts = line.split('\t');
  if (parts.length < 3) return;
  final path = _normalizeCheckoutNumstatPath(parts.skip(2).join('\t'));
  if (path.isEmpty) return;
  if (parts[0] == '-' || parts[1] == '-') {
    stats[path] = (additions: 0, deletions: 0);
    return;
  }
  final additions = int.tryParse(parts[0]);
  final deletions = int.tryParse(parts[1]);
  if (additions == null || deletions == null) return;
  stats[path] = (additions: additions, deletions: deletions);
}

String _normalizeCheckoutNumstatPath(String value) {
  final braces = RegExp(r'^(.*)\{(.*) => (.*)\}(.*)$').firstMatch(value);
  if (braces != null) {
    return '${braces.group(1)}${braces.group(3)}${braces.group(4)}';
  }
  final inline = RegExp(r'^(.*) => (.*)$').firstMatch(value);
  return inline?.group(2) ?? value;
}

String _normalizeLocalBranchRef(String input) => input
    .replaceFirst(RegExp(r'^refs/remotes/origin/'), '')
    .replaceFirst(RegExp(r'^refs/heads/'), '')
    .replaceFirst(RegExp(r'^origin/'), '');
