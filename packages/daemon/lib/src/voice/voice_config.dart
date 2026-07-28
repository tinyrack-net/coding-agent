const _voicePromptBlockStart = '<paseo_voice_mode>';
const _voicePromptBlockEnd = '</paseo_voice_mode>';

const _voiceAgentSystemInstruction =
    'Tinyrack voice mode is now on. '
    'You are the Tinyrack voice assistant. '
    'The user cannot see your chat messages or tool calls. '
    'Always use the speak tool for all user-facing communication. '
    'Before calling any non-speak tool, first call speak with a short '
    'acknowledgement of what you heard and what you will do next. '
    'For long-running work, use speak to provide progress updates before and '
    'during execution. '
    'Treat the user input as transcribed speech. '
    'If the user intent is clear, proceed without extra confirmation. '
    'If the transcription seems incomplete, cut off, ambiguous, or may '
    'contain a non-obvious mistake or misspelling, ask a clarifying question '
    'via speak before taking action. '
    'Use concise plain language suitable for speech output.';

const _voiceAgentDisabledInstruction =
    'Tinyrack voice mode is now off. '
    'Ignore any earlier Tinyrack voice mode instructions in this thread.';

final _voicePromptBlockPattern = RegExp(
  '${RegExp.escape(_voicePromptBlockStart)}'
  r'[\s\S]*?'
  '${RegExp.escape(_voicePromptBlockEnd)}',
);

String? stripVoiceModeSystemPrompt(String? existing) {
  final trimmed = existing?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final stripped = trimmed.replaceAll(_voicePromptBlockPattern, '').trim();
  return stripped.isEmpty ? null : stripped;
}

String buildVoiceModeSystemPrompt(String? existing, bool enabled) {
  final basePrompt = stripVoiceModeSystemPrompt(existing);
  final voiceInstruction = enabled
      ? _voiceAgentSystemInstruction
      : _voiceAgentDisabledInstruction;
  final voiceBlock = [
    _voicePromptBlockStart,
    voiceInstruction,
    _voicePromptBlockEnd,
  ].join('\n');
  return [
    if (basePrompt != null && basePrompt.isNotEmpty) basePrompt,
    voiceBlock,
  ].join('\n\n');
}

String wrapSpokenInput(String text) =>
    '<spoken-input>\n'
    '$text\n'
    '</spoken-input>\n'
    '<instruction>This message was spoken by the user. Respond using the '
    'speak tool only, not normal messages, because the user may not be looking '
    'at the chat.</instruction>';

Map<String, Object?> buildVoiceAgentMcpServerConfig({
  required String command,
  required List<String> baseArgs,
  required String socketPath,
  Map<String, String>? env,
}) => {
  'type': 'stdio',
  'command': command,
  'args': [...baseArgs, '--socket', socketPath],
  if (env != null) 'env': Map<String, String>.from(env),
};
