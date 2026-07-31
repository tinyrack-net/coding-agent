/// Handshake messages exchanged right after the WebSocket opens.
library;

abstract final class MessageTypes {
  // handshake
  static const clientHelloRequest = 'client.hello.request';
  // providers
  static const providerListRequest = 'provider.list.request';
  static const providerCredentialSetRequest = 'provider.credential.set.request';
  static const providerCredentialClearRequest =
      'provider.credential.clear.request';
  static const providerCredentialTestRequest =
      'provider.credential.test.request';
  // agents (M1+)
  static const agentCreateRequest = 'agent.create.request';
  static const agentListRequest = 'agent.list.request';
  static const agentPromptRequest = 'agent.prompt.request';
  static const agentInterruptRequest = 'agent.interrupt.request';
  static const agentSetModeRequest = 'agent.set_mode.request';
  static const agentRenameRequest = 'agent.rename.request';
  static const agentArchiveRequest = 'agent.archive.request';
  static const agentDetachRequest = 'agent.detach.request';
  static const agentAttentionClearRequest = 'agent.attention.clear.request';
  static const agentTimelineFetchRequest = 'agent.timeline.fetch.request';
  static const providerSubagentListRequest =
      'agent.provider_subagents.list.request';
  static const providerSubagentTimelineRequest =
      'agent.provider_subagents.timeline.get.request';
  // Wipe persisted + in-memory conversation state. Request payload is
  // empty (clear every agent) or `{agentId}` (clear one). Response is
  // [AgentConversationClearResponse] with the number of affected agents.
  static const agentConversationClearRequest =
      'agent.conversation.clear.request';
  // broadcast events
  static const agentStreamEvent = 'agent.stream';
  static const agentStateEvent = 'agent.state';
  static const providerSubagentUpdateEvent = 'agent.provider_subagents.update';
  static const permissionRequestedEvent = 'permission.requested';
  static const permissionResolvedEvent = 'permission.resolved';
  // permissions
  static const permissionRespondRequest = 'permission.respond.request';
  // projects & worktrees (M4)
  static const projectListRequest = 'project.list.request';
  static const projectAddRequest = 'project.add.request';
  static const worktreeCreateRequest = 'worktree.create.request';
  static const worktreeListRequest = 'worktree.list.request';
  static const worktreeArchiveRequest = 'worktree.archive.request';
  static const branchListRequest = 'branch.list.request';
  // diff (M4)
  static const diffGetRequest = 'diff.get.request';
  // terminals (M5)
  static const terminalCreateRequest = 'terminal.create.request';
  static const terminalListRequest = 'terminal.list.request';
  static const terminalKillRequest = 'terminal.kill.request';
  static const terminalSubscribeRequest = 'terminal.subscribe.request';
  static const terminalUnsubscribeRequest = 'terminal.unsubscribe.request';
  // broadcast: a terminal exited (payload {terminalId, exitCode?})
  static const terminalExitedEvent = 'terminal.exited';
  // daemon lifecycle (desktop shell)
  static const daemonShutdownRequest = 'daemon.shutdown.request';
  static const daemonStatusRequest = 'daemon.status.request';
  // Paseo 0.2.0 legacy compatibility messages.
  static const resumeAgentRequest = 'resume_agent_request';
  static const restartServerRequest = 'restart_server_request';
  static const shutdownServerRequest = 'shutdown_server_request';
  static const checkoutCommitRequest = 'checkout_commit_request';
  static const checkoutCommitResponse = 'checkout_commit_response';
  static const validateBranchRequest = 'validate_branch_request';
  static const validateBranchResponse = 'validate_branch_response';
  static const branchSuggestionsRequest = 'branch_suggestions_request';
  static const branchSuggestionsResponse = 'branch_suggestions_response';
  static const stashSaveRequest = 'stash_save_request';
  static const stashSaveResponse = 'stash_save_response';
  static const stashPopRequest = 'stash_pop_request';
  static const stashPopResponse = 'stash_pop_response';
  static const stashListRequest = 'stash_list_request';
  static const stashListResponse = 'stash_list_response';
  static const listAvailableEditorsRequest = 'list_available_editors_request';
  static const listAvailableEditorsResponse = 'list_available_editors_response';
  static const openInEditorRequest = 'open_in_editor_request';
  static const openInEditorResponse = 'open_in_editor_response';
  static const fileDownloadTokenRequest = 'file_download_token_request';
  static const fileDownloadTokenResponse = 'file_download_token_response';
  static const workspaceUpdateEvent = 'workspace_update';
}

final class ClientHello {
  const ClientHello({
    required this.clientName,
    required this.clientVersion,
    this.token,
  });

  final String clientName;
  final String clientVersion;

  /// Bearer token for remote (non-loopback) connections. Optional on loopback.
  final String? token;

  static ClientHello fromJson(Map<String, Object?> json) => ClientHello(
    clientName: (json['clientName'] as String?) ?? 'unknown',
    clientVersion: (json['clientVersion'] as String?) ?? '0.0.0',
    token: json['token'] as String?,
  );

  Map<String, Object?> toJson() => {
    'clientName': clientName,
    'clientVersion': clientVersion,
    if (token != null) 'token': token,
  };
}

final class ServerHello {
  const ServerHello({
    required this.daemonVersion,
    required this.protocolVersion,
    this.capabilities = const [],
    this.pid,
    this.desktopManaged = false,
  });

  final String daemonVersion;
  final int protocolVersion;
  final List<String> capabilities;

  /// Daemon process id, when the daemon chooses to expose it (desktop shell).
  final int? pid;

  /// True when this daemon was spawned and is owned by the desktop app.
  final bool desktopManaged;

  static ServerHello fromJson(Map<String, Object?> json) => ServerHello(
    daemonVersion: (json['daemonVersion'] as String?) ?? '0.0.0',
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 0,
    capabilities: ((json['capabilities'] as List?) ?? const []).cast<String>(),
    pid: (json['pid'] as num?)?.toInt(),
    desktopManaged: (json['desktopManaged'] as bool?) ?? false,
  );

  Map<String, Object?> toJson() => {
    'daemonVersion': daemonVersion,
    'protocolVersion': protocolVersion,
    'capabilities': capabilities,
    if (pid != null) 'pid': pid,
    'desktopManaged': desktopManaged,
  };
}
