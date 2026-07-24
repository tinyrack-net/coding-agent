import 'package:agent_protocol/agent_protocol.dart';

/// Friendly display name for a wire-level provider id (e.g. `"openai"`),
/// shared by the settings screen and the permission card so both agree on
/// what to call each provider.
String providerDisplayName(String? providerId) {
  if (providerId == null || providerId.isEmpty) return 'The agent';
  for (final id in ProviderId.values) {
    if (id.name == providerId) {
      return switch (id) {
        ProviderId.openai => 'Codex',
        ProviderId.deepseek => 'DeepSeek',
        ProviderId.openrouter => 'OpenRouter',
      };
    }
  }
  return providerId;
}
