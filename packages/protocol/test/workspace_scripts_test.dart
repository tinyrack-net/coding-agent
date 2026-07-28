import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const script = WorkspaceScript(
    scriptName: 'web',
    type: WorkspaceScriptType.service,
    hostname: 'web.localhost',
    port: 4173,
    localProxyUrl: 'http://web.localhost',
    publicProxyUrl: null,
    proxyUrl: 'http://web.localhost',
    lifecycle: WorkspaceScriptLifecycle.running,
    health: WorkspaceScriptHealth.healthy,
    exitCode: null,
    terminalId: 'terminal',
  );

  test('parses all workspace script request variants', () {
    final requests = <WorkspaceScriptRequest>[
      const StartWorkspaceScriptRequest(
        workspaceId: 'workspace',
        scriptName: 'web',
        requestId: 'legacy',
      ),
      const WorkspaceScriptListRequest(
        workspaceId: 'workspace',
        requestId: 'list',
      ),
      const WorkspaceScriptStartRequest(
        workspaceId: 'workspace',
        scriptName: 'web',
        requestId: 'start',
      ),
      const WorkspaceScriptStopRequest(
        workspaceId: 'workspace',
        scriptName: 'web',
        requestId: 'stop',
      ),
    ];
    for (final request in requests) {
      final parsed = WorkspaceScriptRequest.fromJson(request.toJson());
      expect(parsed.runtimeType, request.runtimeType);
      expect(parsed.toJson(), request.toJson());
    }
  });

  test('legacy and management responses round trip exact envelopes', () {
    const legacy = StartWorkspaceScriptResponse(
      requestId: 'legacy',
      workspaceId: 'workspace',
      scriptName: 'web',
      terminalId: 'terminal',
      error: null,
    );
    expect(
      StartWorkspaceScriptResponse.fromJson(legacy.toJson()).toJson(),
      legacy.toJson(),
    );
    for (final type in [
      'workspace.script.list.response',
      'workspace.script.start.response',
      'workspace.script.stop.response',
    ]) {
      final response = WorkspaceScriptOperationResponse(
        type: type,
        requestId: 'request',
        workspaceId: 'workspace',
        scriptName: type.contains('list') ? null : 'web',
        script: type.contains('list') ? null : script,
        scripts: type.contains('list') ? const [script] : null,
        error: null,
      );
      expect(
        WorkspaceScriptOperationResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    }
  });

  test('script status update round trips', () {
    const update = WorkspaceScriptStatusUpdate(
      workspaceId: 'workspace',
      scripts: [script],
    );
    expect(
      WorkspaceScriptStatusUpdate.fromJson(update.toJson()).toJson(),
      update.toJson(),
    );
  });

  test('rejects malformed workspace script boundaries', () {
    expect(
      () => WorkspaceScriptRequest.fromJson({'type': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => WorkspaceScriptRequest.fromJson({
        'type': 'workspace.script.list.request',
        'workspaceId': 1,
        'requestId': 'request',
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceScriptOperationResponse.fromJson({
        'type': 'unknown',
        'payload': {},
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceScriptOperationResponse.fromJson({
        'type': 'workspace.script.list.response',
        'payload': {
          'requestId': 'request',
          'workspaceId': 'workspace',
          'scripts': true,
          'error': null,
        },
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceScriptStatusUpdate.fromJson({
        'type': 'script_status_update',
        'payload': {'workspaceId': 'workspace', 'scripts': true},
      }),
      throwsFormatException,
    );
    expect(
      () => StartWorkspaceScriptResponse.fromJson({
        'type': 'wrong',
        'payload': {},
      }),
      throwsFormatException,
    );
  });
}
