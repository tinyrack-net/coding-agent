/// Platform-neutral pseudo-terminal abstraction.
///
/// `Pty.spawn` dispatches at runtime: ConPTY (win32 FFI) on Windows,
/// openpty/fork (libc FFI) on Unix. Both are pure Dart — no Flutter plugins.
library;

import 'dart:io';
import 'dart:typed_data';

import 'pty_unix.dart';
import 'pty_windows.dart';

abstract interface class Pty {
  /// Raw output bytes from the shell (single-subscription stream; closes on
  /// process exit).
  Stream<Uint8List> get output;

  /// Resolved shell executable that was spawned.
  String get shell;

  /// Completes with the shell's exit code once the process dies.
  Future<int> get exitCode;

  void write(Uint8List data);

  void resize(int cols, int rows);

  /// Forcibly terminates the shell process and releases the PTY.
  void kill();

  static Pty spawn({
    required String cwd,
    int cols = 80,
    int rows = 24,
    String? shell,
  }) {
    if (Platform.isWindows) {
      return WindowsPty.spawn(cwd: cwd, cols: cols, rows: rows, shell: shell);
    }
    return UnixPty.spawn(cwd: cwd, cols: cols, rows: rows, shell: shell);
  }
}
