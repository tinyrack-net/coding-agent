import 'dart:io';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/project_config_service.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-project-config-');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'file editor defaults to Tinyrack and reads Paseo compatibility files',
    () async {
      const files = ProjectConfigFile();
      expect(await files.read(root.path), {
        'ok': true,
        'config': null,
        'revision': null,
      });
      final created = await files.write(
        repoRoot: root.path,
        config: {
          'worktree': {'setup': 'install'},
        },
        expectedRevision: null,
      );
      expect(created['ok'], isTrue);
      expect(
        File(p.join(root.path, tinyrackProjectConfigFileName)).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(root.path, tinyrackProjectConfigFileName),
        ).readAsStringSync(),
        endsWith('\n'),
      );

      File(p.join(root.path, tinyrackProjectConfigFileName)).deleteSync();
      File(
        p.join(root.path, paseoProjectConfigFileName),
      ).writeAsStringSync('{"scripts":{"dev":{"command":"run"}}}');
      final compatible = await files.read(root.path);
      expect(compatible['ok'], isTrue);
      expect((compatible['config'] as Map)['scripts'], isNotNull);
      final revision = ProjectConfigRevision.fromJson(
        (compatible['revision'] as Map).cast<String, Object?>(),
      );
      final updated = await files.write(
        repoRoot: root.path,
        config: const {'future': true},
        expectedRevision: revision,
      );
      expect(updated['ok'], isTrue);
      expect(
        File(p.join(root.path, paseoProjectConfigFileName)).readAsStringSync(),
        contains('"future": true'),
      );
    },
  );

  test(
    'file editor reports invalid, stale, and write failure outcomes',
    () async {
      const files = ProjectConfigFile();
      final config = File(p.join(root.path, tinyrackProjectConfigFileName))
        ..writeAsStringSync('{bad');
      expect((await files.read(root.path))['error'], {
        'code': 'invalid_project_config',
      });
      config.writeAsStringSync('{}');
      final read = await files.read(root.path);
      final revision = ProjectConfigRevision.fromJson(
        (read['revision'] as Map).cast<String, Object?>(),
      );
      config.writeAsStringSync('{"changed":true}');
      final stale = await files.write(
        repoRoot: root.path,
        config: const {},
        expectedRevision: revision,
      );
      expect((stale['error'] as Map)['code'], 'stale_project_config');
      expect((stale['error'] as Map)['currentRevision'], isNotNull);
      expect(
        (await files.write(
          repoRoot: root.path,
          config: {
            'worktree': {
              'servicePorts': {'range': 'bad'},
            },
          },
          expectedRevision: null,
        ))['error'],
        {'code': 'invalid_project_config'},
      );
      expect(
        (await files.write(
          repoRoot: p.join(root.path, 'missing'),
          config: const {},
          expectedRevision: null,
        ))['error'],
        {'code': 'write_failed'},
      );
    },
  );

  test(
    'session restricts reads and writes to active registered roots',
    () async {
      final registry = FileBackedProjectRegistry(
        filePath: p.join(root.path, 'projects.json'),
        projectIdFactory: () => 'project_test',
      );
      await registry.initialize();
      await registry.getOrCreateActiveByRoot(
        rootPath: root.path,
        kind: PersistedProjectKind.nonGit,
        displayName: 'project',
        timestamp: DateTime.utc(2026).toIso8601String(),
      );
      final service = ProjectConfigService(projects: registry);
      final connection = _connection();

      final missing =
          await service.handle(connection, {
                'type': 'read_project_config_request',
                'requestId': 'missing',
                'repoRoot': p.join(root.path, 'other'),
              })
              as Map;
      expect(
        ((missing['payload'] as Map)['error'] as Map)['code'],
        'project_not_found',
      );
      final missingWrite =
          await service.handle(connection, {
                'type': 'write_project_config_request',
                'requestId': 'missing-write',
                'repoRoot': p.join(root.path, 'other'),
                'config': <String, Object?>{},
                'expectedRevision': null,
              })
              as Map;
      expect(
        ((missingWrite['payload'] as Map)['error'] as Map)['code'],
        'project_not_found',
      );

      final written =
          await service.handle(connection, {
                'type': 'write_project_config_request',
                'requestId': 'write',
                'repoRoot': '${root.path}${p.separator}',
                'config': {
                  'worktree': {'teardown': 'stop'},
                },
                'expectedRevision': null,
              })
              as Map;
      final writePayload = written['payload'] as Map;
      expect(writePayload['ok'], isTrue);
      final read =
          await service.handle(connection, {
                'type': 'read_project_config_request',
                'requestId': 'read',
                'repoRoot': root.path,
              })
              as Map;
      expect((read['payload'] as Map)['config'], writePayload['config']);
      expect(await service.handle(connection, {'type': 'unknown'}), isNull);

      final project = (await registry.list()).single;
      await registry.upsert(
        project.copyWith(archivedAt: DateTime.utc(2026, 2).toIso8601String()),
      );
      final archived =
          await service.handle(connection, {
                'type': 'read_project_config_request',
                'requestId': 'archived',
                'repoRoot': root.path,
              })
              as Map;
      expect(
        ((archived['payload'] as Map)['error'] as Map)['code'],
        'project_not_found',
      );
    },
  );
}

Connection _connection() => Connection.external(
  frames: const Stream.empty(),
  send: (_) {},
  close: (_, __) {},
  id: 'project-config-test',
  transport: 'direct',
  externalSessionKey: null,
  relayConnectionId: null,
);
