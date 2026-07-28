import '../core/daemon_client.dart';

const providersSnapshotQueryRoot = 'providersSnapshot';

String? normalizeProvidersSnapshotCwd(String? cwd) {
  final trimmed = cwd?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final normalized = trimmed.replaceAll(r'\', '/');
  if (normalized == '/') return normalized;
  final withoutTrailingSlash = normalized.replaceFirst(RegExp(r'/+$'), '');
  return withoutTrailingSlash.isEmpty ? '/' : withoutTrailingSlash;
}

final class ProvidersSnapshotScope {
  ProvidersSnapshotScope({
    required this.client,
    required this.serverId,
    String? cwd,
    this.enabled = true,
  }) : cwd = normalizeProvidersSnapshotCwd(cwd);

  final DaemonClient client;
  final String? serverId;
  final String? cwd;
  final bool enabled;

  bool get isHomeScope => cwd == null;

  List<Object?> get queryRoot => [providersSnapshotQueryRoot, serverId];

  List<Object?> get queryKey => cwd == null
      ? [providersSnapshotQueryRoot, serverId, 'home']
      : [providersSnapshotQueryRoot, serverId, 'cwd', cwd];

  @override
  bool operator ==(Object other) =>
      other is ProvidersSnapshotScope &&
      identical(other.client, client) &&
      other.serverId == serverId &&
      other.cwd == cwd &&
      other.enabled == enabled;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(client), serverId, cwd, enabled);
}

enum SelectorOpenRefetchDecision { refetchStale, refetchAlways }

SelectorOpenRefetchDecision selectorOpenRefetchDecision({
  required Iterable<ProviderSnapshotStatus>? entries,
  String? selectedProvider,
}) {
  if (selectedProvider == null || selectedProvider.isEmpty) {
    return SelectorOpenRefetchDecision.refetchStale;
  }
  ProviderSnapshotStatus? selected;
  for (final entry in entries ?? const <ProviderSnapshotStatus>[]) {
    if (entry.provider == selectedProvider) {
      selected = entry;
      break;
    }
  }
  if (selected == null || selected.loading) {
    return SelectorOpenRefetchDecision.refetchAlways;
  }
  return SelectorOpenRefetchDecision.refetchStale;
}

final class ProviderSnapshotStatus {
  const ProviderSnapshotStatus({required this.provider, required this.loading});

  final String provider;
  final bool loading;
}
