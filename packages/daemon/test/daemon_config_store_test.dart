import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tinyrack-config-store-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('persists before notifying and preserves unrelated config', () {
    final file = File(p.join(home.path, 'config.json'));
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'theme': 'dark',
        'daemon': {
          'listen': '127.0.0.1:7000',
          'enableTerminalAgentHooks': false,
        },
      }),
    );
    final store = DaemonConfigStore(
      home: home.path,
      enableTerminalAgentHooks: false,
    );
    final observed = <bool>[];
    final snapshots = <MutableDaemonConfig>[];
    final unsubscribe = store.onEnableTerminalAgentHooksChanged((value) {
      final persisted = jsonDecode(file.readAsStringSync()) as Map;
      expect((persisted['daemon'] as Map)['enableTerminalAgentHooks'], value);
      observed.add(value);
    });
    final unsubscribeAll = store.onChange(snapshots.add);

    expect(store.setEnableTerminalAgentHooks(true), isTrue);
    expect(store.enableTerminalAgentHooks, isTrue);
    expect(observed, [true]);
    final persisted = jsonDecode(file.readAsStringSync()) as Map;
    expect(persisted['theme'], 'dark');
    expect((persisted['daemon'] as Map)['listen'], '127.0.0.1:7000');
    expect(snapshots.single.enableTerminalAgentHooks, isTrue);
    expect(snapshots.single.injectMcpIntoAgents, isFalse);

    unsubscribe();
    unsubscribeAll();
    expect(store.setEnableTerminalAgentHooks(false), isTrue);
    expect(observed, [true]);
  });

  test('no-op patch neither writes nor notifies', () {
    final store = DaemonConfigStore(
      home: home.path,
      enableTerminalAgentHooks: false,
    );
    var notifications = 0;
    store.onEnableTerminalAgentHooksChanged((_) => notifications++);

    expect(store.setEnableTerminalAgentHooks(false), isFalse);
    expect(File(p.join(home.path, 'config.json')).existsSync(), isFalse);
    expect(notifications, 0);
  });

  test('rejects malformed persistence without changing runtime state', () {
    File(p.join(home.path, 'config.json')).writeAsStringSync('{bad');
    final store = DaemonConfigStore(
      home: home.path,
      enableTerminalAgentHooks: false,
    );

    expect(
      () => store.setEnableTerminalAgentHooks(true),
      throwsFormatException,
    );
    expect(store.enableTerminalAgentHooks, isFalse);
  });

  test('loads and persists the complete mutable daemon config contract', () {
    final file = File(p.join(home.path, 'config.json'));
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'untouched': 'root',
        'daemon': {
          'listen': '127.0.0.1:7000',
          'mcp': {'injectIntoAgents': false, 'untouchedMcp': true},
          'browserTools': {'enabled': false},
          'terminalProfiles': [
            {
              'id': 'codex',
              'name': 'Codex',
              'command': 'codex',
              'args': ['--search'],
            },
          ],
        },
        'agents': {
          'providers': {
            'codex': {
              'enabled': true,
              'label': 'Codex custom',
              'providerRuntime': 'stripped',
            },
            'claude': {'enabled': true},
          },
          'metadataGeneration': {
            'providers': [
              {'provider': 'claude'},
            ],
          },
        },
      }),
    );
    final store = DaemonConfigStore.load(home: home.path);

    expect(store.config.providers.keys, containsAll(['codex', 'claude']));
    expect(store.config.terminalProfiles!.single.args, ['--search']);
    expect(store.config.metadataGenerationProviders.single.provider, 'claude');

    final changed = store.patch(
      MutableDaemonConfigPatch.fromJson({
        'mcp': {'injectIntoAgents': true},
        'browserTools': {'enabled': true},
        'providers': {
          'codex': {
            'additionalModels': [
              {'id': 'gpt-5', 'label': 'GPT-5'},
            ],
          },
        },
        'removeProviders': ['claude'],
        'metadataGeneration': {
          'providers': [
            {'provider': 'codex', 'model': 'gpt-5'},
          ],
        },
        'autoArchiveAfterMerge': true,
        'appendSystemPrompt': 'Tinyrack',
      }),
    );

    expect(changed, isTrue);
    expect(store.config.injectMcpIntoAgents, isTrue);
    expect(store.config.browserToolsEnabled, isTrue);
    expect(store.config.providers.keys, ['codex']);
    expect(
      store.config.providers['codex']!.additionalModels!.single.id,
      'gpt-5',
    );
    expect(store.config.metadataGenerationProviders.single.provider, 'codex');
    expect(store.config.autoArchiveAfterMerge, isTrue);
    expect(store.config.appendSystemPrompt, 'Tinyrack');

    final persisted = jsonDecode(file.readAsStringSync()) as Map;
    expect(persisted['untouched'], 'root');
    final daemon = persisted['daemon'] as Map;
    expect(daemon['listen'], '127.0.0.1:7000');
    expect((daemon['mcp'] as Map)['untouchedMcp'], isTrue);
    final agents = persisted['agents'] as Map;
    final providers = agents['providers'] as Map;
    expect(providers.containsKey('claude'), isFalse);
    expect((providers['codex'] as Map)['label'], 'Codex custom');
    expect((providers['codex'] as Map).containsKey('providerRuntime'), isFalse);
  });

  test('removing the final provider omits the empty providers object', () {
    final file = File(p.join(home.path, 'config.json'));
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'agents': {
          'providers': {
            'gemini': {
              'extends': 'acp',
              'label': 'Gemini',
              'command': ['gemini', '--acp'],
            },
          },
        },
      }),
    );
    final store = DaemonConfigStore.load(home: home.path);

    expect(
      store.patch(const MutableDaemonConfigPatch(removeProviders: ['gemini'])),
      isTrue,
    );

    final persisted = jsonDecode(file.readAsStringSync()) as Map;
    expect((persisted['agents'] as Map?)?['providers'], isNull);
  });

  test('migrates frozen legacy provider runtime settings on load', () {
    File(p.join(home.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'agents': {
          'providers': {
            'claude': {
              'command': {
                'mode': 'replace',
                'argv': ['docker', 'run', 'claude'],
              },
              'env': {'CLAUDE_CONFIG_DIR': '/custom'},
            },
            'codex': {
              'command': {'mode': 'default'},
              'env': {'CODEX_HOME': '/codex'},
            },
            'opencode': {
              'command': {
                'mode': 'append',
                'args': ['--debug'],
              },
            },
          },
        },
      }),
    );

    final providers = DaemonConfigStore.load(home: home.path).config.providers;

    expect(providers['claude']?.extra, {
      'command': ['docker', 'run', 'claude'],
      'env': {'CLAUDE_CONFIG_DIR': '/custom'},
    });
    expect(providers['codex']?.extra, {
      'env': {'CODEX_HOME': '/codex'},
    });
    expect(providers, isNot(contains('opencode')));
  });

  test(
    'provider persistence strips passthrough fields and validates overrides',
    () {
      final store = DaemonConfigStore(home: home.path);
      expect(
        store.patch(
          MutableDaemonConfigPatch.fromJson({
            'providers': {
              'custom-acp': {
                'extends': 'acp',
                'label': 'Custom ACP',
                'command': ['custom', '--acp'],
                'env': {'MODE': 'test'},
                'futureWireOnly': true,
              },
            },
          }),
        ),
        isTrue,
      );
      final persisted =
          jsonDecode(File(p.join(home.path, 'config.json')).readAsStringSync())
              as Map;
      final provider =
          ((persisted['agents'] as Map)['providers'] as Map)['custom-acp']
              as Map;
      expect(provider['extends'], 'acp');
      expect(provider['env'], {'MODE': 'test'});
      expect(provider.containsKey('futureWireOnly'), isFalse);

      expect(
        () => store.patch(
          MutableDaemonConfigPatch.fromJson({
            'providers': {
              'bad': {
                'command': [''],
              },
            },
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'metadata generation is absent until configured, then clears durably',
    () {
      final file = File(p.join(home.path, 'config.json'));
      final store = DaemonConfigStore(home: home.path);

      expect(
        store.patch(
          const MutableDaemonConfigPatch(autoArchiveAfterMerge: true),
        ),
        isTrue,
      );
      var persisted = jsonDecode(file.readAsStringSync()) as Map;
      expect(persisted.containsKey('agents'), isFalse);

      expect(
        store.patch(
          const MutableDaemonConfigPatch(
            metadataGenerationProviders: [
              MutableStructuredGenerationProvider(
                provider: 'codex',
                model: 'gpt-5',
                extra: {'future': true},
              ),
            ],
          ),
        ),
        isTrue,
      );
      persisted = jsonDecode(file.readAsStringSync()) as Map;
      var metadata = (persisted['agents'] as Map)['metadataGeneration'] as Map;
      expect(metadata['providers'], [
        {'provider': 'codex', 'model': 'gpt-5'},
      ]);

      expect(
        store.patch(
          const MutableDaemonConfigPatch(metadataGenerationProviders: []),
        ),
        isTrue,
      );
      persisted = jsonDecode(file.readAsStringSync()) as Map;
      metadata = (persisted['agents'] as Map)['metadataGeneration'] as Map;
      expect(metadata['providers'], isEmpty);
    },
  );
}
