import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import 'agent_manager.dart';

final class StructuredGenerationProvider {
  const StructuredGenerationProvider({
    required this.provider,
    this.model,
    this.thinkingOptionId,
  });

  final String provider;
  final String? model;
  final String? thinkingOptionId;
}

final class StructuredGenerationSelection {
  const StructuredGenerationSelection({
    this.provider,
    this.model,
    this.thinkingOptionId,
  });

  final String? provider;
  final String? model;
  final String? thinkingOptionId;
}

typedef ProviderSnapshotLoader =
    Future<List<ProviderSnapshotEntry>> Function({
      required String cwd,
      required bool wait,
    });

const _preferredModels = <({String substring, String? thinkingOptionId})>[
  (substring: 'haiku', thinkingOptionId: null),
  (substring: 'gpt-5.4-mini', thinkingOptionId: 'low'),
  (substring: 'minimax-m3', thinkingOptionId: null),
  (substring: 'nemotron-3-super', thinkingOptionId: null),
];

Future<List<StructuredGenerationProvider>>
resolveStructuredGenerationProviders({
  required String cwd,
  required List<MutableStructuredGenerationProvider> configured,
  required ProviderSnapshotLoader loadSnapshot,
  StructuredGenerationSelection? currentSelection,
}) async {
  final result = <StructuredGenerationProvider>[];
  final keys = <String>{};
  void add(StructuredGenerationProvider provider) {
    final key =
        '${provider.provider}\u0000${provider.model ?? ''}\u0000'
        '${provider.thinkingOptionId ?? ''}';
    if (keys.add(key)) result.add(provider);
  }

  if (configured.isNotEmpty) {
    final explicit = [
      for (final entry in configured)
        if (entry.provider.trim().isNotEmpty &&
            (entry.model?.trim().isNotEmpty ?? false))
          StructuredGenerationProvider(
            provider: entry.provider.trim(),
            model: entry.model!.trim(),
            thinkingOptionId: entry.thinkingOptionId,
          ),
    ];
    if (explicit.length == configured.length) {
      for (final provider in explicit) {
        add(provider);
      }
      return result;
    }
    final snapshot = await loadSnapshot(cwd: cwd, wait: false);
    for (final entry in configured) {
      final resolved = _resolveCandidate(entry, snapshot);
      if (resolved != null) add(resolved);
    }
    if (result.isNotEmpty) return result;
  }

  final snapshot = await loadSnapshot(cwd: cwd, wait: true);
  final enabled = snapshot.where((entry) => entry.enabled).toList();
  final modelEntries = enabled
      .where((entry) => entry.models?.isNotEmpty ?? false)
      .toList();
  for (final entry in configured) {
    final resolved = _resolveCandidate(entry, enabled);
    if (resolved != null) add(resolved);
  }
  for (final preferred in _preferredModels) {
    for (final entry in modelEntries) {
      final model = entry.models!
          .where(
            (model) =>
                model.id.toLowerCase().contains(preferred.substring) ||
                model.label.toLowerCase().contains(preferred.substring),
          )
          .firstOrNull;
      if (model == null) continue;
      final optionIds = model.thinkingOptions
          ?.map((option) => option.id)
          .toSet();
      add(
        StructuredGenerationProvider(
          provider: entry.provider,
          model: model.id,
          thinkingOptionId:
              optionIds?.contains(preferred.thinkingOptionId) == true
              ? preferred.thinkingOptionId
              : model.defaultThinkingOptionId,
        ),
      );
      break;
    }
  }
  final selectedProvider = currentSelection?.provider?.trim();
  if (selectedProvider != null && selectedProvider.isNotEmpty) {
    final selected = _resolveCandidate(
      MutableStructuredGenerationProvider(
        provider: selectedProvider,
        model: currentSelection?.model?.trim().isEmpty == true
            ? null
            : currentSelection?.model?.trim(),
        thinkingOptionId: currentSelection?.thinkingOptionId,
      ),
      enabled,
    );
    if (selected != null) {
      add(selected);
    } else {
      add(
        StructuredGenerationProvider(
          provider: selectedProvider,
          model: currentSelection?.model?.trim(),
          thinkingOptionId: currentSelection?.thinkingOptionId,
        ),
      );
    }
  }
  return result;
}

StructuredGenerationProvider? _resolveCandidate(
  MutableStructuredGenerationProvider candidate,
  List<ProviderSnapshotEntry> entries,
) {
  final provider = candidate.provider.trim();
  if (provider.isEmpty) return null;
  final configuredModel = candidate.model?.trim();
  final topLevel = entries
      .where((entry) => entry.provider == provider)
      .firstOrNull;
  if (topLevel != null) {
    if (configuredModel != null && configuredModel.isNotEmpty) {
      return StructuredGenerationProvider(
        provider: provider,
        model: configuredModel,
        thinkingOptionId: candidate.thinkingOptionId,
      );
    }
    final model = _defaultModel(topLevel.models);
    return StructuredGenerationProvider(
      provider: provider,
      model: model?.id,
      thinkingOptionId: _thinkingOption(model, candidate.thinkingOptionId),
    );
  }
  if (configuredModel == null || configuredModel.isEmpty) {
    return StructuredGenerationProvider(
      provider: provider,
      thinkingOptionId: candidate.thinkingOptionId,
    );
  }
  final normalizedProvider = provider.toLowerCase();
  final normalizedModel = configuredModel.toLowerCase();
  for (final entry in entries) {
    for (final model in entry.models ?? const <ProviderModelDefinition>[]) {
      final nestedProvider = model.metadata?['providerId'];
      final nestedModel = model.metadata?['modelId'];
      if (nestedProvider is! String ||
          nestedProvider.trim().toLowerCase() != normalizedProvider) {
        continue;
      }
      if (normalizedModel == model.id.toLowerCase() ||
          (nestedModel is String &&
              normalizedModel == nestedModel.trim().toLowerCase()) ||
          model.id.toLowerCase() == '$normalizedProvider/$normalizedModel') {
        return StructuredGenerationProvider(
          provider: entry.provider,
          model: model.id,
          thinkingOptionId: _thinkingOption(model, candidate.thinkingOptionId),
        );
      }
    }
  }
  return StructuredGenerationProvider(
    provider: provider,
    model: configuredModel,
    thinkingOptionId: candidate.thinkingOptionId,
  );
}

ProviderModelDefinition? _defaultModel(List<ProviderModelDefinition>? models) =>
    models?.where((model) => model.isDefault == true).firstOrNull ??
    models?.firstOrNull;

String? _thinkingOption(ProviderModelDefinition? model, String? preferred) {
  if (model == null) return null;
  if (preferred != null &&
      (model.thinkingOptions?.any((option) => option.id == preferred) ??
          false)) {
    return preferred;
  }
  return model.defaultThinkingOptionId;
}

Future<Map<String, Object?>?> generateStructuredAgentResponseWithFallback({
  required AgentManager manager,
  required String cwd,
  required List<StructuredGenerationProvider> providers,
  required String prompt,
  required Map<String, Object?> jsonSchema,
  String? Function(Map<String, Object?> value)? validate,
  int maxRetries = 2,
}) async {
  Object? lastError;
  for (final provider in providers) {
    if (!manager.isProviderAvailable(provider.provider)) continue;
    String? agentId;
    try {
      final agent = await manager.createAgent(
        cwd: cwd,
        provider: provider.provider,
        model: provider.model ?? '',
        mode: AgentMode.normal,
        thinkingOptionId: provider.thinkingOptionId,
        title: 'Branch name generator',
        internal: true,
      );
      agentId = agent.agentId;
      var request =
          '$prompt\n\nYou must respond with JSON only that matches this JSON '
          'Schema:\n${jsonEncode(jsonSchema)}';
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        final output = (await manager.runAndWait(agentId, request)).output;
        try {
          if (output == null) throw const FormatException('empty response');
          final decoded = jsonDecode(_extractJson(output));
          if (decoded is! Map) {
            throw const FormatException('response must be an object');
          }
          final value = Map<String, Object?>.from(decoded);
          final validationError = validate?.call(value);
          if (validationError != null) throw FormatException(validationError);
          return value;
        } on Object catch (error) {
          if (attempt == maxRetries) rethrow;
          request =
              '$prompt\n\nThe previous response did not match the required '
              'JSON schema: $error\nRespond again with JSON only that matches '
              'this JSON Schema:\n${jsonEncode(jsonSchema)}';
        }
      }
    } on Object catch (error) {
      lastError = error;
    } finally {
      if (agentId != null) await manager.discardInternalAgent(agentId);
    }
  }
  if (lastError != null) throw StateError('$lastError');
  return null;
}

String _extractJson(String response) {
  final fenced = RegExp(
    r'```(?:json)?\s*([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(response);
  if (fenced != null) return fenced.group(1)!.trim();
  final start = response.indexOf(RegExp(r'[\{\[]'));
  if (start < 0) return response.trim();
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start; index < response.length; index++) {
    final char = response[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
    } else if (char == '{' || char == '[') {
      depth++;
    } else if (char == '}' || char == ']') {
      depth--;
      if (depth == 0) return response.substring(start, index + 1);
    }
  }
  return response.trim();
}
