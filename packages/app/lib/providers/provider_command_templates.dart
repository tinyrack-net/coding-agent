const providerResumeCommandTemplates = <String, String>{
  'codex': 'codex resume {sessionId}',
  'claude': 'claude --resume {sessionId}',
  'pi': 'pi --session {sessionId}',
  'omp': 'omp --session {sessionId}',
  'opencode': 'opencode --session {sessionId}',
};

String? buildProviderResumeCommand({
  required String provider,
  required String sessionId,
}) {
  final template = providerResumeCommandTemplates[provider];
  if (template == null) return null;
  return template.replaceAll('{sessionId}', sessionId);
}
