/// Pure Paseo 0.2.0 import-session sheet projection rules.
library;

import 'package:agent_protocol/agent_protocol.dart';

const int importSessionsPerProviderLimit = 15;
const String allImportSessionProviders = '__all__';

bool requiresImportSessionsHostUpgrade({
  required bool supportsSnapshot,
  required String? workspaceId,
  required bool supportsWorkspaceTarget,
}) =>
    !supportsSnapshot ||
    ((workspaceId?.isNotEmpty ?? false) && !supportsWorkspaceTarget);

List<String>? resolveImportSessionProviders(
  bool supportsSnapshot,
  List<ProviderSnapshotEntry>? entries,
) {
  if (!supportsSnapshot || entries == null) return null;
  return [
    for (final entry in entries)
      if (entry.enabled) entry.provider,
  ];
}

Map<String, String> buildImportProviderLabelMap(
  List<ProviderSnapshotEntry>? entries,
) => {
  for (final entry in entries ?? const <ProviderSnapshotEntry>[])
    if (entry case ProviderSnapshotEntry(label: final String label))
      entry.provider: label,
};

final class ImportSessionsQueryResult {
  const ImportSessionsQueryResult({
    this.data,
    this.isError = false,
    this.isLoading = false,
    this.isPending = false,
  });

  final FetchRecentProviderSessionsResponse? data;
  final bool isError;
  final bool isLoading;
  final bool isPending;
}

List<RecentProviderSessionDescriptor> aggregateImportSessionEntries(
  Iterable<ImportSessionsQueryResult> queries,
) {
  final seen = <String>{};
  final collected = <RecentProviderSessionDescriptor>[];
  for (final query in queries) {
    for (final entry
        in query.data?.entries ?? const <RecentProviderSessionDescriptor>[]) {
      final key = '${entry.providerId}:${entry.providerHandleId}';
      if (seen.add(key)) collected.add(entry);
    }
  }
  collected.sort(
    (left, right) => DateTime.parse(
      right.lastActivityAt,
    ).compareTo(DateTime.parse(left.lastActivityAt)),
  );
  return collected;
}

int sumAlreadyImportedSessions(Iterable<ImportSessionsQueryResult> queries) =>
    queries.fold(
      0,
      (total, query) => total + (query.data?.filteredAlreadyImportedCount ?? 0),
    );

List<String> collectErroredImportProviderLabels({
  required List<String>? providers,
  required List<ImportSessionsQueryResult> queries,
  required Map<String, String> providerLabels,
}) {
  if (providers == null) return const [];
  return [
    for (var index = 0; index < queries.length; index++)
      if (queries[index].isError)
        providerLabels[providers[index]] ?? providers[index],
  ];
}

String importSessionTitle(RecentProviderSessionDescriptor entry) {
  final title = entry.title?.trim();
  if (title?.isNotEmpty == true) return title!;
  final preview = entry.firstPromptPreview?.trim();
  if (preview?.isNotEmpty == true) return preview!;
  return 'Untitled session';
}

String importSessionPromptPreview(RecentProviderSessionDescriptor entry) {
  final last = entry.lastPromptPreview?.trim();
  if (last?.isNotEmpty == true) return last!;
  final first = entry.firstPromptPreview?.trim();
  if (first?.isNotEmpty == true) return first!;
  return 'No prompt preview';
}

final class ImportSessionsEmptyState {
  const ImportSessionsEmptyState({required this.show, required this.title});

  final bool show;
  final String title;
}

ImportSessionsEmptyState computeImportSessionsEmptyState({
  required bool isLoadingSessions,
  required bool allQueriesErrored,
  required bool isQueryingProviders,
  required bool allQueriesSettled,
  required String selectedProvider,
  required int aggregatedCount,
  required int visibleCount,
  required int totalAlreadyImportedCount,
  required Map<String, String> providerLabels,
}) {
  final show =
      !isLoadingSessions &&
      !allQueriesErrored &&
      isQueryingProviders &&
      allQueriesSettled &&
      visibleCount == 0;
  if (!show) return const ImportSessionsEmptyState(show: false, title: '');
  if (selectedProvider != allImportSessionProviders && aggregatedCount > 0) {
    final label = providerLabels[selectedProvider] ?? selectedProvider;
    return ImportSessionsEmptyState(
      show: true,
      title: 'No recent $label sessions to import.',
    );
  }
  if (totalAlreadyImportedCount > 0) {
    return const ImportSessionsEmptyState(
      show: true,
      title: 'All recent sessions are already imported.',
    );
  }
  return const ImportSessionsEmptyState(
    show: true,
    title: 'No recent sessions to import.',
  );
}
