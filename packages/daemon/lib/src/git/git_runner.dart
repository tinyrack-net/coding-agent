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

/// Runs git commands with UTF-8 output and `core.quotepath=false` always set.
class GitRunner {
  const GitRunner({this.executable = 'git'});

  final String executable;

  /// Run `git <args>` in [cwd]. When [check] is true (default), a nonzero
  /// exit throws [GitException]; pass false for probes where nonzero is an
  /// expected answer (e.g. `rev-parse --verify`).
  Future<GitResult> run(
    List<String> args, {
    required String cwd,
    bool check = true,
  }) async {
    final fullArgs = ['-c', 'core.quotepath=false', ...args];
    final result = await Process.run(
      executable,
      fullArgs,
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final gitResult = GitResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
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
