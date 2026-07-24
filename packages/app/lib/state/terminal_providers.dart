import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import 'agents_provider.dart';
import 'daemon_providers.dart';

enum TerminalSessionStatus { starting, running, exited, error }

/// UI-facing snapshot of one embedded terminal session.
class TerminalSessionState {
  const TerminalSessionState({
    required this.terminal,
    this.status = TerminalSessionStatus.starting,
    this.exitCode,
    this.errorMessage,
  });

  /// The xterm emulator instance rendered by TerminalView. Long-lived: it
  /// keeps scrollback while the user switches tabs.
  final Terminal terminal;
  final TerminalSessionStatus status;
  final int? exitCode;
  final String? errorMessage;

  TerminalSessionState copyWith({
    Terminal? terminal,
    TerminalSessionStatus? status,
    int? exitCode,
    String? errorMessage,
  }) =>
      TerminalSessionState(
        terminal: terminal ?? this.terminal,
        status: status ?? this.status,
        exitCode: exitCode ?? this.exitCode,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// One daemon-backed PTY per agent, created lazily when the Terminal tab is
/// first opened and kept alive across tab switches. Killed via [shutdown]
/// when the agent is archived (see [AgentActions.archive]).
class TerminalSessionNotifier extends Notifier<TerminalSessionState> {
  TerminalSessionNotifier(this.agentId);

  /// Family argument: the agent this terminal belongs to.
  final String agentId;

  String? _terminalId;
  int? _slotId;
  int _generation = 0;

  @override
  TerminalSessionState build() {
    _terminalId = null;
    _slotId = null;
    final client = ref.watch(daemonClientProvider);
    final generation = ++_generation;
    final terminal = Terminal(maxLines: 10000);

    final frameSub = client.terminalFrames.listen((frame) {
      if (generation != _generation) return;
      if (frame.slotId != _slotId) return;
      if (frame.opcode != TerminalOpcode.output &&
          frame.opcode != TerminalOpcode.snapshot) {
        return;
      }
      terminal.write(utf8.decode(frame.payload, allowMalformed: true));
    });
    final eventSub = client.events.listen((event) {
      if (generation != _generation) return;
      if (event.type != MessageTypes.terminalExitedEvent) return;
      if (event.payload['terminalId'] != _terminalId) return;
      state = state.copyWith(
        status: TerminalSessionStatus.exited,
        exitCode: (event.payload['exitCode'] as num?)?.toInt(),
      );
    });
    ref.onDispose(() {
      frameSub.cancel();
      eventSub.cancel();
    });

    Future.microtask(() => _start(generation, terminal));
    return TerminalSessionState(terminal: terminal);
  }

  Future<void> _start(int generation, Terminal terminal) async {
    final client = ref.read(daemonClientProvider);
    final cwd = ref.read(agentSummaryProvider(agentId))?.cwd ?? '.';
    try {
      final created =
          await client.request(MessageTypes.terminalCreateRequest, {
        'cwd': cwd,
        'cols': terminal.viewWidth,
        'rows': terminal.viewHeight,
      });
      if (generation != _generation) {
        // Rebuilt while creating: don't leak the daemon terminal.
        final id = (created['terminal'] as Map?)?['terminalId'] as String?;
        if (id != null) {
          unawaited(client
              .request(MessageTypes.terminalKillRequest, {'terminalId': id})
              .catchError((_) => const <String, Object?>{}));
        }
        return;
      }
      final terminalId =
          (created['terminal'] as Map?)?['terminalId'] as String?;
      if (terminalId == null) throw StateError('malformed create response');
      _terminalId = terminalId;

      final subscribed = await client.request(
        MessageTypes.terminalSubscribeRequest,
        {'terminalId': terminalId},
      );
      if (generation != _generation) return;
      final slotId = (subscribed['slotId'] as num?)?.toInt();
      if (slotId == null) throw StateError('malformed subscribe response');
      _slotId = slotId;

      terminal.onOutput = (data) {
        if (generation != _generation) return;
        client.sendTerminalFrame(TerminalFrame(
          opcode: TerminalOpcode.input,
          slotId: slotId,
          payload: Uint8List.fromList(utf8.encode(data)),
        ));
      };
      terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
        if (generation != _generation) return;
        client.sendTerminalFrame(
          TerminalFrame.resize(slotId, cols: cols, rows: rows),
        );
      };
      // TerminalView may already have resized the emulator while we were
      // subscribing; sync the PTY to the actual view size.
      client.sendTerminalFrame(TerminalFrame.resize(
        slotId,
        cols: terminal.viewWidth,
        rows: terminal.viewHeight,
      ));

      state = state.copyWith(status: TerminalSessionStatus.running);
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

  /// Kills the daemon-side terminal. Called when the agent is archived.
  Future<void> shutdown() async {
    _generation++;
    final client = ref.read(daemonClientProvider);
    final terminalId = _terminalId;
    _terminalId = null;
    _slotId = null;
    if (terminalId == null) return;
    try {
      await client.request(
        MessageTypes.terminalUnsubscribeRequest,
        {'terminalId': terminalId},
      );
    } catch (_) {}
    try {
      await client.request(
        MessageTypes.terminalKillRequest,
        {'terminalId': terminalId},
      );
    } catch (_) {}
  }
}

final terminalSessionProvider = NotifierProvider.family<
    TerminalSessionNotifier, TerminalSessionState, String>(
  TerminalSessionNotifier.new,
);
