import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/provider_display.dart';
import 'package:coding_agent_app/core/provider_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('providerDisplayName', () {
    const claude = ProviderInfo(
      id: 'p-claude',
      displayName: 'Claude (work)',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      configured: true,
    );

    test('resolves the name from the live provider list', () {
      expect(
        providerDisplayName('p-claude', providers: const [claude]),
        'Claude (work)',
      );
    });

    // An agent whose provider the user has since deleted: showing the raw id
    // is more honest than inventing a name.
    test('falls back to the raw id when the provider is gone', () {
      expect(
        providerDisplayName('p-deleted', providers: const [claude]),
        'p-deleted',
      );
      expect(providerDisplayName('p-deleted'), 'p-deleted');
    });

    test('null or empty means no specific provider', () {
      expect(providerDisplayName(null), 'The agent');
      expect(providerDisplayName(''), 'The agent');
    });
  });

  group('providerKindLabel', () {
    test('labels every kind', () {
      expect(
        providerKindLabel(ProviderKind.openaiCompatible),
        'OpenAI-compatible',
      );
      expect(providerKindLabel(ProviderKind.anthropic), 'Claude-compatible');
    });
  });

  group('ProviderPresets', () {
    test('every vendor preset carries a base URL and seed models', () {
      final vendors = ProviderPresets.all.where((p) => !p.isCustom);
      expect(vendors, isNotEmpty);
      for (final preset in vendors) {
        expect(preset.baseUrl, startsWith('https://'), reason: preset.displayName);
        expect(preset.baseUrl, isNot(endsWith('/')), reason: preset.displayName);
        expect(preset.models, isNotEmpty, reason: preset.displayName);
      }
    });

    test('both dialects are offered as manual options', () {
      final customKinds =
          ProviderPresets.all.where((p) => p.isCustom).map((p) => p.kind);
      expect(customKinds, containsAll(ProviderKind.values));
    });

    test('toConfig produces an unsaved config with an empty id', () {
      final config = ProviderPresets.claude.toConfig();
      expect(config.id, isEmpty);
      expect(config.displayName, 'Claude (Anthropic)');
      expect(config.kind, ProviderKind.anthropic);
      expect(config.baseUrl, 'https://api.anthropic.com/v1');
      expect(config.models, isNotEmpty);
    });

    test('a custom preset leaves the name blank for the user to fill', () {
      final config = ProviderPresets.customOpenAi.toConfig();
      expect(config.displayName, isEmpty);
      expect(config.baseUrl, isEmpty);
      expect(config.kind, ProviderKind.openaiCompatible);
    });

    test('openrouter carries its required attribution headers', () {
      expect(
        ProviderPresets.openrouter.toConfig().extraHeaders,
        containsPair('X-Title', 'coding-agent'),
      );
    });
  });
}
