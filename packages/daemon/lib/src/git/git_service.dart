/// Git operations backing the M4 workspace RPCs: worktree management and
/// structured diffs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'git_runner.dart';
import 'unified_diff_parser.dart';

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

  /// Lists all worktrees of the repository containing [projectPath].
  Future<List<WorktreeInfo>> listWorktrees(String projectPath) async {
    final result = await runner.run(
      ['worktree', 'list', '--porcelain'],
      cwd: projectPath,
    );
    return _parseWorktreePorcelain(result.stdout);
  }

  /// Creates a worktree for [branch] under `<dataDir>/worktrees/`. If the
  /// branch already exists it is checked out; otherwise it is created.
  Future<WorktreeInfo> createWorktree(String projectPath, String branch) async {
    final projectName = p.basename(p.normalize(projectPath));
    final sanitized = sanitizeBranch(branch);
    final worktreesDir = Directory(p.join(dataDir, 'worktrees'));
    await worktreesDir.create(recursive: true);

    var target = p.join(worktreesDir.path, '$projectName-$sanitized');
    var suffix = 2;
    while (Directory(target).existsSync() || File(target).existsSync()) {
      target = p.join(worktreesDir.path, '$projectName-$sanitized-$suffix');
      suffix++;
    }

    final branchExists = (await runner.run(
      ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'],
      cwd: projectPath,
      check: false,
    ))
        .ok;

    if (branchExists) {
      await runner.run(['worktree', 'add', target, branch], cwd: projectPath);
    } else {
      await runner.run(
        ['worktree', 'add', target, '-b', branch],
        cwd: projectPath,
      );
    }

    final canonicalTarget = _canonical(target);
    final created = (await listWorktrees(projectPath)).firstWhere(
      (w) => p.equals(_canonical(w.path), canonicalTarget),
      orElse: () => WorktreeInfo(
        path: p.normalize(target),
        branch: branch,
        projectPath: p.normalize(projectPath),
      ),
    );
    return created;
  }

  /// Removes the worktree at [path] (`git worktree remove --force`). The main
  /// checkout cannot be archived.
  Future<void> archiveWorktree(String path) async {
    if (!Directory(path).existsSync()) {
      throw GitException(
        args: ['worktree', 'remove', '--force', path],
        exitCode: 1,
        stderr: 'worktree path does not exist: $path',
      );
    }
    final worktrees = await listWorktrees(path);
    final wanted = _canonical(path);
    final match =
        worktrees.where((w) => p.equals(_canonical(w.path), wanted)).toList();
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
    // Run from the main checkout so we are not deleting our own cwd.
    await runner.run(
      ['worktree', 'remove', '--force', path],
      cwd: info.projectPath,
    );
  }

  /// Structured diff. Without [baseRef]: working tree vs HEAD plus untracked
  /// files synthesized as added. With [baseRef]: `git diff <baseRef>`.
  Future<DiffResponse> diff(String cwd, {String? baseRef}) async {
    if (baseRef != null) {
      final result =
          await runner.run(['diff', baseRef, '--no-color'], cwd: cwd);
      return DiffResponse(files: parseUnifiedDiff(result.stdout));
    }

    final files = <DiffFile>[];

    // Tracked changes vs HEAD (skip when the repo has no commits yet).
    final hasHead = (await runner.run(
      ['rev-parse', '--verify', '--quiet', 'HEAD'],
      cwd: cwd,
      check: false,
    ))
        .ok;
    if (hasHead) {
      final result =
          await runner.run(['diff', 'HEAD', '--no-color'], cwd: cwd);
      files.addAll(parseUnifiedDiff(result.stdout));
    }

    files.addAll(await _untrackedAsAdded(cwd));
    return DiffResponse(files: files);
  }

  /// Synthesizes an all-added [DiffFile] for every untracked file.
  Future<List<DiffFile>> _untrackedAsAdded(String cwd) async {
    final root = (await runner.run(
      ['rev-parse', '--show-toplevel'],
      cwd: cwd,
    ))
        .stdout
        .trim();

    final status = await runner.run(
      ['status', '--porcelain=v2', '--untracked-files=all', '-z'],
      cwd: cwd,
    );

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
      return DiffFile(path: relPath, status: DiffFileStatus.added, binary: true);
    }
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) {
      return DiffFile(path: relPath, status: DiffFileStatus.added, binary: true);
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
      infos.add(WorktreeInfo(
        path: path,
        branch: isDetached && branch.isEmpty ? '(detached)' : branch,
        projectPath: mainPath,
        isMain: idx == 0,
      ));
    }
    return infos;
  }
}
