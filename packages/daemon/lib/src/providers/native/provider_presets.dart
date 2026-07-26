/// Templates for the "Add provider" flow.
///
/// These are *not* the set of providers that exist — user-created instances in
/// [ProviderConfigStore] are. A preset only pre-fills the form with a vendor's
/// base URL, dialect, and a seed model list.
library;

import 'package:agent_protocol/agent_protocol.dart';

final class ProviderPreset {
  const ProviderPreset({
    required this.presetId,
    required this.displayName,
    required this.kind,
    required this.baseUrl,
    required this.models,
    this.extraHeaders = const {},
  });

  /// Stable template key (not a provider id).
  final String presetId;
  final String displayName;
  final ProviderKind kind;

  /// Base URL without a trailing slash and without the endpoint path.
  final String baseUrl;
  final List<ProviderModel> models;
  final Map<String, String> extraHeaders;

  /// A fresh, unsaved config seeded from this preset. The daemon assigns the
  /// real id on upsert.
  ProviderConfig toConfig() => ProviderConfig(
        id: '',
        displayName: displayName,
        kind: kind,
        baseUrl: baseUrl,
        models: models,
        extraHeaders: extraHeaders,
      );
}

abstract final class ProviderPresets {
  static const openai = ProviderPreset(
    presetId: 'openai',
    displayName: 'OpenAI',
    kind: ProviderKind.openaiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    models: [
      ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
      ProviderModel(id: 'gpt-5.4', displayName: 'GPT-5.4'),
    ],
  );

  static const claude = ProviderPreset(
    presetId: 'claude',
    displayName: 'Claude (Anthropic)',
    kind: ProviderKind.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    models: [
      ProviderModel(id: 'claude-opus-4-8', displayName: 'Claude Opus 4.8'),
      ProviderModel(id: 'claude-sonnet-5', displayName: 'Claude Sonnet 5'),
      ProviderModel(id: 'claude-haiku-4-5', displayName: 'Claude Haiku 4.5'),
    ],
  );

  static const deepseek = ProviderPreset(
    presetId: 'deepseek',
    displayName: 'DeepSeek',
    kind: ProviderKind.openaiCompatible,
    baseUrl: 'https://api.deepseek.com/v1',
    models: [
      ProviderModel(id: 'deepseek-chat', displayName: 'DeepSeek Chat'),
      ProviderModel(id: 'deepseek-reasoner', displayName: 'DeepSeek Reasoner'),
    ],
  );

  static const openrouter = ProviderPreset(
    presetId: 'openrouter',
    displayName: 'OpenRouter',
    kind: ProviderKind.openaiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      ProviderModel(id: 'openai/gpt-5.4', displayName: 'GPT-5.4 (OpenRouter)'),
      ProviderModel(
        id: 'deepseek/deepseek-chat',
        displayName: 'DeepSeek Chat (OpenRouter)',
      ),
    ],
    extraHeaders: {
      'HTTP-Referer': 'https://tinyrack.net',
      'X-Title': 'coding-agent',
    },
  );

  static const all = [openai, claude, deepseek, openrouter];

  static ProviderPreset? byId(String presetId) =>
      all.where((preset) => preset.presetId == presetId).firstOrNull;
}
