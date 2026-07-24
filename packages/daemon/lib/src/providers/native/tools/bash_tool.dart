/// Single-shot shell command execution for the `bash` tool — runs one
/// command to completion (or timeout) and captures its output, unlike the
/// interactive multi-subscriber `TerminalManager` used by the terminal pane.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultTimeout = Duration(seconds: 120);
const _maxOutputLength = 20000;

class BashToolResult {
  const BashToolResult({
    required this.output,
    required this.exitCode,
    required this.timedOut,
  });

  final String output;

  /// Null when [timedOut] is true (the process was killed before exiting).
  final int? exitCode;
  final bool timedOut;
}

Future<BashToolResult> runBash(
  String cwd,
  String command, {
  Duration timeout = _defaultTimeout,
}) async {
  final process = Platform.isWindows
      ? await Process.start('cmd', ['/c', command], workingDirectory: cwd)
      : await Process.start('/bin/sh', ['-c', command], workingDirectory: cwd);

  final output = StringBuffer();
  final stdoutSub =
      process.stdout.transform(utf8.decoder).listen(output.write);
  final stderrSub =
      process.stderr.transform(utf8.decoder).listen(output.write);

  var timedOut = false;
  int? exitCode;
  try {
    exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        _killTree(process.pid);
        return -1;
      },
    );
  } finally {
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }

  var text = output.toString();
  if (text.length > _maxOutputLength) {
    text = '${text.substring(0, _maxOutputLength)}\n...[truncated]';
  }
  return BashToolResult(
    output: text,
    exitCode: timedOut ? null : exitCode,
    timedOut: timedOut,
  );
}

void _killTree(int pid) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/T', '/F', '/PID', '$pid']);
  } else {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}
