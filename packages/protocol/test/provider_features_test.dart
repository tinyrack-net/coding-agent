import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const draft = ListCommandsDraftConfig(
    provider: 'claude',
    cwd: '/repo',
    modeId: 'auto',
    model: 'claude-opus-4-6',
    thinkingOptionId: 'high',
    featureValues: {'fast_mode': true},
  );

  test('round trips the Paseo provider feature request', () {
    const request = ListProviderFeaturesRequest(
      draftConfig: draft,
      requestId: 'request-1',
    );

    final decoded = ListProviderFeaturesRequest.fromJson(request.toJson());

    expect(decoded.requestId, 'request-1');
    expect(decoded.draftConfig.toJson(), draft.toJson());
  });

  test('round trips toggle and select feature response payloads', () {
    const response = ListProviderFeaturesResponse(
      provider: 'custom',
      fetchedAt: '2026-07-28T00:00:00.000Z',
      requestId: 'request-2',
      features: [
        AgentFeatureToggle(
          id: 'fast',
          label: 'Fast',
          value: true,
          tooltip: 'Toggle fast mode',
        ),
        AgentFeatureSelect(
          id: 'profile',
          label: 'Profile',
          value: 'safe',
          options: [
            ProviderSelectOption(id: 'safe', label: 'Safe', isDefault: true),
            ProviderSelectOption(id: 'full', label: 'Full'),
          ],
        ),
      ],
    );

    final decoded = ListProviderFeaturesResponse.fromJson(response.toJson());

    expect(decoded.features, hasLength(2));
    expect(decoded.features!.first, isA<AgentFeatureToggle>());
    expect(
      (decoded.features!.last as AgentFeatureSelect).options,
      hasLength(2),
    );
    expect(decoded.error, isNull);
  });

  test('rejects malformed feature discriminators and values', () {
    expect(
      () => AgentFeature.fromJson({
        'type': 'unknown',
        'id': 'x',
        'label': 'X',
        'value': true,
      }),
      throwsFormatException,
    );
    expect(
      () => AgentFeature.fromJson({
        'type': 'toggle',
        'id': 'x',
        'label': 'X',
        'value': 'true',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentFeature.fromJson({
        'type': 'select',
        'id': 'x',
        'label': 'X',
        'value': null,
        'options': [false],
      }),
      throwsFormatException,
    );
  });

  test('allows an error response without a features array', () {
    const response = ListProviderFeaturesResponse(
      provider: 'missing',
      fetchedAt: 'now',
      requestId: 'request-3',
      error: 'not installed',
    );

    final decoded = ListProviderFeaturesResponse.fromJson(response.toJson());

    expect(decoded.features, isNull);
    expect(decoded.error, 'not installed');
  });
}
