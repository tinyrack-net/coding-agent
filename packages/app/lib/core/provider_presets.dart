import 'package:agent_protocol/agent_protocol.dart';

/// Templates for the "Add provider" flow.
///
/// Deliberately duplicated from the daemon's `provider_presets.dart` rather
/// than fetched over the wire: it's a handful of constants, and an RPC would
/// mean faking it in every widget test. The daemon keeps its own copy for the
/// smoke script; neither is a source of truth for what providers exist — that
/// is `providers.json`.
final class ProviderPreset {
  const ProviderPreset({
    required this.displayName,
    required this.kind,
    required this.baseUrl,
    this.models = const [],
    this.extraHeaders = const {},
  });

  final String displayName;
  final ProviderKind kind;

  /// Empty for the "Custom …" entries, so the form starts blank.
  final String baseUrl;
  final List<ProviderModel> models;
  final Map<String, String> extraHeaders;

  bool get isCustom => baseUrl.isEmpty;

  /// A fresh, unsaved config. The daemon assigns the real id on upsert.
  ProviderConfig toConfig() => ProviderConfig(
        id: '',
        displayName: isCustom ? '' : displayName,
        kind: kind,
        baseUrl: baseUrl,
        models: models,
        extraHeaders: extraHeaders,
      );
}

abstract final class ProviderPresets {
  static const openai = ProviderPreset(
    displayName: 'OpenAI',
    kind: ProviderKind.openaiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    models: [
      ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
      ProviderModel(id: 'gpt-5.4', displayName: 'GPT-5.4'),
    ],
  );

  static const claude = ProviderPreset(
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
    displayName: 'DeepSeek',
    kind: ProviderKind.openaiCompatible,
    baseUrl: 'https://api.deepseek.com/v1',
    models: [
      ProviderModel(id: 'deepseek-chat', displayName: 'DeepSeek Chat'),
      ProviderModel(id: 'deepseek-reasoner', displayName: 'DeepSeek Reasoner'),
    ],
  );

  static const openrouter = ProviderPreset(
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

  static const customOpenAi = ProviderPreset(
    displayName: 'Custom (OpenAI-compatible)',
    kind: ProviderKind.openaiCompatible,
    baseUrl: '',
  );

  static const customAnthropic = ProviderPreset(
    displayName: 'Custom (Claude-compatible)',
    kind: ProviderKind.anthropic,
    baseUrl: '',
  );

  /// Order shown in the picker: vendors first, then the manual options.
  static const all = [
    openai,
    claude,
    deepseek,
    openrouter,
    customOpenAi,
    customAnthropic,
  ];
}
