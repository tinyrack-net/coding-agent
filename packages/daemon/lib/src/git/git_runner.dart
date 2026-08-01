/// Thin wrapper around the `git` CLI.
library;

import 'dart:convert';
import 'dart:io';

/// Raised when git exits nonzero and the caller asked for a checked run.
class GitException implements Exception {
  GitException({
    required this.args,
    required this.exitCode,
    required this.stderr,
    this.stdout = '',
  });

  final List<String> args;
  final int exitCode;
  final String stderr;
  final String stdout;

  String get message {
    final err = stderr.trim();
    return err.isEmpty ? 'git ${args.join(' ')} exited $exitCode' : err;
  }

  @override
  String toString() =>
      'GitException(git ${args.join(' ')} -> $exitCode): $message';
}

/// Raised by [GitService.archiveWorktree] when the worktree has uncommitted
/// changes and the caller did not pass `force: true`.
class GitDirtyWorktreeException implements Exception {
  GitDirtyWorktreeException({
    required this.path,
    required this.uncommittedPaths,
  });

  final String path;
  final List<String> uncommittedPaths;

  String get message =>
      'worktree has uncommitted changes: ${uncommittedPaths.join(', ')}';

  @override
  String toString() => 'GitDirtyWorktreeException($path): $message';
}

final class GitResult {
  const GitResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// Watches git commands so telemetry can be recorded around them.
///
/// Declared here rather than beside the metrics window because
/// `paseo_server_services.dart` already imports this file; pointing the
/// dependency the other way would be circular. The handle is opaque so this
/// file stays unaware of what the observer records.
abstract interface class GitCommandObserver {
  /// Called before the process starts. The returned handle is passed back to
  /// [end]; return null if the observer keeps no per-command state.
  Object? begin(String operation);

  /// Called once the process has exited, or thrown.
  void end(Object? handle, {required bool success});
}

/// Runs git commands with UTF-8 output and `core.quotepath=false` always set.
class GitRunner {
  const GitRunner({this.executable = 'git', this.observer});

  final String executable;

  /// Optional telemetry sink. Upstream's `runGitCommand` records every
  /// command centrally; without this the ported metrics window would observe
  /// nothing from real git calls.
  final GitCommandObserver? observer;

  /// Run `git <args>` in [cwd]. When [check] is true (default), a nonzero
  /// exit throws [GitException]; pass false for probes where nonzero is an
  /// expected answer (e.g. `rev-parse --verify`).
  Future<GitResult> run(
    List<String> args, {
    required String cwd,
    bool check = true,
  }) async {
    final fullArgs = ['-c', 'core.quotepath=false', ...args];
    // The subcommand, not the whole line — the metrics window counts commands
    // by operation, and arguments would shatter that into unique buckets.
    final handle = observer?.begin(args.isEmpty ? 'git' : args.first);
    late final GitResult gitResult;
    try {
      final result = await Process.run(
        executable,
        fullArgs,
        workingDirectory: cwd,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      gitResult = GitResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } catch (_) {
      // A spawn failure is a failed command, not an absent one; leaving the
      // handle open would leak it into the next window's pending set.
      observer?.end(handle, success: false);
      rethrow;
    }
    // Reported before the `check` throw, so a nonzero exit is recorded once
    // whether or not the caller asked for it to raise.
    observer?.end(handle, success: gitResult.ok);
    if (check && !gitResult.ok) {
      throw GitException(
        args: args,
        exitCode: gitResult.exitCode,
        stderr: gitResult.stderr,
        stdout: gitResult.stdout,
      );
    }
    return gitResult;
  }
}
