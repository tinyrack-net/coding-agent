/// Built-in provider icon identifiers from the frozen Paseo 0.2.0 contract.
const builtinProviderIconNames = <String>[
  'claude',
  'codex',
  'copilot',
  'kiro',
  'minimax',
  'omp',
  'opencode',
  'pi',
];

/// ACP catalog provider icon identifiers from the frozen Paseo 0.2.0 contract.
const acpProviderIconNames = <String>[
  'agoragentic-acp',
  'amp-acp',
  'auggie',
  'autohand',
  'cline',
  'codebuddy-code',
  'codewhale',
  'cortex-code',
  'corust-agent',
  'crow-cli',
  'cursor',
  'deepagents',
  'dimcode',
  'dirac',
  'factory-droid',
  'fast-agent',
  'gemini',
  'glm-acp-agent',
  'goose',
  'grok',
  'junie',
  'kilo',
  'kimi',
  'minion-code',
  'mistral-vibe',
  'nova',
  'poolside',
  'qoder',
  'qwen-code',
  'sigit',
  'stakpak',
  'traecli',
  'vtcode',
];

/// Icon identifiers used by terminal profiles but not the ACP catalog.
const terminalProfileIconNames = <String>['agy'];

/// Every icon name understood by Paseo 0.2.0 clients.
const knownProviderIconNames = <String>[
  ...builtinProviderIconNames,
  ...acpProviderIconNames,
  ...terminalProfileIconNames,
];
