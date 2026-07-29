import 'package:agent_daemon/src/providers/paseo/provider_manifest.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('matches the Paseo 0.2 built-in provider manifest', () {
    final definitions = PaseoProviderManifest.definitions;

    expect(definitions.map((entry) => entry.id), [
      'claude',
      'codex',
      'copilot',
      'opencode',
      'pi',
      'omp',
    ]);
    expect(definitions.map((entry) => entry.command), [
      'claude',
      'codex',
      'copilot',
      'opencode',
      'pi',
      'omp',
    ]);
    expect(PaseoProviderManifest.find('claude')?.defaultModeId, 'auto');
    expect(PaseoProviderManifest.find('codex')?.defaultModeId, 'auto-review');
    expect(PaseoProviderManifest.find('opencode')?.defaultModeId, isNull);
    expect(PaseoProviderManifest.find('pi')?.modes, isEmpty);
    expect(PaseoProviderManifest.find('omp')?.enabledByDefault, isFalse);
    expect(PaseoProviderManifest.find('missing'), isNull);
    expect(
      PaseoProviderManifest.builtInProviderIds,
      definitions.map((entry) => entry.id),
    );
    expect(
      PaseoProviderManifest.agentProviderIds,
      PaseoProviderManifest.builtInProviderIds,
    );
  });

  test('preserves every frozen provider label and description', () {
    expect(
      PaseoProviderManifest.definitions
          .map(
            (entry) => (
              id: entry.id,
              label: entry.label,
              description: entry.description,
              defaultModeId: entry.defaultModeId,
            ),
          )
          .toList(),
      [
        (
          id: 'claude',
          label: 'Claude',
          description:
              "Anthropic's multi-tool assistant with MCP support, streaming, and deep reasoning",
          defaultModeId: 'auto',
        ),
        (
          id: 'codex',
          label: 'Codex',
          description:
              "OpenAI's Codex workspace agent with sandbox controls and optional network access",
          defaultModeId: 'auto-review',
        ),
        (
          id: 'copilot',
          label: 'Copilot',
          description:
              'GitHub Copilot via Agent Client Protocol with dynamic modes and session support',
          defaultModeId:
              'https://agentclientprotocol.com/protocol/session-modes#agent',
        ),
        (
          id: 'opencode',
          label: 'OpenCode',
          description:
              'Open-source coding assistant with multi-provider model support',
          defaultModeId: null,
        ),
        (
          id: 'pi',
          label: 'Pi',
          description:
              'Minimal terminal-based coding agent with multi-provider LLM support',
          defaultModeId: null,
        ),
        (
          id: 'omp',
          label: 'Oh My Pi',
          description:
              'Multi-provider coding agent with native approvals, host tools, and subagents',
          defaultModeId: 'full',
        ),
      ],
    );
  });

  test('preserves voice defaults and development-only definitions', () {
    final claude = PaseoProviderManifest.get('claude');
    final codex = PaseoProviderManifest.get('codex');
    final openCode = PaseoProviderManifest.get('opencode');

    expect(claude.voice?.enabled, isTrue);
    expect(claude.voice?.defaultModeId, 'default');
    expect(claude.voice?.defaultModel, 'haiku');
    expect(codex.voice?.defaultModeId, 'auto');
    expect(codex.voice?.defaultModel, 'gpt-5.4-mini');
    expect(openCode.voice?.defaultModeId, 'build');
    expect(openCode.voice?.defaultModel, isNull);
    expect(PaseoProviderManifest.find('pi')?.voice, isNull);

    expect(
      PaseoProviderManifest.developmentDefinitions.map((entry) => entry.id),
      ['mock', 'mock-slow'],
    );
    expect(PaseoProviderManifest.get('mock').modes.single.mode.id, 'load-test');
    expect(
      PaseoProviderManifest.get('mock-slow').modes.single.mode.id,
      'default',
    );
    expect(PaseoProviderManifest.builtInProviderIds, isNot(contains('mock')));
  });

  test('preserves mode ids, visuals, and unattended semantics', () {
    final claude = PaseoProviderManifest.find('claude')!;
    final codex = PaseoProviderManifest.find('codex')!;
    final copilot = PaseoProviderManifest.find('copilot')!;
    final opencode = PaseoProviderManifest.find('opencode')!;
    final omp = PaseoProviderManifest.find('omp')!;

    expect(claude.modes.map((entry) => entry.mode.id), [
      'plan',
      'default',
      'acceptEdits',
      'auto',
      'bypassPermissions',
    ]);
    expect(
      claude.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'bypassPermissions',
    );
    expect(
      codex.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'full-access',
    );
    expect(
      copilot.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'allow-all',
    );
    expect(opencode.modes.last.mode.colorTier, 'planning');
    expect(omp.modes.first.isUnattended, isTrue);
    expect(copilot.commandArgs, ['--acp']);
  });

  test('preserves every frozen mode field', () {
    List<
      ({
        String id,
        String label,
        String description,
        String icon,
        String colorTier,
        bool isUnattended,
      })
    >
    modes(String provider) => [
      for (final entry in PaseoProviderManifest.get(provider).modes)
        (
          id: entry.mode.id,
          label: entry.mode.label,
          description: entry.mode.description!,
          icon: entry.mode.icon!,
          colorTier: entry.mode.colorTier!,
          isUnattended: entry.isUnattended,
        ),
    ];

    expect(modes('claude'), [
      (
        id: 'plan',
        label: 'Plan Mode',
        description: 'Analyze the codebase without executing tools or edits',
        icon: 'ShieldEllipsis',
        colorTier: 'planning',
        isUnattended: false,
      ),
      (
        id: 'default',
        label: 'Always Ask',
        description: 'Prompts for permission the first time a tool is used',
        icon: 'Shield',
        colorTier: 'safe',
        isUnattended: false,
      ),
      (
        id: 'acceptEdits',
        label: 'Accept File Edits',
        description:
            'Automatically approves edit-focused tools without prompting',
        icon: 'ShieldPlus',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'auto',
        label: 'Auto mode',
        description:
            'Uses a model classifier to review permission prompts automatically',
        icon: 'ShieldCheck',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'bypassPermissions',
        label: 'Bypass',
        description: 'Skip all permission prompts (use with caution)',
        icon: 'ShieldOff',
        colorTier: 'dangerous',
        isUnattended: true,
      ),
    ]);
    expect(modes('codex'), [
      (
        id: 'auto',
        label: 'Default Permissions',
        description:
            "Edit files and run commands with Codex's default approval flow.",
        icon: 'Shield',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'auto-review',
        label: 'Auto-review',
        description:
            'Same workspace-write permissions as Default, but eligible '
            '`on-request` approvals are routed through the auto-reviewer subagent.',
        icon: 'ShieldCheck',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'full-access',
        label: 'Full Access',
        description:
            'Edit files, run commands, and access the network without additional prompts.',
        icon: 'ShieldOff',
        colorTier: 'dangerous',
        isUnattended: true,
      ),
    ]);
    expect(modes('copilot'), [
      (
        id: 'https://agentclientprotocol.com/protocol/session-modes#agent',
        label: 'Agent',
        description: 'Default agent mode for conversational interactions',
        icon: 'Shield',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'https://agentclientprotocol.com/protocol/session-modes#plan',
        label: 'Plan',
        description: 'Plan mode for creating and executing multi-step plans',
        icon: 'ShieldEllipsis',
        colorTier: 'planning',
        isUnattended: false,
      ),
      (
        id: 'allow-all',
        label: 'Allow All',
        description:
            'Automatically approves all Copilot tool, path, and URL requests.',
        icon: 'ShieldOff',
        colorTier: 'dangerous',
        isUnattended: true,
      ),
    ]);
    expect(modes('opencode'), [
      (
        id: 'build',
        label: 'Build',
        description: 'Allows edits and tool execution for implementation work',
        icon: 'Shield',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'plan',
        label: 'Plan',
        description: 'Read-only planning mode that avoids file edits',
        icon: 'ShieldEllipsis',
        colorTier: 'planning',
        isUnattended: false,
      ),
    ]);
    expect(modes('pi'), isEmpty);
    expect(modes('omp'), [
      (
        id: 'full',
        label: 'Full Access',
        description:
            'Launches OMP with yolo approval mode so tools run without prompts.',
        icon: 'ShieldOff',
        colorTier: 'dangerous',
        isUnattended: true,
      ),
      (
        id: 'write',
        label: 'Write Approval',
        description:
            'Launches OMP with write approval mode — reads are free, writes require approval.',
        icon: 'ShieldAlert',
        colorTier: 'moderate',
        isUnattended: false,
      ),
      (
        id: 'ask',
        label: 'Always Ask',
        description:
            'Launches OMP with always-ask approval mode for write and exec tools.',
        icon: 'ShieldCheck',
        colorTier: 'safe',
        isUnattended: false,
      ),
    ]);
  });

  test('matches frozen provider capability differences', () {
    final claude = PaseoProviderManifest.find('claude')!;
    final codex = PaseoProviderManifest.find('codex')!;
    final openCode = PaseoProviderManifest.find('opencode')!;
    final pi = PaseoProviderManifest.find('pi')!;
    final omp = PaseoProviderManifest.find('omp')!;

    expect(claude.capabilities['supportsRewindBoth'], isTrue);
    expect(codex.capabilities['supportsDynamicModes'], isFalse);
    expect(codex.capabilities['supportsRewindConversation'], isTrue);
    expect(openCode.capabilities['supportsRewindBoth'], isTrue);
    expect(pi.capabilities['supportsMcpServers'], isFalse);
    expect(omp.capabilities['supportsNativePaseoTools'], isTrue);
  });

  test(
    'matches manifest lookup, validation, unattended, and visuals helpers',
    () {
      expect(PaseoProviderManifest.isValid('claude'), isTrue);
      expect(PaseoProviderManifest.isValid('mock'), isFalse);
      expect(PaseoProviderManifest.isValid('custom', const {'custom'}), isTrue);
      expect(
        () => PaseoProviderManifest.get('missing'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Unknown agent provider: missing',
          ),
        ),
      );

      expect(
        PaseoProviderManifest.unattendedModeId('claude'),
        'bypassPermissions',
      );
      expect(PaseoProviderManifest.unattendedModeId('codex'), 'full-access');
      expect(PaseoProviderManifest.unattendedModeId('opencode'), isNull);
      expect(PaseoProviderManifest.unattendedModeId('missing'), isNull);

      expect(
        PaseoProviderManifest.modeVisuals(
          'claude',
          'plan',
          PaseoProviderManifest.definitions,
        ),
        (icon: 'ShieldEllipsis', colorTier: 'planning'),
      );
      expect(
        PaseoProviderManifest.modeVisuals(
          'claude',
          'missing',
          PaseoProviderManifest.definitions,
        ),
        isNull,
      );
    },
  );

  test('projects only frozen provider features supported by the model', () {
    AgentSummary agent({
      required String provider,
      required String model,
      Map<String, Object?> featureValues = const {},
    }) => AgentSummary(
      agentId: 'agent-1',
      title: '',
      cwd: r'C:\repo',
      provider: provider,
      model: model,
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 0,
      featureValues: featureValues,
    );

    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'codex',
          model: 'gpt-5.4',
          featureValues: const {'fast_mode': true, 'plan_mode': true},
        ),
      ),
      [containsPair('id', 'fast_mode'), containsPair('id', 'plan_mode')],
    );
    expect(
      paseoProviderFeaturesFor(
        agent(provider: 'codex', model: 'unknown-model'),
      ).map((feature) => feature['id']),
      ['plan_mode'],
    );
    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'claude',
          model: 'claude-opus-4-8',
          featureValues: const {'fast_mode': true},
        ),
      ).single,
      containsPair('value', true),
    );
    expect(
      paseoProviderFeaturesFor(
        agent(provider: 'claude', model: 'claude-sonnet-5'),
      ),
      isEmpty,
    );
    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'opencode',
          model: '',
          featureValues: const {'auto_accept': true},
        ),
      ).single,
      allOf(containsPair('id', 'auto_accept'), containsPair('value', true)),
    );
    expect(paseoProviderFeaturesFor(agent(provider: 'pi', model: '')), isEmpty);
  });
}
