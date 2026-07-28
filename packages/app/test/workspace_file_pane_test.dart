import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/workspace_file_pane.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDaemonClient extends DaemonClient {
  _FakeDaemonClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'fake',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {'workspaceFileEditing': true},
    );
  }

  String kind = 'text';
  String? content = 'first\nsecond\nthird';
  int size = 18;
  Object? error;
  int requestCount = 0;
  final writes = <Map<String, Object?>>[];
  void Function(FileVersion version)? onFileUpdate;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Stream<TerminalFrame> get terminalFrames => const Stream.empty();

  @override
  Future<FileSubscription> subscribeFile({
    required String cwd,
    required String path,
    required void Function(FileVersion version) onUpdate,
  }) async {
    onFileUpdate = onUpdate;
    return FileSubscription(
      initial: ReadyFileVersion(
        cwd: cwd,
        path: path,
        size: size,
        modifiedAt: '2026-07-27T00:00:00.000Z',
        revision: 'revision',
      ),
      unsubscribe: () async {},
    );
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requestCount++;
    if (message['type'] == 'fs.file.subscribe.request') {
      return {
        'type': 'fs.file.subscribe.response',
        'payload': {
          'requestId': message['requestId'],
          'subscriptionId': message['subscriptionId'],
          'initial': {
            'status': 'ready',
            'cwd': r'C:\repo',
            'path': message['path'],
            'size': size,
            'modifiedAt': '2026-07-27T00:00:00.000Z',
            'revision': 'revision',
          },
        },
      };
    }
    if (message['type'] == 'fs.file.unsubscribe.request') {
      return {
        'type': 'fs.file.unsubscribe.response',
        'payload': {
          'requestId': message['requestId'],
          'subscriptionId': message['subscriptionId'],
        },
      };
    }
    if (message['type'] == 'fs.file.write.request') {
      writes.add(message);
      return {
        'type': 'fs.file.write.response',
        'payload': {
          'requestId': message['requestId'],
          'result': {
            'status': 'written',
            'size': (message['content']! as String).length,
            'modifiedAt': '2026-07-27T00:00:01.000Z',
            'revision': 'revision-2',
          },
        },
      };
    }
    return {
      'type': 'file_explorer_response',
      'payload': {
        'file': {
          'path': message['path'],
          'kind': kind,
          'size': size,
          'mimeType': kind == 'image' ? 'image/png' : 'text/plain',
          'content': content,
          'modifiedAt': '2026-07-27T00:00:00.000Z',
          'revision': 'revision',
        },
        'error': error,
      },
    };
  }

  @override
  void sendSessionMessage(Map<String, Object?> message) {}

  @override
  void sendTerminalFrame(TerminalFrame frame) {}
}

Future<void> _pumpPane(
  WidgetTester tester,
  _FakeDaemonClient client, {
  WorkspaceFileLocation location = const WorkspaceFileLocation(
    path: 'lib/main.dart',
    lineStart: 2,
    lineEnd: 3,
  ),
  int navigationRevision = 0,
  VoidCallback? onClose,
  ValueChanged<bool>? onModifiedChanged,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [daemonClientProvider.overrideWithValue(client)],
      child: FluentApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: WorkspaceFilePane(
            cwd: r'C:\repo',
            location: location,
            navigationRevision: navigationRevision,
            onClose: onClose,
            onModifiedChanged: onModifiedChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('reports dirty and clean transitions for tab retention', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    final transitions = <bool>[];
    await _pumpPane(tester, client, onModifiedChanged: transitions.add);

    await tester.enterText(
      find.byKey(const ValueKey('workspace-file-editor')),
      'changed',
    );
    await tester.pump();
    expect(transitions, contains(true));

    await tester.pump(const Duration(milliseconds: 850));
    await tester.pump();
    expect(transitions.last, isFalse);
  });

  testWidgets('renders text lines, selection, refresh, and close controls', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    var closed = false;
    await _pumpPane(tester, client, onClose: () => closed = true);

    final editor = find.byKey(const ValueKey('workspace-file-editor'));
    expect(editor, findsOneWidget);
    expect(
      tester.widget<TextBox>(editor).controller?.text,
      'first\nsecond\nthird',
    );
    expect(find.text('18 B'), findsWidgets);

    await tester.enterText(editor, 'changed');
    await tester.pump(const Duration(milliseconds: 850));
    await tester.pump();
    expect(client.writes.single['content'], 'changed');

    await tester.tap(find.byIcon(FluentIcons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.requestCount, greaterThanOrEqualTo(3));

    await tester.tap(find.byIcon(FluentIcons.chrome_close));
    await tester.pump(const Duration(milliseconds: 150));
    expect(closed, isTrue);
  });

  testWidgets('renders valid and invalid image previews', (tester) async {
    final client = _FakeDaemonClient()
      ..kind = 'image'
      ..content = base64Encode(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQ'
          'VR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    await _pumpPane(tester, client);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    client.content = 'not-base64';
    await _pumpPane(
      tester,
      client,
      location: const WorkspaceFileLocation(path: 'broken.png'),
    );
    expect(find.text('Image preview unavailable'), findsOneWidget);
  });

  testWidgets('renders binary sizes and daemon errors', (tester) async {
    final client = _FakeDaemonClient()
      ..kind = 'binary'
      ..content = null
      ..size = 2048;
    await _pumpPane(tester, client);
    expect(find.text('Binary preview unavailable'), findsOneWidget);
    expect(find.text('2.0 KB'), findsWidgets);

    client
      ..size = 2 * 1024 * 1024
      ..error = 'permission denied';
    await _pumpPane(
      tester,
      client,
      location: const WorkspaceFileLocation(path: 'secret.bin'),
    );
    expect(find.textContaining('permission denied'), findsOneWidget);
  });

  testWidgets('markdown source editing surfaces live conflicts and overwrite', (
    tester,
  ) async {
    final client = _FakeDaemonClient()
      ..content = '# Hello'
      ..size = 7;
    await _pumpPane(
      tester,
      client,
      location: const WorkspaceFileLocation(path: 'README.md'),
    );

    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);

    await tester.tap(find.text('Source'));
    await tester.pump();
    final editor = find.byKey(const ValueKey('workspace-file-editor'));
    await tester.enterText(editor, '# Mine');
    await tester.pump(const Duration(milliseconds: 100));

    client.onFileUpdate!(
      const ReadyFileVersion(
        cwd: r'C:\repo',
        path: 'README.md',
        size: 10,
        modifiedAt: '2026-07-27T00:00:02.000Z',
        revision: 'external',
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('file-conflict-alert')), findsOneWidget);
    expect(find.text('File changed on disk'), findsOneWidget);

    await tester.tap(find.text('Overwrite'));
    await tester.pump();
    expect(client.writes.single['expectedRevision'], 'external');
    await tester.pump(const Duration(milliseconds: 150));

    await tester.enterText(editor, '# Again');
    client
      ..content = '# Disk'
      ..onFileUpdate!(
        const ReadyFileVersion(
          cwd: r'C:\repo',
          path: 'README.md',
          size: 6,
          modifiedAt: '2026-07-27T00:00:03.000Z',
          revision: 'external-2',
        ),
      );
    await tester.pump();
    await tester.tap(find.text('Reload'));
    await tester.pump();
    expect(find.text('Reload file?'), findsOneWidget);
    await tester.tap(find.text('Reload').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<TextBox>(editor).controller?.text, '# Disk');

    await tester.enterText(editor, '# Local');
    client.onFileUpdate!(
      const MissingFileVersion(cwd: r'C:\repo', path: 'README.md'),
    );
    await tester.pump();
    expect(find.text('File unavailable'), findsOneWidget);
    final overwrite = find.ancestor(
      of: find.text('Overwrite'),
      matching: find.byType(Button),
    );
    expect(tester.widget<Button>(overwrite).onPressed, isNull);
  });

  testWidgets('old daemons retain read-only highlighted file previews', (
    tester,
  ) async {
    final client = _FakeDaemonClient()
      ..serverInfo = const ServerInfoStatus(
        serverId: 'old',
        hostname: 'old',
        version: '0.1.0',
        desktopManaged: false,
      )
      ..content = 'first\n\nthird';
    const location = WorkspaceFileLocation(
      path: 'lib/main.dart',
      lineStart: 2,
      lineEnd: 3,
    );
    await _pumpPane(tester, client, location: location);

    expect(find.byKey(const ValueKey('workspace-file-editor')), findsNothing);
    expect(find.text('first'), findsOneWidget);
    expect(find.text(' '), findsOneWidget);
    expect(find.text('third'), findsOneWidget);

    await _pumpPane(tester, client, location: location, navigationRevision: 1);
    expect(find.text('third'), findsOneWidget);
  });
}
