/// Port of Paseo 0.2.0's `agent-stream/turn-footer.tsx` and the
/// `AssistantTurnFooter` / `LiveElapsed` pieces of `components/message.tsx`
/// that it composes.
///
/// The stream shows exactly one footer at a time per turn slot: a live
/// "working" indicator with elapsed time while a turn runs, or a completed
/// turn's copy/fork actions plus its duration. The duration label swaps to
/// the turn's end timestamp on hover, with a hidden sizer holding the width
/// steady so the row does not reflow mid-swap.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../state/timeline_provider.dart';
import 'layout.dart';
import 'stream_strategy.dart';
import 'turn_boundary.dart';
import 'turn_time.dart';

/// Font size shared by the stream's metadata rows.
const streamMetadataFontSize = 13.0;

/// Where a fork should place the new conversation.
enum AssistantForkTarget { newAgent, currentAgent }

typedef AssistantTurnForkHandler =
    void Function({
      required AssistantForkTarget target,
      required AssistantTurnForkBoundary boundary,
    });

/// Renders the turn slot below the stream: the running indicator, a
/// completed turn's footer, or nothing.
class TurnFooter extends StatelessWidget {
  const TurnFooter({
    super.key,
    required this.isRunning,
    required this.inFlightTurnStartedAt,
    required this.host,
    required this.strategy,
    required this.supportsTimelineCursor,
    this.onForkAssistantTurn,
    this.clock,
  });

  final bool isRunning;

  /// When the in-flight turn's authoritative user message was sent, or null
  /// when a turn is reserved but not yet started (an optimistic prompt).
  final DateTime? inFlightTurnStartedAt;
  final TurnFooterHost? host;
  final StreamStrategy strategy;
  final bool supportsTimelineCursor;
  final AssistantTurnForkHandler? onForkAssistantTurn;

  /// Injectable "now" for the running-turn ticker; see [LiveElapsed.clock].
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    if (isRunning) {
      return _TurnFooterRow(
        child: _RunningTurnFooter(
          inFlightTurnStartedAt: inFlightTurnStartedAt,
          clock: clock,
        ),
      );
    }
    final host = this.host;
    if (host == null) return const SizedBox.shrink();
    return CompletedTurnFooterRow(
      strategy: strategy,
      items: host.items,
      timing: host.timing,
      startIndex: host.startIndex,
      supportsTimelineCursor: supportsTimelineCursor,
      onForkAssistantTurn: onForkAssistantTurn,
    );
  }
}

class CompletedTurnFooterRow extends StatelessWidget {
  const CompletedTurnFooterRow({
    super.key,
    required this.strategy,
    required this.items,
    required this.startIndex,
    required this.supportsTimelineCursor,
    this.timing,
    this.onForkAssistantTurn,
  });

  final StreamStrategy strategy;
  final List<TimelineDisplayItem> items;
  final int startIndex;
  final bool supportsTimelineCursor;
  final TurnTiming? timing;
  final AssistantTurnForkHandler? onForkAssistantTurn;

  @override
  Widget build(BuildContext context) => _TurnFooterRow(
    child: _CompletedTurnFooter(
      strategy: strategy,
      items: items,
      startIndex: startIndex,
      supportsTimelineCursor: supportsTimelineCursor,
      timing: timing,
      onForkAssistantTurn: onForkAssistantTurn,
    ),
  );
}

class _TurnFooterRow extends StatelessWidget {
  const _TurnFooterRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: PaseoSpacing.s4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: PaseoSpacing.s2),
      child: Align(alignment: Alignment.centerLeft, child: child),
    ),
  );
}

class _RunningTurnFooter extends StatelessWidget {
  const _RunningTurnFooter({required this.inFlightTurnStartedAt, this.clock});

  final DateTime? inFlightTurnStartedAt;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final startedAt = inFlightTurnStartedAt;
    return Padding(
      key: const ValueKey('turn-working-indicator'),
      padding: const EdgeInsets.only(bottom: PaseoSpacing.s6),
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: ProgressRing(strokeWidth: 2),
            ),
            if (startedAt != null) ...[
              const SizedBox(width: PaseoSpacing.s3),
              LiveElapsed(
                startedAt: startedAt,
                clock: clock,
                key: const ValueKey('turn-working-elapsed'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Ticks once a second, rendering the time elapsed since [startedAt].
class LiveElapsed extends StatefulWidget {
  const LiveElapsed({
    super.key,
    required this.startedAt,
    this.active = true,
    this.clock,
  });

  final DateTime startedAt;

  /// When false the ticker stops and the last rendered value is retained,
  /// so an off-screen panel does not keep waking the UI.
  final bool active;

  /// Source of "now". Injectable because widget tests advance fake async
  /// time, which does not move the real wall clock.
  final DateTime Function()? clock;

  @override
  State<LiveElapsed> createState() => _LiveElapsedState();
}

class _LiveElapsedState extends State<LiveElapsed> {
  Timer? _timer;
  late int _elapsedMs;

  @override
  void initState() {
    super.initState();
    _elapsedMs = _currentElapsedMs();
    _syncTicker();
  }

  @override
  void didUpdateWidget(LiveElapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt ||
        oldWidget.active != widget.active) {
      _elapsedMs = _currentElapsedMs();
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  int _currentElapsedMs() {
    final now = (widget.clock ?? DateTime.now)();
    final elapsed = now.difference(widget.startedAt).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  void _syncTicker() {
    _timer?.cancel();
    if (!widget.active) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedMs = _currentElapsedMs());
    });
  }

  @override
  Widget build(BuildContext context) => Text(
    formatDuration(widget.active ? _currentElapsedMs() : _elapsedMs),
    key: const ValueKey('live-elapsed-text'),
    style: TextStyle(
      color: context.paseoPalette.foregroundMuted,
      fontSize: streamMetadataFontSize,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _CompletedTurnFooter extends StatelessWidget {
  const _CompletedTurnFooter({
    required this.strategy,
    required this.items,
    required this.startIndex,
    required this.supportsTimelineCursor,
    this.timing,
    this.onForkAssistantTurn,
  });

  final StreamStrategy strategy;
  final List<TimelineDisplayItem> items;
  final int startIndex;
  final bool supportsTimelineCursor;
  final TurnTiming? timing;
  final AssistantTurnForkHandler? onForkAssistantTurn;

  @override
  Widget build(BuildContext context) {
    final boundary = resolveAssistantTurnForkBoundary(
      items: items,
      startIndex: startIndex,
      supportsTimelineCursor: supportsTimelineCursor,
    );
    final onFork = onForkAssistantTurn;
    final timing = this.timing;

    return Padding(
      padding: const EdgeInsets.only(bottom: PaseoSpacing.s6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TurnCopyButton(
              getContent: () =>
                  strategy.collectAssistantTurnContent(items, startIndex),
            ),
            if (boundary != null && onFork != null) ...[
              const SizedBox(width: PaseoSpacing.s2),
              _AssistantForkButton(
                onFork: (target) => onFork(target: target, boundary: boundary),
              ),
            ],
            if (timing != null) ...[
              const SizedBox(width: PaseoSpacing.s2),
              _TurnDurationLabel(
                durationMs: timing.durationMs,
                completedAt: timing.completedAt,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows "Worked for 2m 12s", swapping to the turn's end timestamp while
/// hovered. A hidden sizer reserves the wider of the two labels so the row
/// keeps a stable width across the swap.
class _TurnDurationLabel extends StatefulWidget {
  const _TurnDurationLabel({
    required this.durationMs,
    required this.completedAt,
  });

  final int durationMs;
  final DateTime completedAt;

  @override
  State<_TurnDurationLabel> createState() => _TurnDurationLabelState();
}

class _TurnDurationLabelState extends State<_TurnDurationLabel> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final durationLabel = 'Worked for ${formatDuration(widget.durationMs)}';
    final timestampLabel = formatMessageTimestamp(widget.completedAt);
    final style = TextStyle(
      color: context.paseoPalette.foregroundMuted,
      fontSize: streamMetadataFontSize,
    );
    final sizerLabel = durationLabel.length >= timestampLabel.length
        ? durationLabel
        : timestampLabel;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        button: true,
        label: '$durationLabel, ended $timestampLabel',
        child: Stack(
          children: [
            Opacity(opacity: 0, child: Text(sizerLabel, style: style)),
            Positioned.fill(
              child: Text(
                _hovered ? timestampLabel : durationLabel,
                key: const ValueKey('turn-duration-label'),
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnCopyButton extends StatefulWidget {
  const _TurnCopyButton({required this.getContent});

  final String Function() getContent;

  @override
  State<_TurnCopyButton> createState() => _TurnCopyButtonState();
}

class _TurnCopyButtonState extends State<_TurnCopyButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.getContent()));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _copied ? 'Copied' : 'Copy turn',
    child: IconButton(
      key: const ValueKey('turn-copy-button'),
      icon: Icon(_copied ? FluentIcons.check_mark : FluentIcons.copy, size: 14),
      onPressed: () => unawaited(_copy()),
    ),
  );
}

class _AssistantForkButton extends StatelessWidget {
  const _AssistantForkButton({required this.onFork});

  final void Function(AssistantForkTarget target) onFork;

  @override
  Widget build(BuildContext context) => DropDownButton(
    key: const ValueKey('turn-fork-button'),
    title: const Icon(FluentIcons.branch_fork2, size: 14),
    items: [
      MenuFlyoutItem(
        text: const Text('Fork into new agent'),
        onPressed: () => onFork(AssistantForkTarget.newAgent),
      ),
      MenuFlyoutItem(
        text: const Text('Fork in this agent'),
        onPressed: () => onFork(AssistantForkTarget.currentAgent),
      ),
    ],
  );
}
