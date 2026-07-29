import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> wire(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

void main() {
  const option = ProviderSelectOption(
    id: 'high',
    label: 'High',
    description: 'High reasoning',
    isDefault: true,
    metadata: {'effort': 3},
  );
  const model = ProviderModelDefinition(
    provider: 'codex',
    id: 'gpt-5.4',
    label: 'GPT-5.4',
    description: 'Frontier coding model',
    isDefault: true,
    metadata: {'family': 'gpt'},
    contextWindowMaxTokens: 200000,
    thinkingOptions: [option],
    defaultThinkingOptionId: 'high',
  );
  const mode = ProviderMode(
    id: 'auto-review',
    label: 'Auto-review',
    description: 'Review approvals automatically',
    icon: 'ShieldCheck',
    colorTier: 'moderate',
  );
  const snapshot = ProviderSnapshotEntry(
    provider: 'codex',
    status: ProviderCatalogStatus.ready,
    source: 'builtin',
    models: [model],
    modes: [mode],
    fetchedAt: '2026-07-26T00:00:00.000Z',
    label: 'Codex',
    description: 'Codex provider',
    defaultModeId: 'auto-review',
  );

  test('catalog value models round-trip all optional fields', () {
    final decodedOption = ProviderSelectOption.fromJson(wire(option.toJson()));
    final decodedModel = ProviderModelDefinition.fromJson(wire(model.toJson()));
    final decodedMode = ProviderMode.fromJson(wire(mode.toJson()));
    final decodedSnapshot = ProviderSnapshotEntry.fromJson(
      wire(snapshot.toJson()),
    );

    expect(decodedOption.metadata, {'effort': 3});
    expect(decodedModel.thinkingOptions?.single.id, 'high');
    expect(decodedModel.contextWindowMaxTokens, 200000);
    expect(decodedMode.icon, 'ShieldCheck');
    expect(decodedSnapshot.status, ProviderCatalogStatus.ready);
    expect(decodedSnapshot.models?.single.id, 'gpt-5.4');
    expect(decodedSnapshot.modes?.single.id, 'auto-review');
    expect(decodedSnapshot.enabled, isTrue);
  });

  test(
    'catalog value models accept omitted optional fields and null defaults',
    () {
      final option = ProviderSelectOption.fromJson({
        'id': 'low',
        'label': 'Low',
      });
      final model = ProviderModelDefinition.fromJson({
        'provider': 'pi',
        'id': 'm',
        'label': 'M',
      });
      final mode = ProviderMode.fromJson({'id': 'ask', 'label': 'Ask'});
      final snapshot = ProviderSnapshotEntry.fromJson({
        'provider': 'pi',
        'status': 'unavailable',
      });

      expect(option.toJson(), {'id': 'low', 'label': 'Low'});
      expect(model.toJson(), {'provider': 'pi', 'id': 'm', 'label': 'M'});
      expect(mode.toJson(), {'id': 'ask', 'label': 'Ask'});
      expect(snapshot.enabled, isTrue);
      expect(snapshot.defaultModeId, isNull);
      expect(snapshot.toJson()['defaultModeId'], isNull);
    },
  );

  test('availability request and response match Paseo wire shape', () {
    const request = ListAvailableProvidersRequest(requestId: 'available');
    const response = ListAvailableProvidersResponse(
      requestId: 'available',
      providers: [
        ProviderAvailabilityV2(provider: 'codex', available: true),
        ProviderAvailabilityV2(
          provider: 'claude',
          available: false,
          error: 'missing',
        ),
      ],
      fetchedAt: 'now',
    );

    expect(
      ListAvailableProvidersRequest.fromJson(request.toJson()).requestId,
      'available',
    );
    final decoded = ListAvailableProvidersResponse.fromJson(
      wire(response.toJson()),
    );
    expect(decoded.providers.first.available, isTrue);
    expect(decoded.providers.last.error, 'missing');
    expect(decoded.error, isNull);
  });

  test('model request and response preserve cwd, models, and errors', () {
    const request = ListProviderModelsRequest(
      provider: 'codex',
      requestId: 'models',
      cwd: '~/repo',
    );
    const response = ListProviderModelsResponse(
      provider: 'codex',
      requestId: 'models',
      fetchedAt: 'now',
      models: [model],
    );
    const failed = ListProviderModelsResponse(
      provider: 'missing',
      requestId: 'failed',
      fetchedAt: 'now',
      error: 'Unknown provider: missing',
    );

    final decodedRequest = ListProviderModelsRequest.fromJson(request.toJson());
    expect(decodedRequest.cwd, '~/repo');
    expect(
      ListProviderModelsResponse.fromJson(
        wire(response.toJson()),
      ).models?.single.id,
      'gpt-5.4',
    );
    expect(
      ListProviderModelsResponse.fromJson(wire(failed.toJson())).error,
      contains('Unknown provider'),
    );
  });

  test('mode request and response preserve cwd, modes, and errors', () {
    const request = ListProviderModesRequest(
      provider: 'codex',
      requestId: 'modes',
      cwd: 'C:/repo',
    );
    const response = ListProviderModesResponse(
      provider: 'codex',
      requestId: 'modes',
      fetchedAt: 'now',
      modes: [mode],
    );
    const failed = ListProviderModesResponse(
      provider: 'omp',
      requestId: 'failed',
      fetchedAt: 'now',
      error: 'Provider omp is disabled',
    );

    expect(ListProviderModesRequest.fromJson(request.toJson()).cwd, 'C:/repo');
    expect(
      ListProviderModesResponse.fromJson(
        wire(response.toJson()),
      ).modes?.single.id,
      'auto-review',
    );
    expect(
      ListProviderModesResponse.fromJson(wire(failed.toJson())).error,
      contains('disabled'),
    );
  });

  test('snapshot get and refresh messages round-trip', () {
    const getRequest = GetProvidersSnapshotRequest(
      requestId: 'get',
      cwd: '~/repo',
    );
    const getResponse = GetProvidersSnapshotResponse(
      entries: [snapshot],
      generatedAt: 'now',
      requestId: 'get',
    );
    const refreshRequest = RefreshProvidersSnapshotRequest(
      requestId: 'refresh',
      cwd: '~/repo',
      providers: ['codex', 'claude'],
    );
    const refreshResponse = RefreshProvidersSnapshotResponse(
      requestId: 'refresh',
      acknowledged: true,
    );

    expect(
      GetProvidersSnapshotRequest.fromJson(getRequest.toJson()).cwd,
      '~/repo',
    );
    expect(
      GetProvidersSnapshotResponse.fromJson(
        wire(getResponse.toJson()),
      ).entries.single.provider,
      'codex',
    );
    expect(
      RefreshProvidersSnapshotRequest.fromJson(
        refreshRequest.toJson(),
      ).providers,
      ['codex', 'claude'],
    );
    expect(
      RefreshProvidersSnapshotResponse.fromJson(
        refreshResponse.toJson(),
      ).acknowledged,
      isTrue,
    );
    const update = ProvidersSnapshotUpdate(
      cwd: r'C:\repo',
      entries: [snapshot],
      generatedAt: '2026-07-28T00:00:00Z',
    );
    expect(
      ProvidersSnapshotUpdate.fromJson(update.toJson()).toJson(),
      update.toJson(),
    );
    expect(
      const ProvidersSnapshotUpdate(
        entries: [],
        generatedAt: '2026-07-28T00:00:00Z',
      ).toJson()['payload'],
      isNot(contains('cwd')),
    );

    const diagnosticRequest = ProviderDiagnosticRequest(
      provider: 'codex',
      requestId: 'diagnostic',
    );
    const diagnosticResponse = ProviderDiagnosticResponse(
      provider: 'codex',
      diagnostic: 'Codex\n  Models: 1\n  Status: Ready',
      requestId: 'diagnostic',
    );
    expect(
      ProviderDiagnosticRequest.fromJson(diagnosticRequest.toJson()).toJson(),
      diagnosticRequest.toJson(),
    );
    expect(
      ProviderDiagnosticResponse.fromJson(
        wire(diagnosticResponse.toJson()),
      ).toJson(),
      diagnosticResponse.toJson(),
    );
  });

  test('requests omit optional cwd and provider filters', () {
    expect(
      const ListProviderModelsRequest(provider: 'pi', requestId: '1').toJson(),
      isNot(contains('cwd')),
    );
    expect(
      const ListProviderModesRequest(provider: 'pi', requestId: '2').toJson(),
      isNot(contains('cwd')),
    );
    expect(
      const GetProvidersSnapshotRequest(requestId: '3').toJson(),
      isNot(contains('cwd')),
    );
    expect(
      const RefreshProvidersSnapshotRequest(requestId: '4').toJson(),
      isNot(contains('providers')),
    );
  });

  test(
    'validation rejects unknown types, status, source, and malformed fields',
    () {
      expect(
        () => ListAvailableProvidersRequest.fromJson({
          'type': 'wrong',
          'requestId': 'x',
        }),
        throwsFormatException,
      );
      expect(() => ProviderCatalogStatus.fromWire(1), throwsFormatException);
      expect(
        () => ProviderCatalogStatus.fromWire('unknown'),
        throwsFormatException,
      );
      expect(
        () => ProviderSnapshotEntry.fromJson({
          'provider': 'x',
          'status': 'ready',
          'source': 'invalid',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderMode.fromJson({'id': 1, 'label': 'x'}),
        throwsFormatException,
      );
      expect(
        () => ProviderMode.fromJson({'id': 'x', 'label': 'x', 'icon': 1}),
        throwsFormatException,
      );
      expect(
        () => ProviderAvailabilityV2.fromJson({
          'provider': 'x',
          'available': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderDiagnosticRequest.fromJson({
          'type': 'wrong',
          'provider': 'codex',
          'requestId': 'diagnostic',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderDiagnosticResponse.fromJson({
          'type': ProviderDiagnosticResponse.type,
          'payload': {
            'provider': 'codex',
            'diagnostic': 1,
            'requestId': 'diagnostic',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderSelectOption.fromJson({
          'id': 'x',
          'label': 'x',
          'isDefault': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderModelDefinition.fromJson({
          'provider': 'x',
          'id': 'x',
          'label': 'x',
          'contextWindowMaxTokens': 'many',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderSelectOption.fromJson({
          'id': 'x',
          'label': 'x',
          'metadata': [],
        }),
        throwsFormatException,
      );
    },
  );

  test('validation rejects malformed maps and arrays', () {
    expect(
      () => ListAvailableProvidersResponse.fromJson({
        'type': 'list_available_providers_response',
        'payload': [],
      }),
      throwsFormatException,
    );
    expect(
      () => ListAvailableProvidersResponse.fromJson({
        'type': 'list_available_providers_response',
        'payload': {
          'requestId': 'x',
          'providers': ['bad'],
          'fetchedAt': 'now',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => RefreshProvidersSnapshotRequest.fromJson({
        'type': 'refresh_providers_snapshot_request',
        'requestId': 'x',
        'providers': [1],
      }),
      throwsFormatException,
    );
    expect(
      () => ProviderSnapshotEntry.fromJson({
        'provider': 'x',
        'status': 'ready',
        'models': 'bad',
      }),
      throwsFormatException,
    );
  });
}
