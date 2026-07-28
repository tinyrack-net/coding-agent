import 'package:agent_protocol/agent_protocol.dart';

const _storedCapabilities = {
  'supportsStreaming': false,
  'supportsSessionPersistence': true,
  'supportsSessionListing': false,
  'supportsDynamicModes': false,
  'supportsMcpServers': false,
  'supportsReasoningStream': false,
  'supportsToolInvocations': true,
  'supportsRewindConversation': false,
  'supportsRewindFiles': false,
  'supportsRewindBoth': false,
};

const paseoAcpCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': true,
  'supportsMcpServers': true,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': false,
  'supportsRewindFiles': false,
  'supportsRewindBoth': false,
};

const _claudeCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': true,
  'supportsMcpServers': true,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': true,
  'supportsRewindFiles': true,
  'supportsRewindBoth': true,
};

const _codexCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': false,
  'supportsMcpServers': true,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': true,
  'supportsRewindFiles': false,
  'supportsRewindBoth': false,
};

const _openCodeCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': true,
  'supportsMcpServers': true,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': false,
  'supportsRewindFiles': false,
  'supportsRewindBoth': true,
};

const _piCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': true,
  'supportsMcpServers': false,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': true,
  'supportsRewindFiles': false,
  'supportsRewindBoth': false,
};

const _ompCapabilities = {
  'supportsStreaming': true,
  'supportsSessionPersistence': true,
  'supportsSessionListing': true,
  'supportsDynamicModes': true,
  'supportsMcpServers': false,
  'supportsReasoningStream': true,
  'supportsToolInvocations': true,
  'supportsRewindConversation': true,
  'supportsRewindFiles': false,
  'supportsRewindBoth': false,
  'supportsNativePaseoTools': true,
};

final class PaseoProviderModeDefinition {
  const PaseoProviderModeDefinition({
    required this.mode,
    this.isUnattended = false,
  });

  final ProviderMode mode;
  final bool isUnattended;
}

final class PaseoProviderDefinition {
  const PaseoProviderDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.command,
    required this.defaultModeId,
    required this.modes,
    this.capabilities = _storedCapabilities,
    this.commandArgs = const [],
    this.enabledByDefault = true,
    this.source = 'builtin',
  });

  final String id;
  final String label;
  final String description;
  final String command;
  final List<String> commandArgs;
  final bool enabledByDefault;
  final String source;
  final String? defaultModeId;
  final List<PaseoProviderModeDefinition> modes;
  final Map<String, bool> capabilities;
}

List<Map<String, Object?>> paseoProviderFeaturesFor(AgentSummary agent) {
  return paseoProviderDraftFeatures(
    ListCommandsDraftConfig(
      provider: agent.provider,
      cwd: agent.cwd,
      model: agent.model,
      featureValues: agent.featureValues,
    ),
  ).map((feature) => feature.toJson()).toList(growable: false);
}

List<AgentFeature> paseoProviderDraftFeatures(ListCommandsDraftConfig config) {
  final values = config.featureValues ?? const <String, Object?>{};
  return switch (config.provider) {
    'claude' when _claudeModelSupportsFastMode(config.model ?? '') => [
      AgentFeatureToggle(
        id: 'fast_mode',
        label: 'Fast',
        description: 'Lower latency Opus responses at higher token cost',
        tooltip: 'Toggle fast mode',
        icon: 'zap',
        value: values['fast_mode'] == true,
      ),
    ],
    'codex' => [
      if (_codexModelSupportsFastMode(config.model ?? ''))
        AgentFeatureToggle(
          id: 'fast_mode',
          label: 'Fast',
          description: 'Priority inference at 2x usage',
          tooltip: 'Toggle fast mode',
          icon: 'zap',
          value: values['fast_mode'] == true,
        ),
      AgentFeatureToggle(
        id: 'plan_mode',
        label: 'Plan',
        description: 'Switch Codex into planning-only collaboration mode',
        tooltip: 'Toggle plan mode',
        icon: 'list-todo',
        value: values['plan_mode'] == true,
      ),
    ],
    'opencode' => [
      AgentFeatureToggle(
        id: 'auto_accept',
        label: 'Auto Accept',
        description: 'Automatically approves OpenCode tool permission prompts.',
        tooltip: 'Auto accept permission prompts',
        icon: 'shield-check',
        value: values['auto_accept'] == true,
      ),
    ],
    _ => const <AgentFeature>[],
  };
}

bool _codexModelSupportsFastMode(String model) {
  final normalized = model.trim();
  if (normalized.isEmpty) return false;
  return const [
    'gpt-5',
    'gpt-4.1',
    'o3',
    'o4-mini',
  ].any((prefix) => normalized == prefix || normalized.startsWith(prefix));
}

bool _claudeModelSupportsFastMode(String model) {
  final normalized = model.trim().toLowerCase();
  return const {
    'claude-opus-4-8[1m]',
    'claude-opus-4-8',
    'claude-opus-4-7[1m]',
    'claude-opus-4-7',
    'claude-opus-4-6[1m]',
    'claude-opus-4-6',
  }.contains(normalized);
}

const _claudeModes = [
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'plan',
      label: 'Plan Mode',
      description: 'Analyze the codebase without executing tools or edits',
      icon: 'ShieldEllipsis',
      colorTier: 'planning',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'default',
      label: 'Always Ask',
      description: 'Prompts for permission the first time a tool is used',
      icon: 'Shield',
      colorTier: 'safe',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'acceptEdits',
      label: 'Accept File Edits',
      description:
          'Automatically approves edit-focused tools without prompting',
      icon: 'ShieldPlus',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'auto',
      label: 'Auto mode',
      description:
          'Uses a model classifier to review permission prompts automatically',
      icon: 'ShieldCheck',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'bypassPermissions',
      label: 'Bypass',
      description: 'Skip all permission prompts (use with caution)',
      icon: 'ShieldOff',
      colorTier: 'dangerous',
    ),
    isUnattended: true,
  ),
];

const _codexModes = [
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'auto',
      label: 'Default Permissions',
      description:
          "Edit files and run commands with Codex's default approval flow.",
      icon: 'Shield',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'auto-review',
      label: 'Auto-review',
      description:
          'Same workspace-write permissions as Default, but eligible '
          '`on-request` approvals are routed through the auto-reviewer subagent.',
      icon: 'ShieldCheck',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'full-access',
      label: 'Full Access',
      description:
          'Edit files, run commands, and access the network without additional prompts.',
      icon: 'ShieldOff',
      colorTier: 'dangerous',
    ),
    isUnattended: true,
  ),
];

const _copilotModes = [
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'https://agentclientprotocol.com/protocol/session-modes#agent',
      label: 'Agent',
      description: 'Default agent mode for conversational interactions',
      icon: 'Shield',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'https://agentclientprotocol.com/protocol/session-modes#plan',
      label: 'Plan',
      description: 'Plan mode for creating and executing multi-step plans',
      icon: 'ShieldEllipsis',
      colorTier: 'planning',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'allow-all',
      label: 'Allow All',
      description:
          'Automatically approves all Copilot tool, path, and URL requests.',
      icon: 'ShieldOff',
      colorTier: 'dangerous',
    ),
    isUnattended: true,
  ),
];

const _openCodeModes = [
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'build',
      label: 'Build',
      description: 'Allows edits and tool execution for implementation work',
      icon: 'Shield',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'plan',
      label: 'Plan',
      description: 'Read-only planning mode that avoids file edits',
      icon: 'ShieldEllipsis',
      colorTier: 'planning',
    ),
  ),
];

const _ompModes = [
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'full',
      label: 'Full Access',
      description:
          'Launches OMP with yolo approval mode so tools run without prompts.',
      icon: 'ShieldOff',
      colorTier: 'dangerous',
    ),
    isUnattended: true,
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'write',
      label: 'Write Approval',
      description:
          'Launches OMP with write approval mode — reads are free, writes require approval.',
      icon: 'ShieldAlert',
      colorTier: 'moderate',
    ),
  ),
  PaseoProviderModeDefinition(
    mode: ProviderMode(
      id: 'ask',
      label: 'Always Ask',
      description:
          'Launches OMP with always-ask approval mode for write and exec tools.',
      icon: 'ShieldCheck',
      colorTier: 'safe',
    ),
  ),
];

abstract final class PaseoProviderManifest {
  static const definitions = [
    PaseoProviderDefinition(
      id: 'claude',
      label: 'Claude',
      description:
          "Anthropic's multi-tool assistant with MCP support, streaming, and deep reasoning",
      command: 'claude',
      defaultModeId: 'auto',
      modes: _claudeModes,
      capabilities: _claudeCapabilities,
    ),
    PaseoProviderDefinition(
      id: 'codex',
      label: 'Codex',
      description:
          "OpenAI's Codex workspace agent with sandbox controls and optional network access",
      command: 'codex',
      defaultModeId: 'auto-review',
      modes: _codexModes,
      capabilities: _codexCapabilities,
    ),
    PaseoProviderDefinition(
      id: 'copilot',
      label: 'Copilot',
      description:
          'GitHub Copilot via Agent Client Protocol with dynamic modes and session support',
      command: 'copilot',
      commandArgs: ['--acp'],
      defaultModeId:
          'https://agentclientprotocol.com/protocol/session-modes#agent',
      modes: _copilotModes,
      capabilities: paseoAcpCapabilities,
    ),
    PaseoProviderDefinition(
      id: 'opencode',
      label: 'OpenCode',
      description:
          'Open-source coding assistant with multi-provider model support',
      command: 'opencode',
      defaultModeId: null,
      modes: _openCodeModes,
      capabilities: _openCodeCapabilities,
    ),
    PaseoProviderDefinition(
      id: 'pi',
      label: 'Pi',
      description:
          'Minimal terminal-based coding agent with multi-provider LLM support',
      command: 'pi',
      defaultModeId: null,
      modes: [],
      capabilities: _piCapabilities,
    ),
    PaseoProviderDefinition(
      id: 'omp',
      label: 'Oh My Pi',
      description:
          'Multi-provider coding agent with native approvals, host tools, and subagents',
      command: 'omp',
      enabledByDefault: false,
      defaultModeId: 'full',
      modes: _ompModes,
      capabilities: _ompCapabilities,
    ),
  ];

  static PaseoProviderDefinition? find(String id) {
    for (final definition in definitions) {
      if (definition.id == id) return definition;
    }
    return null;
  }
}
