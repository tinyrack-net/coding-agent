/// Terminal session registry: owns PTYs, retains scrollback, and fans binary
/// output frames out to per-connection subscription slots.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/core.dart' as xterm;

import 'pty/pty.dart';
import 'terminal_activity_tracker.dart';
import 'terminal_output_coalescer.dart';

/// Matches [Pty.spawn]; injectable so tests can supply a fake.
typedef PtySpawner =
    Pty Function({
      required String cwd,
      int cols,
      int rows,
      String? shell,
      List<String>? arguments,
      Map<String, String>? environment,
    });

enum TerminalActivityTokenValidation { valid, unknown, invalid }

final class TerminalActivityTransition {
  const TerminalActivityTransition({
    required this.terminalId,
    required this.terminalName,
    required this.cwd,
    required this.workspaceId,
    required this.activity,
    required this.previous,
  });

  final String terminalId;
  final String terminalName;
  final String cwd;
  final String? workspaceId;
  final TerminalActivity? activity;
  final TerminalActivity? previous;
}

final class TerminalsChangedEvent {
  const TerminalsChangedEvent({required this.cwd});
  final String cwd;
}

/// Max retained scrollback per terminal (snapshot sent on subscribe).
const int kScrollbackLimit = 256 * 1024;
const int kMaxTerminalOutputFrameBytes = 256 * 1024;
const int kMaxClientBufferedBytes = 4 * 1024 * 1024;

class TerminalManager {
  TerminalManager({
    required this.sendBinary,
    required this.onExited,
    this.onWorkspaceContributionChanged,
    this.onActivityChanged,
    this.onStreamExited,
    this.getClientBufferedAmount,
    PtySpawner? spawn,
    String? Function()? getTerminalActivityUrl,
    String Function()? activityTokenFactory,
    TerminalActivityClock? activityClock,
    this.scrollbackLimit = kScrollbackLimit,
  }) : _spawn = spawn ?? Pty.spawn,
       _getTerminalActivityUrl = getTerminalActivityUrl ?? (() => null),
       _activityTokenFactory =
           activityTokenFactory ?? _createTerminalActivityToken,
       _activityClock =
           activityClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Sends a raw binary WebSocket frame to one connection.
  final void Function(String connectionId, Uint8List bytes) sendBinary;

  /// Called after a shell dies and its session is cleaned up (broadcast the
  /// `terminal.exited` event from here).
  final void Function(String terminalId, int? exitCode) onExited;

  /// Emitted only when a terminal's derived workspace bucket changes.
  final void Function(String? workspaceId)? onWorkspaceContributionChanged;
  final void Function(TerminalActivityTransition transition)? onActivityChanged;
  final void Function(String connectionId, String terminalId)? onStreamExited;
  final int? Function(String connectionId)? getClientBufferedAmount;

  final PtySpawner _spawn;
  final String? Function() _getTerminalActivityUrl;
  final String Function() _activityTokenFactory;
  final TerminalActivityClock _activityClock;
  final int scrollbackLimit;

  final Map<String, _Session> _sessions = {};
  final Map<String, Map<String, String>> _defaultEnvironmentByCwd = {};

  /// connectionId -> slotId -> terminalId (input/resize routing).
  final Map<String, Map<int, String>> _slots = {};
  final Map<String, int> _nextSlot = {};
  final Set<void Function(TerminalsChangedEvent)> _terminalsChangedListeners =
      {};
  final _uuid = const Uuid();
  bool _disposed = false;

  /// {terminalId, cwd, shell} for the create response.
  Map<String, Object?> create({
    required String cwd,
    String? workspaceId,
    String? name,
    String? title,
    String? command,
    List<String>? arguments,
    int? cols,
    int? rows,
    Map<String, String> environment = const {},
  }) {
    final id = _uuid.v4();
    final activityToken = _activityTokenFactory();
    final activityUrl = _getTerminalActivityUrl();
    final activityEnvironment = {
      ...?_resolveDefaultEnvironment(cwd),
      ...environment,
      'TINYRACK_TERMINAL_ID': id,
      'TINYRACK_ACTIVITY_TOKEN': activityToken,
      if (activityUrl != null) 'TINYRACK_TERMINAL_ACTIVITY_URL': activityUrl,
    };
    final pty = _spawn(
      cwd: cwd,
      cols: cols ?? 80,
      rows: rows ?? 24,
      shell: command,
      arguments: arguments,
      environment: activityEnvironment,
    );
    final tracker = TerminalActivityTracker(now: _activityClock);
    final emulator = xterm.Terminal(maxLines: 10000)
      ..resize(cols ?? 80, rows ?? 24);
    final session = _Session(
      terminalId: id,
      pty: pty,
      cwd: cwd,
      workspaceId: workspaceId,
      name:
          name ??
          'Terminal ${_sessions.values.where((session) => session.cwd == cwd).length + 1}',
      title: title,
      activityToken: activityToken,
      activityTracker: tracker,
      scrollback: _RingBuffer(scrollbackLimit),
      emulator: emulator,
    );
    session.decoder = utf8.decoder.startChunkedConversion(
      StringConversionSink.from(_StringCallbackSink(emulator.write)),
    );
    emulator.onTitleChange = (title) {
      session.emulatorTitle = title;
      _emitTerminalsChanged(cwd);
    };
    session.activityUnsubscribe = tracker.onChange((activity, previous) {
      onActivityChanged?.call(
        TerminalActivityTransition(
          terminalId: id,
          terminalName: session.name,
          cwd: cwd,
          workspaceId: workspaceId,
          activity: activity,
          previous: previous,
        ),
      );
      final previousBucket = deriveTerminalActivityStatusBucket(previous);
      final nextBucket = deriveTerminalActivityStatusBucket(activity);
      if (previousBucket != nextBucket) {
        onWorkspaceContributionChanged?.call(workspaceId);
      }
      _emitTerminalsChanged(cwd);
    });
    _sessions[id] = session;
    _emitTerminalsChanged(cwd);

    session.outputSub = pty.output.listen((chunk) {
      session.scrollback.add(chunk);
      session.decoder.add(chunk);
      final inputModeUpdate = session.inputModeTracker.feed(
        utf8.decode(chunk, allowMalformed: true),
      );
      for (final response in inputModeUpdate.responses) {
        session.pty.write(Uint8List.fromList(utf8.encode(response)));
      }
      session.revision++;
      for (final stream in session.subscribers.values.toList()) {
        if (stream.needsSnapshot || stream.snapshotInFlight) {
          stream.bufferedOutputs.add(
            _RevisionedOutput(
              data: Uint8List.fromList(chunk),
              revision: session.revision,
            ),
          );
        } else {
          stream.outputCoalescer.handle(chunk);
        }
      }
    });

    unawaited(pty.exitCode.then((code) => _onSessionExit(id, code)));

    return {
      'terminalId': id,
      'cwd': cwd,
      'shell': pty.shell,
      if (workspaceId != null) 'workspaceId': workspaceId,
      'activity': null,
    };
  }

  /// Registers environment inherited by terminals opened at [cwd] or below.
  ///
  /// The longest matching root wins, matching Paseo's worktree runtime
  /// environment behavior. Per-terminal values still override inherited
  /// values, while protected activity fields are assigned last by [create].
  void registerCwdEnvironment(String cwd, Map<String, String> environment) {
    _defaultEnvironmentByCwd[_normalizePath(cwd)] = Map.of(environment);
  }

  Map<String, String>? _resolveDefaultEnvironment(String cwd) {
    final candidate = _normalizePath(cwd);
    String? bestRoot;
    for (final root in _defaultEnvironmentByCwd.keys) {
      if (candidate != root && !candidate.startsWith('$root/')) continue;
      if (bestRoot == null || root.length > bestRoot.length) bestRoot = root;
    }
    return bestRoot == null ? null : _defaultEnvironmentByCwd[bestRoot];
  }

  List<Map<String, Object?>> list() => [
    for (final s in _sessions.values)
      {
        'terminalId': s.terminalId,
        'cwd': s.cwd,
        'shell': s.pty.shell,
        if (s.workspaceId != null) 'workspaceId': s.workspaceId,
        'activity': s.activityTracker.activity?.toJson(),
      },
  ];

  /// Paseo v2 projection. The legacy `terminal.*` adapter continues to use
  /// [list], while v2 callers receive the upstream id/name/cwd shape.
  List<Map<String, Object?>> listV2({String? cwd, String? workspaceId}) => [
    for (final s in _sessions.values)
      if ((cwd == null || _isSameOrDescendant(cwd, s.cwd)) &&
          (workspaceId == null || workspaceId == s.workspaceId))
        {
          'id': s.terminalId,
          'name': s.name,
          'cwd': s.cwd,
          if (s.workspaceId != null) 'workspaceId': s.workspaceId,
          if (s.title != null) 'title': s.title,
          'activity': s.activityTracker.activity?.toJson(),
        },
  ];

  bool rename(String terminalId, String title) {
    final session = _require(terminalId);
    session.title = title;
    _emitTerminalsChanged(session.cwd);
    return true;
  }

  void resize(String terminalId, int cols, int rows) {
    final session = _require(terminalId);
    if (session.emulator.viewWidth == cols &&
        session.emulator.viewHeight == rows) {
      return;
    }
    session.pty.resize(cols, rows);
    session.emulator.resize(cols, rows);
    session.revision++;
  }

  TerminalState snapshot(
    String terminalId, {
    int? scrollbackLines,
    bool includeWrapFlags = false,
  }) {
    final session = _require(terminalId);
    final terminal = session.emulator;
    final buffer = terminal.buffer;
    final scrollbackCount = buffer.scrollBack;
    final firstScrollback = scrollbackLines == null
        ? 0
        : max(0, scrollbackCount - scrollbackLines);

    List<TerminalCell> rowAt(int row) {
      final line = row >= 0 && row < buffer.lines.length
          ? buffer.lines[row]
          : null;
      return [
        for (var col = 0; col < terminal.viewWidth; col++)
          _terminalCell(line, col),
      ];
    }

    bool continuesAt(int row) =>
        row + 1 < buffer.lines.length && buffer.lines[row + 1].isWrapped;

    return TerminalState(
      rows: terminal.viewHeight,
      cols: terminal.viewWidth,
      grid: [
        for (var row = 0; row < terminal.viewHeight; row++)
          rowAt(scrollbackCount + row),
      ],
      scrollback: [
        for (var row = firstScrollback; row < scrollbackCount; row++)
          rowAt(row),
      ],
      cursor: TerminalCursor(
        row: buffer.cursorY,
        col: buffer.cursorX,
        hidden: terminal.cursorVisibleMode ? null : true,
        blink: terminal.cursorBlinkMode,
      ),
      title: session.emulatorTitle,
      gridWrapped: includeWrapFlags
          ? [
              for (var row = 0; row < terminal.viewHeight; row++)
                continuesAt(scrollbackCount + row),
            ]
          : null,
      scrollbackWrapped: includeWrapFlags
          ? [
              for (var row = firstScrollback; row < scrollbackCount; row++)
                continuesAt(row),
            ]
          : null,
    );
  }

  TerminalCapture capture(
    String terminalId, {
    int? start,
    int? end,
    bool stripAnsi = true,
  }) {
    final bytes = _sessions[terminalId]?.scrollback.snapshot();
    if (bytes == null) return const TerminalCapture(lines: [], totalLines: 0);
    final rendered = _renderTerminalText(
      utf8.decode(bytes, allowMalformed: true),
      stripAnsi: stripAnsi,
    );
    final lines = rendered.split('\n').map((line) => line.trimRight()).toList();
    final total = lines.length;
    if (total == 0) {
      return const TerminalCapture(lines: [], totalLines: 0);
    }
    int resolve(int? value, int fallback) {
      if (value == null) return fallback;
      final resolved = value < 0 ? total + value : value;
      return resolved.clamp(0, total - 1);
    }

    final first = resolve(start, 0);
    final last = resolve(end, total - 1);
    return TerminalCapture(
      lines: first > last ? const [] : lines.sublist(first, last + 1),
      totalLines: total,
    );
  }

  List<TerminalWorkspaceContribution> listActivityContributions() => [
    for (final session in _sessions.values)
      TerminalWorkspaceContribution(
        cwd: session.cwd,
        workspaceId: session.workspaceId,
        activity: session.activityTracker.activity,
      ),
  ];

  bool setActivity(String terminalId, TerminalActivityState state) =>
      _require(terminalId).activityTracker.set(state);

  bool clearAttention(String terminalId) =>
      _require(terminalId).activityTracker.clearAttention();

  TerminalActivityTokenValidation validateActivityToken(
    String terminalId,
    String token,
  ) {
    final session = _sessions[terminalId];
    if (session == null) return TerminalActivityTokenValidation.unknown;
    return session.activityToken == token
        ? TerminalActivityTokenValidation.valid
        : TerminalActivityTokenValidation.invalid;
  }

  void kill(String terminalId) {
    _require(terminalId).pty.kill();
    // Cleanup + exited broadcast happen when the exit future completes.
  }

  bool contains(String terminalId) => _sessions.containsKey(terminalId);

  void sendInput(String terminalId, String text) {
    _require(terminalId).pty.write(Uint8List.fromList(utf8.encode(text)));
  }

  Future<int?> killAndWait(String terminalId) async {
    final session = _require(terminalId);
    session.pty.kill();
    return session.pty.exitCode;
  }

  /// Registers [connectionId] on [terminalId]; returns the assigned slotId and
  /// immediately sends the scrollback snapshot frame.
  int subscribe(
    String connectionId,
    String terminalId, {
    TerminalRestoreOptions? restore,
    bool includeWrapFlags = false,
  }) {
    final session = _require(terminalId);
    final existing = session.subscribers[connectionId];
    if (existing != null) {
      existing.outputCoalescer.flush();
      existing.restore = restore;
      existing.includeWrapFlags = includeWrapFlags;
      existing.needsSnapshot = true;
      existing.bufferedOutputs.clear();
      _scheduleInitialFrame(connectionId, session, existing);
      return existing.slotId;
    }

    final slots = _slots[connectionId] ??= {};
    final start = _nextSlot[connectionId] ?? 0;
    int? slotId;
    for (var offset = 0; offset < 256; offset++) {
      final candidate = (start + offset) & 0xff;
      if (!slots.containsKey(candidate)) {
        slotId = candidate;
        break;
      }
    }
    if (slotId == null) {
      throw StateError('no terminal stream slots available');
    }
    _nextSlot[connectionId] = (slotId + 1) & 0xff;
    late final _ActiveTerminalStream stream;
    stream = _ActiveTerminalStream(
      connectionId: connectionId,
      terminalId: terminalId,
      slotId: slotId,
      restore: restore,
      includeWrapFlags: includeWrapFlags,
      outputCoalescer: TerminalOutputCoalescer(
        onFlush: (batch) => _flushOutput(session, stream, batch),
      ),
    );
    session.subscribers[connectionId] = stream;
    slots[slotId] = terminalId;

    _scheduleInitialFrame(connectionId, session, stream);
    return slotId;
  }

  void _scheduleInitialFrame(
    String connectionId,
    _Session session,
    _ActiveTerminalStream stream,
  ) {
    Timer.run(() {
      if (_sessions[session.terminalId] != session) return;
      if (session.subscribers[connectionId] != stream) return;
      _trySendSnapshot(session, stream);
    });
  }

  void _flushOutput(
    _Session session,
    _ActiveTerminalStream stream,
    TerminalOutputBatch batch,
  ) {
    if (session.subscribers[stream.connectionId] != stream) return;
    stream.outputBytesSinceSnapshot += batch.bytes;
    final bufferedAmount = getClientBufferedAmount?.call(stream.connectionId);
    if (stream.outputBytesSinceSnapshot > kMaxTerminalOutputFrameBytes &&
        (bufferedAmount == null || bufferedAmount > kMaxClientBufferedBytes)) {
      stream.restore = const TerminalRestoreOptions(
        mode: TerminalRestoreMode.visibleSnapshot,
        scrollbackLines: 200,
      );
      stream.needsSnapshot = true;
      _scheduleInitialFrame(stream.connectionId, session, stream);
      return;
    }
    sendBinary(
      stream.connectionId,
      TerminalFrame(
        opcode: TerminalOpcode.output,
        slotId: stream.slotId,
        payload: batch.payload,
      ).encode(),
    );
  }

  void _trySendSnapshot(_Session session, _ActiveTerminalStream stream) {
    if (!stream.needsSnapshot ||
        stream.snapshotInFlight ||
        _sessions[session.terminalId] != session ||
        session.subscribers[stream.connectionId] != stream) {
      return;
    }
    stream.outputCoalescer.flush();
    stream.snapshotInFlight = true;
    try {
      final revision = session.revision;
      final restore = stream.restore;
      if (restore?.mode != TerminalRestoreMode.live) {
        final scrollbackLines = switch (restore?.mode) {
          TerminalRestoreMode.visibleSnapshot =>
            (restore!.scrollbackLines ?? 200).clamp(0, 500),
          _ => null,
        };
        final state = snapshot(
          session.terminalId,
          scrollbackLines: scrollbackLines,
          includeWrapFlags: stream.includeWrapFlags,
        );
        final frame = restore == null
            ? TerminalFrame.snapshot(stream.slotId, state)
            : TerminalFrame.restore(stream.slotId, state);
        sendBinary(stream.connectionId, frame.encode());
        stream.outputCoalescer.markFlushed();
      }

      final preamble = session.inputModeTracker.getPreamble();
      if (preamble.isNotEmpty) {
        sendBinary(
          stream.connectionId,
          TerminalFrame(
            opcode: TerminalOpcode.output,
            slotId: stream.slotId,
            payload: Uint8List.fromList(utf8.encode(preamble)),
          ).encode(),
        );
      }
      for (final output in stream.bufferedOutputs) {
        if (output.revision <= revision) continue;
        sendBinary(
          stream.connectionId,
          TerminalFrame(
            opcode: TerminalOpcode.output,
            slotId: stream.slotId,
            payload: output.data,
          ).encode(),
        );
      }
      stream.bufferedOutputs.clear();
      stream.needsSnapshot = false;
      stream.outputBytesSinceSnapshot = 0;
    } finally {
      stream.snapshotInFlight = false;
    }
  }

  void Function() subscribeTerminalsChanged(
    void Function(TerminalsChangedEvent) listener,
  ) {
    _terminalsChangedListeners.add(listener);
    return () => _terminalsChangedListeners.remove(listener);
  }

  void _emitTerminalsChanged(String cwd) {
    final event = TerminalsChangedEvent(cwd: cwd);
    for (final listener in _terminalsChangedListeners.toList()) {
      listener(event);
    }
  }

  void unsubscribe(String connectionId, String terminalId) {
    final session = _require(terminalId);
    final stream = session.subscribers.remove(connectionId);
    if (stream == null) return;
    stream.outputCoalescer.flush();
    stream.outputCoalescer.dispose();
    stream.bufferedOutputs.clear();
    _slots[connectionId]?.remove(stream.slotId);
  }

  /// Routes a client binary frame (input/resize) by (connection, slot).
  /// Unknown slots and daemon->client opcodes are ignored.
  void handleFrame(String connectionId, TerminalFrame frame) {
    final terminalId = _slots[connectionId]?[frame.slotId];
    if (terminalId == null) return;
    final session = _sessions[terminalId];
    if (session == null) return;
    switch (frame.opcode) {
      case TerminalOpcode.input:
        session.pty.write(frame.payload);
      case TerminalOpcode.resize:
        final size = frame.tryResizeSize;
        if (size == null) return;
        final (cols, rows) = size;
        session.pty.resize(cols, rows);
        session.emulator.resize(cols, rows);
        session.revision++;
      case TerminalOpcode.output:
      case TerminalOpcode.snapshot:
      case TerminalOpcode.restore:
        break; // daemon -> client only
    }
  }

  /// Drops all subscriptions held by a closed connection.
  void onConnectionClosed(String connectionId) {
    final slots = _slots.remove(connectionId);
    _nextSlot.remove(connectionId);
    if (slots == null) return;
    for (final terminalId in slots.values) {
      final stream = _sessions[terminalId]?.subscribers.remove(connectionId);
      stream?.outputCoalescer.dispose();
      stream?.bufferedOutputs.clear();
    }
  }

  void _onSessionExit(String terminalId, int? exitCode) {
    final session = _sessions.remove(terminalId);
    if (session == null) return;
    final contributed =
        deriveTerminalActivityStatusBucket(session.activityTracker.activity) !=
        null;
    session.activityUnsubscribe?.call();
    session.activityTracker.dispose();
    session.decoder.close();
    unawaited(session.outputSub?.cancel());
    for (final entry in session.subscribers.entries) {
      final stream = entry.value;
      stream.outputCoalescer.flush();
      stream.outputCoalescer.dispose();
      stream.bufferedOutputs.clear();
      _slots[entry.key]?.remove(stream.slotId);
      onStreamExited?.call(entry.key, terminalId);
    }
    if (contributed) {
      onWorkspaceContributionChanged?.call(session.workspaceId);
    }
    _emitTerminalsChanged(session.cwd);
    if (!_disposed) onExited(terminalId, exitCode);
  }

  Future<void> dispose() async {
    _disposed = true;
    final sessions = _sessions.values.toList(growable: false);
    for (final session in sessions) {
      session.activityUnsubscribe?.call();
      session.activityTracker.dispose();
      session.decoder.close();
      session.inputModeTracker.reset();
      session.pty.kill();
      for (final stream in session.subscribers.values) {
        stream.outputCoalescer.dispose();
      }
    }
    await Future.wait([
      for (final session in sessions)
        session.pty.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        ),
    ]);
    for (final session in sessions) {
      await session.outputSub?.cancel();
    }
    _sessions.clear();
    _slots.clear();
    _nextSlot.clear();
    _terminalsChangedListeners.clear();
  }

  _Session _require(String terminalId) {
    final session = _sessions[terminalId];
    if (session == null) {
      throw StateError('unknown terminal: $terminalId');
    }
    return session;
  }
}

class _Session {
  _Session({
    required this.terminalId,
    required this.pty,
    required this.cwd,
    required this.workspaceId,
    required this.name,
    required this.title,
    required this.activityToken,
    required this.activityTracker,
    required this.scrollback,
    required this.emulator,
  });

  final String terminalId;
  final Pty pty;
  final String cwd;
  final String? workspaceId;
  final String name;
  String? title;
  final String activityToken;
  final TerminalActivityTracker activityTracker;
  final _RingBuffer scrollback;
  final xterm.Terminal emulator;
  late final ByteConversionSink decoder;
  int revision = 0;
  String? emulatorTitle;
  void Function()? activityUnsubscribe;

  final TerminalInputModeTracker inputModeTracker = TerminalInputModeTracker();

  /// connectionId -> active stream.
  final Map<String, _ActiveTerminalStream> subscribers = {};
  StreamSubscription<Uint8List>? outputSub;
}

final class _RevisionedOutput {
  const _RevisionedOutput({required this.data, required this.revision});
  final Uint8List data;
  final int revision;
}

final class _ActiveTerminalStream {
  _ActiveTerminalStream({
    required this.connectionId,
    required this.terminalId,
    required this.slotId,
    required this.restore,
    required this.includeWrapFlags,
    required this.outputCoalescer,
  });

  final String connectionId;
  final String terminalId;
  final int slotId;
  TerminalRestoreOptions? restore;
  bool includeWrapFlags;
  final TerminalOutputCoalescer outputCoalescer;
  bool needsSnapshot = true;
  bool snapshotInFlight = false;
  final List<_RevisionedOutput> bufferedOutputs = [];
  int outputBytesSinceSnapshot = 0;
}

final class TerminalCapture {
  const TerminalCapture({required this.lines, required this.totalLines});
  final List<String> lines;
  final int totalLines;
}

final class _StringCallbackSink implements Sink<String> {
  const _StringCallbackSink(this.callback);
  final void Function(String value) callback;

  @override
  void add(String data) => callback(data);

  @override
  void close() {}
}

TerminalCell _terminalCell(xterm.BufferLine? line, int col) {
  if (line == null || col >= line.length) {
    return const TerminalCell(char: ' ');
  }
  final codePoint = line.getCodePoint(col);
  final foreground = line.getForeground(col);
  final background = line.getBackground(col);
  final attributes = line.getAttributes(col);
  final fgMode =
      (foreground & xterm.CellColor.typeMask) >> xterm.CellColor.typeShift;
  final bgMode =
      (background & xterm.CellColor.typeMask) >> xterm.CellColor.typeShift;
  return TerminalCell(
    char: codePoint == 0 ? ' ' : String.fromCharCode(codePoint),
    fg: fgMode == 0 ? null : foreground & xterm.CellColor.valueMask,
    bg: bgMode == 0 ? null : background & xterm.CellColor.valueMask,
    fgMode: fgMode == 0 ? null : fgMode,
    bgMode: bgMode == 0 ? null : bgMode,
    bold: attributes & xterm.CellAttr.bold != 0,
    italic: attributes & xterm.CellAttr.italic != 0,
    underline: attributes & xterm.CellAttr.underline != 0,
    dim: attributes & xterm.CellAttr.faint != 0,
    inverse: attributes & xterm.CellAttr.inverse != 0,
    strikethrough: attributes & xterm.CellAttr.strikethrough != 0,
  );
}

bool _isSameOrDescendant(String root, String candidate) {
  final normalizedRoot = _normalizePath(root);
  final normalizedCandidate = _normalizePath(candidate);
  return normalizedCandidate == normalizedRoot ||
      normalizedCandidate.startsWith('$normalizedRoot/');
}

String _normalizePath(String value) {
  final normalized = value
      .replaceAll('\\', '/')
      .replaceAll(RegExp('/+'), '/')
      .replaceAll(RegExp(r'/$'), '');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _renderTerminalText(String input, {required bool stripAnsi}) {
  var output = stripAnsi
      ? input.replaceAll(
          RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'),
          '',
        )
      : input;
  output = output.replaceAll('\r\n', '\n');
  final rendered = StringBuffer();
  var line = <int>[];
  var cursor = 0;
  void flush() {
    rendered.write(String.fromCharCodes(line));
    rendered.write('\n');
    line = [];
    cursor = 0;
  }

  for (final rune in output.runes) {
    if (rune == 10) {
      flush();
    } else if (rune == 13) {
      cursor = 0;
    } else if (rune == 8) {
      if (cursor > 0) cursor--;
    } else {
      if (cursor < line.length) {
        line[cursor] = rune;
      } else {
        line.add(rune);
      }
      cursor++;
    }
  }
  rendered.write(String.fromCharCodes(line));
  return rendered.toString();
}

String _createTerminalActivityToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

final class TerminalWorkspaceContribution {
  const TerminalWorkspaceContribution({
    required this.cwd,
    required this.workspaceId,
    required this.activity,
  });

  final String cwd;
  final String? workspaceId;
  final TerminalActivity? activity;
}

/// Byte ring buffer built from chunks; trims oldest bytes past [limit].
class _RingBuffer {
  _RingBuffer(this.limit);

  final int limit;
  final Queue<Uint8List> _chunks = Queue();
  int _length = 0;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (chunk.length >= limit) {
      _chunks.clear();
      _chunks.add(Uint8List.sublistView(chunk, chunk.length - limit));
      _length = limit;
      return;
    }
    _chunks.add(chunk);
    _length += chunk.length;
    while (_length > limit) {
      final excess = _length - limit;
      final head = _chunks.first;
      if (head.length <= excess) {
        _chunks.removeFirst();
        _length -= head.length;
      } else {
        _chunks
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(head, excess));
        _length -= excess;
      }
    }
  }

  Uint8List snapshot() {
    final out = Uint8List(_length);
    var offset = 0;
    for (final chunk in _chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }
}
