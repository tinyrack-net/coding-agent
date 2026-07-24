/// Tests `registerWorkspaceHandlers` end-to-end over a live WebSocket
/// connection, following the same pattern as `ws_server_test.dart`: spin up
/// a real [WsServer] with the workspace RPCs wired in, connect a real
/// [WebSocketChannel], do the hello handshake, then exercise each request.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/git/workspace_rpc.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/store/project_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<String> _git(List<String> args, String cwd) async {
  final result = await Process.run(
    'git',
    ['-c', 'core.quotepath=false', ...args],
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('git $args failed (${result.exitCode}): ${result.stderr}');
  }
  return result.stdout as String;
}

void main() {
  late Directory tempDir;
  late String repo;
  late String dataDir;
  late WsServer server;
  late WebSocketChannel channel;
  late Stream<Map<String, Object?>> frames;
  var nextRequestId = 0;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('workspace_rpc_test_');
    final base = tempDir.resolveSymbolicLinksSync();
    repo = p.join(base, 'myproject');
    dataDir = p.join(base, 'data');
    Directory(repo).createSync(recursive: true);

    await _git(['init', '-b', 'main'], repo);
    File(p.join(repo, 'readme.md')).writeAsStringSync('hello\n');
    await _git(['add', '-A'], repo);
    await _git(
      [
        '-c', 'user.email=test@example.com',
        '-c', 'user.name=Test',
        '-c', 'commit.gpgsign=false',
        'commit', '-m', 'initial',
      ],
      repo,
    );

    final router = RpcRouter();
    registerWorkspaceHandlers(
      router,
      projects: ProjectStore(dataDir: dataDir),
      git: GitService(dataDir: dataDir, runner: const GitRunner()),
    );
    server = WsServer(router: router);
    await server.start(host: '127.0.0.1', port: 0);

    channel =
        WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await channel.ready;
    frames = channel.stream
        .map((f) => jsonDecode(f as String) as Map<String, Object?>)
        .asBroadcastStream();

    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'hello',
      payload: {'clientName': 'test', 'clientVersion': '0.0.1'},
    ).toJson()));
    await frames.first;
  });

  tearDown(() async {
    await channel.sink.close();
    await server.stop();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload,
  ) async {
    final id = 'req-${nextRequestId++}';
    channel.sink.add(jsonEncode(
        RpcRequest(type: type, requestId: id, payload: payload).toJson()));
    return frames.firstWhere((f) => f['requestId'] == id);
  }

  test('project.add registers a project and project.list returns it',
      () async {
    final addResponse = await request(
      MessageTypes.projectAddRequest,
      {'path': repo},
    );
    expect(addResponse['error'], isNull);
    final project = ProjectInfo.fromJson(
        (addResponse['payload'] as Map)['project'] as Map<String, Object?>);
    expect(project.name, 'myproject');
    expect(project.isGitRepo, isTrue);

    final listResponse =
        await request(MessageTypes.projectListRequest, const {});
    final projects = ((listResponse['payload'] as Map)['projects'] as List)
        .cast<Map<String, Object?>>()
        .map(ProjectInfo.fromJson)
        .toList();
    expect(projects, hasLength(1));
    expect(projects.single.name, 'myproject');
  });

  test('project.add rejects a nonexistent directory with not_found',
      () async {
    final response = await request(
      MessageTypes.projectAddRequest,
      {'path': p.join(tempDir.path, 'does-not-exist')},
    );
    expect(response['error'], isNotNull);
    expect(
      (response['error'] as Map)['code'],
      RpcErrorCodes.notFound,
    );
  });

  test('project.add requires a non-empty "path"', () async {
    final response = await request(MessageTypes.projectAddRequest, const {});
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });

  test('worktree.list rejects a missing projectPath directory', () async {
    final response = await request(
      MessageTypes.worktreeListRequest,
      {'projectPath': p.join(tempDir.path, 'missing')},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('worktree.create rejects a missing projectPath directory', () async {
    final response = await request(
      MessageTypes.worktreeCreateRequest,
      {'projectPath': p.join(tempDir.path, 'missing'), 'branch': 'x'},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('worktree.create then worktree.list then worktree.archive '
      'round-trip', () async {
    final createResponse = await request(
      MessageTypes.worktreeCreateRequest,
      {'projectPath': repo, 'branch': 'feature/x'},
    );
    expect(createResponse['error'], isNull);
    final created = WorktreeInfo.fromJson(
        (createResponse['payload'] as Map)['worktree'] as Map<String, Object?>);
    expect(created.branch, 'feature/x');
    expect(Directory(created.path).existsSync(), isTrue);

    final listResponse =
        await request(MessageTypes.worktreeListRequest, {'projectPath': repo});
    final worktrees = ((listResponse['payload'] as Map)['worktrees'] as List)
        .cast<Map<String, Object?>>()
        .map(WorktreeInfo.fromJson)
        .toList();
    expect(worktrees, hasLength(2));

    final archiveResponse = await request(
      MessageTypes.worktreeArchiveRequest,
      {'path': created.path},
    );
    expect(archiveResponse['error'], isNull);
    expect(Directory(created.path).existsSync(), isFalse);
  });

  test('worktree.archive on the main worktree fails with invalid_payload',
      () async {
    final response =
        await request(MessageTypes.worktreeArchiveRequest, {'path': repo});
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });

  test('worktree.archive on an unknown path fails with not_found', () async {
    final response = await request(
      MessageTypes.worktreeArchiveRequest,
      {'path': p.join(tempDir.path, 'nope')},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('worktree.archive without force fails with conflict when dirty, '
      'succeeds with force: true', () async {
    final createResponse = await request(
      MessageTypes.worktreeCreateRequest,
      {'projectPath': repo, 'branch': 'dirty'},
    );
    final created = WorktreeInfo.fromJson(
        (createResponse['payload'] as Map)['worktree'] as Map<String, Object?>);
    File(p.join(created.path, 'readme.md')).writeAsStringSync('changed\n');

    final blocked = await request(
      MessageTypes.worktreeArchiveRequest,
      {'path': created.path},
    );
    expect((blocked['error'] as Map)['code'], RpcErrorCodes.conflict);
    expect(Directory(created.path).existsSync(), isTrue);

    final forced = await request(
      MessageTypes.worktreeArchiveRequest,
      {'path': created.path, 'force': true},
    );
    expect(forced['error'], isNull);
    expect(Directory(created.path).existsSync(), isFalse);
  });

  test('branch.list returns local branches and the current branch',
      () async {
    await _git(['branch', 'feature/y'], repo);
    final response =
        await request(MessageTypes.branchListRequest, {'projectPath': repo});
    expect(response['error'], isNull);
    final parsed = BranchListResponse.fromJson(
        response['payload'] as Map<String, Object?>);
    expect(parsed.currentBranch, 'main');
    expect(parsed.branches, containsAll(['main', 'feature/y']));
  });

  test('branch.list rejects a missing projectPath directory', () async {
    final response = await request(
      MessageTypes.branchListRequest,
      {'projectPath': p.join(tempDir.path, 'missing')},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('worktree.create with baseRef branches off that ref', () async {
    await _git(['branch', 'base-branch'], repo);
    File(p.join(repo, 'readme.md')).writeAsStringSync('advance main\n');
    await _git(
      [
        '-c', 'user.email=test@example.com',
        '-c', 'user.name=Test',
        '-c', 'commit.gpgsign=false',
        'commit', '-am', 'advance main',
      ],
      repo,
    );

    final response = await request(MessageTypes.worktreeCreateRequest, {
      'projectPath': repo,
      'branch': 'off-base',
      'baseRef': 'base-branch',
    });
    expect(response['error'], isNull);
    final created = WorktreeInfo.fromJson(
        (response['payload'] as Map)['worktree'] as Map<String, Object?>);
    final headResult = await Process.run(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: created.path,
    );
    final baseResult = await Process.run(
      'git',
      ['rev-parse', 'base-branch'],
      workingDirectory: repo,
    );
    expect((headResult.stdout as String).trim(), (baseResult.stdout as String).trim());
  });

  test('diff.get without baseRef diffs the working tree', () async {
    File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nchanged\n');
    final response = await request(MessageTypes.diffGetRequest, {'cwd': repo});
    expect(response['error'], isNull);
    final diff =
        DiffResponse.fromJson(response['payload'] as Map<String, Object?>);
    expect(diff.files, hasLength(1));
    expect(diff.files.single.path, 'readme.md');
  });

  test('diff.get rejects a missing cwd directory', () async {
    final response = await request(
      MessageTypes.diffGetRequest,
      {'cwd': p.join(tempDir.path, 'nope')},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('diff.get rejects a non-string baseRef', () async {
    final response = await request(
      MessageTypes.diffGetRequest,
      {'cwd': repo, 'baseRef': 42},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });

  test('diff.get with a bad baseRef surfaces a git failure as internal',
      () async {
    final response = await request(
      MessageTypes.diffGetRequest,
      {'cwd': repo, 'baseRef': 'no-such-ref'},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.internal);
  });
}
