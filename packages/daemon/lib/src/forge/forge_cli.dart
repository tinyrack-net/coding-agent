import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const forgeCliMaxOutputBytes = 10 * 1024 * 1024;

final class ForgeCommandResult {
  const ForgeCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

sealed class ForgeCliException implements Exception {
  const ForgeCliException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ForgeCliMissingException extends ForgeCliException {
  const ForgeCliMissingException(String executable)
    : super('$executable CLI is not installed');
}

final class ForgeAuthenticationException extends ForgeCliException {
  const ForgeAuthenticationException(super.message);
}

final class ForgeCommandException extends ForgeCliException {
  ForgeCommandException({
    required this.executable,
    required this.args,
    required this.cwd,
    required this.exitCode,
    required this.stderr,
  }) : super('$executable CLI command failed: $executable ${args.join(' ')}');

  final String executable;
  final List<String> args;
  final String cwd;
  final int? exitCode;
  final String stderr;
}

abstract interface class ForgeCommandTransport {
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  });
}

// The real process boundary is exercised by platform E2E. Unit tests cover the
// shared normalization and every adapter through an injected transport.
// coverage:ignore-start
final class ProcessForgeCommandTransport implements ForgeCommandTransport {
  const ProcessForgeCommandTransport();

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    late final Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: cwd,
        environment: {...Platform.environment, ...environment},
        includeParentEnvironment: false,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      if (error.errorCode == 2 || error.errorCode == 3) {
        throw ForgeCliMissingException(executable);
      }
      throw ForgeCommandException(
        executable: executable,
        args: List.unmodifiable(args),
        cwd: cwd,
        exitCode: null,
        stderr: error.message,
      );
    }

    final stdout = _BoundedOutput();
    final stderr = _BoundedOutput();
    final stdoutDone = process.stdout.listen(stdout.add).asFuture<void>();
    final stderrDone = process.stderr.listen(stderr.add).asFuture<void>();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      throw ForgeCommandException(
        executable: executable,
        args: List.unmodifiable(args),
        cwd: cwd,
        exitCode: null,
        stderr: '$executable timed out after ${timeout.inMilliseconds}ms',
      );
    }
    await Future.wait([stdoutDone, stderrDone]);
    if (stdout.overflowed || stderr.overflowed) {
      throw ForgeCommandException(
        executable: executable,
        args: List.unmodifiable(args),
        cwd: cwd,
        exitCode: exitCode,
        stderr: '$executable exceeded the 10 MiB output limit',
      );
    }
    return ForgeCommandResult(
      exitCode: exitCode,
      stdout: stdout.text,
      stderr: stderr.text,
    );
  }
}

final class _BoundedOutput {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  bool overflowed = false;

  void add(List<int> chunk) {
    if (overflowed) return;
    final remaining = forgeCliMaxOutputBytes - _bytes.length;
    if (chunk.length > remaining) {
      if (remaining > 0) _bytes.add(chunk.sublist(0, remaining));
      overflowed = true;
      return;
    }
    _bytes.add(chunk);
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}
// coverage:ignore-end

Future<String> runForgeCli(
  ForgeCommandTransport transport,
  String executable,
  List<String> args, {
  required String cwd,
  Map<String, String> environment = const {},
  bool classifyAuthentication = true,
}) async {
  final result = await transport.run(
    executable,
    args,
    cwd: cwd,
    environment: environment,
  );
  if (result.exitCode == 0) return result.stdout.trim();
  final message = result.stderr.trim().isEmpty
      ? result.stdout.trim()
      : result.stderr.trim();
  if (classifyAuthentication && _isAuthenticationFailure(message)) {
    throw ForgeAuthenticationException(
      message.isEmpty ? '$executable is not authenticated' : message,
    );
  }
  throw ForgeCommandException(
    executable: executable,
    args: List.unmodifiable(args),
    cwd: cwd,
    exitCode: result.exitCode,
    stderr: message,
  );
}

Object? decodeForgeJson(
  String value, {
  required String executable,
  required List<String> args,
  required String cwd,
}) {
  try {
    return jsonDecode(value);
  } on FormatException {
    throw ForgeCommandException(
      executable: executable,
      args: List.unmodifiable(args),
      cwd: cwd,
      exitCode: null,
      stderr: '$executable did not return valid JSON (${value.length} bytes)',
    );
  }
}

bool _isAuthenticationFailure(String value) => RegExp(
  r'\b(401|403|unauthorized|forbidden|not logged in|authentication failed|no token|invalid token|no logins?|requires authentication)\b',
  caseSensitive: false,
).hasMatch(value);
