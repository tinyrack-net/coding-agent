import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> _git(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git $args failed: ${result.stderr}');
  }
}

Future<void> _commit(String cwd, String subject) => _git(cwd, [
  '-c',
  'user.name=E2E',
  '-c',
  'user.email=e2e@example.com',
  '-c',
  'commit.gpgsign=false',
  'commit',
  '-am',
  subject,
]);

void main() {
  test('commit history and file diff cross the assembled v2 daemon', () async {
    final temp = Directory.systemTemp.createTempSync('daemon-commits-e2e-');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can retain short-lived git/websocket handles.
      }
    });
    final repo = Directory(p.join(temp.path, 'repo'))..createSync();
    await _git(repo.path, ['init', '-b', 'main']);
    final file = File(p.join(repo.path, 'main.dart'))..writeAsStringSync('a\n');
    await _git(repo.path, ['add', '-A']);
    await _commit(repo.path, 'base');
    await _git(repo.path, ['checkout', '-b', 'feature']);
    file.writeAsStringSync('a\nb\n');
    await _commit(repo.path, 'feature');

    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: p.join(temp.path, '.tinyrack')),
      dataDir: p.join(temp.path, '.data'),
      host: '127.0.0.1',
      port: 0,
      log: (_) {},
    );
    addTearDown(handle.stop);
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'commits-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    final info = await frames.firstWhere(
      (frame) => frame['status'] == 'server_info',
    );
    expect(
      info['features'],
      allOf(
        containsPair('commitsList', true),
        containsPair('commitBaseClassification', true),
      ),
    );

    Future<Map<String, Object?>> request(
      Map<String, Object?> message,
      String responseType,
    ) async {
      final response = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == responseType,
      );
      channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
      return ((await response)['message'] as Map).cast<String, Object?>();
    }

    final listed = CheckoutCommitsListResponse.fromJson(
      await request(
        CheckoutCommitsListRequest(cwd: repo.path, requestId: 'list').toJson(),
        CheckoutCommitsListResponse.type,
      ),
    );
    expect(listed.error, isNull);
    expect(listed.baseRef, 'main');
    final commit = listed.commits.singleWhere(
      (candidate) => candidate.isOnBase == false,
    );
    expect(commit.subject, 'feature');
    expect(commit.files.single.path, 'main.dart');

    final diff = CheckoutCommitFileDiffResponse.fromJson(
      await request(
        CheckoutCommitFileDiffRequest(
          cwd: repo.path,
          sha: commit.sha,
          path: 'main.dart',
          requestId: 'diff',
        ).toJson(),
        CheckoutCommitFileDiffResponse.type,
      ),
    );
    expect(diff.error, isNull);
    expect(diff.file?.path, 'main.dart');
    expect(diff.file?.additions, 1);
  });
}
