import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/clone_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('clone traverses the real WebSocket and persists the project', () async {
    final root = Directory.systemTemp.createTempSync('daemon-clone-e2e-');
    addTearDown(() => _deleteDirectoryEventually(root));
    final dataDir = await Directory(p.join(root.path, 'data')).create();
    final target = await Directory(p.join(root.path, 'target')).create();
    final cloneCalls = <Map<String, Object?>>[];
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: dataDir.path),
      dataDir: dataDir.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: const {},
      projectGithubCloneRunner:
          ({
            required cloneUrl,
            required targetPath,
            required cwd,
            required timeout,
            required maxOutputBytes,
          }) async {
            cloneCalls.add({
              'cloneUrl': cloneUrl,
              'targetPath': targetPath,
              'cwd': cwd,
            });
            await File(p.join(targetPath, 'README.md')).writeAsString('cloned');
          },
      log: (_) {},
    );
    addTearDown(handle.stop);

    final output = StringBuffer();
    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          target.path,
          '--protocol',
          'https',
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--json',
        ],
        environment: const {},
        writeOutput: output.write,
      ),
      0,
    );

    final result = jsonDecode(output.toString()) as Map<String, Object?>;
    final checkoutPath = result['checkoutPath']! as String;
    expect(checkoutPath, p.join(target.path, 'repo'));
    expect(
      File(p.join(checkoutPath, 'README.md')).readAsStringSync(),
      'cloned',
    );
    expect(cloneCalls.single['cloneUrl'], 'https://github.com/owner/repo.git');
    expect(cloneCalls.single['cwd'], target.path);
    expect(
      target.listSync().where(
        (entry) => p.basename(entry.path).startsWith('.tinyrack-clone-'),
      ),
      isEmpty,
    );

    final projects = FileBackedProjectRegistry(
      filePath: p.join(dataDir.path, 'projects.json'),
    );
    await projects.initialize();
    final persisted = await projects.list();
    expect(persisted.single.projectId, result['projectId']);
    expect(persisted.single.rootPath, checkoutPath);

    final error = StringBuffer();
    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          target.path,
          '--protocol',
          'ssh',
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--json',
        ],
        environment: const {},
        writeError: error.write,
      ),
      1,
    );
    expect(
      (jsonDecode(error.toString()) as Map)['error'],
      containsPair('code', 'CLONE_FAILED'),
    );
    expect(cloneCalls, hasLength(1));
  });
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on PathAccessException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
