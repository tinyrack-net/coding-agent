import 'package:agent_protocol/agent_protocol.dart';

enum ProviderIconNameKind { builtin, catalog, bot }

final class ProviderIconName {
  const ProviderIconName._(this.kind, this.id);

  const ProviderIconName.builtin(String id)
    : this._(ProviderIconNameKind.builtin, id);

  const ProviderIconName.catalog(String id)
    : this._(ProviderIconNameKind.catalog, id);

  const ProviderIconName.bot() : this._(ProviderIconNameKind.bot, null);

  final ProviderIconNameKind kind;
  final String? id;
}

ProviderIconName resolveProviderIconName(String provider) {
  if (builtinProviderIconNames.contains(provider)) {
    return ProviderIconName.builtin(provider);
  }
  if (knownProviderIconNames.contains(provider)) {
    return ProviderIconName.catalog(provider);
  }
  return const ProviderIconName.bot();
}
