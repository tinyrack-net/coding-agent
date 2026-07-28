import 'package:agent_protocol/agent_protocol.dart';

String resolveEffectiveDraftModelId({
  required String? selectedModelId,
  required List<ProviderModelDefinition> availableModels,
}) {
  final selected = selectedModelId?.trim() ?? '';
  if (selected.isNotEmpty) return selected;
  for (final model in availableModels) {
    if (model.isDefault == true) return model.id;
  }
  return availableModels.firstOrNull?.id ?? '';
}

String resolveEffectiveDraftThinkingOptionId({
  required String? selectedThinkingOptionId,
  required String effectiveModelId,
  required List<ProviderModelDefinition> availableModels,
}) {
  final selected = selectedThinkingOptionId?.trim() ?? '';
  if (selected.isNotEmpty) return selected;
  for (final model in availableModels) {
    if (model.id == effectiveModelId) {
      return model.defaultThinkingOptionId ?? '';
    }
  }
  return '';
}

String resolveEffectiveDraftModeId({
  required String? selectedModeId,
  required ProviderSnapshotEntry provider,
}) {
  final modes = provider.modes ?? const <ProviderMode>[];
  final selected = selectedModeId?.trim() ?? '';
  if (selected.isNotEmpty && modes.any((mode) => mode.id == selected)) {
    return selected;
  }
  final providerDefault = provider.defaultModeId?.trim() ?? '';
  if (providerDefault.isNotEmpty &&
      modes.any((mode) => mode.id == providerDefault)) {
    return providerDefault;
  }
  return modes.firstOrNull?.id ?? '';
}

ListCommandsDraftConfig? buildDraftCommandConfig({
  required String? provider,
  required String cwd,
  required String modeId,
  required String modelId,
  required String thinkingOptionId,
  Map<String, Object?>? featureValues,
}) {
  final normalizedProvider = provider?.trim() ?? '';
  final normalizedCwd = cwd.trim();
  if (normalizedProvider.isEmpty || normalizedCwd.isEmpty) return null;
  return ListCommandsDraftConfig(
    provider: normalizedProvider,
    cwd: normalizedCwd,
    modeId: modeId.trim().isEmpty ? null : modeId.trim(),
    model: modelId.trim().isEmpty ? null : modelId.trim(),
    thinkingOptionId: thinkingOptionId.trim().isEmpty
        ? null
        : thinkingOptionId.trim(),
    featureValues: featureValues,
  );
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
