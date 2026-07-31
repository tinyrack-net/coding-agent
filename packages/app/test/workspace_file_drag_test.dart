import 'dart:convert';

import 'package:coding_agent_app/attachments/workspace_file_drag.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:coding_agent_app/workspace/workspace_distance_draggable.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ExplorerDaemonClient extends DaemonClient {
  _ExplorerDaemonClient() : super(uri: Uri.parse('ws://fake'));

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState => const Stream.empty();

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async => {
    'type': 'file_explorer_response',
    'payload': {
      'requestId': message['requestId'],
      'error': null,
      'directory': {
        'entries': [
          {
            'name': 'app.dart',
            'path': 'lib/app.dart',
            'kind': 'file',
            'size': 42,
          },
          {'name': 'src', 'path': 'src', 'kind': 'directory', 'size': 0},
        ],
      },
    },
  };
}

WorkspaceFileDragPayload _payload() => WorkspaceFileDragPayload(
  serverId: 'server-1',
  workspaceId: 'workspace-1',
  attachment: ComposerWorkspaceFileAttachment(
    path: 'src/app.dart',
    selection: ComposerWorkspaceFileSelection.lineRange(
      startLine: 12,
      endLine: 24,
    ),
  ),
);

void main() {
  test('round-trips Paseo workspace identity and line selection', () {
    final serialized = serializeWorkspaceFileDragPayload(_payload());

    expect(jsonDecode(serialized), {
      'version': 1,
      'serverId': 'server-1',
      'workspaceId': 'workspace-1',
      'attachment': {
        'kind': 'workspace_file',
        'path': 'src/app.dart',
        'selection': {'kind': 'line_range', 'startLine': 12, 'endLine': 24},
      },
    });
    expect(parseWorkspaceFileDragPayload(serialized), _payload());
  });

  test('rejects malformed and invalid payloads without throwing', () {
    expect(parseWorkspaceFileDragPayload('not json'), isNull);
    expect(parseWorkspaceFileDragPayload('null'), isNull);
    expect(
      parseWorkspaceFileDragPayload(
        jsonEncode({
          ..._payload().toJson(),
          'attachment': {
            'kind': 'workspace_file',
            'path': 'src/app.dart',
            'selection': {'kind': 'line_range', 'startLine': 24, 'endLine': 12},
          },
        }),
      ),
      isNull,
    );
    for (final mutation in [
      {'version': 2},
      {'serverId': ''},
      {'workspaceId': ''},
      {
        'attachment': {
          'kind': 'file',
          'path': 'src/app.dart',
          'selection': {'kind': 'whole_file'},
        },
      },
    ]) {
      expect(
        parseWorkspaceFileDragPayload(
          jsonEncode({..._payload().toJson(), ...mutation}),
        ),
        isNull,
      );
    }
  });

  test('resolves only within the originating server and workspace', () {
    final payload = _payload();

    expect(
      resolveWorkspaceFileDrop(
        payload: payload,
        serverId: 'server-1',
        workspaceId: 'workspace-1',
      ),
      payload.attachment,
    );
    expect(
      resolveWorkspaceFileDrop(
        payload: payload,
        serverId: 'server-2',
        workspaceId: 'workspace-1',
      ),
      isNull,
    );
    expect(
      resolveWorkspaceFileDrop(
        payload: payload,
        serverId: 'server-1',
        workspaceId: 'workspace-2',
      ),
      isNull,
    );
  });

  testWidgets('workspace explorer exposes a scoped file drag source', (
    tester,
  ) async {
    final client = _ExplorerDaemonClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [daemonClientProvider.overrideWithValue(client)],
        child: FluentApp(
          home: ScaffoldPage(
            content: SizedBox(
              width: 400,
              height: 600,
              child: WorkspaceExplorer(
                serverId: 'server-1',
                workspaceId: 'workspace-1',
                cwd: '/repo',
                isGit: false,
                onClose: _noop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dragSource = tester
        .widget<WorkspaceDistanceDraggable<WorkspaceFileDragPayload>>(
          find.byKey(const ValueKey('workspace-file-drag-lib/app.dart')),
        );
    expect(dragSource.activationDistance, 8);
    expect(
      dragSource.data,
      WorkspaceFileDragPayload(
        serverId: 'server-1',
        workspaceId: 'workspace-1',
        attachment: ComposerWorkspaceFileAttachment(path: 'lib/app.dart'),
      ),
    );
    expect(find.byKey(const ValueKey('workspace-file-drag-src')), findsNothing);
  });
}

void _noop() {}
