/// Windows ConPTY-backed [Pty] via dart:ffi + package:win32.
///
/// Blocking pipe reads and the process-exit wait run on dedicated isolates
/// (HANDLEs are process-wide, so raw handle ints can cross isolates safely).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'pty.dart';

class WindowsPty implements Pty {
  WindowsPty._({
    required int hpc,
    required int hProcess,
    required int hThread,
    required int inputWrite,
    required int outputRead,
    required this.shell,
  }) : _hpc = hpc,
       _hProcess = hProcess,
       _hThread = hThread,
       _inputWrite = inputWrite,
       _outputRead = outputRead {
    _startReader();
    _startExitWatcher();
  }

  final int _hpc;
  final int _hProcess;
  final int _hThread;
  final int _inputWrite;
  final int _outputRead;

  @override
  final String shell;

  final _output = StreamController<Uint8List>();
  final _exit = Completer<int>();
  bool _released = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  static WindowsPty spawn({
    required String cwd,
    required int cols,
    required int rows,
    String? shell,
    List<String>? arguments,
    Map<String, String>? environment,
  }) {
    final resolvedShell = shell ?? _defaultShell();
    return using((arena) {
      // Pipe pair 1: we write -> ConPTY reads (shell stdin).
      // Pipe pair 2: ConPTY writes -> we read (shell output).
      final inRead = arena<Pointer<Void>>();
      final inWrite = arena<Pointer<Void>>();
      final outRead = arena<Pointer<Void>>();
      final outWrite = arena<Pointer<Void>>();
      final inputPipe = CreatePipe(inRead, inWrite, null, 0);
      final outputPipe = CreatePipe(outRead, outWrite, null, 0);
      if (!inputPipe.value || !outputPipe.value) {
        throw StateError('CreatePipe failed: ${GetLastError()}');
      }

      final size = arena<COORD>()
        ..ref.X = cols
        ..ref.Y = rows;
      final pseudoConsole = CreatePseudoConsole(
        size.ref,
        HANDLE(inRead.value),
        HANDLE(outWrite.value),
        0,
      );
      final hpc = pseudoConsole;

      // ConPTY duplicated its ends; close ours.
      CloseHandle(HANDLE(inRead.value));
      CloseHandle(HANDLE(outWrite.value));

      // Attribute list carrying PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
      final attrSize = arena<IntPtr>();
      InitializeProcThreadAttributeList(null, 1, attrSize);
      final attrList = arena<Uint8>(attrSize.value);
      final typedAttrList = LPPROC_THREAD_ATTRIBUTE_LIST(attrList.cast());
      if (!InitializeProcThreadAttributeList(
        typedAttrList,
        1,
        attrSize,
      ).value) {
        ClosePseudoConsole(hpc);
        throw StateError(
          'InitializeProcThreadAttributeList failed: ${GetLastError()}',
        );
      }
      if (!UpdateProcThreadAttribute(
        typedAttrList,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        Pointer.fromAddress(hpc),
        sizeOf<IntPtr>(),
        null,
        null,
      ).value) {
        ClosePseudoConsole(hpc);
        throw StateError('UpdateProcThreadAttribute failed: ${GetLastError()}');
      }

      final si = arena<STARTUPINFOEX>();
      si.ref.StartupInfo.cb = sizeOf<STARTUPINFOEX>();
      // STARTF_USESTDHANDLES with NULL handles (arena is zeroed) prevents the
      // child from inheriting our redirected stdio; without this the shell
      // writes to the daemon's console/pipes instead of the ConPTY (same
      // workaround node-pty uses).
      si.ref.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
      si.ref.lpAttributeList = typedAttrList;

      final pi = arena<PROCESS_INFORMATION>();
      final commandLine = [
        _quoteWindowsArgument(resolvedShell),
        for (final argument in arguments ?? const <String>[])
          _quoteWindowsArgument(argument),
      ].join(' ');
      final cmdLine = commandLine.toNativeUtf16(allocator: arena);
      final cwdPtr = cwd.toNativeUtf16(allocator: arena);
      final environmentPtr = _environmentBlock(environment, arena);
      final created = CreateProcess(
        null,
        PWSTR(cmdLine),
        null,
        null,
        false,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
        environmentPtr,
        PCWSTR(cwdPtr),
        si.cast(),
        pi,
      );
      typedAttrList.close();
      if (!created.value) {
        ClosePseudoConsole(hpc);
        CloseHandle(HANDLE(inWrite.value));
        CloseHandle(HANDLE(outRead.value));
        throw StateError(
          'CreateProcess("$resolvedShell") failed: ${created.error.code}',
        );
      }

      return WindowsPty._(
        hpc: hpc,
        hProcess: pi.ref.hProcess.address,
        hThread: pi.ref.hThread.address,
        inputWrite: inWrite.value.address,
        outputRead: outRead.value.address,
        shell: resolvedShell,
      );
    });
  }

  static String _defaultShell() {
    // Prefer Windows PowerShell; fall back to COMSPEC (cmd.exe).
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final powershell =
        '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    if (File(powershell).existsSync()) return powershell;
    return Platform.environment['COMSPEC'] ?? 'cmd.exe';
  }

  static String _quoteWindowsArgument(String value) {
    if (value.isNotEmpty && !value.contains(RegExp(r'[\s"]'))) return value;
    final out = StringBuffer('"');
    var slashes = 0;
    for (final rune in value.runes) {
      if (rune == 0x5c) {
        slashes++;
      } else if (rune == 0x22) {
        out
          ..write('\\' * (slashes * 2 + 1))
          ..write('"');
        slashes = 0;
      } else {
        out
          ..write('\\' * slashes)
          ..writeCharCode(rune);
        slashes = 0;
      }
    }
    out
      ..write('\\' * (slashes * 2))
      ..write('"');
    return out.toString();
  }

  static Pointer<Void> _environmentBlock(
    Map<String, String>? additions,
    Arena arena,
  ) {
    final merged = <String, String>{...Platform.environment, ...?additions};
    final entries = merged.entries.toList()
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    final text =
        '${entries.map((entry) => '${entry.key}=${entry.value}').join('\u0000')}\u0000\u0000';
    final units = text.codeUnits;
    final block = arena<Uint16>(units.length);
    for (var index = 0; index < units.length; index++) {
      block[index] = units[index];
    }
    return block.cast();
  }

  void _startReader() {
    final port = ReceivePort();
    port.listen((message) {
      if (message == null) {
        // Reader hit EOF/broken pipe: safe to close our read handle now.
        port.close();
        CloseHandle(HANDLE(Pointer.fromAddress(_outputRead)));
        if (!_output.isClosed) unawaited(_output.close());
        return;
      }
      if (!_output.isClosed) _output.add(message as Uint8List);
    });
    Isolate.spawn(_readLoop, [_outputRead, port.sendPort]);
  }

  void _startExitWatcher() {
    final port = ReceivePort();
    port.listen((message) {
      port.close();
      _onExited(message as int);
    });
    Isolate.spawn(_waitLoop, [_hProcess, port.sendPort]);
  }

  void _onExited(int code) {
    _release();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// Closes the pseudoconsole and our pipe ends. Closing the pseudoconsole
  /// breaks the output pipe, which unblocks the reader isolate.
  void _release() {
    if (_released) return;
    _released = true;
    ClosePseudoConsole(HPCON(_hpc));
    CloseHandle(HANDLE(Pointer.fromAddress(_inputWrite)));
    CloseHandle(HANDLE(Pointer.fromAddress(_hThread)));
    CloseHandle(HANDLE(Pointer.fromAddress(_hProcess)));
    // _outputRead is closed by the reader listener once ReadFile fails; if the
    // reader is already done it was closed there.
  }

  @override
  void write(Uint8List data) {
    if (_released || data.isEmpty) return;
    using((arena) {
      final buf = arena<Uint8>(data.length);
      buf.asTypedList(data.length).setAll(0, data);
      final written = arena<Uint32>();
      WriteFile(
        HANDLE(Pointer.fromAddress(_inputWrite)),
        buf,
        data.length,
        written,
        null,
      );
    });
  }

  @override
  void resize(int cols, int rows) {
    if (_released) return;
    using((arena) {
      final size = arena<COORD>()
        ..ref.X = cols
        ..ref.Y = rows;
      ResizePseudoConsole(HPCON(_hpc), size.ref);
    });
  }

  @override
  void kill() {
    if (_released) return;
    TerminateProcess(HANDLE(Pointer.fromAddress(_hProcess)), 1);
    // Exit watcher observes the termination and runs _onExited/_release.
  }

  /// Blocking ReadFile loop on a dedicated isolate; sends Uint8List chunks,
  /// then null on EOF/broken pipe.
  static void _readLoop(List<Object> args) {
    final handle = args[0] as int;
    final port = args[1] as SendPort;
    const chunkSize = 64 * 1024;
    final buf = calloc<Uint8>(chunkSize);
    final read = calloc<Uint32>();
    try {
      while (true) {
        final result = ReadFile(
          HANDLE(Pointer.fromAddress(handle)),
          buf,
          chunkSize,
          read,
          null,
        );
        if (!result.value || read.value == 0) break;
        port.send(Uint8List.fromList(buf.asTypedList(read.value)));
      }
    } finally {
      calloc.free(buf);
      calloc.free(read);
      port.send(null);
    }
  }

  /// Blocks until the shell process exits, then reports its exit code.
  static void _waitLoop(List<Object> args) {
    final handle = args[0] as int;
    final port = args[1] as SendPort;
    WaitForSingleObject(HANDLE(Pointer.fromAddress(handle)), INFINITE);
    final code = calloc<Uint32>();
    GetExitCodeProcess(HANDLE(Pointer.fromAddress(handle)), code);
    final value = code.value;
    calloc.free(code);
    port.send(value);
  }
}
