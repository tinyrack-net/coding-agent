import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> completeConfig() => {
    'mcp': {'injectIntoAgents': true, 'futureMcp': 1},
    'browserTools': {'enabled': true, 'futureBrowser': 2},
    'providers': {
      'codex': {
        'enabled': true,
        'additionalModels': [
          {
            'id': 'gpt-5',
            'label': 'GPT-5',
            'description': 'Primary',
            'isDefault': true,
            'futureModel': 3,
          },
        ],
        'futureProvider': 4,
      },
    },
    'metadataGeneration': {
      'providers': [
        {
          'provider': 'codex',
          'model': 'gpt-5',
          'thinkingOptionId': 'high',
          'futureMetadataProvider': 5,
        },
      ],
      'futureMetadata': 6,
    },
    'autoArchiveAfterMerge': true,
    'enableTerminalAgentHooks': true,
    'appendSystemPrompt': 'Tinyrack',
    'terminalProfiles': [
      {
        'id': 'codex',
        'name': 'Codex',
        'command': 'codex',
        'args': ['--search'],
        'icon': 'codex',
        'futureProfile': 8,
      },
    ],
    'futureRoot': 7,
  };

  test('mutable config round-trips known fields and passthrough values', () {
    final source = completeConfig();
    final config = MutableDaemonConfig.fromJson(source);

    expect(config.injectMcpIntoAgents, isTrue);
    expect(config.browserToolsEnabled, isTrue);
    expect(config.providers['codex']!.additionalModels!.single.id, 'gpt-5');
    expect(config.metadataGenerationProviders.single.thinkingOptionId, 'high');
    expect(config.enableTerminalAgentHooks, isTrue);
    expect(config.terminalProfiles!.single.args, ['--search']);
    expect(config.toJson(), source);
  });

  test('mutable config applies every frozen default', () {
    final config = MutableDaemonConfig.fromJson({
      'mcp': {'injectIntoAgents': false},
    });

    expect(config.browserToolsEnabled, isFalse);
    expect(config.providers, isEmpty);
    expect(config.metadataGenerationProviders, isEmpty);
    expect(config.autoArchiveAfterMerge, isFalse);
    expect(config.enableTerminalAgentHooks, isFalse);
    expect(config.appendSystemPrompt, isEmpty);
    expect(config.terminalProfiles, isNull);
  });

  test('get, set, response, and change status use exact wire names', () {
    const get = GetDaemonConfigRequest(requestId: 'get-1');
    expect(GetDaemonConfigRequest.fromJson(get.toJson()).requestId, 'get-1');

    const set = SetDaemonConfigRequest(
      requestId: 'set-1',
      config: MutableDaemonConfigPatch(enableTerminalAgentHooks: true),
    );
    final decodedSet = SetDaemonConfigRequest.fromJson(set.toJson());
    expect(decodedSet.config.enableTerminalAgentHooks, isTrue);

    final config = MutableDaemonConfig.fromJson(completeConfig());
    final response = DaemonConfigResponse(
      type: 'set_daemon_config_response',
      requestId: 'set-1',
      config: config,
    );
    expect(
      DaemonConfigResponse.fromJson(response.toJson()).config.toJson(),
      completeConfig(),
    );

    final changed = DaemonConfigChangedStatus(config: config);
    expect(
      DaemonConfigChangedStatus.fromJson(
        changed.toJson(),
      ).config.enableTerminalAgentHooks,
      isTrue,
    );
  });

  test('typed mutable patch fields produce the exact partial wire shape', () {
    final patch = MutableDaemonConfigPatch(
      injectMcpIntoAgents: true,
      browserToolsEnabled: true,
      providers: const {'codex': MutableDaemonProviderConfig(enabled: false)},
      removeProviders: const ['old-acp'],
      metadataGenerationProviders: const [
        MutableStructuredGenerationProvider(provider: 'codex', model: 'gpt-5'),
      ],
      autoArchiveAfterMerge: true,
      appendSystemPrompt: 'Keep it short.',
      terminalProfiles: const [
        TerminalProfile(id: 'codex', name: 'Codex', command: 'codex'),
      ],
    );

    expect(patch.toJson(), {
      'mcp': {'injectIntoAgents': true},
      'browserTools': {'enabled': true},
      'providers': {
        'codex': {'enabled': false},
      },
      'removeProviders': ['old-acp'],
      'metadataGeneration': {
        'providers': [
          {'provider': 'codex', 'model': 'gpt-5'},
        ],
      },
      'autoArchiveAfterMerge': true,
      'appendSystemPrompt': 'Keep it short.',
      'terminalProfiles': [
        {'id': 'codex', 'name': 'Codex', 'command': 'codex'},
      ],
    });
    final decoded = MutableDaemonConfigPatch.fromJson(patch.toJson());
    expect(decoded.injectMcpIntoAgents, isTrue);
    expect(decoded.browserToolsEnabled, isTrue);
    expect(decoded.providers!['codex']!.enabled, isFalse);
    expect(decoded.removeProviders, ['old-acp']);
    expect(decoded.metadataGenerationProviders!.single.model, 'gpt-5');
    expect(decoded.autoArchiveAfterMerge, isTrue);
    expect(decoded.appendSystemPrompt, 'Keep it short.');
    expect(decoded.terminalProfiles!.single.command, 'codex');
  });

  test('rejects malformed boundaries and constrained strings', () {
    expect(() => MutableDaemonConfig.fromJson(const {}), throwsFormatException);
    expect(
      () => MutableDaemonConfig.fromJson({
        'mcp': {'injectIntoAgents': 'yes'},
      }),
      throwsFormatException,
    );
    expect(
      () => MutableDaemonConfig.fromJson({
        'mcp': {'injectIntoAgents': false},
        'providers': {
          'codex': {
            'additionalModels': [
              {'id': '', 'label': 'bad'},
            ],
          },
        },
      }),
      throwsFormatException,
    );
    expect(
      () => MutableDaemonConfig.fromJson({
        'mcp': {'injectIntoAgents': false},
        'terminalProfiles': [
          {
            'id': 'codex',
            'name': 'Codex',
            'command': 'codex',
            'args': [1],
          },
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => MutableDaemonConfig.fromJson({
        'mcp': {'injectIntoAgents': false},
        'terminalProfiles': [
          {'id': 1, 'name': 'Codex', 'command': 'codex'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => DaemonConfigResponse.fromJson(const {'type': 'wrong_response'}),
      throwsFormatException,
    );
    expect(
      () => DaemonConfigChangedStatus.fromJson(const {'status': 'wrong'}),
      throwsFormatException,
    );
    for (final invalidPatch in <Map<String, Object?>>[
      {'mcp': 'wrong'},
      {
        'browserTools': {'enabled': 'yes'},
      },
      {'providers': []},
      {
        'providers': {
          'codex': {'additionalModels': 'wrong'},
        },
      },
      {
        'removeProviders': [''],
      },
      {
        'metadataGeneration': {'providers': 'wrong'},
      },
      {'autoArchiveAfterMerge': 'yes'},
      {'appendSystemPrompt': false},
      {'terminalProfiles': 'wrong'},
    ]) {
      expect(
        () => MutableDaemonConfigPatch.fromJson(invalidPatch),
        throwsFormatException,
        reason: '$invalidPatch',
      );
    }
  });
}
