final class ClaudeProcessConfig {
  const ClaudeProcessConfig({
    required this.cwd,
    required this.permissionMode,
    required this.fastMode,
    this.model,
    this.thinkingOptionId,
    this.sessionId,
  });

  final String cwd;
  final String permissionMode;
  final bool fastMode;
  final String? model;
  final String? thinkingOptionId;
  final String? sessionId;
}

String? normalizeClaudeThinkingOption(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty || normalized == 'default') {
    return null;
  }
  if (const {
    'off',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultracode',
  }.contains(normalized)) {
    return normalized;
  }
  throw ArgumentError.value(value, 'thinkingOptionId', 'Unknown Claude option');
}
