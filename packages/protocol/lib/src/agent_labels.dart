/// Frozen Paseo 0.2.0 labels used to express daemon-managed agent relations.
library;

const paseoParentAgentIdLabel = 'paseo.parent-agent-id';

String? parentAgentIdFromLabels(Map<String, Object?>? labels) {
  final value = labels?[paseoParentAgentIdLabel];
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

bool isDelegatedAgentLabels(Map<String, Object?>? labels) =>
    parentAgentIdFromLabels(labels) != null;
