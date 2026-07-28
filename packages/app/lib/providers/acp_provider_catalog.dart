import 'package:agent_protocol/agent_protocol.dart';

final class AcpProviderCatalogEntry {
  const AcpProviderCatalogEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.version,
    required this.iconName,
    required this.installLink,
    required this.command,
    this.env = const {},
    this.params = const {},
  });

  final String id;
  final String title;
  final String description;
  final String version;
  final String? iconName;
  final String installLink;
  final List<String> command;
  final Map<String, Object?> env;
  final Map<String, Object?> params;
}

bool acpProviderMatchesSearch(AcpProviderCatalogEntry entry, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  return [
    entry.title,
    entry.id,
    entry.description,
  ].any((value) => value.toLowerCase().contains(normalized));
}

MutableDaemonConfigPatch buildAcpProviderConfigPatch(
  AcpProviderCatalogEntry entry,
) => MutableDaemonConfigPatch(
  providers: {
    entry.id: MutableDaemonProviderConfig(
      extra: {
        'extends': 'acp',
        'label': entry.title,
        'description': entry.description,
        'command': List<String>.unmodifiable(entry.command),
        'env': Map<String, Object?>.unmodifiable(entry.env),
        if (entry.params.isNotEmpty)
          'params': Map<String, Object?>.unmodifiable(entry.params),
      },
    ),
  },
);
