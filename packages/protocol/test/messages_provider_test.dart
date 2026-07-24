import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ProviderId', () {
    test('fromWire resolves known values', () {
      expect(ProviderId.fromWire('claude'), ProviderId.claude);
      expect(ProviderId.fromWire('codex'), ProviderId.codex);
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
        id: ProviderId.claude,
        displayName: 'Claude',
        available: true,
        executablePath: '/usr/bin/claude',
        version: '1.0.0',
        models: [ProviderModel(id: 'sonnet', displayName: 'Sonnet')],
        unavailableReason: null,
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.id, ProviderId.claude);
      expect(decoded.displayName, 'Claude');
      expect(decoded.available, isTrue);
      expect(decoded.executablePath, '/usr/bin/claude');
      expect(decoded.version, '1.0.0');
      expect(decoded.models, hasLength(1));
      expect(decoded.unavailableReason, isNull);
    });

    test('unavailable provider round-trips with reason', () {
      const info = ProviderInfo(
        id: ProviderId.codex,
        displayName: 'Codex',
        available: false,
        unavailableReason: 'not installed',
      );
      final decoded = ProviderInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.available, isFalse);
      expect(decoded.unavailableReason, 'not installed');
      expect(decoded.executablePath, isNull);
      expect(decoded.version, isNull);
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
            id: ProviderId.claude,
            displayName: 'Claude',
            available: true,
          ),
          ProviderInfo(
            id: ProviderId.codex,
            displayName: 'Codex',
            available: false,
          ),
        ],
      );
      final decoded =
          ProviderListResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.providers, hasLength(2));
      expect(decoded.providers[0].id, ProviderId.claude);
      expect(decoded.providers[1].id, ProviderId.codex);
    });

    test('fromJson defaults to empty list when providers missing', () {
      final decoded = ProviderListResponse.fromJson(const {});
      expect(decoded.providers, isEmpty);
    });
  });
}
