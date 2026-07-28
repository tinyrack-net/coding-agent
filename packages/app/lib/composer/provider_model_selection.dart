import 'package:agent_protocol/agent_protocol.dart';

import 'create_agent_preferences.dart';

sealed class ProviderModelSelection {
  const ProviderModelSelection();
}

final class ProviderModelRows extends ProviderModelSelection {
  const ProviderModelRows(this.rows);

  final List<ProviderSelectionModelRow> rows;
}

final class ProviderModelsLoading extends ProviderModelSelection {
  const ProviderModelsLoading();
}

final class ProviderModelsError extends ProviderModelSelection {
  const ProviderModelsError(this.message);

  final String message;
}

final class ProviderSelectorProvider {
  const ProviderSelectorProvider({
    required this.id,
    required this.label,
    required this.modelSelection,
  });

  final String id;
  final String label;
  final ProviderModelSelection modelSelection;
}

final class ProviderSelectionModelRow {
  const ProviderSelectionModelRow({
    required this.favoriteKey,
    required this.provider,
    required this.providerLabel,
    required this.modelId,
    required this.modelLabel,
    this.description,
    this.isDefault,
  });

  final String favoriteKey;
  final String provider;
  final String providerLabel;
  final String modelId;
  final String modelLabel;
  final String? description;
  final bool? isDefault;
}

final class ProviderSelectionReadiness {
  const ProviderSelectionReadiness({required this.ok, this.reason});

  final bool ok;
  final String? reason;
}

sealed class ModelBrowserView {
  const ModelBrowserView();
}

final class AllModelsView extends ModelBrowserView {
  const AllModelsView();
}

final class ProviderModelsView extends ModelBrowserView {
  const ProviderModelsView({
    required this.providerId,
    required this.providerLabel,
  });

  final String providerId;
  final String providerLabel;
}

List<ProviderSelectorProvider> buildSelectableProviderSelectorProviders(
  List<ProviderSnapshotEntry>? entries,
) => [
  for (final entry in entries ?? const <ProviderSnapshotEntry>[])
    if (entry.enabled)
      ProviderSelectorProvider(
        id: entry.provider,
        label: entry.label ?? entry.provider,
        modelSelection: _buildEntryModelSelection(entry),
      ),
];

ProviderModelSelection _buildEntryModelSelection(ProviderSnapshotEntry entry) {
  final label = entry.label ?? entry.provider;
  final models = entry.models;
  if (models?.isNotEmpty == true) {
    return ProviderModelRows(_buildModelRows(entry.provider, label, models!));
  }
  if (entry.status == ProviderCatalogStatus.ready) {
    if (models == null) return const ProviderModelsLoading();
    return ProviderModelRows([
      ProviderSelectionModelRow(
        favoriteKey: buildFavoriteModelKey(
          provider: entry.provider,
          modelId: '',
        ),
        provider: entry.provider,
        providerLabel: label,
        modelId: '',
        modelLabel: 'Default',
        isDefault: true,
      ),
    ]);
  }
  if (entry.status == ProviderCatalogStatus.loading) {
    return const ProviderModelsLoading();
  }
  return ProviderModelsError(
    entry.error ??
        (entry.status == ProviderCatalogStatus.unavailable
            ? 'Unavailable'
            : 'Unknown error'),
  );
}

List<ProviderSelectionModelRow> _buildModelRows(
  String provider,
  String providerLabel,
  List<ProviderModelDefinition> models,
) => [
  for (final model in models)
    ProviderSelectionModelRow(
      favoriteKey: buildFavoriteModelKey(provider: provider, modelId: model.id),
      provider: provider,
      providerLabel: providerLabel,
      modelId: model.id,
      modelLabel: model.label,
      description: model.description ?? model.id,
      isDefault: model.isDefault,
    ),
];

List<ProviderSelectionModelRow> getProviderModelRows(
  ProviderSelectorProvider provider,
) => switch (provider.modelSelection) {
  ProviderModelRows(:final rows) => rows,
  _ => const [],
};

List<ProviderSelectionModelRow> getAllProviderModelRows(
  List<ProviderSelectorProvider> providers,
) => [for (final provider in providers) ...getProviderModelRows(provider)];

String resolveSelectedModelLabel({
  required List<ProviderSelectorProvider> providers,
  required String selectedProvider,
  required String selectedModel,
  required bool isLoading,
}) {
  final providerId = selectedProvider.trim();
  if (providerId.isEmpty) return isLoading ? 'Loading...' : 'Select model';
  final provider = providers
      .where((entry) => entry.id == providerId)
      .firstOrNull;
  if (provider == null) return isLoading ? 'Loading...' : 'Select model';
  switch (provider.modelSelection) {
    case ProviderModelsLoading():
      return 'Loading...';
    case ProviderModelsError():
      return 'Error';
    case ProviderModelRows(:final rows):
      final selected = rows
          .where((entry) => entry.modelId == selectedModel)
          .firstOrNull;
      if (selected == null && selectedModel.trim().isNotEmpty) {
        return selectedModel.trim();
      }
      return selected?.modelLabel ??
          rows.where((row) => row.isDefault == true).firstOrNull?.modelLabel ??
          rows.firstOrNull?.modelLabel ??
          'Select model';
  }
}

ModelBrowserView resolveInitialModelBrowserView({
  required List<ProviderSelectorProvider> providers,
  required String selectedProvider,
  required String selectedModel,
  required Set<String> favoriteKeys,
}) {
  if (providers case [final provider]) {
    return ProviderModelsView(
      providerId: provider.id,
      providerLabel: provider.label,
    );
  }
  final selectedFavoriteKey = buildFavoriteModelKey(
    provider: selectedProvider,
    modelId: selectedModel,
  );
  if (selectedProvider.isNotEmpty &&
      selectedModel.isNotEmpty &&
      !favoriteKeys.contains(selectedFavoriteKey)) {
    final provider = providers
        .where((entry) => entry.id == selectedProvider)
        .firstOrNull;
    if (provider != null) {
      return ProviderModelsView(
        providerId: provider.id,
        providerLabel: provider.label,
      );
    }
  }
  return const AllModelsView();
}

List<ProviderSelectionModelRow> filterAndRankModelRows(
  List<ProviderSelectionModelRow> rows,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return rows;
  final scored = <({ProviderSelectionModelRow row, _MatchScore score})>[];
  for (final row in rows) {
    final score = _scoreTextFields(normalized, [
      row.modelLabel,
      row.modelId,
      row.providerLabel,
      row.description ?? '',
    ]);
    if (score != null) scored.add((row: row, score: score));
  }
  scored.sort((left, right) {
    final result = _compareScores(left.score, right.score);
    return result != 0
        ? result
        : left.row.modelLabel.compareTo(right.row.modelLabel);
  });
  return [for (final entry in scored) entry.row];
}

ProviderSelectionReadiness resolveSubmissionReadiness({
  required String text,
  required bool allowsEmptyAutoSubmit,
  required int providerCount,
  required String? provider,
  required String modelId,
  required List<Object?> availableModels,
  required bool isModelLoading,
  String? autoSubmitProvider,
  String? autoSubmitModel,
  required String? workspaceDirectory,
  required bool hasClient,
}) {
  if (!allowsEmptyAutoSubmit && text.trim().isEmpty) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'Initial prompt is required',
    );
  }
  if (providerCount == 0) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'No available providers on the selected host',
    );
  }
  final effectiveProvider = autoSubmitProvider ?? provider;
  if (effectiveProvider == null || effectiveProvider.isEmpty) {
    return const ProviderSelectionReadiness(ok: false, reason: 'Select model');
  }
  if (isModelLoading) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'Model defaults are still loading',
    );
  }
  final effectiveModel = autoSubmitModel ?? modelId;
  if (effectiveModel.isEmpty && availableModels.isNotEmpty) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'No model is available for the selected provider',
    );
  }
  if (workspaceDirectory == null || workspaceDirectory.isEmpty) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'Workspace directory not found',
    );
  }
  if (!hasClient) {
    return const ProviderSelectionReadiness(
      ok: false,
      reason: 'Host is not connected',
    );
  }
  return const ProviderSelectionReadiness(ok: true);
}

final class _MatchScore {
  const _MatchScore(this.tier, this.offset, [this.spread = 0]);

  final int tier;
  final int offset;
  final int spread;

  _MatchScore operator +(_MatchScore other) => _MatchScore(
    tier + other.tier,
    offset + other.offset,
    spread + other.spread,
  );
}

bool _isWordBoundary(String? character) =>
    character == null || !RegExp(r'[a-z0-9]').hasMatch(character);

_MatchScore? _scoreMatch(String query, String text) {
  if (query.isEmpty) return const _MatchScore(0, 0);
  final normalizedText = text.toLowerCase();
  if (normalizedText == query) return const _MatchScore(0, 0);

  _MatchScore? best;
  var position = 0;
  while (position <= normalizedText.length - query.length) {
    final found = normalizedText.indexOf(query, position);
    if (found == -1) break;
    final before = found > 0 ? normalizedText[found - 1] : null;
    final after = found + query.length < normalizedText.length
        ? normalizedText[found + query.length]
        : null;
    final startsAtBoundary = found == 0 || _isWordBoundary(before);
    final endsAtBoundary = _isWordBoundary(after);
    final tier = startsAtBoundary && endsAtBoundary
        ? 1
        : found == 0
        ? 2
        : startsAtBoundary
        ? 3
        : 4;
    final candidate = _MatchScore(tier, found);
    if (best == null || _compareScores(candidate, best) < 0) {
      best = candidate;
    }
    position = found + 1;
  }
  if (best != null) return best;

  var queryIndex = 0;
  var firstIndex = -1;
  var lastIndex = -1;
  for (
    var textIndex = 0;
    textIndex < normalizedText.length && queryIndex < query.length;
    textIndex++
  ) {
    if (normalizedText[textIndex] != query[queryIndex]) continue;
    if (firstIndex == -1) firstIndex = textIndex;
    lastIndex = textIndex;
    queryIndex++;
  }
  if (queryIndex != query.length || firstIndex == -1) return null;
  return _MatchScore(5, firstIndex, lastIndex - firstIndex + 1);
}

_MatchScore? _scoreTextFields(String query, List<String> fields) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty);
  var aggregate = const _MatchScore(0, 0);
  for (final token in tokens) {
    _MatchScore? best;
    for (final field in fields) {
      final score = _scoreMatch(token, field);
      if (score != null && (best == null || _compareScores(score, best) < 0)) {
        best = score;
      }
    }
    if (best == null) return null;
    aggregate += _MatchScore(
      best.tier,
      best.offset,
      best.spread == 0 ? token.length : best.spread,
    );
  }
  return aggregate;
}

int _compareScores(_MatchScore left, _MatchScore right) {
  var result = left.tier.compareTo(right.tier);
  if (result != 0) return result;
  result = left.offset.compareTo(right.offset);
  return result != 0 ? result : left.spread.compareTo(right.spread);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
