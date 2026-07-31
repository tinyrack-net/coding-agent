/// Port of Paseo 0.2.0's `composer/submit.ts`.
///
/// The generic submit decision shared by every composer surface: whether a
/// press is a no-op, whether it queues behind a running turn or sends now,
/// when the visible draft clears, and how a failed send restores what the
/// user typed.
library;

/// What a submit attempt did.
enum AgentInputSubmitResult { noop, queued, submitted, failed }

/// Whether submitting clears the composer or leaves its content in place.
///
/// `preserveAndLock` is used by surfaces that keep showing what was sent
/// (and disable further edits) instead of emptying the input.
enum ComposerSubmitBehavior { clear, preserveAndLock }

/// Runs the frozen submit flow for one press.
///
/// [attachments] is generic so each surface can pass its own attachment
/// type; this only ever counts and hands them back.
Future<AgentInputSubmitResult> submitAgentInput<TAttachment>({
  required String message,
  required List<TAttachment> attachments,
  required bool isAgentRunning,
  required bool canSubmit,
  required void Function({
    required String message,
    required List<TAttachment> attachments,
  })
  queueMessage,
  required Future<void> Function({
    required String message,
    required List<TAttachment> attachments,
  })
  submitMessage,
  required void Function(String lifecycle) clearDraft,
  required void Function(String text) setUserInput,
  required void Function(List<TAttachment> attachments) setAttachments,
  required void Function(String? message) setSendError,
  required void Function(bool isProcessing) setIsProcessing,
  bool hasExternalContent = false,
  bool allowEmptySubmit = false,
  ComposerSubmitBehavior submitBehavior = ComposerSubmitBehavior.clear,
  bool forceSend = false,
  void Function(Object error)? onSubmitError,
  String? failedToSendMessage,
}) async {
  final trimmedMessage = message.trim();
  final shouldClearOnSubmit =
      submitBehavior != ComposerSubmitBehavior.preserveAndLock;

  // Nothing to send: no text, no attachments, and no surface-supplied
  // content standing in for either.
  if (trimmedMessage.isEmpty &&
      attachments.isEmpty &&
      !hasExternalContent &&
      !allowEmptySubmit) {
    return AgentInputSubmitResult.noop;
  }

  if (!canSubmit) return AgentInputSubmitResult.noop;

  // A running turn queues unless the caller explicitly asked to send now.
  if (isAgentRunning && !forceSend) {
    queueMessage(message: trimmedMessage, attachments: attachments);
    if (shouldClearOnSubmit) {
      setUserInput('');
      setAttachments(const []);
    }
    return AgentInputSubmitResult.queued;
  }

  // Clear before awaiting so the optimistic stream row and the composer do
  // not briefly show the same message twice.
  if (shouldClearOnSubmit) {
    setUserInput('');
    setAttachments(const []);
  }
  setSendError(null);
  setIsProcessing(true);

  try {
    await submitMessage(message: trimmedMessage, attachments: attachments);
    clearDraft('sent');
    setIsProcessing(false);
    return AgentInputSubmitResult.submitted;
  } on Object catch (error) {
    onSubmitError?.call(error);
    // Give the user back exactly what they were about to send.
    if (shouldClearOnSubmit) {
      setUserInput(trimmedMessage);
      setAttachments(attachments);
    }
    setSendError(
      error is Exception || error is Error
          ? _errorMessage(error, failedToSendMessage)
          : (failedToSendMessage ?? 'Failed to send message'),
    );
    setIsProcessing(false);
    return AgentInputSubmitResult.failed;
  }
}

/// Upstream surfaces `error.message` for real errors and falls back to the
/// caller's copy otherwise. Dart has no single `message` accessor, so this
/// uses the error's string form and falls back when it is unhelpful.
String _errorMessage(Object error, String? fallback) {
  final text = error.toString().trim();
  if (text.isEmpty) return fallback ?? 'Failed to send message';
  return text;
}
