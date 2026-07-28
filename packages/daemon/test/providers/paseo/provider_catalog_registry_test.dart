import 'package:agent_daemon/src/providers/paseo/provider_catalog_registry.dart';
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
        mode: ProviderMode(id: 'default', label: 'Default'),
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

  PaseoProviderCatalogRegistry registry() => PaseoProviderCatalogRegistry(
    definitions: const [ready, missing, disabled, broken],
    commandResolver: (definition) async => switch (definition.id) {
      'ready' => '/bin/ready',
      'missing' => null,
      'broken' => throw StateError('probe failed'),
      _ => throw StateError('disabled provider must not be probed'),
    },
    now: () => DateTime.utc(2026, 7, 26),
  );

  test(
    'definition lookup and availability cover ready, missing, disabled, error',
    () async {
      final catalog = registry();

      expect(catalog.definition('ready')?.label, 'Ready');
      expect(catalog.definition('unknown'), isNull);
      final availability = await catalog.listAvailability();
      expect(availability.map((entry) => entry.provider), [
        'ready',
        'missing',
        'disabled',
        'broken',
      ]);
      expect(availability[0].available, isTrue);
      expect(availability[1].available, isFalse);
      expect(availability[2].available, isFalse);
      expect(availability[3].error, contains('probe failed'));
    },
  );

  test(
    'snapshot exposes exact status, metadata, modes, and filtering',
    () async {
      final catalog = registry();
      final entries = await catalog.snapshot();
      final byId = {for (final entry in entries) entry.provider: entry};

      expect(byId['ready']?.status, ProviderCatalogStatus.ready);
      expect(byId['ready']?.source, 'builtin');
      expect(byId['ready']?.modes?.single.id, 'default');
      expect(byId['ready']?.models, isEmpty);
      expect(byId['ready']?.fetchedAt, '2026-07-26T00:00:00.000Z');
      expect(byId['missing']?.status, ProviderCatalogStatus.unavailable);
      expect(byId['missing']?.modes, isNull);
      expect(byId['disabled']?.enabled, isFalse);
      expect(byId['broken']?.status, ProviderCatalogStatus.error);
      expect(byId['broken']?.error, contains('probe failed'));

      expect(
        (await catalog.snapshot(providers: ['ready'])).single.provider,
        'ready',
      );
      expect(await catalog.snapshot(providers: ['unknown']), isEmpty);
    },
  );
}
