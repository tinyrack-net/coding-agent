import 'package:agent_protocol/agent_protocol.dart';

typedef TerminalActivityClock = int Function();
typedef TerminalActivityListener =
    void Function(TerminalActivity? activity, TerminalActivity? previous);

/// Paseo's terminal activity state machine.
///
/// A terminal starts with unknown activity. A working -> idle edge is retained
/// as finished attention until explicitly cleared, and provider "attention"
/// reports normalize to idle + needs-input attention.
final class TerminalActivityTracker {
  TerminalActivityTracker({TerminalActivityClock? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final TerminalActivityClock _now;
  final Set<TerminalActivityListener> _listeners = {};
  TerminalActivity? _activity;

  TerminalActivity? get activity => _activity;

  bool set(TerminalActivityState state) {
    if (state == TerminalActivityState.idle &&
        _activity?.state == TerminalActivityState.working) {
      return _set(
        TerminalActivityState.idle,
        TerminalActivityAttentionReason.finished,
      );
    }
    if (state == TerminalActivityState.idle &&
        _activity?.attentionReason ==
            TerminalActivityAttentionReason.finished) {
      return false;
    }
    return _set(
      state == TerminalActivityState.attention
          ? TerminalActivityState.idle
          : state,
      state == TerminalActivityState.attention
          ? TerminalActivityAttentionReason.needsInput
          : null,
    );
  }

  bool clear() {
    if (_activity == null) return false;
    final previous = _activity;
    _activity = null;
    _notify(null, previous);
    return true;
  }

  bool clearAttention() {
    if (_activity?.attentionReason == null) return false;
    return _set(TerminalActivityState.idle, null);
  }

  void Function() onChange(TerminalActivityListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  bool _set(
    TerminalActivityState state,
    TerminalActivityAttentionReason? attentionReason,
  ) {
    final previous = _activity;
    if (previous?.state == state &&
        previous?.attentionReason == attentionReason) {
      return false;
    }
    final next = TerminalActivity(
      state: state,
      attentionReason: attentionReason,
      changedAt: _now(),
    );
    _activity = next;
    _notify(next, previous);
    return true;
  }

  void _notify(TerminalActivity? next, TerminalActivity? previous) {
    for (final listener in _listeners.toList(growable: false)) {
      listener(next, previous);
    }
  }

  void dispose() => _listeners.clear();
}
