import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/create_agent_mode.dart';
import 'package:agent_daemon/src/providers/paseo/acp_catalog.dart';
import 'package:agent_daemon/src/providers/paseo/provider_catalog_registry.dart';
import 'package:agent_daemon/src/providers/paseo/provider_manifest.dart';
import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const ready = PaseoProviderDefinition(
    id: 'ready',
    label: 'Ready',
    description: 'Ready provider',
    command: 'ready',
    defaultModeId: 'default',
    voice: PaseoProviderVoiceDefinition(
      enabled: true,
      defaultModeId: 'default',
      defaultModel: 'small',
    ),
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

  test(
    'diagnostics force a catalog probe and append models and status',
    () async {
      final catalog = registry();

      final readyDiagnostic = await catalog.diagnostic('ready');
      expect(readyDiagnostic, contains('Ready'));
      expect(readyDiagnostic, contains('Diagnostic: No diagnostic available'));
      expect(readyDiagnostic, contains('Models: 0'));
      expect(readyDiagnostic, contains('Status: Ready'));

      final missingDiagnostic = await catalog.diagnostic('missing');
      expect(missingDiagnostic, contains('Models: —'));
      expect(missingDiagnostic, contains('Status: Unavailable'));

      final brokenDiagnostic = await catalog.diagnostic('broken');
      expect(brokenDiagnostic, contains('Models: —'));
      expect(brokenDiagnostic, contains('Status: Error:'));
      expect(brokenDiagnostic, contains('probe failed'));
    },
  );

  test(
    'unknown provider diagnostics return an inline configured error',
    () async {
      expect(
        await registry().diagnostic('unknown'),
        'unknown\n  Error: Provider unknown is not configured',
      );
    },
  );

  test(
    'resolves create modes from the ready catalog and unattended metadata',
    () async {
      const worker = PaseoProviderDefinition(
        id: 'worker',
        label: 'Worker',
        description: 'Worker provider',
        command: 'worker',
        defaultModeId: 'build',
        modes: [
          PaseoProviderModeDefinition(
            mode: ProviderMode(id: 'build', label: 'Build'),
          ),
          PaseoProviderModeDefinition(
            mode: ProviderMode(id: 'allow-all', label: 'Allow all'),
            isUnattended: true,
          ),
        ],
      );
      const plain = PaseoProviderDefinition(
        id: 'plain',
        label: 'Plain',
        description: 'Provider without modes',
        command: 'plain',
        defaultModeId: null,
        modes: [],
      );
      final catalog = PaseoProviderCatalogRegistry(
        definitions: const [worker, plain],
        commandResolver: (definition) async => '/bin/${definition.command}',
      );

      expect(
        await catalog.resolveCreateAgentMode(
          const AgentCreateModeRequest(
            cwd: '.',
            targetProvider: 'worker',
            requestedMode: 'build',
            parent: null,
            unattended: false,
          ),
        ),
        'build',
      );
      expect(
        await catalog.resolveCreateAgentMode(
          const AgentCreateModeRequest(
            cwd: '.',
            targetProvider: 'worker',
            requestedMode: null,
            parent: AgentCreateModeParent(
              provider: 'parent',
              modeId: 'unattended',
              isUnattended: true,
            ),
            unattended: false,
          ),
        ),
        'allow-all',
      );
      expect(
        await catalog.resolveCreateAgentMode(
          const AgentCreateModeRequest(
            cwd: '.',
            targetProvider: 'plain',
            requestedMode: null,
            parent: AgentCreateModeParent(
              provider: 'parent',
              modeId: 'unattended',
              isUnattended: true,
            ),
            unattended: false,
          ),
        ),
        isNull,
      );
      expect(
        catalog.isCreateAgentModeUnattended(
          provider: 'worker',
          modeId: 'allow-all',
        ),
        isTrue,
      );
      expect(
        () => catalog.resolveCreateAgentMode(
          const AgentCreateModeRequest(
            cwd: '.',
            targetProvider: 'worker',
            requestedMode: 'missing',
            parent: null,
            unattended: false,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            "Invalid mode 'missing' for provider 'worker'. "
                'Available modes: build, allow-all',
          ),
        ),
      );
    },
  );

  test(
    'requires a configured, enabled, ready provider before agent creation',
    () async {
      final catalog = registry();

      Future<void> expectCreateError(String provider, Matcher message) async {
        await expectLater(
          catalog.resolveCreateAgentConfig(
            AgentCreateConfigRequest(
              cwd: '.',
              targetProvider: provider,
              requestedMode: null,
              featureValues: const {},
              parent: null,
              unattended: false,
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      }

      await expectCreateError(
        'disabled',
        equals("Provider 'disabled' is disabled"),
      );
      await expectCreateError(
        'missing',
        equals("Provider 'missing' is not available"),
      );
      await expectCreateError('broken', contains('probe failed'));
    },
  );

  test(
    'normalizes OpenCode create mode and feature policy before agent launch',
    () async {
      final openCode = PaseoProviderManifest.find('opencode')!;
      final catalog = PaseoProviderCatalogRegistry(
        definitions: [openCode],
        commandResolver: (_) async => '/bin/opencode',
      );

      final legacy = await catalog.resolveCreateAgentConfig(
        const AgentCreateConfigRequest(
          cwd: '.',
          targetProvider: 'opencode',
          requestedMode: 'full-access',
          featureValues: {'auto_accept': false, 'custom': 'kept'},
          parent: null,
          unattended: false,
        ),
      );
      expect(legacy.modeId, 'build');
      expect(legacy.featureValues, {'auto_accept': true, 'custom': 'kept'});

      final inherited = await catalog.resolveCreateAgentConfig(
        const AgentCreateConfigRequest(
          cwd: '.',
          targetProvider: 'opencode',
          requestedMode: null,
          featureValues: {},
          parent: AgentCreateModeParent(
            provider: 'claude',
            modeId: 'bypassPermissions',
            isUnattended: true,
          ),
          unattended: false,
        ),
      );
      expect(inherited.modeId, isNull);
      expect(inherited.featureValues, {'auto_accept': true});

      final explicit = await catalog.resolveCreateAgentConfig(
        const AgentCreateConfigRequest(
          cwd: '.',
          targetProvider: 'opencode',
          requestedMode: 'plan',
          featureValues: {'auto_accept': false},
          parent: null,
          unattended: true,
        ),
      );
      expect(explicit.modeId, 'plan');
      expect(explicit.featureValues, {'auto_accept': false});
    },
  );

  test('treats OpenCode auto_accept as unattended parent state', () {
    final catalog = PaseoProviderCatalogRegistry(
      definitions: [PaseoProviderManifest.find('opencode')!],
    );
    const parent = AgentSummary(
      agentId: 'parent',
      title: 'Parent',
      cwd: '.',
      provider: 'opencode',
      model: 'model',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 0,
      currentModeId: 'plan',
      featureValues: {'auto_accept': true},
    );

    expect(catalog.createAgentModeParent(parent).isUnattended, isTrue);
    expect(
      catalog.isCreateAgentConfigUnattended(
        provider: 'opencode',
        modeId: 'plan',
        featureValues: const {'auto_accept': false},
      ),
      isFalse,
    );
  });

  test(
    'rebuilds custom ACP providers and builtin overrides from config',
    () async {
      var config = MutableDaemonConfig(
        injectMcpIntoAgents: false,
        providers: {
          'ready': const MutableDaemonProviderConfig(
            enabled: false,
            extra: {'label': 'Ready override'},
          ),
          'amp-acp': const MutableDaemonProviderConfig(
            extra: {
              'extends': 'acp',
              'label': 'Amp',
              'description': 'ACP wrapper',
              'command': ['amp-acp', '--stdio'],
              'env': {'AMP_LOG': 'info'},
              'params': {'supportsMcpServers': false},
            },
          ),
        },
      );
      final probes = <String>[];
      final catalog = PaseoProviderCatalogRegistry(
        definitions: const [ready],
        configResolver: () => config,
        commandResolver: (definition) async {
          probes.add(definition.id);
          return '/bin/${definition.command}';
        },
        now: () => DateTime.utc(2026, 7, 28),
      );

      expect(catalog.definition('ready')?.label, 'Ready override');
      expect(catalog.definition('ready')?.enabledByDefault, isFalse);
      expect(catalog.definition('ready')?.voice?.defaultModeId, 'default');
      expect(catalog.definition('ready')?.voice?.defaultModel, 'small');
      final custom = catalog.definition('amp-acp');
      expect(custom?.source, 'custom');
      expect(custom?.command, 'amp-acp');
      expect(custom?.commandArgs, ['--stdio']);
      expect(custom?.environment, {'AMP_LOG': 'info'});
      expect(custom?.providerParams, {'supportsMcpServers': false});
      expect(custom?.capabilities, {
        ...paseoAcpCapabilities,
        'supportsMcpServers': false,
      });

      final first = await catalog.snapshot();
      expect(first.map((entry) => entry.provider), ['ready', 'amp-acp']);
      expect(first.first.enabled, isFalse);
      expect(first.last.source, 'custom');
      expect(first.last.status, ProviderCatalogStatus.ready);
      expect(probes, ['amp-acp']);

      config = const MutableDaemonConfig(
        injectMcpIntoAgents: false,
        providers: {},
      );
      expect(catalog.definition('amp-acp'), isNull);
      expect(catalog.definition('ready')?.label, 'Ready');
    },
  );

  test('rejects malformed custom provider definitions', () {
    PaseoProviderCatalogRegistry configured(
      MutableDaemonProviderConfig provider,
    ) => PaseoProviderCatalogRegistry(
      definitions: const [],
      configResolver: () => MutableDaemonConfig(
        injectMcpIntoAgents: false,
        providers: {'custom': provider},
      ),
    );

    expect(
      () => configured(
        const MutableDaemonProviderConfig(
          extra: {
            'command': ['custom'],
          },
        ),
      ).definitions,
      throwsA(isA<StateError>()),
    );
    expect(
      () => configured(
        const MutableDaemonProviderConfig(extra: {'extends': 'acp'}),
      ).definitions,
      throwsA(isA<StateError>()),
    );
  });

  test(
    'probes and caches workspace-scoped ACP catalogs until forced',
    () async {
      final probeCwds = <String>[];
      final catalog = PaseoProviderCatalogRegistry(
        definitions: const [ready],
        commandResolver: (_) async => '/bin/ready',
        catalogProbe: (definition, cwd) async {
          probeCwds.add(cwd);
          return AcpProviderCatalog(
            models: [
              ProviderModelDefinition(
                provider: definition.id,
                id: 'model',
                label: 'Model',
                isDefault: true,
              ),
            ],
            modes: const [ProviderMode(id: 'agent', label: 'Agent')],
            currentModelId: 'model',
            currentModeId: 'agent',
            currentThinkingOptionId: null,
            configOptions: const [],
            hasExplicitModels: true,
            hasExplicitModes: true,
          );
        },
      );

      final first = (await catalog.snapshot(cwd: '.')).single;
      final second = (await catalog.snapshot(cwd: '.')).single;
      final forced = (await catalog.snapshot(cwd: '.', force: true)).single;

      expect(first.models?.single.id, 'model');
      expect(first.modes?.single.id, 'agent');
      expect(second.models?.single.id, 'model');
      expect(forced.models?.single.id, 'model');
      expect(probeCwds, hasLength(2));
      expect(probeCwds.toSet().single, Directory.current.absolute.path);

      await catalog.snapshot(cwd: Directory.systemTemp.path);
      expect(probeCwds, hasLength(3));
    },
  );

  test('ready snapshots publish capability-aware modes and defaults', () async {
    final claude = PaseoProviderManifest.find('claude')!;
    final catalog = PaseoProviderCatalogRegistry(
      definitions: [claude],
      commandResolver: (_) async => '/bin/claude',
      modeCatalogResolver: (definition, cwd) async => (
        modes: [
          for (final mode in definition.modes)
            if (mode.mode.id != 'auto') mode.mode,
        ],
        defaultModeId: 'default',
      ),
    );

    final entry = (await catalog.snapshot(cwd: '.')).single;
    expect(entry.status, ProviderCatalogStatus.ready);
    expect(entry.defaultModeId, 'default');
    expect(entry.modes?.map((mode) => mode.id), [
      'plan',
      'default',
      'acceptEdits',
      'bypassPermissions',
    ]);
  });

  test('isolates ACP catalog probe failures in the provider entry', () async {
    final catalog = PaseoProviderCatalogRegistry(
      definitions: const [ready],
      commandResolver: (_) async => '/bin/ready',
      catalogProbe: (_, _) async => throw StateError('ACP probe failed'),
    );

    final entry = (await catalog.snapshot(cwd: '.')).single;
    expect(entry.status, ProviderCatalogStatus.error);
    expect(entry.error, contains('ACP probe failed'));
    expect(entry.models, isNull);
  });

  test(
    'reflects persisted ACP install and removal without daemon restart',
    () async {
      final home = await Directory.systemTemp.createTemp('provider-install-');
      addTearDown(() => home.delete(recursive: true));
      final store = DaemonConfigStore(home: home.path);
      final catalog = PaseoProviderCatalogRegistry(
        definitions: const [ready],
        configResolver: () => store.config,
        commandResolver: (definition) async =>
            definition.id == 'amp-acp' ? '/bin/amp-acp' : null,
        now: () => DateTime.utc(2026, 7, 28),
      );

      store.patch(
        const MutableDaemonConfigPatch(
          providers: {
            'amp-acp': MutableDaemonProviderConfig(
              extra: {
                'extends': 'acp',
                'label': 'Amp',
                'description': 'ACP wrapper',
                'command': ['amp-acp'],
                'env': <String, Object?>{},
              },
            ),
          },
        ),
      );
      final installed = await catalog.snapshot();
      expect(installed.map((entry) => entry.provider), ['ready', 'amp-acp']);
      expect(installed.last.source, 'custom');
      expect(installed.last.label, 'Amp');
      expect(installed.last.status, ProviderCatalogStatus.ready);

      store.patch(const MutableDaemonConfigPatch(removeProviders: ['amp-acp']));
      expect((await catalog.snapshot()).map((entry) => entry.provider), [
        'ready',
      ]);
    },
  );

  test(
    'returns loading entries immediately and publishes asynchronous readiness',
    () async {
      final gate = Completer<AcpProviderCatalog>();
      final updates = <List<ProviderSnapshotEntry>>[];
      final catalog = PaseoProviderCatalogRegistry(
        definitions: const [ready],
        commandResolver: (_) async => '/bin/ready',
        catalogProbe: (_, _) => gate.future,
        onSnapshotChanged: (_, entries) => updates.add(entries),
      );

      final initial = await catalog.snapshot(
        cwd: '/repo',
        wait: false,
        emitUpdates: true,
      );
      expect(initial.single.status, ProviderCatalogStatus.loading);
      expect(updates, isEmpty);

      gate.complete(
        AcpProviderCatalog(
          models: [
            const ProviderModelDefinition(
              provider: 'ready',
              id: 'model',
              label: 'Model',
            ),
          ],
          modes: const [],
          currentModelId: 'model',
          currentModeId: null,
          currentThinkingOptionId: null,
          configOptions: const [],
          hasExplicitModels: true,
          hasExplicitModes: true,
        ),
      );
      final loaded = await catalog.snapshot(cwd: '/repo');
      expect(loaded.single.status, ProviderCatalogStatus.ready);
      expect(loaded.single.models?.single.id, 'model');
      expect(updates, hasLength(1));
      expect(updates.single.single.status, ProviderCatalogStatus.ready);
    },
  );

  test('forced refresh suppresses a stale in-flight provider load', () async {
    final gates = <Completer<AcpProviderCatalog>>[];
    final updates = <List<ProviderSnapshotEntry>>[];
    final catalog = PaseoProviderCatalogRegistry(
      definitions: const [ready],
      commandResolver: (_) async => '/bin/ready',
      catalogProbe: (_, _) {
        final gate = Completer<AcpProviderCatalog>();
        gates.add(gate);
        return gate.future;
      },
      onSnapshotChanged: (_, entries) => updates.add(entries),
    );

    await catalog.snapshot(cwd: '/repo', wait: false, emitUpdates: true);
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(1));

    await catalog.snapshot(
      cwd: '/repo',
      force: true,
      wait: false,
      emitUpdates: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(2));

    gates[1].complete(
      AcpProviderCatalog(
        models: [
          const ProviderModelDefinition(
            provider: 'ready',
            id: 'new-model',
            label: 'New model',
          ),
        ],
        modes: const [],
        currentModelId: 'new-model',
        currentModeId: null,
        currentThinkingOptionId: null,
        configOptions: const [],
        hasExplicitModels: true,
        hasExplicitModes: true,
      ),
    );
    final refreshed = catalog.snapshot(cwd: '/repo');
    gates[0].complete(
      AcpProviderCatalog(
        models: [
          const ProviderModelDefinition(
            provider: 'ready',
            id: 'stale-model',
            label: 'Stale model',
          ),
        ],
        modes: const [],
        currentModelId: 'stale-model',
        currentModeId: null,
        currentThinkingOptionId: null,
        configOptions: const [],
        hasExplicitModels: true,
        hasExplicitModes: true,
      ),
    );

    final entries = await refreshed;
    expect(entries.single.models?.single.id, 'new-model');
    expect(updates, hasLength(1));
    expect(updates.single.single.models?.single.id, 'new-model');
  });
}
