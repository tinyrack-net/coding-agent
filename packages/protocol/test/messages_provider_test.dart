import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ProviderId', () {
    test('fromWire resolves known values', () {
      expect(ProviderId.fromWire('openai'), ProviderId.openai);
      expect(ProviderId.fromWire('deepseek'), ProviderId.deepseek);
      expect(ProviderId.fromWire('openrouter'), ProviderId.openrouter);
    });

    test('fromWire throws on unknown value', () {
      expect(() => ProviderId.fromWire('bogus'), throwsStateError);
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

  group('ProviderInfo', () {
    test('round-trips with all fields', () {
      const info = ProviderInfo(
        id: ProviderId.openai,
        displayName: 'Codex (OpenAI)',
        configured: true,
        models: [ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex')],
        unavailableReason: null,
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.id, ProviderId.openai);
      expect(decoded.displayName, 'Codex (OpenAI)');
      expect(decoded.configured, isTrue);
      expect(decoded.models, hasLength(1));
      expect(decoded.unavailableReason, isNull);
    });

    test('unconfigured provider round-trips with reason', () {
      const info = ProviderInfo(
        id: ProviderId.deepseek,
        displayName: 'DeepSeek',
        configured: false,
        unavailableReason: 'no API key configured',
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.configured, isFalse);
      expect(decoded.unavailableReason, 'no API key configured');
      expect(decoded.models, isEmpty);
    });

    test('fromJson throws when id missing', () {
      expect(() => ProviderInfo.fromJson(const {}), throwsA(anything));
    });

    test('fromJson throws on unknown provider id', () {
      expect(
        () => ProviderInfo.fromJson(const {'id': 'bogus'}),
        throwsStateError,
      );
    });
  });

  group('ProviderListResponse', () {
    test('round-trips with multiple providers', () {
      const response = ProviderListResponse(
        providers: [
          ProviderInfo(
            id: ProviderId.openai,
            displayName: 'Codex (OpenAI)',
            configured: true,
          ),
          ProviderInfo(
            id: ProviderId.openrouter,
            displayName: 'OpenRouter',
            configured: false,
          ),
        ],
      );
      final decoded =
          ProviderListResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.providers, hasLength(2));
      expect(decoded.providers[0].id, ProviderId.openai);
      expect(decoded.providers[1].id, ProviderId.openrouter);
    });

    test('fromJson defaults to empty list when providers missing', () {
      final decoded = ProviderListResponse.fromJson(const {});
      expect(decoded.providers, isEmpty);
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
