/// Port of Paseo 0.2.0's `composer/input/labels.ts`.
///
/// Chooses which label the composer's send and voice affordances announce.
/// The app has no localization layer yet (`i18n/*` is tracked separately),
/// so these keep upstream's shape by taking the translator as a parameter:
/// they resolve the *key*, and translation stays the caller's job.
library;

/// Translates a message key, mirroring i18next's `t`.
typedef ComposerTranslator = String Function(String key);

/// Announces what pressing send will actually do, which differs while a
/// turn is running or when queueing is the chosen default.
String resolveSubmitAccessibilityLabel({
  required bool canPressLoadingButton,
  required bool defaultActionQueues,
  required bool isAgentRunning,
  required ComposerTranslator t,
  String? submitButtonAccessibilityLabel,
}) {
  if (submitButtonAccessibilityLabel != null &&
      submitButtonAccessibilityLabel.isNotEmpty) {
    return submitButtonAccessibilityLabel;
  }
  if (canPressLoadingButton) return t('composer.input.interruptAgent');
  if (defaultActionQueues) return t('composer.input.queueMessage');
  if (isAgentRunning) return t('composer.input.sendAndInterrupt');
  return t('composer.input.sendMessage');
}

/// The voice button doubles as a mute toggle while realtime voice owns the
/// current agent.
String resolveVoiceAccessibilityLabel({
  required bool isRealtimeVoiceForCurrentAgent,
  required bool isMuted,
  required bool isDictating,
  required ComposerTranslator t,
}) {
  if (isRealtimeVoiceForCurrentAgent) {
    return isMuted
        ? t('composer.voice.unmuteVoiceMode')
        : t('composer.voice.muteVoiceMode');
  }
  if (isDictating) return t('composer.voice.stopDictation');
  return t('composer.voice.startDictation');
}

String resolveVoiceTooltipText({
  required bool isRealtimeVoiceForCurrentAgent,
  required bool isMuted,
  required ComposerTranslator t,
}) {
  if (isRealtimeVoiceForCurrentAgent) {
    return isMuted
        ? t('composer.voice.unmuteVoice')
        : t('composer.voice.muteVoice');
  }
  return t('composer.voice.dictation');
}

String resolveSendTooltipLabel({
  required bool defaultActionQueues,
  required ComposerTranslator t,
  String? submitButtonAccessibilityLabel,
}) {
  if (submitButtonAccessibilityLabel != null &&
      submitButtonAccessibilityLabel.isNotEmpty) {
    return submitButtonAccessibilityLabel;
  }
  return defaultActionQueues
      ? t('composer.input.queue')
      : t('composer.input.send');
}
