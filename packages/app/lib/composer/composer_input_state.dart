/// Port of Paseo 0.2.0's `composer/input/state.ts`.
///
/// The pure decisions behind the composer's input surface: which of the
/// input/voice-overlay pair is live, whether dictation can start, how the
/// two send affordances map onto submit-vs-queue, and how a message-input
/// keyboard shortcut resolves against the current dictation/voice state.
library;

/// Which action the primary send affordance performs while an agent is
/// running. The alternate affordance (Mod+Enter) always performs the other.
enum SendBehavior { interrupt, queue }

final class ComposerSurfaceState {
  const ComposerSurfaceState({
    required this.opacity,
    required this.interactive,
  });

  /// 0 or 1 — the surfaces cross-fade rather than mount and unmount, so the
  /// input keeps its text and selection while the overlay is up.
  final double opacity;

  /// Upstream's `pointerEvents: "auto" | "none"`.
  final bool interactive;

  @override
  bool operator ==(Object other) =>
      other is ComposerSurfaceState &&
      other.opacity == opacity &&
      other.interactive == interactive;

  @override
  int get hashCode => Object.hash(opacity, interactive);

  @override
  String toString() =>
      'ComposerSurfaceState(opacity: $opacity, interactive: $interactive)';
}

final class ComposerSurfacePresentation {
  const ComposerSurfacePresentation({
    required this.input,
    required this.overlay,
  });

  final ComposerSurfaceState input;
  final ComposerSurfaceState overlay;

  @override
  bool operator ==(Object other) =>
      other is ComposerSurfacePresentation &&
      other.input == input &&
      other.overlay == overlay;

  @override
  int get hashCode => Object.hash(input, overlay);
}

const _inputPresentation = ComposerSurfacePresentation(
  input: ComposerSurfaceState(opacity: 1, interactive: true),
  overlay: ComposerSurfaceState(opacity: 0, interactive: false),
);

const _overlayPresentation = ComposerSurfacePresentation(
  input: ComposerSurfaceState(opacity: 0, interactive: false),
  overlay: ComposerSurfaceState(opacity: 1, interactive: true),
);

/// Exactly one of the input and the voice overlay is visible and
/// interactive at a time.
ComposerSurfacePresentation resolveComposerSurfacePresentation(
  bool showOverlay,
) => showOverlay ? _overlayPresentation : _inputPresentation;

/// Dictation needs a live socket, host readiness, an enabled input, and no
/// standing unavailability reason. When readiness is unknown it defers to
/// the socket.
bool computeCanStartDictation({
  required bool? isSocketConnected,
  required bool? isReadyForDictation,
  required bool disabled,
  String? dictationUnavailableMessage,
}) {
  final socketConnected = isSocketConnected ?? false;
  final readyForDictation = isReadyForDictation ?? socketConnected;
  return socketConnected &&
      readyForDictation &&
      !disabled &&
      (dictationUnavailableMessage == null ||
          dictationUnavailableMessage.isEmpty);
}

/// The two send affordances and the state they branch on.
final class SendActionContext {
  const SendActionContext({
    required this.defaultSendBehavior,
    required this.isAgentRunning,
    required this.handleSendMessage,
    required this.handleQueueMessage,
    this.canQueue = true,
  });

  final SendBehavior defaultSendBehavior;
  final bool isAgentRunning;
  final void Function() handleSendMessage;
  final void Function() handleQueueMessage;

  /// Whether the surface supports queueing at all (upstream's `onQueue`
  /// being present).
  final bool canQueue;
}

/// The primary affordance: queues only when queueing is the chosen default
/// and there is a running turn to queue behind.
void runDefaultSendAction(SendActionContext ctx) {
  if (ctx.defaultSendBehavior == SendBehavior.queue &&
      ctx.isAgentRunning &&
      ctx.canQueue) {
    ctx.handleQueueMessage();
    return;
  }
  ctx.handleSendMessage();
}

/// The alternate affordance: always the other action, and a no-op when the
/// other action is queueing but there is nothing to queue behind.
void runAlternateSendAction(SendActionContext ctx) {
  if (ctx.defaultSendBehavior == SendBehavior.queue) {
    ctx.handleSendMessage();
    return;
  }
  if (ctx.isAgentRunning && ctx.canQueue) {
    ctx.handleQueueMessage();
  }
}

/// The message-input scoped keyboard actions.
enum MessageInputKeyboardAction {
  focus,
  send,
  voiceToggle,
  voiceMuteToggle,
  dictationToggle,
  dictationConfirm,
  dictationCancel,
}

/// Callbacks a message-input shortcut can drive.
final class MessageInputKeyboardActions {
  const MessageInputKeyboardActions({
    required this.focusInput,
    required this.isDictationRecording,
    required this.markTranscriptForSend,
    required this.confirmDictation,
    required this.cancelDictation,
    required this.startDictation,
    required this.toggleRealtimeVoice,
    required this.isRealtimeVoiceActive,
    required this.toggleRealtimeVoiceMute,
  });

  final void Function() focusInput;
  final bool Function() isDictationRecording;
  final void Function() markTranscriptForSend;
  final void Function() confirmDictation;
  final void Function() cancelDictation;
  final void Function() startDictation;
  final void Function() toggleRealtimeVoice;
  final bool isRealtimeVoiceActive;
  final void Function() toggleRealtimeVoiceMute;
}

/// Runs [action], returning whether it was handled. Send and cancel are
/// only claimed while dictation is recording, so they fall through to the
/// normal send path otherwise.
bool runMessageInputKeyboardAction(
  MessageInputKeyboardAction action,
  MessageInputKeyboardActions actions,
) {
  switch (action) {
    case MessageInputKeyboardAction.focus:
      actions.focusInput();
      return true;
    case MessageInputKeyboardAction.send:
    case MessageInputKeyboardAction.dictationConfirm:
      if (!actions.isDictationRecording()) return false;
      actions
        ..markTranscriptForSend()
        ..confirmDictation();
      return true;
    case MessageInputKeyboardAction.voiceToggle:
      actions.toggleRealtimeVoice();
      return true;
    case MessageInputKeyboardAction.voiceMuteToggle:
      if (actions.isRealtimeVoiceActive) actions.toggleRealtimeVoiceMute();
      return true;
    case MessageInputKeyboardAction.dictationCancel:
      if (!actions.isDictationRecording()) return false;
      actions.cancelDictation();
      return true;
    case MessageInputKeyboardAction.dictationToggle:
      // Toggling mid-recording sends the transcript; otherwise it starts a
      // new dictation, including retrying after a start that never entered
      // the recording state.
      if (actions.isDictationRecording()) {
        actions
          ..markTranscriptForSend()
          ..confirmDictation();
      } else {
        actions.startDictation();
      }
      return true;
  }
}

/// Stops realtime voice for the current agent, cancelling its in-flight
/// turn first so the agent does not keep running unattended.
Future<void> stopRealtimeVoice({
  required bool hasVoice,
  required bool isRealtimeVoiceForCurrentAgent,
  required bool isAgentRunning,
  required Future<void> Function() stopVoice,
  Future<void> Function(String agentId)? cancelAgent,
  String? voiceAgentId,
}) async {
  if (!hasVoice || !isRealtimeVoiceForCurrentAgent) return;

  if (isAgentRunning) {
    if (cancelAgent == null || voiceAgentId == null) {
      throw StateError(
        'Cannot stop the running voice agent while the host is unavailable',
      );
    }
    await cancelAgent(voiceAgentId);
  }

  await stopVoice();
}
