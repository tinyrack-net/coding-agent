/// Port of Paseo 0.2.0's `composer/agent-controls/utils.ts`.
///
/// Label formatting and the model/thinking selection resolution the composer
/// toolbar reads. Selection is deliberately forgiving: a runtime model that
/// is not in the catalog, a configured model that has since disappeared, and
/// a stale thinking option all still produce something displayable rather
/// than an empty control.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'composer_input_labels.dart';

/// The toolbar controls that carry an explanatory hint.
enum ExplainedAgentControl { mode, model, thinking }

/// Highlight treatment for a feature chip.
enum FeatureHighlightColor { blue, defaultColor, green, yellow }

String getAgentControlHintKey(ExplainedAgentControl selector) =>
    switch (selector) {
      ExplainedAgentControl.thinking => 'agentControls.hints.thinking',
      ExplainedAgentControl.model => 'agentControls.hints.model',
      ExplainedAgentControl.mode => 'agentControls.hints.mode',
    };

/// Trims a model id, treating blank as absent.
String? normalizeModelId(String? modelId) {
  final normalized = modelId?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

/// A feature's tooltip falls back to its label.
String getFeatureTooltip({required String label, String? tooltip}) =>
    tooltip ?? label;

FeatureHighlightColor getFeatureHighlightColor(String featureId) =>
    switch (featureId) {
      'fast_mode' => FeatureHighlightColor.yellow,
      'auto_accept' => FeatureHighlightColor.green,
      'plan_mode' => FeatureHighlightColor.blue,
      _ => FeatureHighlightColor.defaultColor,
    };

String _sentenceCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1).toLowerCase();
}

/// Expands a compact identifier into words: separators become spaces and
/// camel/acronym boundaries are split.
String _splitCompactLabel(String value, {required bool splitHyphen}) {
  final separator = splitHyphen ? RegExp('[_-]+') : RegExp('_+');
  return value
      .replaceAll(separator, ' ')
      .replaceAllMapped(
        RegExp('([a-z])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAllMapped(
        RegExp('([A-Z]+)([A-Z][a-z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _formatControlLabel({
  required String id,
  String? label,
  required bool splitHyphen,
}) {
  final rawLabel = (label ?? id).trim();
  return _sentenceCase(_splitCompactLabel(rawLabel, splitHyphen: splitHyphen));
}

/// A mode without its own label is derived from its id, so hyphens are
/// treated as word separators; a provider-supplied label is left intact.
String formatAgentModeLabel({required String id, String? label}) =>
    _formatControlLabel(id: id, label: label, splitHyphen: label == null);

/// Thinking labels always split hyphens, and the `xhigh` level gets a
/// spelled-out name rather than the compact id.
String formatThinkingOptionLabel({
  required String id,
  String? label,
  required ComposerTranslator t,
}) {
  final rawLabel = (label ?? id).trim();
  final compactId = id.replaceAll(RegExp(r'[\s_-]+'), '').toLowerCase();
  final compactLabel = rawLabel
      .replaceAll(RegExp(r'[\s_-]+'), '')
      .toLowerCase();

  if (compactId == 'xhigh' || compactLabel == 'xhigh') {
    return t('agentControls.thinking.extraHigh');
  }
  return _formatControlLabel(id: id, label: label, splitHyphen: true);
}

final class AgentModelSelection {
  const AgentModelSelection({
    required this.selectedModel,
    required this.activeModelId,
    required this.displayModel,
    required this.thinkingOptions,
    required this.selectedThinkingId,
    required this.displayThinking,
  });

  final ProviderModelDefinition? selectedModel;

  /// The id the toolbar treats as active, which can be a model id the
  /// catalog does not contain.
  final String? activeModelId;
  final String displayModel;
  final List<ProviderSelectOption>? thinkingOptions;
  final String? selectedThinkingId;
  final String displayThinking;
}

ProviderModelDefinition? _findModelById(
  List<ProviderModelDefinition>? models,
  String? modelId,
) {
  if (models == null || modelId == null) return null;
  for (final model in models) {
    if (model.id == modelId) return model;
  }
  return null;
}

/// The catalog's declared default, else its first entry.
ProviderModelDefinition? _fallbackModel(List<ProviderModelDefinition>? models) {
  if (models == null || models.isEmpty) return null;
  for (final model in models) {
    if (model.isDefault == true) return model;
  }
  return models.first;
}

/// Resolves the model and thinking option the toolbar should show.
///
/// A runtime model present in the catalog wins; otherwise the configured id
/// is preferred over a runtime id the catalog does not know, and an unknown
/// id still displays rather than collapsing to the fallback's label.
AgentModelSelection resolveAgentModelSelection({
  required List<ProviderModelDefinition>? models,
  String? runtimeModelId,
  String? configuredModelId,
  String? explicitThinkingOptionId,
  required ComposerTranslator t,
}) {
  final normalizedRuntimeModelId = normalizeModelId(runtimeModelId);
  final normalizedConfiguredModelId = normalizeModelId(configuredModelId);

  final runtimeSelectedModel = _findModelById(models, normalizedRuntimeModelId);
  final preferredModelId =
      runtimeSelectedModel?.id ??
      normalizedConfiguredModelId ??
      normalizedRuntimeModelId;
  final fallbackModel = _fallbackModel(models);
  final selectedModel = models == null || preferredModelId == null
      ? fallbackModel
      : _findModelById(models, preferredModelId) ?? fallbackModel;

  final activeModelId = selectedModel?.id ?? preferredModelId;
  final displayModel =
      selectedModel?.label ??
      preferredModelId ??
      fallbackModel?.label ??
      t('agentControls.model.unknown');

  final thinkingOptions = selectedModel?.thinkingOptions;
  // "default" is a sentinel meaning "use the model's own default".
  final resolvedThinkingId =
      (explicitThinkingOptionId != null &&
          explicitThinkingOptionId.isNotEmpty &&
          explicitThinkingOptionId != 'default')
      ? explicitThinkingOptionId
      : selectedModel?.defaultThinkingOptionId;
  final effectiveThinking =
      _findThinkingOption(thinkingOptions, resolvedThinkingId) ??
      (thinkingOptions == null || thinkingOptions.isEmpty
          ? null
          : thinkingOptions.first);
  final selectedThinkingId = effectiveThinking?.id;

  final String displayThinking;
  if (effectiveThinking != null) {
    displayThinking = formatThinkingOptionLabel(
      id: effectiveThinking.id,
      label: effectiveThinking.label,
      t: t,
    );
  } else if (selectedThinkingId != null) {
    displayThinking = formatThinkingOptionLabel(id: selectedThinkingId, t: t);
  } else {
    displayThinking = t('agentControls.thinking.unknown');
  }

  return AgentModelSelection(
    selectedModel: selectedModel,
    activeModelId: activeModelId,
    displayModel: displayModel,
    thinkingOptions: thinkingOptions,
    selectedThinkingId: selectedThinkingId,
    displayThinking: displayThinking,
  );
}

ProviderSelectOption? _findThinkingOption(
  List<ProviderSelectOption>? options,
  String? id,
) {
  if (options == null || id == null) return null;
  for (final option in options) {
    if (option.id == id) return option;
  }
  return null;
}
