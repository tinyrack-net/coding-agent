/// Handshake messages exchanged right after the WebSocket opens.
library;

abstract final class MessageTypes {
  // handshake
  static const clientHelloRequest = 'client.hello.request';
  // providers
  static const providerListRequest = 'provider.list.request';
  // agents (M1+)
  static const agentCreateRequest = 'agent.create.request';
  static const agentListRequest = 'agent.list.request';
  static const agentPromptRequest = 'agent.prompt.request';
  static const agentInterruptRequest = 'agent.interrupt.request';
  static const agentSetModeRequest = 'agent.set_mode.request';
  static const agentArchiveRequest = 'agent.archive.request';
  static const agentTimelineFetchRequest = 'agent.timeline.fetch.request';
  // broadcast events
  static const agentStreamEvent = 'agent.stream';
  static const agentStateEvent = 'agent.state';
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
        capabilities: ((json['capabilities'] as List?) ?? const [])
            .cast<String>(),
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
