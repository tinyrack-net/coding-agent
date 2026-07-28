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
  Future<DiffResponse> diff(String cwd, {String? baseRef}) async {
    if (baseRef != null) {
      final result = await runner.run([
        'diff',
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
      final result = await runner.run(['diff', 'HEAD', '--no-color'], cwd: cwd);
      files.addAll(parseUnifiedDiff(result.stdout));
    }

    files.addAll(await _untrackedAsAdded(cwd));
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
        binary: true,
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
