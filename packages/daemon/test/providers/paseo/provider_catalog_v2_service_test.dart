import 'package:agent_daemon/src/providers/paseo/provider_catalog_registry.dart';
import 'package:agent_daemon/src/providers/paseo/provider_catalog_v2_service.dart';
import 'package:agent_daemon/src/providers/paseo/provider_manifest.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const ready = PaseoProviderDefinition(
    id: 'ready',
    label: 'Ready',
    description: 'Ready provider',
    command: 'ready',
    defaultModeId: 'default',
    modes: [
      PaseoProviderModeDefinition(
        mode: ProviderMode(
          id: 'default',
          label: 'Default',
          icon: 'Shield',
          colorTier: 'safe',
        ),
      ),
    ],
  );
  const missing = PaseoProviderDefinition(
    id: 'missing',
    label: 'Missing',
    description: 'Missing provider',
    command: 'missing',
    defaultModeId: null,
    modes: [],
  );
  const disabled = PaseoProviderDefinition(
    id: 'disabled',
    label: 'Disabled',
    description: 'Disabled provider',
    command: 'disabled',
    enabledByDefault: false,
    defaultModeId: null,
    modes: [],
  );
  const broken = PaseoProviderDefinition(
    id: 'broken',
    label: 'Broken',
    description: 'Broken provider',
    command: 'broken',
    defaultModeId: null,
    modes: [],
  );

  late ProviderCatalogV2Service service;
  late List<String> probes;
  late List<ProvidersSnapshotUpdate> updates;

  setUp(() {
    probes = [];
    updates = [];
    service = ProviderCatalogV2Service(
      registry: PaseoProviderCatalogRegistry(
        definitions: const [ready, missing, disabled, broken],
        commandResolver: (definition) async {
          probes.add(definition.id);
          return switch (definition.id) {
            'ready' => '/bin/ready',
            'missing' => null,
            'broken' => throw StateError('catalog failed'),
            _ => throw StateError('disabled must not be probed'),
          };
        },
        now: () => DateTime.utc(2026, 7, 26),
      ),
      now: () => DateTime.utc(2026, 7, 26),
      onSnapshotChanged: updates.add,
    );
  });

  test('lists provider availability in manifest order', () async {
    final response = ListAvailableProvidersResponse.fromJson(
      (await service.handle(
        const ListAvailableProvidersRequest(requestId: 'available').toJson(),
      ))!,
    );

    expect(response.providers.map((entry) => entry.provider), [
      'ready',
      'missing',
      'disabled',
      'broken',
    ]);
    expect(response.providers.first.available, isTrue);
    expect(response.providers.last.error, contains('catalog failed'));
    expect(response.fetchedAt, '2026-07-26T00:00:00.000Z');
  });

  test('lists ready models and modes with Paseo response envelopes', () async {
    final models = ListProviderModelsResponse.fromJson(
      (await service.handle(
        const ListProviderModelsRequest(
          provider: 'ready',
          requestId: 'models',
        ).toJson(),
      ))!,
    );
    final modes = ListProviderModesResponse.fromJson(
      (await service.handle(
        const ListProviderModesRequest(
          provider: 'ready',
          requestId: 'modes',
        ).toJson(),
      ))!,
    );

    expect(models.models, isEmpty);
    expect(models.error, isNull);
    expect(modes.modes?.single.id, 'default');
    expect(modes.error, isNull);
  });

  test(
    'lists draft provider features and preserves request correlation',
    () async {
      service = ProviderCatalogV2Service(
        registry: PaseoProviderCatalogRegistry(
          definitions: PaseoProviderManifest.definitions,
          commandResolver: (_) async => '/bin/provider',
        ),
        now: () => DateTime.utc(2026, 7, 26),
      );

      final response = ListProviderFeaturesResponse.fromJson(
        (await service.handle(
          const ListProviderFeaturesRequest(
            draftConfig: ListCommandsDraftConfig(
              provider: 'claude',
              cwd: '/repo',
              model: 'claude-opus-4-6',
              featureValues: {'fast_mode': true},
            ),
            requestId: 'features',
          ).toJson(),
        ))!,
      );

      expect(response.provider, 'claude');
      expect(response.requestId, 'features');
      expect(response.fetchedAt, '2026-07-26T00:00:00.000Z');
      expect(response.error, isNull);
      expect(response.features, hasLength(1));
      expect((response.features!.single as AgentFeatureToggle).value, isTrue);
    },
  );

  test('delegates feature discovery to the provider runtime', () async {
    ListCommandsDraftConfig? received;
    service = ProviderCatalogV2Service(
      registry: PaseoProviderCatalogRegistry(
        definitions: PaseoProviderManifest.definitions,
        commandResolver: (_) async => '/bin/provider',
      ),
      featureResolver: (config) async {
        received = config;
        return const [
          AgentFeatureSelect(
            id: 'agent',
            label: 'Agent',
            value: 'reviewer',
            options: [ProviderSelectOption(id: 'reviewer', label: 'Reviewer')],
          ),
        ];
      },
      now: () => DateTime.utc(2026, 7, 28),
    );

    final response = ListProviderFeaturesResponse.fromJson(
      (await service.handle(
        const ListProviderFeaturesRequest(
          draftConfig: ListCommandsDraftConfig(
            provider: 'claude',
            cwd: r'C:\repo',
            model: 'claude-opus-4-6',
          ),
          requestId: 'features-dynamic',
        ).toJson(),
      ))!,
    );

    expect(received?.cwd, r'C:\repo');
    expect(response.features, hasLength(1));
    expect(response.features!.single, isA<AgentFeatureSelect>());
  });

  test('returns correlated provider feature errors', () async {
    final unknown = ListProviderFeaturesResponse.fromJson(
      (await service.handle(
        const ListProviderFeaturesRequest(
          draftConfig: ListCommandsDraftConfig(
            provider: 'unknown',
            cwd: '/repo',
          ),
          requestId: 'unknown-features',
        ).toJson(),
      ))!,
    );
    final disabledResponse = ListProviderFeaturesResponse.fromJson(
      (await service.handle(
        const ListProviderFeaturesRequest(
          draftConfig: ListCommandsDraftConfig(
            provider: 'disabled',
            cwd: '/repo',
          ),
          requestId: 'disabled-features',
        ).toJson(),
      ))!,
    );

    expect(unknown.error, contains('Unknown provider: unknown'));
    expect(unknown.features, isNull);
    expect(disabledResponse.error, contains('Provider disabled is disabled'));
  });

  test('draft features do not probe or guess a missing model', () async {
    final response = ListProviderFeaturesResponse.fromJson(
      (await service.handle(
        const ListProviderFeaturesRequest(
          draftConfig: ListCommandsDraftConfig(provider: 'ready', cwd: '/repo'),
          requestId: 'features-without-model',
        ).toJson(),
      ))!,
    );

    expect(response.features, isEmpty);
    expect(response.error, isNull);
    expect(probes, isEmpty);
  });

  test('draft feature discovery rejects an unavailable provider', () async {
    final response = ListProviderFeaturesResponse.fromJson(
      (await service.handle(
        const ListProviderFeaturesRequest(
          draftConfig: ListCommandsDraftConfig(
            provider: 'missing',
            cwd: '/repo',
            model: 'model',
          ),
          requestId: 'missing-features',
        ).toJson(),
      ))!,
    );

    expect(response.features, isNull);
    expect(response.error, contains("Provider 'missing' is not available"));
  });

  test(
    'model errors distinguish unknown, disabled, unavailable, and failed',
    () async {
      Future<ListProviderModelsResponse> request(String provider) async =>
          ListProviderModelsResponse.fromJson(
            (await service.handle(
              ListProviderModelsRequest(
                provider: provider,
                requestId: provider,
              ).toJson(),
            ))!,
          );

      expect((await request('unknown')).error, 'Unknown provider: unknown');
      expect(
        (await request('disabled')).error,
        'Provider disabled is disabled',
      );
      expect(
        (await request('missing')).error,
        'Provider missing is not available',
      );
      expect((await request('broken')).error, contains('catalog failed'));
      expect(probes, isNot(contains('disabled')));
    },
  );

  test(
    'mode errors distinguish unknown, disabled, unavailable, and failed',
    () async {
      Future<ListProviderModesResponse> request(String provider) async =>
          ListProviderModesResponse.fromJson(
            (await service.handle(
              ListProviderModesRequest(
                provider: provider,
                requestId: provider,
              ).toJson(),
            ))!,
          );

      expect((await request('unknown')).error, 'Unknown provider: unknown');
      expect(
        (await request('disabled')).error,
        'Provider disabled is disabled',
      );
      expect(
        (await request('missing')).error,
        'Provider missing is not available',
      );
      expect((await request('broken')).error, contains('catalog failed'));
    },
  );

  test(
    'gets and refreshes snapshots and falls through unknown messages',
    () async {
      final snapshot = GetProvidersSnapshotResponse.fromJson(
        (await service.handle(
          const GetProvidersSnapshotRequest(requestId: 'snapshot').toJson(),
        ))!,
      );
      final refresh = RefreshProvidersSnapshotResponse.fromJson(
        (await service.handle(
          const RefreshProvidersSnapshotRequest(
            requestId: 'refresh',
            cwd: '/repo',
            providers: ['ready'],
          ).toJson(),
        ))!,
      );

      expect(snapshot.entries, hasLength(4));
      expect(snapshot.generatedAt, '2026-07-26T00:00:00.000Z');
      expect(refresh.acknowledged, isTrue);
      expect(updates, hasLength(1));
      expect(updates.single.cwd, '/repo');
      expect(updates.single.entries, hasLength(4));
      expect(await service.handle({'type': 'not_a_provider_message'}), isNull);
    },
  );
}
