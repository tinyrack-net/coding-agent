/// Static catalog of native (API-key based) LLM providers. All three speak
/// an OpenAI-compatible Chat Completions API, so one [ProviderCatalogEntry]
/// per provider is enough to drive a shared backend implementation.
library;

import 'package:agent_protocol/agent_protocol.dart';

final class ProviderCatalogEntry {
  const ProviderCatalogEntry({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.models,
    this.extraHeaders = const {},
  });

  final ProviderId id;
  final String displayName;

  /// Chat Completions base URL, without a trailing slash (e.g. no `/chat/completions`).
  final String baseUrl;
  final List<ProviderModel> models;

  /// Extra headers this provider requires beyond `Authorization: Bearer`.
  final Map<String, String> extraHeaders;
}

abstract final class ProviderCatalog {
  static const openai = ProviderCatalogEntry(
    id: ProviderId.openai,
    displayName: 'Codex (OpenAI)',
    baseUrl: 'https://api.openai.com/v1',
    models: [
      ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
      ProviderModel(id: 'gpt-5.4', displayName: 'GPT-5.4'),
    ],
  );

  static const deepseek = ProviderCatalogEntry(
    id: ProviderId.deepseek,
    displayName: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    models: [
      ProviderModel(id: 'deepseek-chat', displayName: 'DeepSeek Chat'),
      ProviderModel(id: 'deepseek-reasoner', displayName: 'DeepSeek Reasoner'),
    ],
  );

  static const openrouter = ProviderCatalogEntry(
    id: ProviderId.openrouter,
    displayName: 'OpenRouter',
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

  static const all = [openai, deepseek, openrouter];

  static ProviderCatalogEntry byId(ProviderId id) =>
      all.firstWhere((e) => e.id == id);
}
