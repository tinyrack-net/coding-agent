// Exercises the real DaemonClient (the class every other test fakes out)
// against an actual local dart:io WebSocket server, covering what
// daemon_lifecycle_provider_test.dart / daemon_version_gate_test.dart don't:
// connect/hello handshake, request/response correlation, error responses,
// timeouts, binary terminal frames, sendTerminalFrame, disconnect + backoff
// reconnect. isLoopbackHost/shouldRejectHello/versionMismatchMessage are
// already covered by daemon_version_gate_test.dart and are not repeated here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// One accepted server-side connection. [frames] is a broadcast view of the
/// raw socket so tests can attach multiple sequential listeners to it (a raw
/// [WebSocket] only supports a single subscription for its whole lifetime).
class ServerConn {
  ServerConn(this.socket) : frames = socket.asBroadcastStream();

  final WebSocket socket;
  final Stream<dynamic> frames;

  Stream<Map<String, Object?>> get rawJsonFrames => frames
      .where((f) => f is String)
      .map((f) => jsonDecode(f as String) as Map<String, Object?>);

  Stream<Map<String, Object?>> get jsonFrames => rawJsonFrames.map((frame) {
    if (frame['type'] == 'session' && frame['message'] is Map) {
      return (frame['message'] as Map).cast<String, Object?>();
    }
    return frame;
  });

  /// Waits for the next request of [type] and returns its decoded frame.
  Future<Map<String, Object?>> nextRequest(String type) =>
      jsonFrames.firstWhere((f) => f['type'] == type);

  void respond(
    String requestId,
    String responseType,
    Map<String, Object?> payload,
  ) {
    socket.add(
      jsonEncode({
        'type': 'session',
        'message': RpcResponse(
          type: responseType,
          requestId: requestId,
          payload: payload,
        ).toJson(),
      }),
    );
  }

  void fail(String requestId, String responseType, RpcError error) {
    socket.add(
      jsonEncode({
        'type': 'session',
        'message': RpcResponse(
          type: responseType,
          requestId: requestId,
          error: error,
        ).toJson(),
      }),
    );
  }

  void respondNative(
    String type,
    String requestId,
    Map<String, Object?> payload,
  ) {
    socket.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': type,
          'payload': {'requestId': requestId, ...payload},
        },
      }),
    );
  }

  /// Answers the Paseo v2 hello with a matching server_info status.
  Future<Map<String, Object?>> respondToHello(ServerHello hello) async {
    final frame = await rawJsonFrames.firstWhere((f) => f['type'] == 'hello');
    socket.add(
      jsonEncode({
        'status': 'server_info',
        'serverId': 'server-test',
        'hostname': 'test-host',
        'version': hello.daemonVersion,
        'desktopManaged': hello.desktopManaged,
        'capabilities': const <String, Object?>{},
        'features': const <String, bool>{},
      }),
    );
    return frame;
  }
}

/// Minimal local WebSocket test server: hands each accepted connection to
/// [connections] as a [ServerConn] so tests can script the daemon side.
class TestDaemonServer {
  TestDaemonServer._(this._server);

  final HttpServer _server;
  final _sockets = <WebSocket>[];
  final _connections = StreamController<ServerConn>.broadcast();

  Stream<ServerConn> get connections => _connections.stream;
  int get connectionCount => _connectionCount;
  int _connectionCount = 0;

  static Future<TestDaemonServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final daemon = TestDaemonServer._(server);
    unawaited(daemon._serve());
    return daemon;
  }

  Uri get uri => Uri(scheme: 'ws', host: '127.0.0.1', port: _server.port);

  Future<void> _serve() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) =>
            protocols.isEmpty ? null : protocols.first,
      );
      _connectionCount++;
      _sockets.add(socket);
      _connections.add(ServerConn(socket));
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _connections.close();
    await _server.close(force: true);
  }
}

Future<ServerConn> nextConnection(TestDaemonServer server) =>
    server.connections.first;

void main() {
  late TestDaemonServer server;
  late DaemonClient client;

  setUp(() async {
    server = await TestDaemonServer.start();
  });

  tearDown(() async {
    client.dispose();
    await server.close();
  });

  test(
    'connect() performs the hello handshake and reaches connected state',
    () async {
      client = DaemonClient(uri: server.uri);
      final states = <DaemonConnectionState>[];
      final sub = client.connectionState.listen(states.add);

      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      final helloPayload = await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1, pid: 999),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(helloPayload['clientId'], 'coding-agent-app');
      expect(helloPayload['clientType'], 'mobile');
      expect(helloPayload['protocolVersion'], paseoWebSocketProtocolVersion);
      expect(helloPayload['appVersion'], '0.2.0');
      expect(helloPayload['capabilities'], {
        for (final capability in ClientCapabilities.all) capability: true,
      });
      expect(client.currentState, DaemonConnectionState.connected);
      expect(client.serverHello?.daemonVersion, '0.2.0');
      expect(states, contains(DaemonConnectionState.connecting));
      expect(states, contains(DaemonConnectionState.connected));
      await sub.cancel();
    },
  );

  test(
    'request() resolves with the response payload for its requestId',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      unawaited(
        conn.nextRequest('agent.list.request').then((frame) {
          conn.respond(
            frame['requestId'] as String,
            'agent.list.response',
            const {'agents': []},
          );
        }),
      );

      final response = await client.request('agent.list.request', const {});

      expect(response, <String, Object?>{'agents': []});
    },
  );

  test('requestSessionMessage correlates Paseo native responses', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(CheckoutPrStatusRequest.type).then((frame) {
        expect(frame['cwd'], '/repo');
        conn.respondNative(
          CheckoutPrStatusResponse.type,
          frame['requestId'] as String,
          const {
            'cwd': '/repo',
            'status': null,
            'githubFeaturesEnabled': true,
            'authState': null,
            'error': null,
          },
        );
      }),
    );
    final response = await client.requestSessionMessage(
      const CheckoutPrStatusRequest(
        cwd: '/repo',
        requestId: 'native-1',
      ).toJson(),
    );
    expect(response['type'], CheckoutPrStatusResponse.type);
    expect((response['payload'] as Map)['cwd'], '/repo');
  });

  test('reads project config via typed correlated RPC', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(ReadProjectConfigRequest.type).then((frame) {
        expect(frame, {
          'type': 'read_project_config_request',
          'requestId': 'read-project-config-1',
          'repoRoot': '/repo/app',
        });
        conn.respondNative(
          ReadProjectConfigResponse.type,
          frame['requestId'] as String,
          const {
            'repoRoot': '/repo/app',
            'ok': true,
            'config': {
              'worktree': {'setup': 'npm install'},
            },
            'revision': {'mtimeMs': 10, 'size': 20},
          },
        );
      }),
    );

    final response = await client.readProjectConfig(
      '/repo/app',
      requestId: 'read-project-config-1',
    );
    expect(response, isA<ReadProjectConfigSuccess>());
    final success = response as ReadProjectConfigSuccess;
    expect((success.config?['worktree'] as Map)['setup'], 'npm install');
    expect(success.revision?.toJson(), {'mtimeMs': 10, 'size': 20});
  });

  test('writes project config and returns inline stale failures', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(WriteProjectConfigRequest.type).then((frame) {
        expect(frame, {
          'type': 'write_project_config_request',
          'requestId': 'write-project-config-1',
          'repoRoot': '/repo/app',
          'config': {
            'worktree': {
              'setup': ['npm install'],
            },
          },
          'expectedRevision': {'mtimeMs': 10, 'size': 20},
        });
        conn.respondNative(
          WriteProjectConfigResponse.type,
          frame['requestId'] as String,
          const {
            'repoRoot': '/repo/app',
            'ok': false,
            'error': {
              'code': 'stale_project_config',
              'currentRevision': {'mtimeMs': 11, 'size': 21},
            },
          },
        );
      }),
    );

    final response = await client.writeProjectConfig(
      requestId: 'write-project-config-1',
      repoRoot: '/repo/app',
      config: const {
        'worktree': {
          'setup': ['npm install'],
        },
      },
      expectedRevision: const ProjectConfigRevision(mtimeMs: 10, size: 20),
    );
    expect(response, isA<WriteProjectConfigFailure>());
    final error = (response as WriteProjectConfigFailure).error;
    expect(error, isA<ProjectConfigStale>());
    expect((error as ProjectConfigStale).currentRevision?.toJson(), {
      'mtimeMs': 11,
      'size': 21,
    });
  });

  test('requests a project icon via typed correlated RPC', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(ProjectIconRequest.type).then((frame) {
        expect(frame, {
          'type': 'project_icon_request',
          'cwd': '/repo/app',
          'requestId': 'project-icon-1',
        });
        conn.respondNative(
          ProjectIconResponse.type,
          frame['requestId'] as String,
          const {
            'cwd': '/repo/app',
            'icon': {'data': 'PHN2Zy8+', 'mimeType': 'image/svg+xml'},
            'error': null,
          },
        );
      }),
    );

    final response = await client.requestProjectIcon(
      '/repo/app',
      requestId: 'project-icon-1',
    );
    expect(response.icon?.data, 'PHN2Zy8+');
    expect(response.icon?.mimeType, 'image/svg+xml');
  });

  test('requests provider diagnostics via typed correlated RPC', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(ProviderDiagnosticRequest.type).then((frame) {
        expect(frame, {
          'type': 'provider_diagnostic_request',
          'provider': 'codex',
          'requestId': 'provider-diagnostic-1',
        });
        conn.respondNative(
          ProviderDiagnosticResponse.type,
          frame['requestId'] as String,
          const {
            'provider': 'codex',
            'diagnostic': 'Codex\n  Models: 1\n  Status: Ready',
          },
        );
      }),
    );

    final response = await client.getProviderDiagnostic(
      'codex',
      requestId: 'provider-diagnostic-1',
    );
    expect(response.provider, 'codex');
    expect(response.diagnostic, contains('Status: Ready'));
  });

  test('renames a project via typed correlated RPC', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest('project.rename.request').then((frame) {
        expect(frame['projectId'], 'project-app');
        expect(frame['customName'], 'Web');
        final requestId = frame['requestId'] as String;
        conn.respondNative('project.rename.response', requestId, const {
          'projectId': 'project-app',
          'accepted': true,
          'customName': 'Web',
          'error': null,
        });
      }),
    );

    final response = await client.renameProject('project-app', 'Web');
    expect(response.accepted, isTrue);
    expect(response.customName, 'Web');
  });

  test('typed agent config surfaces notices and rejected changes', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest('set_agent_mode_request').then((frame) {
        expect(frame['agentId'], 'agent-1');
        expect(frame['modeId'], 'full-access');
        conn.respondNative(
          'set_agent_mode_response',
          frame['requestId'] as String,
          const {
            'agentId': 'agent-1',
            'accepted': true,
            'error': null,
            'notice': {
              'type': 'warning',
              'message': 'Permission mode applies next turn',
            },
          },
        );
      }),
    );
    final notice = await client.setAgentMode('agent-1', 'full-access');
    expect(notice?.type, AgentProviderNoticeType.warning);
    expect(notice?.message, 'Permission mode applies next turn');

    unawaited(
      conn.nextRequest('set_agent_thinking_request').then((frame) {
        conn.respondNative(
          'set_agent_thinking_response',
          frame['requestId'] as String,
          const {
            'agentId': 'agent-1',
            'accepted': false,
            'error': 'unsupported effort',
          },
        );
      }),
    );
    await expectLater(
      client.setAgentThinkingOption('agent-1', 'max'),
      throwsA(
        isA<DaemonRpcException>().having(
          (error) => error.error.message,
          'message',
          'unsupported effort',
        ),
      ),
    );
  });

  test('removeProject sends, correlates, and surfaces rejection', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest('project.remove.request').then((frame) {
        expect(frame['projectId'], 'project-1');
        conn.respondNative(
          'project.remove.response',
          frame['requestId'] as String,
          const {
            'projectId': 'project-1',
            'accepted': true,
            'removedWorkspaceIds': ['workspace-1'],
            'error': null,
          },
        );
      }),
    );
    final removed = await client.removeProject('project-1');
    expect(removed.removedWorkspaceIds, ['workspace-1']);

    unawaited(
      conn.nextRequest('project.remove.request').then((frame) {
        conn.respondNative(
          'project.remove.response',
          frame['requestId'] as String,
          const {
            'projectId': 'project-1',
            'accepted': false,
            'removedWorkspaceIds': [],
            'error': 'worktree archive failed',
          },
        );
      }),
    );
    await expectLater(
      client.removeProject('project-1'),
      throwsA(
        isA<DaemonRpcException>().having(
          (error) => error.error.message,
          'message',
          'worktree archive failed',
        ),
      ),
    );
  });

  test(
    'listProviderFeatures sends and validates the typed draft query',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      unawaited(
        conn.nextRequest(ListProviderFeaturesRequest.type).then((frame) {
          expect((frame['draftConfig'] as Map)['provider'], 'codex');
          expect((frame['draftConfig'] as Map)['model'], 'gpt-5.4');
          conn.respondNative(
            ListProviderFeaturesResponse.type,
            frame['requestId'] as String,
            {
              'provider': 'codex',
              'features': [
                {
                  'type': 'toggle',
                  'id': 'fast_mode',
                  'label': 'Fast',
                  'value': false,
                },
              ],
              'error': null,
              'fetchedAt': 'now',
            },
          );
        }),
      );

      final response = await client.listProviderFeatures(
        draftConfig: const ListCommandsDraftConfig(
          provider: 'codex',
          cwd: '/repo',
          model: 'gpt-5.4',
        ),
      );

      expect(response.provider, 'codex');
      expect(response.features, hasLength(1));
      expect(response.features!.single, isA<AgentFeatureToggle>());
    },
  );

  test(
    'cloneGithubProject sends and validates the typed clone request',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      unawaited(
        conn.nextRequest(ProjectGithubCloneRequest.type).then((frame) {
          expect(frame['repo'], 'tinyrack/coding-agent');
          expect(frame['cloneProtocol'], 'ssh');
          expect(frame['targetDirectory'], r'C:\src');
          conn.respondNative(
            ProjectGithubCloneResponse.type,
            frame['requestId'] as String,
            {
              'repo': 'tinyrack/coding-agent',
              'checkoutPath': r'C:\src\coding-agent',
              'project': {
                'projectId': 'project-1',
                'projectDisplayName': 'coding-agent',
                'projectRootPath': r'C:\src\coding-agent',
                'projectKind': 'git',
              },
              'error': null,
            },
          );
        }),
      );

      final response = await client.cloneGithubProject(
        repo: 'tinyrack/coding-agent',
        cloneProtocol: ProjectGithubCloneProtocol.ssh,
        targetDirectory: r'C:\src',
      );

      expect(response.repo, 'tinyrack/coding-agent');
      expect(response.project?.projectId, 'project-1');
    },
  );

  test('fetchAgentTimeline sends and parses the typed Paseo page', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(FetchAgentTimelineRequest.type).then((frame) {
        expect(frame['agentId'], 'agent-1');
        expect(frame['direction'], 'before');
        expect(frame['cursor'], {'epoch': '9', 'seq': 41});
        expect(frame['limit'], agentTimelineFetchPageSize);
        expect(frame['projection'], 'projected');
        conn.respondNative(
          AgentTimelinePage.responseType,
          frame['requestId'] as String,
          {
            'agentId': 'agent-1',
            'agent': null,
            'direction': 'before',
            'projection': 'projected',
            'epoch': '9',
            'reset': false,
            'staleCursor': false,
            'gap': false,
            'window': {'minSeq': 1, 'maxSeq': 80, 'nextSeq': 81},
            'startCursor': {'epoch': '9', 'seq': 1},
            'endCursor': {'epoch': '9', 'seq': 40},
            'hasOlder': false,
            'hasNewer': true,
            'entries': [
              {
                'provider': 'codex',
                'item': {
                  'type': 'assistant_message',
                  'messageId': 'answer',
                  'text': 'done',
                },
                'timestamp': '2026-07-28T00:00:00.000Z',
                'seqStart': 40,
                'seqEnd': 40,
                'sourceSeqRanges': [
                  {'startSeq': 40, 'endSeq': 40},
                ],
                'collapsed': <Object?>[],
              },
            ],
            'error': null,
          },
        );
      }),
    );

    final page = await client.fetchAgentTimeline(
      agentId: 'agent-1',
      direction: AgentTimelineDirection.before,
      cursor: const AgentTimelineCursor(epoch: '9', seq: 41),
    );
    expect(page.cursorRange?.startSeq, 1);
    expect(page.cursorRange?.endSeq, 40);
    expect(page.entries.single.item.id, 'answer');
  });

  test('fetchAgents sends and correlates the native directory page', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(FetchAgentsRequest.type).then((frame) {
        expect(frame['scope'], 'active');
        expect(frame['page'], {'limit': 40, 'cursor': '40'});
        expect(frame['subscribe'], isEmpty);
        expect(frame['sort'], [
          {'key': 'updated_at', 'direction': 'desc'},
        ]);
        conn.respondNative(
          FetchAgentsResponse.type,
          frame['requestId'] as String,
          {
            'subscriptionId': 'subscription-1',
            'entries': [
              {
                'agent': PaseoAgentSnapshotCodec.encode(
                  const AgentSummary(
                    agentId: 'agent-1',
                    title: 'Agent',
                    cwd: '/repo',
                    provider: 'codex',
                    model: 'gpt-5',
                    mode: AgentMode.normal,
                    runState: AgentRunState.idle,
                    createdAtMs: 1000,
                  ),
                ),
                'project': {
                  'projectKey': '/repo',
                  'projectName': 'repo',
                  'checkout': <String, Object?>{},
                },
              },
            ],
            'pageInfo': {
              'nextCursor': null,
              'prevCursor': '0',
              'hasMore': false,
            },
          },
        );
      }),
    );

    final response = await client.fetchAgents(
      sort: const [
        AgentDirectorySort(
          key: AgentDirectorySortKey.updatedAt,
          direction: AgentDirectorySortDirection.desc,
        ),
      ],
      limit: 40,
      cursor: '40',
      subscribe: true,
    );
    expect(response.subscriptionId, 'subscription-1');
    expect(response.entries.single.agent.agentId, 'agent-1');
  });

  test('fetchAgentHistory sends and parses archived directory pages', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(FetchAgentHistoryRequest.type).then((frame) {
        expect(frame.containsKey('scope'), isFalse);
        expect(frame['filter'], {
          'statuses': ['closed'],
          'includeArchived': true,
        });
        expect(frame['page'], {'limit': 20, 'cursor': 'history-cursor'});
        conn.respondNative(
          FetchAgentHistoryResponse.type,
          frame['requestId'] as String,
          {
            'entries': <Object?>[],
            'pageInfo': {
              'nextCursor': null,
              'prevCursor': 'history-cursor',
              'hasMore': false,
            },
          },
        );
      }),
    );

    final response = await client.fetchAgentHistory(
      filter: const AgentDirectoryFilter(
        statuses: ['closed'],
        includeArchived: true,
      ),
      limit: 20,
      cursor: 'history-cursor',
    );
    expect(response.entries, isEmpty);
    expect(response.pageInfo.prevCursor, 'history-cursor');
  });

  test(
    'fetchAgent returns detail placement and surfaces server errors',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      unawaited(
        conn.nextRequest(FetchAgentRequest.type).then((frame) {
          expect(frame['agentId'], 'Archived title');
          conn.respondNative(
            FetchAgentResponse.type,
            frame['requestId'] as String,
            {
              'agent': PaseoAgentSnapshotCodec.encode(
                const AgentSummary(
                  agentId: 'archived-1',
                  title: 'Archived title',
                  cwd: '/repo',
                  provider: 'codex',
                  model: 'gpt-5',
                  mode: AgentMode.normal,
                  runState: AgentRunState.closed,
                  createdAtMs: 1,
                  archivedAt: '2026-07-28T00:00:00.000Z',
                ),
              ),
              'project': {'projectKey': '/repo'},
              'error': null,
            },
          );
        }),
      );
      final result = await client.fetchAgent('Archived title');
      expect(result?.agent.agentId, 'archived-1');
      expect(result?.project, {'projectKey': '/repo'});

      unawaited(
        conn.nextRequest(FetchAgentRequest.type).then((frame) {
          conn.respondNative(
            FetchAgentResponse.type,
            frame['requestId'] as String,
            {
              'agent': null,
              'project': null,
              'error': 'Agent not found: missing',
            },
          );
        }),
      );
      await expectLater(
        client.fetchAgent('missing'),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'Agent not found: missing',
          ),
        ),
      );
    },
  );

  test(
    'workspace setup status and live progress use typed contracts',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      const detail = WorkspaceSetupDetail(
        worktreePath: '/repo/feature',
        branchName: 'feature',
        log: 'installing',
        commands: [],
      );
      unawaited(
        conn.nextRequest(WorkspaceSetupStatusRequest.type).then((frame) {
          expect(frame['workspaceId'], 'workspace-1');
          conn.respondNative(
            WorkspaceSetupStatusResponse.type,
            frame['requestId'] as String,
            {
              'workspaceId': 'workspace-1',
              'snapshot': const WorkspaceSetupSnapshot(
                status: WorkspaceSetupStatus.running,
                detail: detail,
                error: null,
              ).toJson(),
            },
          );
        }),
      );
      final response = await client.fetchWorkspaceSetupStatus('workspace-1');
      expect(response.snapshot?.detail.log, 'installing');

      final progressFuture = client.workspaceSetupProgress.first;
      conn.socket.add(
        jsonEncode({
          'type': 'session',
          'message': const WorkspaceSetupProgress(
            workspaceId: 'workspace-1',
            snapshot: WorkspaceSetupSnapshot(
              status: WorkspaceSetupStatus.completed,
              detail: detail,
              error: null,
            ),
          ).toJson(),
        }),
      );
      expect(
        (await progressFuture).snapshot.status,
        WorkspaceSetupStatus.completed,
      );
    },
  );

  test('sendSessionMessage emits a native fire-and-forget envelope', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final request = conn.nextRequest('unsubscribe_terminal_request');
    client.sendSessionMessage(const {
      'type': 'unsubscribe_terminal_request',
      'terminalId': 'term-1',
    });
    expect((await request)['terminalId'], 'term-1');
  });

  test(
    'requestSessionMessage validates ids and handles errors/timeouts',
    () async {
      client = DaemonClient(uri: server.uri);
      await expectLater(
        client.requestSessionMessage(const {'type': 'native'}),
        throwsArgumentError,
      );

      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      unawaited(
        conn.nextRequest('native.failure').then((frame) {
          conn.respondNative('rpc_error', frame['requestId'] as String, const {
            'error': 'native failed',
          });
        }),
      );
      await expectLater(
        client.requestSessionMessage(const {
          'type': 'native.failure',
          'requestId': 'native-failure',
        }),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'native failed',
          ),
        ),
      );
      await expectLater(
        client.requestSessionMessage(const {
          'type': 'native.timeout',
          'requestId': 'native-timeout',
        }, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('request() throws DaemonRpcException on an error response', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest('agent.prompt.request').then((frame) {
        conn.fail(
          frame['requestId'] as String,
          'agent.prompt.response',
          const RpcError(code: 'not_found', message: 'no such agent'),
        );
      }),
    );

    await expectLater(
      client.request('agent.prompt.request', const {'agentId': 'missing'}),
      throwsA(
        isA<DaemonRpcException>().having(
          (e) => e.toString(),
          'message',
          contains('no such agent'),
        ),
      ),
    );

    unawaited(
      conn.nextRequest(FetchAgentRequest.type).then((frame) {
        conn.respondNative(
          FetchAgentResponse.type,
          frame['requestId'] as String,
          {'agent': null, 'project': null, 'error': null},
        );
      }),
    );
    expect(await client.fetchAgent('hidden'), isNull);
  });

  test('daemon config get, patch, and change events use v2 messages', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final baseConfig = <String, Object?>{
      'mcp': {'injectIntoAgents': false},
      'enableTerminalAgentHooks': false,
    };
    unawaited(
      conn.nextRequest('get_daemon_config_request').then((frame) {
        conn.respondNative(
          'get_daemon_config_response',
          frame['requestId'] as String,
          {'config': baseConfig},
        );
      }),
    );
    expect((await client.getDaemonConfig()).enableTerminalAgentHooks, isFalse);

    unawaited(
      conn.nextRequest('set_daemon_config_request').then((frame) {
        expect((frame['config'] as Map)['enableTerminalAgentHooks'], isTrue);
        conn.respondNative(
          'set_daemon_config_response',
          frame['requestId'] as String,
          {
            'config': {...baseConfig, 'enableTerminalAgentHooks': true},
          },
        );
      }),
    );
    expect(
      (await client.patchDaemonConfig(
        const MutableDaemonConfigPatch(enableTerminalAgentHooks: true),
      )).enableTerminalAgentHooks,
      isTrue,
    );

    final changedFuture = client.daemonConfigChanges.first;
    conn.socket.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'status',
          'message': {
            'status': 'daemon_config_changed',
            'config': {...baseConfig, 'enableTerminalAgentHooks': true},
          },
        },
      }),
    );
    expect((await changedFuture).config.enableTerminalAgentHooks, isTrue);
  });

  test(
    'daemon config requests time out and fail when the socket closes',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await expectLater(
        client.getDaemonConfig(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );

      final requestReceived = conn.nextRequest('get_daemon_config_request');
      final pendingFailure = expectLater(
        client.getDaemonConfig(),
        throwsA(isA<StateError>()),
      );
      await requestReceived;
      await conn.socket.close();
      await pendingFailure;
    },
  );

  test('diagnostics uses the native Paseo response envelope', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(
      conn.nextRequest(DiagnosticsRequest.type).then((frame) {
        conn.respondNative(
          DiagnosticsResponse.type,
          frame['requestId'] as String,
          const {'diagnostic': 'Tinyrack diagnostics\n  PID: 1'},
        );
      }),
    );
    expect(await client.getDiagnostics(), contains('PID: 1'));
  });

  test('diagnostics rejects disconnected and times out', () async {
    client = DaemonClient(uri: server.uri);
    await expectLater(client.getDiagnostics(), throwsStateError);

    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(
      client.getDiagnostics(timeout: const Duration(milliseconds: 10)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('v2 auth uses the Tinyrack bearer subprotocol', () async {
    client = DaemonClient(uri: server.uri, token: 'shared-secret');
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(conn.socket.protocol, 'tinyrack.bearer.shared-secret');
    expect(client.currentState, DaemonConnectionState.connected);
  });

  test('request() times out when the daemon never responds', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(
      client.request(
        'agent.list.request',
        const {},
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('request() throws StateError before a connection exists', () async {
    client = DaemonClient(uri: server.uri);

    await expectLater(
      client.request('agent.list.request', const {}),
      throwsA(isA<StateError>()),
    );
  });

  test('daemon config requests reject before a connection exists', () async {
    client = DaemonClient(uri: server.uri);

    await expectLater(client.getDaemonConfig(), throwsA(isA<StateError>()));
  });

  test('terminal frames: binary output from the daemon is decoded and '
      'exposed via terminalFrames', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final framesFuture = client.terminalFrames.first;
    final frame = TerminalFrame(
      opcode: TerminalOpcode.output,
      slotId: 7,
      payload: Uint8List.fromList(utf8.encode('hello from daemon')),
    );
    conn.socket.add(frame.encode());

    final decoded = await framesFuture;
    expect(decoded.opcode, TerminalOpcode.output);
    expect(decoded.slotId, 7);
    expect(utf8.decode(decoded.payload), 'hello from daemon');
  });

  test(
    'sendTerminalFrame() writes the encoded binary frame to the socket',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final received = conn.frames.firstWhere((f) => f is List<int>);
      client.sendTerminalFrame(
        TerminalFrame(
          opcode: TerminalOpcode.input,
          slotId: 3,
          payload: Uint8List.fromList(utf8.encode('ls')),
        ),
      );

      final bytes = await received as List<int>;
      final decoded = TerminalFrame.decode(Uint8List.fromList(bytes));
      expect(decoded!.opcode, TerminalOpcode.input);
      expect(decoded.slotId, 3);
      expect(utf8.decode(decoded.payload), 'ls');
    },
  );

  test('events: an unsolicited RpcEvent frame is exposed via events', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final eventFuture = client.events.first;
    conn.socket.add(
      jsonEncode(
        const RpcEvent(
          type: 'terminal.exited',
          payload: {'terminalId': 't1', 'exitCode': 1},
        ).toJson(),
      ),
    );

    final event = await eventFuture;
    expect(event.type, 'terminal.exited');
    expect(event.payload['exitCode'], 1);
  });

  test('native terminal_stream_exit is normalized onto events', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final eventFuture = client.events.first;
    conn.socket.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'terminal_stream_exit',
          'payload': {'terminalId': 'term-native'},
        },
      }),
    );

    final event = await eventFuture;
    expect(event.type, 'terminal_stream_exit');
    expect(event.payload, {'terminalId': 'term-native'});
  });

  test('native agent_stream is decoded without the legacy adapter', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final eventFuture = client.agentStreamEvents.first;
    conn.socket.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'agent_stream',
          'payload': {
            'agentId': 'agent-native',
            'event': {
              'type': 'timeline',
              'provider': 'codex',
              'item': {
                'type': 'assistant_message',
                'messageId': 'assistant-native',
                'text': 'native',
              },
            },
            'timestamp': '2026-07-28T00:00:00.000Z',
            'seq': 2,
            'epoch': '1',
          },
        },
      }),
    );

    final event = await eventFuture;
    expect(event.agentId, 'agent-native');
    expect(event.epoch, 1);
    expect(event.seq, 2);
    expect(event.item.id, 'assistant-native');
  });

  test('native directory updates are decoded onto a typed stream', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final eventFuture = client.directoryUpdateEvents.first;
    conn.socket.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'agent_update',
          'payload': {
            'kind': 'upsert',
            'agent': PaseoAgentSnapshotCodec.encode(
              const AgentSummary(
                agentId: 'agent-directory',
                title: 'Directory',
                cwd: '/repo',
                provider: 'codex',
                model: 'gpt-5',
                mode: AgentMode.normal,
                runState: AgentRunState.idle,
                createdAtMs: 1000,
              ),
            ),
          },
        },
      }),
    );

    final event = await eventFuture;
    expect(event, isA<AgentUpsertDirectoryEvent>());
    expect(
      (event as AgentUpsertDirectoryEvent).agent.agentId,
      'agent-directory',
    );
  });

  test('disconnect: server closing the socket surfaces disconnected state '
      'and pending requests fail', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.currentState, DaemonConnectionState.connected);

    final pending = client.request('agent.list.request', const {});
    // Attach the failure expectation before yielding control (the socket
    // close below completes `pending` with an error synchronously on its
    // callback; a listener must already be attached or Dart reports it as
    // an unhandled zone error instead of surfacing it through expectLater).
    final pendingExpectation = expectLater(pending, throwsA(isA<StateError>()));
    final disconnected = client.connectionState.firstWhere(
      (s) => s == DaemonConnectionState.disconnected,
    );
    await conn.socket.close();

    await pendingExpectation;
    await disconnected;
    expect(client.currentState, DaemonConnectionState.disconnected);
  });

  test('reconnect: after a disconnect the client retries and can '
      're-handshake on a new socket', () async {
    client = DaemonClient(uri: server.uri);
    final firstConnFuture = nextConnection(server);
    unawaited(client.connect());
    final firstConn = await firstConnFuture;
    await firstConn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final secondConnFuture = nextConnection(server);
    await firstConn.socket.close();
    // Initial backoff is 1s; give the retry timer time to fire and dial in.
    final secondConn = await secondConnFuture.timeout(
      const Duration(seconds: 3),
    );
    await secondConn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(server.connectionCount, 2);
    expect(client.currentState, DaemonConnectionState.connected);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
    'a same-major-version hello on loopback is always accepted '
    '(remote-only version gate is covered by daemon_version_gate_test.dart)',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '9.9.9', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(client.currentState, DaemonConnectionState.connected);
      expect(client.rejectedHello, isNull);
    },
  );

  test('an unsolicited request-shaped frame from the daemon is ignored '
      '(the MVP never expects the daemon to send requests)', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Send a request-shaped frame; the client should just ignore it (no
    // crash, no response sent back, no effect on connection state).
    conn.socket.add(
      jsonEncode(
        const RpcRequest(
          type: 'some.made_up.request',
          requestId: 'req-1',
          payload: {'foo': 'bar'},
        ).toJson(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(client.currentState, DaemonConnectionState.connected);
    // A subsequent real request still resolves normally, proving the client
    // wasn't left in a broken state.
    unawaited(
      conn.nextRequest('agent.list.request').then((frame) {
        conn.respond(
          frame['requestId'] as String,
          'agent.list.response',
          const {'agents': []},
        );
      }),
    );
    final response = await client.request('agent.list.request', const {});
    expect(response, <String, Object?>{'agents': []});
  });

  test(
    'file subscriptions dispatch updates and file writes are typed',
    () async {
      client = DaemonClient(uri: server.uri);
      final connFuture = nextConnection(server);
      unawaited(client.connect());
      final conn = await connFuture;
      await conn.respondToHello(
        const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final versions = <FileVersion>[];
      final subscribeRequest = Completer<Map<String, Object?>>();
      unawaited(
        conn.nextRequest('fs.file.subscribe.request').then((frame) {
          subscribeRequest.complete(frame);
          conn.respondNative(
            'fs.file.subscribe.response',
            frame['requestId'] as String,
            {
              'subscriptionId': frame['subscriptionId'],
              'initial': const ReadyFileVersion(
                cwd: '/repo',
                path: 'a.txt',
                size: 1,
                modifiedAt: '2026-01-01T00:00:00.000Z',
                revision: 'one',
              ).toJson(),
            },
          );
        }),
      );
      final subscription = await client.subscribeFile(
        cwd: '/repo',
        path: 'a.txt',
        onUpdate: versions.add,
      );
      expect(subscription.initial, isA<ReadyFileVersion>());

      final subscribeFrame = await subscribeRequest.future;
      conn.socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'fs.file.update',
            'payload': {
              'subscriptionId': subscribeFrame['subscriptionId'],
              'version': const MissingFileVersion(
                cwd: '/repo',
                path: 'a.txt',
              ).toJson(),
            },
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(versions.single, isA<MissingFileVersion>());

      unawaited(
        conn.nextRequest('fs.file.write.request').then((frame) {
          expect(frame['expectedRevision'], 'one');
          conn.respondNative(
            'fs.file.write.response',
            frame['requestId'] as String,
            {
              'result': const WrittenFileResult(
                modifiedAt: '2026-01-01T00:00:01.000Z',
                size: 2,
                revision: 'two',
              ).toJson(),
            },
          );
        }),
      );
      final result = await client.writeFile(
        cwd: '/repo',
        path: 'a.txt',
        content: 'hi',
        expectedModifiedAt: '2026-01-01T00:00:00.000Z',
        expectedRevision: 'one',
      );
      expect(result, isA<WrittenFileResult>());

      unawaited(
        conn.nextRequest('fs.file.unsubscribe.request').then((frame) {
          conn.respondNative(
            'fs.file.unsubscribe.response',
            frame['requestId'] as String,
            {'subscriptionId': frame['subscriptionId']},
          );
        }),
      );
      await subscription.unsubscribe();
    },
  );

  test('connect() swallows a connection failure and schedules a retry '
      'instead of throwing', () async {
    // Port 0 with no listener: WebSocketChannel.connect's `ready` future
    // rejects, exercising connect()'s catch-and-retry path instead of the
    // hello handshake.
    final unreachable = Uri(scheme: 'ws', host: '127.0.0.1', port: 1);
    client = DaemonClient(uri: unreachable);
    final states = <DaemonConnectionState>[];
    final sub = client.connectionState.listen(states.add);

    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(client.currentState, DaemonConnectionState.disconnected);
    expect(states, contains(DaemonConnectionState.connecting));
    expect(states, contains(DaemonConnectionState.disconnected));
    await sub.cancel();
  });

  test('dispose() closes the socket and stops the reconnect loop', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final secondConnection = nextConnection(server);
    client.dispose();
    await conn.socket.close();

    // No new connection should show up after dispose, even after waiting
    // past the first backoff interval.
    final gotAnother = await secondConnection
        .timeout(const Duration(milliseconds: 1500))
        .then((_) => true, onError: (_) => false);
    expect(gotAnother, isFalse);
  });
}
