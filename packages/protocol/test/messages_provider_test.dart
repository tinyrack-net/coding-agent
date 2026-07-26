import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ProviderKind', () {
    test('fromWire resolves known values', () {
      expect(
        ProviderKind.fromWire('openai_compatible'),
        ProviderKind.openaiCompatible,
      );
      expect(ProviderKind.fromWire('anthropic'), ProviderKind.anthropic);
    });

    test('wire is snake_case and round-trips', () {
      for (final kind in ProviderKind.values) {
        expect(ProviderKind.fromWire(kind.wire), kind);
      }
    });

    // A newer daemon must not be able to crash an older client.
    test('fromWire falls back to openaiCompatible on unknown/null', () {
      expect(ProviderKind.fromWire('bogus'), ProviderKind.openaiCompatible);
      expect(ProviderKind.fromWire(null), ProviderKind.openaiCompatible);
    });
  });

  group('ProviderModel', () {
    test('round-trips with explicit displayName', () {
      const model = ProviderModel(id: 'gpt-5', displayName: 'GPT-5');
      final decoded = ProviderModel.fromJson(roundTrip(model.toJson()));
      expect(decoded.id, 'gpt-5');
      expect(decoded.displayName, 'GPT-5');
    });

    test('fromJson falls back to id when displayName missing', () {
      final decoded = ProviderModel.fromJson(const {'id': 'sonnet'});
      expect(decoded.id, 'sonnet');
      expect(decoded.displayName, 'sonnet');
    });

    test('fromJson throws when id missing', () {
      expect(() => ProviderModel.fromJson(const {}), throwsA(anything));
    });
  });

  group('ProviderConfig', () {
    test('round-trips with all fields', () {
      const config = ProviderConfig(
        id: 'p1',
        displayName: 'Claude (work)',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        models: [ProviderModel(id: 'claude-opus-4-8', displayName: 'Opus 4.8')],
        extraHeaders: {'X-Title': 'coding-agent'},
        maxTokens: 4096,
      );
      final decoded = ProviderConfig.fromJson(roundTrip(config.toJson()));
      expect(decoded.id, 'p1');
      expect(decoded.displayName, 'Claude (work)');
      expect(decoded.kind, ProviderKind.anthropic);
      expect(decoded.baseUrl, 'https://api.anthropic.com/v1');
      expect(decoded.models.single.id, 'claude-opus-4-8');
      expect(decoded.extraHeaders, {'X-Title': 'coding-agent'});
      expect(decoded.maxTokens, 4096);
    });

    test('fromJson defaults every field', () {
      final decoded = ProviderConfig.fromJson(const {});
      expect(decoded.id, '');
      expect(decoded.displayName, '');
      expect(decoded.kind, ProviderKind.openaiCompatible);
      expect(decoded.baseUrl, '');
      expect(decoded.models, isEmpty);
      expect(decoded.extraHeaders, isEmpty);
      expect(decoded.maxTokens, ProviderConfig.defaultMaxTokens);
    });

    test('extraHeaders coerces non-string values', () {
      final decoded = ProviderConfig.fromJson(const {
        'extraHeaders': {'X-Count': 3},
      });
      expect(decoded.extraHeaders, {'X-Count': '3'});
    });

    test('copyWith replaces only the named fields', () {
      const config = ProviderConfig(
        id: 'p1',
        displayName: 'Old',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://a.example/v1',
        maxTokens: 2048,
      );
      final updated = config.copyWith(displayName: 'New');
      expect(updated.displayName, 'New');
      expect(updated.id, 'p1');
      expect(updated.kind, ProviderKind.anthropic);
      expect(updated.baseUrl, 'https://a.example/v1');
      expect(updated.maxTokens, 2048);
    });
  });

  group('ProviderInfo', () {
    test('round-trips with all fields', () {
      const info = ProviderInfo(
        id: 'p1',
        displayName: 'OpenAI',
        kind: ProviderKind.openaiCompatible,
        baseUrl: 'https://api.openai.com/v1',
        configured: true,
        models: [
          ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
        ],
        maxTokens: 16000,
        extraHeaders: {'X-Title': 'coding-agent'},
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.id, 'p1');
      expect(decoded.displayName, 'OpenAI');
      expect(decoded.kind, ProviderKind.openaiCompatible);
      expect(decoded.baseUrl, 'https://api.openai.com/v1');
      expect(decoded.configured, isTrue);
      expect(decoded.models, hasLength(1));
      expect(decoded.unavailableReason, isNull);
      expect(decoded.maxTokens, 16000);
      expect(decoded.extraHeaders, {'X-Title': 'coding-agent'});
    });

    test('unconfigured provider round-trips with reason', () {
      const info = ProviderInfo(
        id: 'p2',
        displayName: 'DeepSeek',
        kind: ProviderKind.openaiCompatible,
        baseUrl: 'https://api.deepseek.com/v1',
        configured: false,
        unavailableReason: 'no API key configured',
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.configured, isFalse);
      expect(decoded.unavailableReason, 'no API key configured');
      expect(decoded.models, isEmpty);
    });

    test('fromJson defaults rather than throwing on an empty payload', () {
      final decoded = ProviderInfo.fromJson(const {});
      expect(decoded.id, '');
      expect(decoded.kind, ProviderKind.openaiCompatible);
      expect(decoded.configured, isFalse);
    });

    // Editing must not silently drop headers or maxTokens.
    test('toConfig carries every editable field', () {
      const info = ProviderInfo(
        id: 'p1',
        displayName: 'Claude',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        configured: true,
        models: [ProviderModel(id: 'claude-opus-4-8', displayName: 'Opus')],
        maxTokens: 1234,
        extraHeaders: {'X-Foo': 'bar'},
      );
      final config = info.toConfig();
      expect(config.id, 'p1');
      expect(config.displayName, 'Claude');
      expect(config.kind, ProviderKind.anthropic);
      expect(config.baseUrl, 'https://api.anthropic.com/v1');
      expect(config.models.single.id, 'claude-opus-4-8');
      expect(config.maxTokens, 1234);
      expect(config.extraHeaders, {'X-Foo': 'bar'});
    });
  });

  group('ProviderListResponse', () {
    test('round-trips with multiple providers', () {
      const response = ProviderListResponse(
        providers: [
          ProviderInfo(
            id: 'p1',
            displayName: 'OpenAI',
            kind: ProviderKind.openaiCompatible,
            baseUrl: 'https://api.openai.com/v1',
            configured: true,
          ),
          ProviderInfo(
            id: 'p2',
            displayName: 'Claude',
            kind: ProviderKind.anthropic,
            baseUrl: 'https://api.anthropic.com/v1',
            configured: false,
          ),
        ],
      );
      final decoded =
          ProviderListResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.providers, hasLength(2));
      expect(decoded.providers[0].id, 'p1');
      expect(decoded.providers[1].kind, ProviderKind.anthropic);
    });

    test('fromJson defaults to empty list when providers missing', () {
      final decoded = ProviderListResponse.fromJson(const {});
      expect(decoded.providers, isEmpty);
    });
  });

  group('ProviderUpsertResponse', () {
    test('round-trips the stored config', () {
      const response = ProviderUpsertResponse(
        config: ProviderConfig(
          id: 'generated-id',
          displayName: 'Claude',
          kind: ProviderKind.anthropic,
          baseUrl: 'https://api.anthropic.com/v1',
        ),
      );
      final decoded =
          ProviderUpsertResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.config.id, 'generated-id');
      expect(decoded.config.kind, ProviderKind.anthropic);
    });

    test('fromJson tolerates a missing config', () {
      final decoded = ProviderUpsertResponse.fromJson(const {});
      expect(decoded.config.id, '');
    });
  });

  group('ProviderCredentialTestResult', () {
    test('round-trips success', () {
      const result = ProviderCredentialTestResult(ok: true);
      final decoded =
          ProviderCredentialTestResult.fromJson(roundTrip(result.toJson()));
      expect(decoded.ok, isTrue);
      expect(decoded.error, isNull);
    });

    test('round-trips failure with error', () {
      const result =
          ProviderCredentialTestResult(ok: false, error: 'invalid key');
      final decoded =
          ProviderCredentialTestResult.fromJson(roundTrip(result.toJson()));
      expect(decoded.ok, isFalse);
      expect(decoded.error, 'invalid key');
    });
  });
}
