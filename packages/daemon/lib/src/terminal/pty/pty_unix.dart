/// Unix (Linux/macOS) [Pty] via posix openpty + fork + exec through dart:ffi.
///
/// WARNING: this implementation is UNTESTED — it was written on a Windows
/// machine where it cannot run. It is best-effort per the POSIX/openpty man
/// pages; expect to validate and fix it on a real Linux/macOS host.
///
/// All native library lookups are lazy (inside functions), so this file
/// compiles and loads on Windows without touching libc/libutil.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pty.dart';

// ---------------------------------------------------------------------------
// Lazy libc bindings. Nothing here executes at import time; the `_Libc`
// singleton is only constructed when UnixPty.spawn runs (i.e. never on
// Windows).
// ---------------------------------------------------------------------------

final class _Libc {
  _Libc._()
    : _process = DynamicLibrary.process(),
      // openpty lives in libutil on glibc Linux; on macOS and musl it is in
      // the default namespace. Try the process first, then libutil.
      _util = _openUtil();

  static _Libc? _instance;
  static _Libc get instance => _instance ??= _Libc._();

  final DynamicLibrary _process;
  final DynamicLibrary? _util;

  static DynamicLibrary? _openUtil() {
    if (!Platform.isLinux) return null;
    try {
      return DynamicLibrary.open('libutil.so.1');
    } catch (_) {
      return null;
    }
  }

  /// openpty lives in libutil on glibc; elsewhere in the default namespace.
  /// int openpty(int *amaster, int *aslave, char *name,
  ///             const struct termios *termp, const struct winsize *winp);
  late final openpty = () {
    try {
      return _process.lookupFunction<
        Int32 Function(
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('openpty');
    } catch (_) {
      final util = _util;
      if (util == null) rethrow;
      return util.lookupFunction<
        Int32 Function(
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('openpty');
    }
  }();

  late final fork = _process.lookupFunction<Int32 Function(), int Function()>(
    'fork',
  );
  late final setsid = _process.lookupFunction<Int32 Function(), int Function()>(
    'setsid',
  );
  late final close = _process
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  late final dup2 = _process
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'dup2',
      );
  late final chdir = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('chdir');
  late final execvp = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      >('execvp');
  late final setenv = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('setenv');
  late final ioctl = _process
      .lookupFunction<
        Int32 Function(Int32, IntPtr, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('ioctl');
  late final kill = _process
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );
  late final write = _process
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  late final read = _process
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  late final waitpid = _process
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  late final exitFn = _process
      .lookupFunction<Void Function(Int32), void Function(int)>('_exit');
}

/// struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }
final class _WinSize extends Struct {
  @Uint16()
  external int wsRow;
  @Uint16()
  external int wsCol;
  @Uint16()
  external int wsXPixel;
  @Uint16()
  external int wsYPixel;
}

int get _tiocsctty => Platform.isMacOS ? 0x20007461 : 0x540E;
int get _tiocswinsz => Platform.isMacOS ? 0x80087467 : 0x5414;
const _sigkill = 9;

class UnixPty implements Pty {
  UnixPty._({required int masterFd, required int pid, required this.shell})
    : _masterFd = masterFd,
      _pid = pid {
    _startReader();
    _startExitWatcher();
  }

  final int _masterFd;
  final int _pid;

  @override
  final String shell;

  final _output = StreamController<Uint8List>();
  final _exit = Completer<int>();
  bool _released = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  static UnixPty spawn({
    required String cwd,
    required int cols,
    required int rows,
    String? shell,
    List<String>? arguments,
    Map<String, String>? environment,
  }) {
    final libc = _Libc.instance;
    final resolvedShell = shell ?? Platform.environment['SHELL'] ?? '/bin/sh';
    return using((arena) {
      final master = arena<Int32>();
      final slave = arena<Int32>();
      final ws = arena<_WinSize>()
        ..ref.wsCol = cols
        ..ref.wsRow = rows;
      if (libc.openpty(master, slave, nullptr, nullptr, ws.cast<Void>()) != 0) {
        throw StateError('openpty failed');
      }

      // Native strings for the child must be allocated before fork: the Dart
      // heap is not usable in the forked child.
      final shellC = resolvedShell.toNativeUtf8(allocator: arena);
      final cwdC = cwd.toNativeUtf8(allocator: arena);
      final argumentPointers = [
        shellC,
        for (final argument in arguments ?? const <String>[])
          argument.toNativeUtf8(allocator: arena),
      ];
      final argv = arena<Pointer<Utf8>>(argumentPointers.length + 1);
      argv[0] = shellC;
      for (var index = 1; index < argumentPointers.length; index++) {
        argv[index] = argumentPointers[index];
      }
      argv[argumentPointers.length] = nullptr;
      final environmentEntries = (environment ?? const <String, String>{})
          .entries
          .map(
            (entry) => (
              entry.key.toNativeUtf8(allocator: arena),
              entry.value.toNativeUtf8(allocator: arena),
            ),
          )
          .toList(growable: false);

      final pid = libc.fork();
      if (pid < 0) {
        libc.close(master.value);
        libc.close(slave.value);
        throw StateError('fork failed');
      }
      if (pid == 0) {
        // Child. Only async-signal-safe libc calls from here; never return.
        libc.close(master.value);
        libc.setsid();
        libc.ioctl(slave.value, _tiocsctty, nullptr);
        libc.dup2(slave.value, 0);
        libc.dup2(slave.value, 1);
        libc.dup2(slave.value, 2);
        if (slave.value > 2) libc.close(slave.value);
        libc.chdir(cwdC);
        for (final entry in environmentEntries) {
          libc.setenv(entry.$1, entry.$2, 1);
        }
        libc.execvp(shellC, argv);
        libc.exitFn(127); // exec failed
      }

      // Parent.
      libc.close(slave.value);
      return UnixPty._(masterFd: master.value, pid: pid, shell: resolvedShell);
    });
  }

  void _startReader() {
    final port = ReceivePort();
    port.listen((message) {
      if (message == null) {
        port.close();
        if (!_output.isClosed) unawaited(_output.close());
        return;
      }
      if (!_output.isClosed) _output.add(message as Uint8List);
    });
    Isolate.spawn(_readLoop, [_masterFd, port.sendPort]);
  }

  void _startExitWatcher() {
    final port = ReceivePort();
    port.listen((message) {
      port.close();
      _onExited(message as int);
    });
    Isolate.spawn(_waitLoop, [_pid, port.sendPort]);
  }

  void _onExited(int code) {
    _release();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _release() {
    if (_released) return;
    _released = true;
    // Closing the master fd sends HUP to the child session and unblocks the
    // reader isolate's read() with EOF/EIO.
    _Libc.instance.close(_masterFd);
  }

  @override
  void write(Uint8List data) {
    if (_released || data.isEmpty) return;
    final libc = _Libc.instance;
    using((arena) {
      final buf = arena<Uint8>(data.length);
      buf.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        final n = libc.write(_masterFd, buf + offset, data.length - offset);
        if (n <= 0) break;
        offset += n;
      }
    });
  }

  @override
  void resize(int cols, int rows) {
    if (_released) return;
    final libc = _Libc.instance;
    using((arena) {
      final ws = arena<_WinSize>()
        ..ref.wsCol = cols
        ..ref.wsRow = rows;
      libc.ioctl(_masterFd, _tiocswinsz, ws.cast<Void>());
    });
  }

  @override
  void kill() {
    if (_released) return;
    _Libc.instance.kill(_pid, _sigkill);
    // Exit watcher reaps the child and runs _onExited/_release.
  }

  /// Blocking read() loop on a dedicated isolate; sends chunks, then null on
  /// EOF/error.
  static void _readLoop(List<Object> args) {
    final fd = args[0] as int;
    final port = args[1] as SendPort;
    final read = _Libc.instance.read;
    const chunkSize = 64 * 1024;
    final buf = calloc<Uint8>(chunkSize);
    try {
      while (true) {
        final n = read(fd, buf, chunkSize);
        if (n <= 0) break;
        port.send(Uint8List.fromList(buf.asTypedList(n)));
      }
    } finally {
      calloc.free(buf);
      port.send(null);
    }
  }

  /// Blocks in waitpid until the child exits, then reports its exit code
  /// (128 + signal for signal deaths).
  static void _waitLoop(List<Object> args) {
    final pid = args[0] as int;
    final port = args[1] as SendPort;
    final waitpid = _Libc.instance.waitpid;
    final status = calloc<Int32>();
    waitpid(pid, status, 0);
    final raw = status.value;
    calloc.free(status);
    // WIFEXITED: (raw & 0x7f) == 0 -> code in high byte; else signal death.
    final code = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f);
    port.send(code);
  }
}
