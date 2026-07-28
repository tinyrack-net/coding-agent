import 'package:agent_protocol/agent_protocol.dart';

const int maxInitialAgentTitleChars = 60 < maxExplicitAgentTitleChars
    ? 60
    : maxExplicitAgentTitleChars;

final class ResolvedCreateAgentTitles {
  const ResolvedCreateAgentTitles({
    required this.explicitTitle,
    required this.provisionalTitle,
  });

  final String? explicitTitle;
  final String? provisionalTitle;
}

ResolvedCreateAgentTitles resolveCreateAgentTitles({
  String? configTitle,
  String? initialPrompt,
}) {
  final trimmedTitle = configTitle?.trim();
  final explicitTitle = trimmedTitle == null || trimmedTitle.isEmpty
      ? null
      : trimmedTitle;
  final trimmedPrompt = initialPrompt?.trim();
  final provisionalTitle =
      explicitTitle ??
      (trimmedPrompt == null || trimmedPrompt.isEmpty
          ? null
          : _deriveInitialAgentTitle(trimmedPrompt));
  return ResolvedCreateAgentTitles(
    explicitTitle: explicitTitle,
    provisionalTitle: provisionalTitle,
  );
}

String? resolveFirstAgentPromptTitle(Map<String, Object?>? firstAgentContext) {
  final prompt = firstAgentContext?['prompt'];
  return resolveCreateAgentTitles(
    initialPrompt: prompt is String ? prompt : null,
  ).provisionalTitle;
}

String? _deriveInitialAgentTitle(String prompt) {
  String? firstContentLine;
  for (final line in prompt.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      firstContentLine = trimmed;
      break;
    }
  }
  if (firstContentLine == null) return null;
  final normalized = firstContentLine.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return null;
  final clamped = normalized.length <= maxInitialAgentTitleChars
      ? normalized
      : normalized.substring(0, maxInitialAgentTitleChars).trim();
  return clamped.isEmpty ? null : clamped;
}
