import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'daemon_providers.dart';
import '../terminal/terminal_keys.dart';
import 'workspace_terminal_session.dart';
import 'worktree_tabs_provider.dart';

enum TerminalSessionStatus { starting, running, exited, error }

/// Identifies one terminal tab: the worktree whose path is its `cwd`, plus
/// the [WorktreeTab.tabId] it belongs to (a worktree can have several
/// terminal tabs, each backed by its own daemon-side PTY).
typedef TerminalSessionKey = ({
  String worktreePath,
  String tabId,
  String? workspaceId,
});

/// UI-facing snapshot of one embedded terminal session.
class TerminalSessionState {
  const TerminalSessionState({
    required this.terminal,
    this.status = TerminalSessionStatus.starting,
    this.exitCode,
    this.errorMessage,
    this.pendingModifiers = PendingTerminalModifiers.empty,
    this.terminalId,
  });

  /// The xterm emulator instance rendered by TerminalView. Long-lived: it
  /// keeps scrollback while the user switches tabs.
  final Terminal terminal;
  final TerminalSessionStatus status;
  final int? exitCode;
  final String? errorMessage;
  final PendingTerminalModifiers pendingModifiers;
  final String? terminalId;

  TerminalSessionState copyWith({
    Terminal? terminal,
    TerminalSessionStatus? status,
    int? exitCode,
    String? errorMessage,
    PendingTerminalModifiers? pendingModifiers,
    String? terminalId,
  }) => TerminalSessionState(
    terminal: terminal ?? this.terminal,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    errorMessage: errorMessage ?? this.errorMessage,
    pendingModifiers: pendingModifiers ?? this.pendingModifiers,
    terminalId: terminalId ?? this.terminalId,
  );
}

/// One daemon-backed PTY per terminal tab, created lazily when the tab is
/// first opened and kept alive across tab switches. Killed via [shutdown]
/// when its tab is closed or the owning agent is archived (see
/// [AgentActions.archive]).
class TerminalSessionNotifier extends Notifier<TerminalSessionState> {
  TerminalSessionNotifier(this.key);

  static const _uuid = Uuid();

  /// Family argument: which worktree/tab this terminal belongs to.
  /// [TerminalSessionKey.worktreePath] *is* the daemon-side `cwd` directly;
  /// [TerminalSessionKey.tabId] gives each tab its own independent session
  /// identity.
  final TerminalSessionKey key;

  String? _terminalId;
  int? _slotId;
  WorkspaceTerminalSession? _workspaceSession;
  final TerminalInputModeTracker _inputModeTracker = TerminalInputModeTracker();
  final List<String> _pendingEncodedKeyInputs = [];
  int _generation = 0;
  bool _resizeClaimEnabled = false;
  int? _lastSentCols;
  int? _lastSentRows;

  @override
  TerminalSessionState build() {
    _terminalId = null;
    _slotId = null;
    _pendingEncodedKeyInputs.clear();
    _inputModeTracker.reset();
    _resizeClaimEnabled = false;
    _lastSentCols = null;
    _lastSentRows = null;
    final client = ref.watch(daemonClientProvider);
    final generation = ++_generation;
    final terminal = Terminal(maxLines: 10000);
    final workspaceSessionScope =
        '${client.uri}|${key.workspaceId ?? key.worktreePath}';
    retainWorkspaceTerminalSession(workspaceSessionScope);
    final workspaceSession = getWorkspaceTerminalSession(workspaceSessionScope);
    _workspaceSession = workspaceSession;

    final frameSub = client.terminalFrames.listen((frame) {
      if (generation != _generation) return;
      if (frame.slotId != _slotId) return;
      switch (frame.opcode) {
        case TerminalOpcode.output:
          final output = utf8.decode(frame.payload, allowMalformed: true);
          _inputModeTracker.feed(output);
          terminal.write(output);
        case TerminalOpcode.snapshot:
          final snapshot = frame.trySnapshotState;
          if (snapshot == null) return;
          _inputModeTracker.reset();
          final terminalId = _terminalId;
          if (terminalId != null) {
            workspaceSession.snapshots.set(terminalId, snapshot);
          }
          terminal.write('\x1bc${renderTerminalSnapshotToAnsi(snapshot)}');
        case TerminalOpcode.restore:
          _inputModeTracker.reset();
          terminal.write(
            '\x1bc${utf8.decode(frame.payload, allowMalformed: true)}',
          );
        case TerminalOpcode.input:
        case TerminalOpcode.resize:
          return;
      }
    });
    final eventSub = client.events.listen((event) {
      if (generation != _generation) return;
      if (event.type != MessageTypes.terminalExitedEvent &&
          event.type != TerminalStreamExit.type) {
        return;
      }
      if (event.payload['terminalId'] != _terminalId) return;
      final terminalId = _terminalId;
      if (terminalId != null) workspaceSession.snapshots.clear(terminalId);
      _slotId = null;
      ref
          .read(worktreeTabsProvider(key.worktreePath).notifier)
          .clearTerminalId(key.tabId);
      state = state.copyWith(
        status: TerminalSessionStatus.exited,
        exitCode: (event.payload['exitCode'] as num?)?.toInt(),
      );
    });
    ref.onDispose(() {
      frameSub.cancel();
      eventSub.cancel();
      releaseWorkspaceTerminalSession(workspaceSessionScope);
    });

    Future.microtask(() => _start(generation, terminal));
    return TerminalSessionState(terminal: terminal);
  }

  Future<void> _start(int generation, Terminal terminal) async {
    final client = ref.read(daemonClientProvider);
    final cwd = key.worktreePath;
    var createdNewTerminal = false;
    try {
      final restoredTerminalId = ref
          .read(worktreeTabsProvider(key.worktreePath))
          .layout
          .tabs
          .where((tab) => tab.tabId == key.tabId)
          .firstOrNull
          ?.lastKnownTerminalId;
      final String terminalId;
      if (restoredTerminalId != null && restoredTerminalId.isNotEmpty) {
        terminalId = restoredTerminalId;
      } else {
        final created = await client.requestSessionMessage(
          CreateTerminalRequest(
            cwd: cwd,
            workspaceId: key.workspaceId,
            size: TerminalSize(
              rows: terminal.viewHeight,
              cols: terminal.viewWidth,
            ),
            requestId: _uuid.v4(),
          ).toJson(),
        );
        final createdPayload = created['payload'];
        final terminalJson = createdPayload is Map
            ? createdPayload['terminal'] as Map?
            : null;
        if (terminalJson == null || terminalJson['id'] is! String) {
          throw StateError('malformed create response');
        }
        terminalId = PaseoTerminalInfo.fromJson(
          terminalJson.cast<String, Object?>(),
        ).id;
        createdNewTerminal = true;
      }
      if (generation != _generation) {
        // Rebuilt while creating: don't leak the daemon terminal.
        if (createdNewTerminal) {
          unawaited(
            client
                .requestSessionMessage(
                  KillTerminalRequest(
                    terminalId: terminalId,
                    requestId: _uuid.v4(),
                  ).toJson(),
                )
                .catchError((_) => const <String, Object?>{}),
          );
        }
        return;
      }
      _terminalId = terminalId;
      final cachedSnapshot = _workspaceSession?.snapshots.get(terminalId);
      if (cachedSnapshot != null) {
        terminal.write('\x1bc${renderTerminalSnapshotToAnsi(cachedSnapshot)}');
      }
      ref
          .read(worktreeTabsProvider(key.worktreePath).notifier)
          .setTerminalId(key.tabId, terminalId);

      final subscribed = await client.requestSessionMessage(
        SubscribeTerminalRequest(
          terminalId: terminalId,
          requestId: _uuid.v4(),
          restore: TerminalRestoreOptions(
            mode: TerminalRestoreMode.visibleSnapshot,
            scrollbackLines: 200,
            size: (rows: terminal.viewHeight, cols: terminal.viewWidth),
          ),
        ).toJson(),
      );
      if (generation != _generation) {
        try {
          client.sendSessionMessage(
            UnsubscribeTerminalRequest(terminalId: terminalId).toJson(),
          );
        } catch (_) {}
        if (createdNewTerminal) {
          unawaited(
            client
                .requestSessionMessage(
                  KillTerminalRequest(
                    terminalId: terminalId,
                    requestId: _uuid.v4(),
                  ).toJson(),
                )
                .catchError((_) => const <String, Object?>{}),
          );
        }
        return;
      }
      final subscribedPayload = subscribed['payload'];
      final subscribeError = subscribedPayload is Map
          ? subscribedPayload['error']
          : null;
      if (subscribeError is String && subscribeError.isNotEmpty) {
        throw _TerminalAttachException(subscribeError);
      }
      final slotId = subscribedPayload is Map
          ? (subscribedPayload['slot'] as num?)?.toInt()
          : null;
      if (slotId == null) throw StateError('malformed subscribe response');
      _slotId = slotId;
      for (final encoded in _pendingEncodedKeyInputs) {
        client.sendTerminalFrame(
          TerminalFrame(
            opcode: TerminalOpcode.input,
            slotId: slotId,
            payload: Uint8List.fromList(utf8.encode(encoded)),
          ),
        );
      }
      _pendingEncodedKeyInputs.clear();

      terminal.onOutput = (data) {
        if (generation != _generation || _slotId != slotId) return;
        final resolution = resolvePendingModifierDataInput(
          data: data,
          pendingModifiers: state.pendingModifiers,
        );
        if (resolution case PendingModifierKeyResolution(:final key)) {
          sendKeyInput(
            TerminalKeyInput(
              key: normalizeTerminalTransportKey(key),
              ctrl: state.pendingModifiers.ctrl,
              shift: state.pendingModifiers.shift,
              alt: state.pendingModifiers.alt,
            ),
          );
          clearPendingModifiers();
          return;
        }
        if (resolution.clearPendingModifiers) clearPendingModifiers();
        client.sendTerminalFrame(
          TerminalFrame(
            opcode: TerminalOpcode.input,
            slotId: slotId,
            payload: Uint8List.fromList(utf8.encode(data)),
          ),
        );
      };
      terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
        if (generation != _generation || _slotId != slotId) return;
        if (_resizeClaimEnabled) {
          _sendTerminalSize(cols: cols, rows: rows);
        }
      };

      state = state.copyWith(
        status: TerminalSessionStatus.running,
        terminalId: terminalId,
      );
    } catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(
        status: TerminalSessionStatus.error,
        errorMessage: '$e',
      );
    }
  }

  /// Starts a fresh daemon terminal after an exit/error. Clears the screen by
  /// swapping in a new emulator.
  void restart() => ref.invalidateSelf();

  bool get enhancedInputActive => _inputModeTracker.supportsModifiedEnter();

  /// Grants this rendered pane ownership of daemon-side PTY sizing. Retained
  /// inactive renderers may still reflow locally, but cannot steal the PTY
  /// dimensions from the focused pane.
  void setResizeClaimEnabled(bool enabled) {
    _resizeClaimEnabled = enabled;
  }

  /// Sends the current renderer size when this pane acquires a focus claim.
  /// A fresh claim deliberately bypasses deduplication so blur/refocus and
  /// visibility recovery restore the authoritative size.
  bool claimCurrentSize() {
    final terminal = state.terminal;
    return _sendTerminalSize(
      cols: terminal.viewWidth,
      rows: terminal.viewHeight,
      force: true,
    );
  }

  bool _sendTerminalSize({
    required int cols,
    required int rows,
    bool force = false,
  }) {
    final slotId = _slotId;
    if (slotId == null || cols <= 0 || rows <= 0) return false;
    if (!force && _lastSentCols == cols && _lastSentRows == rows) return true;
    ref
        .read(daemonClientProvider)
        .sendTerminalFrame(
          TerminalFrame.resize(slotId, cols: cols, rows: rows),
        );
    _lastSentCols = cols;
    _lastSentRows = rows;
    return true;
  }

  void togglePendingModifier(TerminalModifier modifier) {
    final pending = state.pendingModifiers;
    state = state.copyWith(
      pendingModifiers: switch (modifier) {
        TerminalModifier.ctrl => pending.copyWith(ctrl: !pending.ctrl),
        TerminalModifier.shift => pending.copyWith(shift: !pending.shift),
        TerminalModifier.alt => pending.copyWith(alt: !pending.alt),
      },
    );
  }

  void clearPendingModifiers() {
    if (!state.pendingModifiers.hasAny) return;
    state = state.copyWith(pendingModifiers: PendingTerminalModifiers.empty);
  }

  /// Sends a normalized key through Paseo's key-input transport. Inputs
  /// intercepted while the terminal subscription is still starting are
  /// queued and replayed in order once the daemon assigns a slot.
  bool sendKeyInput(TerminalKeyInput input) {
    final encoded = encodeTerminalKeyInput(
      input,
      TerminalKeyInputEncodingOptions(inputMode: _inputModeTracker.getState()),
    );
    if (encoded.isEmpty) return false;
    final slotId = _slotId;
    if (slotId == null) {
      if (state.status != TerminalSessionStatus.starting) return false;
      _pendingEncodedKeyInputs.add(encoded);
      return true;
    }
    ref
        .read(daemonClientProvider)
        .sendTerminalFrame(
          TerminalFrame(
            opcode: TerminalOpcode.input,
            slotId: slotId,
            payload: Uint8List.fromList(utf8.encode(encoded)),
          ),
        );
    return true;
  }

  /// Sends modified Enter only when the terminal has negotiated an enhanced
  /// Kitty or Win32 input mode. Otherwise TerminalView keeps its normal input.
  bool sendModifiedEnter({
    required bool ctrl,
    required bool shift,
    required bool alt,
    required bool meta,
  }) {
    if ((!ctrl && !shift && !alt && !meta) || !enhancedInputActive) {
      return false;
    }
    return sendKeyInput(
      TerminalKeyInput(
        key: 'Enter',
        ctrl: ctrl,
        shift: shift,
        alt: alt,
        meta: meta,
      ),
    );
  }

  /// Sends text directly to the PTY, as terminal file drop does in Paseo.
  /// This is deliberately not [Terminal.paste]: dropped paths must not gain
  /// bracketed-paste framing or a trailing newline.
  bool sendRawInput(String data) {
    final slotId = _slotId;
    if (slotId == null || data.isEmpty) return false;
    ref
        .read(daemonClientProvider)
        .sendTerminalFrame(
          TerminalFrame(
            opcode: TerminalOpcode.input,
            slotId: slotId,
            payload: Uint8List.fromList(utf8.encode(data)),
          ),
        );
    return true;
  }

  /// Kills the daemon-side terminal. Called when this tab is closed or the
  /// owning agent is archived.
  Future<void> shutdown() async {
    _generation++;
    final client = ref.read(daemonClientProvider);
    final terminalId = _terminalId;
    _terminalId = null;
    _slotId = null;
    _resizeClaimEnabled = false;
    _lastSentCols = null;
    _lastSentRows = null;
    _pendingEncodedKeyInputs.clear();
    if (terminalId == null) return;
    final workspaceSessionScope =
        '${client.uri}|${key.workspaceId ?? key.worktreePath}';
    getWorkspaceTerminalSession(
      workspaceSessionScope,
    ).snapshots.clear(terminalId);
    try {
      client.sendSessionMessage(
        UnsubscribeTerminalRequest(terminalId: terminalId).toJson(),
      );
    } catch (_) {}
    try {
      await client.requestSessionMessage(
        KillTerminalRequest(
          terminalId: terminalId,
          requestId: _uuid.v4(),
        ).toJson(),
      );
    } catch (_) {}
  }
}

final class _TerminalAttachException implements Exception {
  const _TerminalAttachException(this.message);
  final String message;

  @override
  String toString() => message;
}

final terminalSessionProvider =
    NotifierProvider.family<
      TerminalSessionNotifier,
      TerminalSessionState,
      TerminalSessionKey
    >(TerminalSessionNotifier.new);
