abstract final class ClientCapabilities {
  static const selectiveAgentTimeline = 'selective_agent_timeline';
  static const reasoningMergeEnum = 'reasoning_merge_enum';
  static const customModeIcons = 'custom_mode_icons';
  static const terminalReflowableSnapshot = 'terminal_reflowable_snapshot';
  static const providerSubagents = 'provider_subagents';
  static const projectUpdates = 'project_updates';
  static const browserHost = 'browser_host';

  static const all = <String>{
    selectiveAgentTimeline,
    reasoningMergeEnum,
    customModeIcons,
    terminalReflowableSnapshot,
    providerSubagents,
    projectUpdates,
    browserHost,
  };
}
