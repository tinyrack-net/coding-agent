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

typedef StructuredAgentCaller = Future<String> Function(String prompt);

final class StructuredAgentResponseError implements Exception {
  const StructuredAgentResponseError({
    required this.lastResponse,
    required this.validationErrors,
  });

  final String lastResponse;
  final List<String> validationErrors;

  @override
  String toString() => 'Agent response did not match the required JSON schema';
}

final class StructuredGenerationAttempt {
  const StructuredGenerationAttempt({
    required this.provider,
    required this.model,
    required this.available,
    required this.error,
  });

  final String provider;
  final String? model;
  final bool available;
  final String? error;
}

final class StructuredAgentFallbackError implements Exception {
  const StructuredAgentFallbackError(this.attempts);

  final List<StructuredGenerationAttempt> attempts;

  @override
  String toString() {
    if (attempts.isEmpty) {
      return 'Structured generation failed for all providers';
    }
    final summary = attempts
        .map((attempt) {
          final model = attempt.model == null ? '' : ' (${attempt.model})';
          final state = attempt.available ? 'failed' : 'unavailable';
          final error = attempt.error == null ? '' : ' (${attempt.error})';
          return '${attempt.provider}$model: $state$error';
        })
        .join('; ');
    return 'Structured generation failed for all providers: $summary';
  }
}

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
  if (providers.isEmpty) throw const StructuredAgentFallbackError([]);
  final attempts = <StructuredGenerationAttempt>[];
  for (final provider in providers) {
    if (!manager.isProviderAvailable(provider.provider)) {
      attempts.add(
        StructuredGenerationAttempt(
          provider: provider.provider,
          model: provider.model,
          available: false,
          error: null,
        ),
      );
      continue;
    }
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
      return await getStructuredAgentResponse(
        caller: (request) async =>
            (await manager.runAndWait(agentId!, request)).output ?? '',
        prompt: prompt,
        jsonSchema: jsonSchema,
        validate: validate,
        maxRetries: maxRetries,
      );
    } on Object catch (error) {
      attempts.add(
        StructuredGenerationAttempt(
          provider: provider.provider,
          model: provider.model,
          available: true,
          error: error.toString(),
        ),
      );
    } finally {
      if (agentId != null) {
        try {
          await manager.discardInternalAgent(agentId);
        } on Object {
          // Cleanup must not hide the provider attempt that triggered it.
        }
      }
    }
  }
  throw StructuredAgentFallbackError(List.unmodifiable(attempts));
}

Future<Map<String, Object?>> getStructuredAgentResponse({
  required StructuredAgentCaller caller,
  required String prompt,
  required Map<String, Object?> jsonSchema,
  String? Function(Map<String, Object?> value)? validate,
  int maxRetries = 2,
}) async {
  final basePrompt = [
    prompt.trim(),
    '',
    'You must respond with JSON only that matches this JSON Schema:',
    const JsonEncoder.withIndent('  ').convert(jsonSchema),
  ].join('\n');
  var attemptPrompt = basePrompt;
  var lastResponse = '';
  var lastErrors = <String>[];
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    final response = await caller(attemptPrompt);
    lastResponse = response;
    Object? decoded;
    try {
      decoded = jsonDecode(_extractJson(response));
    } on Object catch (error) {
      lastErrors = ['Invalid JSON: $error'];
      if (attempt == maxRetries) break;
      attemptPrompt = _retryPrompt(basePrompt, lastErrors);
      continue;
    }
    if (decoded is! Map) {
      lastErrors = ['(root): response must be an object'];
    } else {
      final value = Map<String, Object?>.from(decoded);
      lastErrors = _validateJsonSchema(value, jsonSchema);
      final validationError = validate?.call(value);
      if (validationError != null) lastErrors.add(validationError);
      if (lastErrors.isEmpty) return value;
    }
    if (attempt == maxRetries) break;
    attemptPrompt = _retryPrompt(basePrompt, lastErrors);
  }
  throw StructuredAgentResponseError(
    lastResponse: lastResponse,
    validationErrors: List.unmodifiable(lastErrors),
  );
}

List<String> _validateJsonSchema(
  Object? value,
  Map<String, Object?> schema, [
  String path = '(root)',
]) {
  final errors = <String>[];
  final type = schema['type'];
  final typeMatches = switch (type) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'number' => value is num,
    'integer' => value is int,
    'boolean' => value is bool,
    _ => true,
  };
  if (!typeMatches) {
    return ['$path: must be $type'];
  }
  if (value is String) {
    final minLength = schema['minLength'];
    final maxLength = schema['maxLength'];
    if (minLength is int && value.length < minLength) {
      errors.add('$path: must NOT have fewer than $minLength characters');
    }
    if (maxLength is int && value.length > maxLength) {
      errors.add('$path: must NOT have more than $maxLength characters');
    }
  }
  final allowed = schema['enum'];
  if (allowed is List && !allowed.contains(value)) {
    errors.add('$path: must be equal to one of the allowed values');
  }
  if (value is Map) {
    final properties = schema['properties'] is Map
        ? Map<String, Object?>.from(schema['properties']! as Map)
        : const <String, Object?>{};
    final required = schema['required'] is List
        ? (schema['required']! as List).whereType<String>()
        : const Iterable<String>.empty();
    for (final key in required) {
      if (!value.containsKey(key))
        errors.add('$path: must have required property $key');
    }
    if (schema['additionalProperties'] == false) {
      for (final key in value.keys.whereType<String>()) {
        if (!properties.containsKey(key)) {
          errors.add('$path: must NOT have additional property $key');
        }
      }
    }
    for (final entry in properties.entries) {
      if (!value.containsKey(entry.key) || entry.value is! Map) continue;
      errors.addAll(
        _validateJsonSchema(
          value[entry.key],
          Map<String, Object?>.from(entry.value! as Map),
          path == '(root)' ? entry.key : '$path.${entry.key}',
        ),
      );
    }
  }
  if (value is List && schema['items'] is Map) {
    final itemSchema = Map<String, Object?>.from(schema['items']! as Map);
    for (var index = 0; index < value.length; index++) {
      errors.addAll(
        _validateJsonSchema(value[index], itemSchema, '$path.$index'),
      );
    }
  }
  return errors;
}

String _retryPrompt(String basePrompt, List<String> errors) => [
  basePrompt,
  '',
  'Previous response was invalid with validation errors:',
  if (errors.isEmpty)
    '- Unknown validation error'
  else
    ...errors.map((e) => '- $e'),
  '',
  'Respond again with JSON only that matches the schema.',
].join('\n');

String _extractJson(String response) {
  final fenced = RegExp(
    r'```(?:json)?\s*\n([\s\S]*?)\n```',
    caseSensitive: false,
  ).firstMatch(response);
  if (fenced != null) return fenced.group(1)!.trim();
  final source = response.trim();
  for (var start = 0; start < source.length; start++) {
    if (source[start] != '{' && source[start] != '[') continue;
    final candidate = _balancedJsonCandidate(source, start);
    if (candidate != null) return candidate;
  }
  return source;
}

String? _balancedJsonCandidate(String source, int start) {
  final open = source[start];
  final close = open == '{' ? '}' : ']';
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start; index < source.length; index++) {
    final char = source[index];
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
    } else if (char == open) {
      depth++;
    } else if (char == close) {
      depth--;
      if (depth == 0) {
        final candidate = source.substring(start, index + 1).trim();
        try {
          jsonDecode(candidate);
          return candidate;
        } on Object {
          return null;
        }
      }
    }
  }
  return null;
}
