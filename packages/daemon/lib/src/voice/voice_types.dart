import 'dart:async';

abstract interface class VoiceAbortSignal {
  bool get aborted;
  Future<void> get onAbort;
  void Function() addAbortListener(void Function() listener);
}

final class VoiceAbortController {
  final Completer<void> _abortCompleter = Completer<void>();
  final Set<void Function()> _listeners = {};
  late final VoiceAbortSignal signal = _ControlledVoiceAbortSignal(this);

  bool get aborted => _abortCompleter.isCompleted;

  void abort() {
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
      final listeners = _listeners.toList(growable: false);
      _listeners.clear();
      for (final listener in listeners) {
        listener();
      }
    }
  }

  void Function() _addListener(void Function() listener) {
    if (aborted) return () {};
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

final class _ControlledVoiceAbortSignal implements VoiceAbortSignal {
  const _ControlledVoiceAbortSignal(this._controller);

  final VoiceAbortController _controller;

  @override
  bool get aborted => _controller.aborted;

  @override
  Future<void> get onAbort => _controller._abortCompleter.future;

  @override
  void Function() addAbortListener(void Function() listener) =>
      _controller._addListener(listener);
}

typedef VoiceSpeakHandler =
    Future<void> Function({
      required String text,
      required String callerAgentId,
      VoiceAbortSignal? signal,
    });

final class VoiceCallerContext {
  const VoiceCallerContext({
    this.childAgentDefaultLabels,
    this.lockedCwd,
    this.allowCustomCwd,
    this.enableVoiceTools,
  });

  final Map<String, String>? childAgentDefaultLabels;
  final String? lockedCwd;
  final bool? allowCustomCwd;
  final bool? enableVoiceTools;
}
