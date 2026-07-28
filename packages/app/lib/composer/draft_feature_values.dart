import 'package:agent_protocol/agent_protocol.dart';

Map<String, Object?> resolveDraftFeatureValues({
  required List<AgentFeature> features,
  Map<String, Object?> persisted = const {},
  Map<String, Object?> local = const {},
}) {
  final result = <String, Object?>{};
  for (final feature in features) {
    if (local.containsKey(feature.id)) {
      result[feature.id] = local[feature.id];
    } else if (persisted.containsKey(feature.id)) {
      result[feature.id] = persisted[feature.id];
    }
  }
  return Map.unmodifiable(result);
}

Object? applyDraftFeatureValue(
  AgentFeature feature,
  Map<String, Object?> featureValues,
) => featureValues.containsKey(feature.id)
    ? featureValues[feature.id]
    : feature.value;
