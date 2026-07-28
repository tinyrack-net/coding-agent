/// Manual smoke for M4 wiring: project.add / worktree.create / diff.get over
/// the real WebSocket API against a scratch git repo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  final repo = Directory.systemTemp.createTempSync('smoke-git-');
  final dataDir = Directory.systemTemp.createTempSync('smoke-git-data-');
  Future<void> git(List<String> args) async {
    final r = await Process.run('git', [
      '-c',
      'user.email=smoke@test',
      '-c',
      'user.name=smoke',
      ...args,
    ], workingDirectory: repo.path);
    if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
  }

  File('${repo.path}/a.txt').writeAsStringSync('line1\nline2\n');
  await git(['init', '-b', 'main']);
  await git(['add', '.']);
  await git(['commit', '-m', 'init']);
  File('${repo.path}/a.txt').writeAsStringSync('line1 changed\nline2\n');
  File('${repo.path}/new.txt').writeAsStringSync('untracked\n');

  const port = 6898;
  final daemon = await Process.start(Platform.resolvedExecutable, [
    'run',
    'agent_daemon:daemon',
    '--port',
    '$port',
    '--data-dir',
    dataDir.path,
  ]);
  daemon.stderr.transform(utf8.decoder).listen(stderr.write);
  await Future<void>.delayed(const Duration(seconds: 4));

  var pass = false;
  try {
    pass = await _run(port, repo.path);
  } finally {
    daemon.kill();
    await Process.run('taskkill', ['/T', '/F', '/PID', '${daemon.pid}']);
  }
  stdout.writeln('[smoke] result: ${pass ? 'PASS' : 'FAIL'}');
  exit(pass ? 0 : 1);
}

Future<bool> _run(int port, String repoPath) async {
  final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
  await channel.ready;
  final frames = channel.stream
      .map((f) => jsonDecode(f as String) as Map<String, Object?>)
      .asBroadcastStream();
  var nextId = 0;
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload,
  ) async {
    final id = 'r${nextId++}';
    channel.sink.add(
      jsonEncode(
        RpcRequest(type: type, requestId: id, payload: payload).toJson(),
      ),
    );
    final response = await frames.firstWhere((f) => f['requestId'] == id);
    if (response['error'] != null) {
      throw StateError('rpc error: ${response['error']}');
    }
    return (response['payload'] as Map<String, Object?>?) ?? const {};
  }

  await request(
    MessageTypes.clientHelloRequest,
    const ClientHello(clientName: 'smoke', clientVersion: '0').toJson(),
  );

  final added = await request(MessageTypes.projectAddRequest, {
    'path': repoPath,
  });
  final project = ProjectInfo.fromJson(
    added['project'] as Map<String, Object?>,
  );
  stdout.writeln(
    '[smoke] project added: ${project.name} git=${project.isGitRepo}',
  );

  final wt = await request(MessageTypes.worktreeCreateRequest, {
    'projectPath': repoPath,
    'branch': 'feature-x',
  });
  final worktree = WorktreeInfo.fromJson(
    wt['worktree'] as Map<String, Object?>,
  );
  stdout.writeln(
    '[smoke] worktree: ${worktree.path} branch=${worktree.branch}',
  );

  final listed = await request(MessageTypes.worktreeListRequest, {
    'projectPath': repoPath,
  });
  stdout.writeln('[smoke] worktrees: ${(listed['worktrees'] as List).length}');

  final diff = DiffResponse.fromJson(
    await request(MessageTypes.diffGetRequest, {'cwd': repoPath}),
  );
  for (final file in diff.files) {
    stdout.writeln(
      '[smoke] diff: ${file.status.name} ${file.path} '
      '+${file.additions}/-${file.deletions} hunks=${file.hunks.length}',
    );
  }

  await request(MessageTypes.worktreeArchiveRequest, {'path': worktree.path});
  stdout.writeln('[smoke] worktree archived');

  await channel.sink.close(1000);
  return diff.files.length == 2;
}
