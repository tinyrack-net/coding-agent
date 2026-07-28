/// Composes provider system-prompt fragments using Paseo's exact whitespace
/// contract.
String? composeSystemPromptParts(Iterable<String?> parts) {
  final prompt = parts
      .map((part) => part?.trim())
      .whereType<String>()
      .where((part) => part.isNotEmpty)
      .join('\n\n');
  return prompt.isEmpty ? null : prompt;
}
