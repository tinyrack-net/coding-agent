import 'package:agent_protocol/agent_protocol.dart';

/// Friendly display name for a provider id. Provider ids are now opaque
/// (user-created), so the name has to be looked up in the live provider list
/// rather than derived from the id.
///
/// Falls back to the raw id when the provider is gone — e.g. an agent created
/// against a provider the user has since deleted. That's deliberate: showing
/// the id is more honest than inventing a name.
String providerDisplayName(
  String? providerId, {
  Iterable<ProviderInfo> providers = const [],
}) {
  if (providerId == null || providerId.isEmpty) return 'The agent';
  for (final provider in providers) {
    if (provider.id == providerId) return provider.displayName;
  }
  return providerId;
}

/// Short label for the API dialect, shown as a badge in the provider list.
String providerKindLabel(ProviderKind kind) => switch (kind) {
      ProviderKind.openaiCompatible => 'OpenAI-compatible',
      ProviderKind.anthropic => 'Claude-compatible',
    };
