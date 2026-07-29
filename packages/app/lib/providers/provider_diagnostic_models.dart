import 'package:agent_protocol/agent_protocol.dart';

final class ProviderDiscoveredModelsCache {
  const ProviderDiscoveredModelsCache({
    required this.serverId,
    required this.provider,
    required this.models,
  });

  final String serverId;
  final String provider;
  final List<ProviderModelDefinition> models;
}

final class ProviderDiscoveredModelsResult {
  const ProviderDiscoveredModelsResult({
    required this.models,
    required this.cache,
  });

  final List<ProviderModelDefinition> models;
  final ProviderDiscoveredModelsCache? cache;
}

ProviderDiscoveredModelsResult resolveProviderDiscoveredModels({
  required String serverId,
  required String provider,
  required List<ProviderModelDefinition>? currentModels,
  required bool providerSnapshotRefreshing,
  required ProviderDiscoveredModelsCache? previousCache,
}) {
  if (currentModels != null && currentModels.isNotEmpty) {
    final cache = ProviderDiscoveredModelsCache(
      serverId: serverId,
      provider: provider,
      models: currentModels,
    );
    return ProviderDiscoveredModelsResult(models: currentModels, cache: cache);
  }

  if (providerSnapshotRefreshing &&
      previousCache?.serverId == serverId &&
      previousCache?.provider == provider) {
    return ProviderDiscoveredModelsResult(
      models: previousCache!.models,
      cache: previousCache,
    );
  }

  return ProviderDiscoveredModelsResult(models: const [], cache: previousCache);
}

List<T> rankProviderModels<T>(
  Iterable<T> models,
  String query,
  List<String> Function(T model) fields,
) {
  final normalized = query.trim().toLowerCase();
  final values = models.toList(growable: false);
  if (normalized.isEmpty) return values;
  final ranked = <({T model, _MatchScore score, int index})>[];
  for (var index = 0; index < values.length; index++) {
    final score = _scoreTextFields(normalized, fields(values[index]));
    if (score != null) {
      ranked.add((model: values[index], score: score, index: index));
    }
  }
  ranked.sort((left, right) {
    final compared = left.score.compareTo(right.score);
    return compared != 0 ? compared : left.index.compareTo(right.index);
  });
  return [for (final entry in ranked) entry.model];
}

String formatProviderFetchedAt(DateTime date, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(date);
  final seconds = difference.inSeconds;
  if (seconds < 10) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

final class _MatchScore implements Comparable<_MatchScore> {
  const _MatchScore(this.tier, this.offset, this.spread);

  final int tier;
  final int offset;
  final int spread;

  _MatchScore operator +(_MatchScore other) => _MatchScore(
    tier + other.tier,
    offset + other.offset,
    spread + other.spread,
  );

  @override
  int compareTo(_MatchScore other) {
    var result = tier.compareTo(other.tier);
    if (result != 0) return result;
    result = offset.compareTo(other.offset);
    return result != 0 ? result : spread.compareTo(other.spread);
  }
}

_MatchScore? _scoreMatch(String query, String text) {
  final normalizedText = text.toLowerCase();
  if (query.isEmpty) return const _MatchScore(0, 0, 0);
  if (normalizedText == query) return const _MatchScore(0, 0, 0);

  _MatchScore? best;
  var position = 0;
  while (position <= normalizedText.length - query.length) {
    final found = normalizedText.indexOf(query, position);
    if (found == -1) break;
    final before = found > 0 ? normalizedText[found - 1] : null;
    final afterIndex = found + query.length;
    final after = afterIndex < normalizedText.length
        ? normalizedText[afterIndex]
        : null;
    final startsAtBoundary = found == 0 || _isWordBoundaryChar(before);
    final endsAtBoundary = after == null || _isWordBoundaryChar(after);
    final tier = switch ((startsAtBoundary, endsAtBoundary, found)) {
      (true, true, _) => 1,
      (_, _, 0) => 2,
      (true, _, _) => 3,
      _ => 4,
    };
    final candidate = _MatchScore(tier, found, 0);
    if (best == null ||
        candidate.tier < best.tier ||
        (candidate.tier == best.tier && candidate.offset < best.offset)) {
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

bool _isWordBoundaryChar(String? character) =>
    character == null || !RegExp(r'[a-z0-9]').hasMatch(character);

_MatchScore? _scoreTextFields(String query, List<String> fields) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty);
  var aggregate = const _MatchScore(0, 0, 0);
  for (final token in tokens) {
    _MatchScore? best;
    for (final field in fields) {
      final score = _scoreMatch(token, field);
      if (score != null && (best == null || score.compareTo(best) < 0)) {
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
