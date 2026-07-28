abstract interface class VoiceAbortSignal {
  bool get aborted;
  Future<void> get onAbort;
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
