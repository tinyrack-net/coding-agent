import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' as lifecycle;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

enum DaemonConnectionState {
  disconnected,
  connecting,
  connected,

  /// Remote daemon has an incompatible major version; no auto-reconnect.
  versionMismatch,
}

final class AgentFetchResult {
  const AgentFetchResult({required this.agent, required this.project});

  final AgentSummary agent;
  final Map<String, Object?>? project;
}

bool isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1';

/// Remote version gate: a non-loopback daemon must share our major version.
/// Loopback daemons are managed by the lifecycle supervisor instead.
bool shouldRejectHello(
  Uri uri,
  ServerHello hello, {
  String appDaemonVersion = lifecycle.daemonVersion,
}) {
  if (isLoopbackHost(uri.host)) return false;
  return lifecycle.majorOf(hello.daemonVersion) !=
      lifecycle.majorOf(appDaemonVersion);
}

/// User guidance shown when a remote daemon fails the version gate.
String versionMismatchMessage(
  ServerHello hello, {
  String appDaemonVersion = lifecycle.daemonVersion,
}) {
  final major = lifecycle.majorOf(appDaemonVersion);
  return '원격 데몬 v${hello.daemonVersion} — 이 앱은 v$major.x만 지원합니다. '
      '데몬 또는 앱을 업데이트하세요.';
}

/// WebSocket client for the daemon: correlates request/response by requestId,
/// exposes broadcast events as a stream, reconnects with backoff.
class DaemonClient {
  DaemonClient({
    required this.uri,
    this.token,
    this.relayE2ee,
    this.appVersion = lifecycle.daemonVersion,
  });

  final Uri uri;
  final String? token;
  final RelayE2eeOptions? relayE2ee;
  final String appVersion;

  final _uuid = const Uuid();
  final Map<String, Completer<RpcResponse>> _pending = {};
  final Map<String, Completer<Map<String, Object?>>> _sessionPending = {};
  final Map<String, _FileSubscriptionRegistration> _fileSubscriptions = {};
  final _events = StreamController<RpcEvent>.broadcast();
  final _agentStreamEvents = StreamController<AgentStreamPayload>.broadcast();
  final _directoryUpdateEvents =
      StreamController<DirectoryUpdateEvent>.broadcast();
  final _daemonConfigChanges =
      StreamController<DaemonConfigChangedStatus>.broadcast();
  final _workspaceSetupProgress =
      StreamController<WorkspaceSetupProgress>.broadcast();
  final _providersSnapshotUpdates =
      StreamController<ProvidersSnapshotUpdate>.broadcast();
  final _serverInfoUpdates = StreamController<ServerInfoStatus>.broadcast();
  final _terminalFrames = StreamController<TerminalFrame>.broadcast();
  final _state = StreamController<DaemonConnectionState>.broadcast();
  final Map<String, Completer<DaemonConfigResponse>> _daemonConfigPending = {};
  final Map<String, Completer<DiagnosticsResponse>> _diagnosticsPending = {};

  WebSocketChannel? _channel;
  RelayE2eeClientChannel? _relayE2eeChannel;
  Completer<ServerInfoStatus>? _serverInfoPending;
  DaemonConnectionState _current = DaemonConnectionState.disconnected;
  ServerHello? serverHello;
  ServerInfoStatus? serverInfo;

  /// Hello of a remote daemon rejected by the major-version gate.
  ServerHello? rejectedHello;
  bool _disposed = false;
  int _retrySeconds = 1;

  Stream<RpcEvent> get events => _events.stream;
  Stream<AgentStreamPayload> get agentStreamEvents => _agentStreamEvents.stream;
  Stream<DirectoryUpdateEvent> get directoryUpdateEvents =>
      _directoryUpdateEvents.stream;
  Stream<DaemonConfigChangedStatus> get daemonConfigChanges =>
      _daemonConfigChanges.stream;
  Stream<WorkspaceSetupProgress> get workspaceSetupProgress =>
      _workspaceSetupProgress.stream;
  Stream<ProvidersSnapshotUpdate> get providersSnapshotUpdates =>
      _providersSnapshotUpdates.stream;
  Stream<ServerInfoStatus> get serverInfoUpdates => _serverInfoUpdates.stream;

  /// Decoded binary terminal frames (output/snapshot) from the daemon.
  Stream<TerminalFrame> get terminalFrames => _terminalFrames.stream;
  Stream<DaemonConnectionState> get connectionState => _state.stream;
  DaemonConnectionState get currentState => _current;

  Future<void> connect() async {
    if (_disposed) return;
    _setState(DaemonConnectionState.connecting);
    try {
      final v2Uri = uri.replace(
        path: uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path,
      );
      final channel = WebSocketChannel.connect(
        v2Uri,
        protocols: token == null || token!.isEmpty
            ? null
            : ['tinyrack.bearer.$token'],
      );
      await channel.ready;
      _channel = channel;
      final useRelayE2ee = isRelayClientWebSocketUrl(v2Uri.toString());
      if (useRelayE2ee) {
        final options = relayE2ee;
        if (options == null || options.daemonPublicKeyB64.trim().isEmpty) {
          throw StateError('daemonPublicKeyB64 is required for relay E2EE');
        }
        final encrypted = RelayE2eeClientChannel(
          daemonPublicKeyB64: options.daemonPublicKeyB64,
          transportSend: channel.sink.add,
          transportClose: (code, reason) => channel.sink.close(code, reason),
          onMessage: (data) => _onFrame(data),
        );
        _relayE2eeChannel = encrypted;
        channel.stream.listen(
          (data) => encrypted.handleFrame(data as Object),
          onDone: () {
            encrypted.transportClosed();
            _onClosed();
          },
          onError: (_) {},
        );
        encrypted.start();
        await encrypted.ready.timeout(const Duration(seconds: 15));
      } else {
        channel.stream.listen(_onFrame, onDone: _onClosed, onError: (_) {});
      }
      final serverInfoPending = Completer<ServerInfoStatus>();
      _serverInfoPending = serverInfoPending;
      _sendFrame(
        jsonEncode(
          WebSocketHello(
            clientId: 'coding-agent-app',
            clientType: WebSocketClientType.mobile,
            protocolVersion: paseoWebSocketProtocolVersion,
            appVersion: appVersion,
            capabilities: {
              for (final capability in ClientCapabilities.all) capability: true,
            },
          ).toJson(),
        ),
      );
      final handshakeInfo = await serverInfoPending.future.timeout(
        const Duration(seconds: 15),
      );
      _serverInfoPending = null;
      final info = serverInfo ?? handshakeInfo;
      final parsed = ServerHello(
        daemonVersion: info.version ?? '0.0.0',
        protocolVersion: paseoWebSocketProtocolVersion,
        desktopManaged: info.desktopManaged,
      );
      if (shouldRejectHello(uri, parsed)) {
        // Incompatible remote daemon: drop the socket and stay put — the
        // user must update the daemon or the app, retrying won't help.
        rejectedHello = parsed;
        serverHello = null;
        serverInfo = null;
        _channel = null;
        _setState(DaemonConnectionState.versionMismatch);
        channel.sink.close(1000);
        return;
      }
      serverHello = parsed;
      serverInfo = info;
      rejectedHello = null;
      _retrySeconds = 1;
      _setState(DaemonConnectionState.connected);
      unawaited(_resubscribeFiles());
    } catch (_) {
      final failedChannel = _channel;
      _onClosed();
      failedChannel?.sink.close(4001, 'Connection handshake failed');
    }
  }

  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('not connected');
    }
    final requestId = _uuid.v4();
    final completer = Completer<RpcResponse>();
    _pending[requestId] = completer;
    _sendFrame(
      jsonEncode({
        'type': 'session',
        'message': RpcRequest(
          type: type,
          requestId: requestId,
          payload: payload,
        ).toJson(),
      }),
    );
    final response = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException('no response to $type');
      },
    );
    final error = response.error;
    if (error != null) throw DaemonRpcException(error);
    return response.payload;
  }

  /// Sends a Paseo v2 native session message and returns its typed response.
  ///
  /// Unlike [request], these messages carry `requestId` at the message root
  /// and use their own response type/payload shape instead of [RpcResponse].
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = message['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw ArgumentError.value(
        requestId,
        'message.requestId',
        'must be a non-empty string',
      );
    }
    if (_channel == null) throw StateError('not connected');
    if (_sessionPending.containsKey(requestId)) {
      throw StateError('duplicate session requestId: $requestId');
    }
    final completer = Completer<Map<String, Object?>>();
    _sessionPending[requestId] = completer;
    _sendFrame(jsonEncode({'type': 'session', 'message': message}));
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _sessionPending.remove(requestId);
        throw TimeoutException(
          'no response to ${message['type'] ?? 'session message'}',
        );
      },
    );
  }

  Future<ReadProjectConfigResponse> readProjectConfig(
    String repoRoot, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final correlatedId = requestId ?? _uuid.v4();
    final response = ReadProjectConfigResponse.fromJson(
      await requestSessionMessage(
        ReadProjectConfigRequest(
          requestId: correlatedId,
          repoRoot: repoRoot,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != correlatedId) {
      throw const FormatException('Project config read response mismatch');
    }
    return response;
  }

  Future<WriteProjectConfigResponse> writeProjectConfig({
    required String repoRoot,
    required Map<String, Object?> config,
    required ProjectConfigRevision? expectedRevision,
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final correlatedId = requestId ?? _uuid.v4();
    final response = WriteProjectConfigResponse.fromJson(
      await requestSessionMessage(
        WriteProjectConfigRequest(
          requestId: correlatedId,
          repoRoot: repoRoot,
          config: config,
          expectedRevision: expectedRevision,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != correlatedId) {
      throw const FormatException('Project config write response mismatch');
    }
    return response;
  }

  Future<ProjectRenameResponse> renameProject(
    String projectId,
    String? customName, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = ProjectRenameResponse.fromJson(
      await requestSessionMessage(
        ProjectRenameRequest(
          projectId: projectId,
          customName: customName,
          requestId: requestId,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId || response.projectId != projectId) {
      throw const FormatException('Project rename response mismatch');
    }
    if (!response.accepted) {
      throw DaemonRpcException(
        RpcError(
          code: 'project_rename_failed',
          message: response.error ?? 'Failed to rename project',
        ),
      );
    }
    return response;
  }

  /// Removes a registered project and archives its active workspaces.
  Future<ProjectRemoveResponse> removeProject(
    String projectId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = ProjectRemoveResponse.fromJson(
      await requestSessionMessage(
        ProjectRemoveRequest(
          projectId: projectId,
          requestId: requestId,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId || response.projectId != projectId) {
      throw const FormatException('Project remove response mismatch');
    }
    if (!response.accepted) {
      throw DaemonRpcException(
        RpcError(
          code: 'project_remove_failed',
          message: response.error ?? 'Failed to remove project',
        ),
      );
    }
    return response;
  }

  Future<AgentProviderNotice?> setAgentMode(String agentId, String modeId) =>
      _requestAgentConfig(
        type: 'set_agent_mode_request',
        responseType: 'set_agent_mode_response',
        agentId: agentId,
        fields: {'modeId': modeId},
      );

  Future<void> setAgentModel(String agentId, String? modelId) async {
    await _requestAgentConfig(
      type: 'set_agent_model_request',
      responseType: 'set_agent_model_response',
      agentId: agentId,
      fields: {'modelId': modelId},
    );
  }

  Future<AgentProviderNotice?> setAgentThinkingOption(
    String agentId,
    String? thinkingOptionId,
  ) => _requestAgentConfig(
    type: 'set_agent_thinking_request',
    responseType: 'set_agent_thinking_response',
    agentId: agentId,
    fields: {'thinkingOptionId': thinkingOptionId},
  );

  Future<void> setAgentFeature(
    String agentId,
    String featureId,
    Object? value,
  ) async {
    await _requestAgentConfig(
      type: 'set_agent_feature_request',
      responseType: 'set_agent_feature_response',
      agentId: agentId,
      fields: {'featureId': featureId, 'value': value},
    );
  }

  Future<AgentProviderNotice?> _requestAgentConfig({
    required String type,
    required String responseType,
    required String agentId,
    required Map<String, Object?> fields,
  }) async {
    final requestId = _uuid.v4();
    final response = AgentConfigResponse.fromJson(
      await requestSessionMessage({
        'type': type,
        'agentId': agentId,
        ...fields,
        'requestId': requestId,
      }),
    );
    if (response.type != responseType ||
        response.requestId != requestId ||
        response.agentId != agentId) {
      throw const FormatException('Agent config response mismatch');
    }
    if (!response.accepted) {
      throw DaemonRpcException(
        RpcError(
          code: 'agent_config_rejected',
          message: response.error ?? 'Agent configuration was rejected',
        ),
      );
    }
    return response.notice;
  }

  /// Fetches one Paseo v2 timeline page and validates response correlation.
  Future<AgentTimelinePage> fetchAgentTimeline({
    required String agentId,
    AgentTimelineDirection direction = AgentTimelineDirection.tail,
    AgentTimelineCursor? cursor,
    int limit = agentTimelineFetchPageSize,
    AgentTimelineProjection projection = AgentTimelineProjection.projected,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = await requestSessionMessage(
      FetchAgentTimelineRequest(
        agentId: agentId,
        requestId: requestId,
        direction: direction,
        cursor: cursor,
        limit: limit,
        projection: projection,
      ).toJson(),
      timeout: timeout,
    );
    final page = AgentTimelinePage.fromResponseJson(response);
    if (page.requestId != requestId) {
      throw FormatException(
        'Timeline response requestId mismatch: ${page.requestId}',
      );
    }
    if (page.agentId != agentId) {
      throw FormatException(
        'Timeline response agentId mismatch: ${page.agentId}',
      );
    }
    if (page.error case final error?) {
      throw DaemonRpcException(
        RpcError(code: 'timeline_fetch', message: error),
      );
    }
    return page;
  }

  Future<FetchAgentsResponse> fetchAgents({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    bool subscribe = false,
    String? subscriptionId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = await requestSessionMessage(
      FetchAgentsRequest(
        requestId: requestId,
        activeScope: true,
        filter: filter,
        sort: sort,
        limit: limit,
        cursor: cursor,
        hasSubscription: subscribe,
        subscriptionId: subscriptionId,
      ).toJson(),
      timeout: timeout,
    );
    final page = FetchAgentsResponse.fromJson(response);
    // coverage:ignore-start
    // requestSessionMessage resolves by this same payload requestId, so this
    // guard can only fire if that correlation invariant changes internally.
    if (page.requestId != requestId) {
      throw FormatException(
        'Agent directory response requestId mismatch: ${page.requestId}',
      );
    }
    // coverage:ignore-end
    return page;
  }

  Future<FetchAgentHistoryResponse> fetchAgentHistory({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = await requestSessionMessage(
      FetchAgentHistoryRequest(
        requestId: requestId,
        filter: filter,
        sort: sort,
        limit: limit,
        cursor: cursor,
      ).toJson(),
      timeout: timeout,
    );
    return FetchAgentHistoryResponse.fromJson(response);
  }

  Future<AgentFetchResult?> fetchAgent(
    String agentId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final requestId = _uuid.v4();
    final response = FetchAgentResponse.fromJson(
      await requestSessionMessage(
        FetchAgentRequest(requestId: requestId, agentId: agentId).toJson(),
        timeout: timeout,
      ),
    );
    if (response.error case final error?) {
      throw DaemonRpcException(RpcError(code: 'agent_fetch', message: error));
    }
    final agent = response.agent;
    if (agent == null) return null;
    return AgentFetchResult(agent: agent, project: response.project);
  }

  Future<FetchRecentProviderSessionsResponse> fetchRecentProviderSessions({
    String? cwd,
    List<String>? providers,
    String? since,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = FetchRecentProviderSessionsResponse.fromJson(
      await requestSessionMessage(
        FetchRecentProviderSessionsRequest(
          requestId: requestId,
          cwd: cwd,
          providers: providers,
          since: since,
          limit: limit,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Recent provider sessions response requestId mismatch: '
        '${response.requestId}',
      );
    }
    return response;
  }

  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = GetProvidersSnapshotResponse.fromJson(
      await requestSessionMessage(
        GetProvidersSnapshotRequest(requestId: requestId, cwd: cwd).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Providers snapshot response requestId mismatch: '
        '${response.requestId}',
      );
    }
    return response;
  }

  Future<RefreshProvidersSnapshotResponse> refreshProvidersSnapshot({
    String? cwd,
    List<String>? providers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = RefreshProvidersSnapshotResponse.fromJson(
      await requestSessionMessage(
        RefreshProvidersSnapshotRequest(
          requestId: requestId,
          cwd: cwd,
          providers: providers,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Refresh providers snapshot response requestId mismatch: '
        '${response.requestId}',
      );
    }
    return response;
  }

  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = ListCommandsResponse.fromJson(
      await requestSessionMessage(
        ListCommandsRequest(
          agentId: agentId,
          draftConfig: draftConfig,
          requestId: requestId,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'List commands response requestId mismatch: ${response.requestId}',
      );
    }
    if (response.agentId != agentId) {
      throw FormatException(
        'List commands response agentId mismatch: ${response.agentId}',
      );
    }
    return response;
  }

  Future<ListProviderFeaturesResponse> listProviderFeatures({
    required ListCommandsDraftConfig draftConfig,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final requestId = _uuid.v4();
    final response = ListProviderFeaturesResponse.fromJson(
      await requestSessionMessage(
        ListProviderFeaturesRequest(
          draftConfig: draftConfig,
          requestId: requestId,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'List provider features response requestId mismatch: '
        '${response.requestId}',
      );
    }
    if (response.provider != draftConfig.provider) {
      throw FormatException(
        'List provider features response provider mismatch: '
        '${response.provider}',
      );
    }
    return response;
  }

  Future<DirectorySuggestionsResponse> getDirectorySuggestions({
    required String query,
    String? cwd,
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = _uuid.v4();
    final response = DirectorySuggestionsResponse.fromJson(
      await requestSessionMessage(
        DirectorySuggestionsRequest(
          query: query,
          cwd: cwd,
          includeFiles: includeFiles,
          includeDirectories: includeDirectories,
          matchMode: matchMode,
          limit: limit,
          requestId: requestId,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Directory suggestions response requestId mismatch: '
        '${response.requestId}',
      );
    }
    return response;
  }

  Future<ImportAgentStatusResponse> importProviderSession({
    required String providerId,
    required String providerHandleId,
    required String cwd,
    String? workspaceId,
    Map<String, String>? labels,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final requestId = _uuid.v4();
    final response = ImportAgentStatusResponse.fromJson(
      await requestSessionMessage(
        ImportAgentRequest(
          requestId: requestId,
          providerId: providerId,
          providerHandleId: providerHandleId,
          cwd: cwd,
          workspaceId: workspaceId,
          labels: labels,
        ).toJson(),
        timeout: timeout,
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Import agent response requestId mismatch: ${response.requestId}',
      );
    }
    if (!response.succeeded) {
      throw DaemonRpcException(
        RpcError(
          code: 'agent_import_failed',
          message: response.error ?? 'Failed to import agent',
        ),
      );
    }
    return response;
  }

  Future<WorkspaceSetupStatusResponse> fetchWorkspaceSetupStatus(
    String workspaceId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await requestSessionMessage(
      WorkspaceSetupStatusRequest(
        workspaceId: workspaceId,
        requestId: _uuid.v4(),
      ).toJson(),
      timeout: timeout,
    );
    return WorkspaceSetupStatusResponse.fromJson(response);
  }

  /// Sends a Paseo v2 session message that intentionally has no response.
  void sendSessionMessage(Map<String, Object?> message) {
    if (_channel == null) throw StateError('not connected');
    _sendFrame(jsonEncode({'type': 'session', 'message': message}));
  }

  Future<FileSubscription> subscribeFile({
    required String cwd,
    required String path,
    required void Function(FileVersion version) onUpdate,
  }) async {
    final subscriptionId = _uuid.v4();
    final registration = _FileSubscriptionRegistration(
      cwd: cwd,
      path: path,
      onUpdate: onUpdate,
    );
    _fileSubscriptions[subscriptionId] = registration;
    try {
      final initial = await _sendFileSubscribe(subscriptionId, registration);
      return FileSubscription(
        initial: initial,
        unsubscribe: () => _unsubscribeFile(subscriptionId),
      );
    } catch (_) {
      _fileSubscriptions.remove(subscriptionId);
      rethrow;
    }
  }

  Future<FileWriteResult> writeFile({
    required String cwd,
    required String path,
    required String content,
    required String expectedModifiedAt,
    String? expectedRevision,
  }) async {
    final requestId = _uuid.v4();
    final response = await requestSessionMessage({
      'type': 'fs.file.write.request',
      'cwd': cwd,
      'path': path,
      'content': content,
      'expectedModifiedAt': expectedModifiedAt,
      'expectedRevision': ?expectedRevision,
      'requestId': requestId,
    });
    final payload = response['payload'];
    final result = payload is Map ? payload['result'] : null;
    if (result is! Map) {
      throw const FormatException('Invalid file write response');
    }
    return FileWriteResult.fromJson(Map<String, Object?>.from(result));
  }

  Future<FileVersion> _sendFileSubscribe(
    String subscriptionId,
    _FileSubscriptionRegistration registration,
  ) async {
    final requestId = _uuid.v4();
    final response = await requestSessionMessage({
      'type': 'fs.file.subscribe.request',
      'cwd': registration.cwd,
      'path': registration.path,
      'subscriptionId': subscriptionId,
      'requestId': requestId,
    });
    final payload = response['payload'];
    final initial = payload is Map ? payload['initial'] : null;
    if (initial is! Map) {
      throw const FormatException('Invalid file subscribe response');
    }
    return FileVersion.fromJson(Map<String, Object?>.from(initial));
  }

  Future<void> _unsubscribeFile(String subscriptionId) async {
    if (_fileSubscriptions.remove(subscriptionId) == null) return;
    if (_channel == null) return;
    try {
      await requestSessionMessage({
        'type': 'fs.file.unsubscribe.request',
        'subscriptionId': subscriptionId,
        'requestId': _uuid.v4(),
      });
    } catch (_) {
      // The local subscription is already gone; disconnect races are benign.
    }
  }

  Future<void> _resubscribeFiles() async {
    for (final entry in _fileSubscriptions.entries.toList(growable: false)) {
      if (_channel == null || !_fileSubscriptions.containsKey(entry.key)) {
        return;
      }
      try {
        final initial = await _sendFileSubscribe(entry.key, entry.value);
        if (_fileSubscriptions[entry.key] == entry.value) {
          entry.value.onUpdate(initial);
        }
      } catch (_) {
        // The reconnect loop remains usable; a later reconnect retries.
      }
    }
  }

  Future<MutableDaemonConfig> getDaemonConfig({
    Duration timeout = const Duration(seconds: 30),
  }) => _requestDaemonConfig(
    (requestId) => GetDaemonConfigRequest(requestId: requestId).toJson(),
    timeout: timeout,
  );

  Future<MutableDaemonConfig> patchDaemonConfig(
    MutableDaemonConfigPatch patch, {
    Duration timeout = const Duration(seconds: 30),
  }) => _requestDaemonConfig(
    (requestId) =>
        SetDaemonConfigRequest(requestId: requestId, config: patch).toJson(),
    timeout: timeout,
  );

  Future<MutableDaemonConfig> _requestDaemonConfig(
    Map<String, Object?> Function(String requestId) buildMessage, {
    required Duration timeout,
  }) async {
    final channel = _channel;
    if (channel == null) throw StateError('not connected');
    final requestId = _uuid.v4();
    final completer = Completer<DaemonConfigResponse>();
    _daemonConfigPending[requestId] = completer;
    _sendFrame(
      jsonEncode({'type': 'session', 'message': buildMessage(requestId)}),
    );
    final response = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _daemonConfigPending.remove(requestId);
        throw TimeoutException('no daemon config response');
      },
    );
    return response.config;
  }

  Future<String> getDiagnostics({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final channel = _channel;
    if (channel == null) throw StateError('not connected');
    final requestId = _uuid.v4();
    final completer = Completer<DiagnosticsResponse>();
    _diagnosticsPending[requestId] = completer;
    _sendFrame(
      jsonEncode({
        'type': 'session',
        'message': DiagnosticsRequest(requestId: requestId).toJson(),
      }),
    );
    final response = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _diagnosticsPending.remove(requestId);
        throw TimeoutException('no diagnostics response');
      },
    );
    return response.diagnostic;
  }

  /// Sends a binary terminal frame (input/resize) to the daemon.
  void sendTerminalFrame(TerminalFrame frame) {
    _sendFrame(frame.encode());
  }

  void _sendFrame(Object frame) {
    final encrypted = _relayE2eeChannel;
    if (encrypted != null) {
      encrypted.send(frame);
    } else {
      _channel?.sink.add(frame);
    }
  }

  void _onFrame(dynamic frame) {
    // Paseo's relay crypto returns valid UTF-8 plaintext as a String even when
    // the sender supplied a binary frame. Attempt binary demux before JSON for
    // both text and byte transports so terminal frames containing only UTF-8
    // bytes are not discarded.
    final frameBytes = switch (frame) {
      String() => Uint8List.fromList(utf8.encode(frame)),
      Uint8List() => frame,
      List<int>() => Uint8List.fromList(frame),
      _ => null,
    };
    if (frameBytes != null) {
      final decoded = TerminalFrame.decode(frameBytes);
      if (decoded != null) {
        _terminalFrames.add(decoded);
        return;
      }
    }
    if (frame is! String) {
      return;
    }
    final Map<String, Object?> envelope;
    try {
      envelope = (jsonDecode(frame) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    if (envelope['status'] == 'server_info') {
      try {
        final info = ServerInfoStatus.fromJson(envelope);
        serverInfo = info;
        final pending = _serverInfoPending;
        if (pending != null && !pending.isCompleted) {
          pending.complete(info);
        } else if (_current == DaemonConnectionState.connected) {
          serverInfo = info;
          _serverInfoUpdates.add(info);
        }
      } catch (error, stack) {
        final pending = _serverInfoPending;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error, stack);
        }
      }
      return;
    }
    final message = switch (envelope) {
      {'type': 'session', 'message': final Map value} =>
        value.cast<String, Object?>(),
      _ => envelope,
    };
    final nativePayload = message['payload'];
    final nativeRequestId = switch (nativePayload) {
      Map() => nativePayload['requestId'],
      _ => message['requestId'],
    };
    if (nativeRequestId is String) {
      final pending = _sessionPending.remove(nativeRequestId);
      if (pending != null) {
        if (message['type'] == 'rpc_error') {
          final errorPayload = nativePayload is Map
              ? Map<String, Object?>.from(nativePayload)
              : const <String, Object?>{};
          pending.completeError(
            DaemonRpcException(
              RpcError(
                code: errorPayload['code']?.toString() ?? 'unknown',
                message:
                    errorPayload['error']?.toString() ??
                    'Session request failed',
              ),
            ),
          );
        } else {
          pending.complete(message);
        }
        return;
      }
    }
    if (message['type'] == 'status' && message['message'] is Map) {
      final status = (message['message'] as Map).cast<String, Object?>();
      if (status['status'] == 'daemon_config_changed') {
        try {
          _daemonConfigChanges.add(DaemonConfigChangedStatus.fromJson(status));
        } catch (_) {}
      }
      return;
    }
    if (message['type'] == 'get_daemon_config_response' ||
        message['type'] == 'set_daemon_config_response') {
      try {
        final response = DaemonConfigResponse.fromJson(message);
        _daemonConfigPending.remove(response.requestId)?.complete(response);
      } catch (_) {}
      return;
    }
    if (message['type'] == DiagnosticsResponse.type) {
      try {
        final response = DiagnosticsResponse.fromJson(message);
        _diagnosticsPending.remove(response.requestId)?.complete(response);
      } catch (_) {}
      return;
    }
    if (message['type'] == TerminalStreamExit.type &&
        message['payload'] is Map) {
      try {
        final event = TerminalStreamExit.fromJson(message);
        _events.add(
          RpcEvent(
            type: TerminalStreamExit.type,
            payload: {'terminalId': event.terminalId},
          ),
        );
      } catch (_) {}
      return;
    }
    if (message['type'] == WorkspaceSetupProgress.type) {
      try {
        _workspaceSetupProgress.add(WorkspaceSetupProgress.fromJson(message));
      } catch (_) {}
      return;
    }
    if (message['type'] == ProvidersSnapshotUpdate.type) {
      try {
        _providersSnapshotUpdates.add(
          ProvidersSnapshotUpdate.fromJson(message),
        );
      } catch (_) {}
      return;
    }
    if (message['type'] == 'agent_stream') {
      try {
        _agentStreamEvents.add(PaseoAgentStreamCodec.decode(message));
      } catch (_) {}
      return;
    }
    if (const {
      'agent_update',
      'agent_deleted',
      'agent_archived',
      'workspace_update',
      'project.update',
    }.contains(message['type'])) {
      try {
        _directoryUpdateEvents.add(DirectoryUpdateEvent.fromJson(message));
      } catch (_) {}
      return;
    }
    if (message['type'] == 'fs.file.update' && nativePayload is Map) {
      final subscriptionId = nativePayload['subscriptionId'];
      final version = nativePayload['version'];
      if (subscriptionId is String && version is Map) {
        try {
          _fileSubscriptions[subscriptionId]?.onUpdate(
            FileVersion.fromJson(Map<String, Object?>.from(version)),
          );
        } catch (_) {}
      }
      return;
    }
    final RpcFrame decoded;
    try {
      decoded = RpcFrame.fromJson(message);
    } catch (_) {
      return;
    }
    switch (decoded) {
      case RpcResponse():
        _pending.remove(decoded.requestId)?.complete(decoded);
      case RpcEvent():
        _events.add(decoded);
      case RpcRequest():
        break; // daemon never sends requests in the MVP
    }
  }

  void _onClosed() {
    _channel = null;
    _relayE2eeChannel?.transportClosed();
    _relayE2eeChannel = null;
    serverInfo = null;
    for (final pending in _pending.values) {
      pending.completeError(StateError('connection closed'));
    }
    _pending.clear();
    for (final pending in _sessionPending.values) {
      pending.completeError(StateError('connection closed'));
    }
    _sessionPending.clear();
    for (final pending in _daemonConfigPending.values) {
      pending.completeError(StateError('connection closed'));
    }
    _daemonConfigPending.clear();
    for (final pending in _diagnosticsPending.values) {
      pending.completeError(StateError('connection closed'));
    }
    _diagnosticsPending.clear();
    final serverInfoPending = _serverInfoPending;
    _serverInfoPending = null;
    if (serverInfoPending != null && !serverInfoPending.isCompleted) {
      serverInfoPending.completeError(StateError('connection closed'));
    }
    if (_disposed) return;
    // A version-rejected connection must not enter the reconnect loop.
    if (_current == DaemonConnectionState.versionMismatch) return;
    _setState(DaemonConnectionState.disconnected);
    final delay = Duration(seconds: _retrySeconds);
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
    Timer(delay, connect);
  }

  void _setState(DaemonConnectionState state) {
    _current = state;
    _state.add(state);
  }

  void dispose() {
    _disposed = true;
    _fileSubscriptions.clear();
    final encrypted = _relayE2eeChannel;
    if (encrypted != null) {
      encrypted.close();
    } else {
      _channel?.sink.close(1000);
    }
    _events.close();
    _agentStreamEvents.close();
    _directoryUpdateEvents.close();
    _workspaceSetupProgress.close();
    _providersSnapshotUpdates.close();
    _serverInfoUpdates.close();
    _daemonConfigChanges.close();
    _terminalFrames.close();
    _state.close();
  }
}

final class FileSubscription {
  const FileSubscription({required this.initial, required this.unsubscribe});

  final FileVersion initial;
  final Future<void> Function() unsubscribe;
}

final class _FileSubscriptionRegistration {
  const _FileSubscriptionRegistration({
    required this.cwd,
    required this.path,
    required this.onUpdate,
  });

  final String cwd;
  final String path;
  final void Function(FileVersion version) onUpdate;
}

final class RelayE2eeOptions {
  const RelayE2eeOptions({required this.daemonPublicKeyB64});

  final String daemonPublicKeyB64;
}

class DaemonRpcException implements Exception {
  DaemonRpcException(this.error);
  final RpcError error;

  @override
  String toString() => error.toString();
}
