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

/// win32 5.5.0 does not export DeleteProcThreadAttributeList; bind it here.
final _deleteProcThreadAttributeList = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<Void Function(Pointer), void Function(Pointer)>(
        'DeleteProcThreadAttributeList');

class WindowsPty implements Pty {
  WindowsPty._({
    required int hpc,
    required int hProcess,
    required int hThread,
    required int inputWrite,
    required int outputRead,
    required this.shell,
  })  : _hpc = hpc,
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
  }) {
    final resolvedShell = shell ?? _defaultShell();
    return using((arena) {
      // Pipe pair 1: we write -> ConPTY reads (shell stdin).
      // Pipe pair 2: ConPTY writes -> we read (shell output).
      final inRead = arena<IntPtr>();
      final inWrite = arena<IntPtr>();
      final outRead = arena<IntPtr>();
      final outWrite = arena<IntPtr>();
      if (CreatePipe(inRead, inWrite, nullptr, 0) == 0 ||
          CreatePipe(outRead, outWrite, nullptr, 0) == 0) {
        throw StateError('CreatePipe failed: ${GetLastError()}');
      }

      final size = arena<COORD>()
        ..ref.X = cols
        ..ref.Y = rows;
      final phPC = arena<IntPtr>();
      final hr = CreatePseudoConsole(
          size.ref, inRead.value, outWrite.value, 0, phPC);
      if (FAILED(hr)) {
        throw StateError('CreatePseudoConsole failed: hr=0x${hr.toRadixString(16)}');
      }
      final hpc = phPC.value;

      // ConPTY duplicated its ends; close ours.
      CloseHandle(inRead.value);
      CloseHandle(outWrite.value);

      // Attribute list carrying PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
      final attrSize = arena<IntPtr>();
      InitializeProcThreadAttributeList(nullptr, 1, 0, attrSize);
      final attrList = arena<Uint8>(attrSize.value);
      if (InitializeProcThreadAttributeList(attrList, 1, 0, attrSize) == 0) {
        ClosePseudoConsole(hpc);
        throw StateError(
            'InitializeProcThreadAttributeList failed: ${GetLastError()}');
      }
      if (UpdateProcThreadAttribute(
            attrList,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            Pointer.fromAddress(hpc),
            sizeOf<IntPtr>(),
            nullptr,
            nullptr,
          ) ==
          0) {
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
      si.ref.lpAttributeList = attrList.cast();

      final pi = arena<PROCESS_INFORMATION>();
      final cmdLine = resolvedShell.toNativeUtf16(allocator: arena);
      final cwdPtr = cwd.toNativeUtf16(allocator: arena);
      final created = CreateProcess(
        nullptr,
        cmdLine,
        nullptr,
        nullptr,
        FALSE,
        EXTENDED_STARTUPINFO_PRESENT,
        nullptr,
        cwdPtr,
        si.cast(),
        pi,
      );
      final createError = GetLastError();
      _deleteProcThreadAttributeList(attrList);
      if (created == 0) {
        ClosePseudoConsole(hpc);
        CloseHandle(inWrite.value);
        CloseHandle(outRead.value);
        throw StateError(
            'CreateProcess("$resolvedShell") failed: $createError');
      }

      return WindowsPty._(
        hpc: hpc,
        hProcess: pi.ref.hProcess,
        hThread: pi.ref.hThread,
        inputWrite: inWrite.value,
        outputRead: outRead.value,
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

  void _startReader() {
    final port = ReceivePort();
    port.listen((message) {
      if (message == null) {
        // Reader hit EOF/broken pipe: safe to close our read handle now.
        port.close();
        CloseHandle(_outputRead);
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
    ClosePseudoConsole(_hpc);
    CloseHandle(_inputWrite);
    CloseHandle(_hThread);
    CloseHandle(_hProcess);
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
      WriteFile(_inputWrite, buf, data.length, written, nullptr);
    });
  }

  @override
  void resize(int cols, int rows) {
    if (_released) return;
    using((arena) {
      final size = arena<COORD>()
        ..ref.X = cols
        ..ref.Y = rows;
      ResizePseudoConsole(_hpc, size.ref);
    });
  }

  @override
  void kill() {
    if (_released) return;
    TerminateProcess(_hProcess, 1);
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
        final ok = ReadFile(handle, buf, chunkSize, read, nullptr);
        if (ok == 0 || read.value == 0) break;
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
    WaitForSingleObject(handle, INFINITE);
    final code = calloc<Uint32>();
    GetExitCodeProcess(handle, code);
    final value = code.value;
    calloc.free(code);
    port.send(value);
  }
}
