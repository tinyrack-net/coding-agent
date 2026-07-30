import 'dart:io';

import 'package:agent_daemon/src/workspace/project_directory_service.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp(
      'project-directory-service-',
    );
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  test('creates, registers, and returns an empty project directory', () async {
    String? registeredPath;
    final result = await createProjectDirectory(
      parentPath: fixture.path,
      name: 'new-project',
      registerProject: (path) async {
        registeredPath = path;
        return createPersistedProjectRecord(
          projectId: 'project-1',
          rootPath: path,
          kind: PersistedProjectKind.nonGit,
          displayName: 'new-project',
          createdAt: 'now',
          updatedAt: 'now',
        );
      },
    );

    expect(result.directoryPath, p.join(fixture.path, 'new-project'));
    expect(registeredPath, result.directoryPath);
    expect(Directory(result.directoryPath).existsSync(), isTrue);
  });

  test('validates names and reports existing or missing parents', () async {
    for (final name in ['', ' ', '.', '..', 'a/b', r'a\b', ' name']) {
      expect(
        () => validateProjectDirectoryName(name),
        throwsA(
          isA<ProjectDirectoryRequestException>().having(
            (error) => error.code,
            'code',
            ProjectCreateDirectoryErrorCode.invalidName,
          ),
        ),
      );
    }

    await Directory(p.join(fixture.path, 'existing')).create();
    await expectLater(
      createProjectDirectory(
        parentPath: fixture.path,
        name: 'existing',
        registerProject: (_) async => throw UnimplementedError(),
      ),
      throwsA(
        isA<ProjectDirectoryRequestException>().having(
          (error) => error.code,
          'code',
          ProjectCreateDirectoryErrorCode.directoryExists,
        ),
      ),
    );
    await expectLater(
      createProjectDirectory(
        parentPath: p.join(fixture.path, 'missing'),
        name: 'child',
        registerProject: (_) async => throw UnimplementedError(),
      ),
      throwsA(
        isA<ProjectDirectoryRequestException>().having(
          (error) => error.code,
          'code',
          ProjectCreateDirectoryErrorCode.parentDirectoryNotFound,
        ),
      ),
    );
  });

  test('registration failure rolls back the newly-created directory', () async {
    final path = p.join(fixture.path, 'rollback');
    await expectLater(
      createProjectDirectory(
        parentPath: fixture.path,
        name: 'rollback',
        registerProject: (_) async => throw StateError('registry failed'),
      ),
      throwsA(
        isA<ProjectDirectoryRequestException>()
            .having(
              (error) => error.code,
              'code',
              ProjectCreateDirectoryErrorCode.registrationFailed,
            )
            .having((error) => error.directoryPath, 'directoryPath', path),
      ),
    );
    expect(Directory(path).existsSync(), isFalse);
  });

  test('serializes concurrent attempts for the same directory', () async {
    final results = await Future.wait([
      for (var index = 0; index < 2; index += 1)
        createProjectDirectory(
          parentPath: fixture.path,
          name: 'one-owner',
          registerProject: (path) async => createPersistedProjectRecord(
            projectId: 'project-$index',
            rootPath: path,
            kind: PersistedProjectKind.nonGit,
            displayName: 'one-owner',
            createdAt: 'now',
            updatedAt: 'now',
          ),
        ).then<Object>((value) => value).catchError((Object error) => error),
    ]);

    expect(results.whereType<CreateProjectDirectoryResult>(), hasLength(1));
    expect(
      results.whereType<ProjectDirectoryRequestException>().single.code,
      ProjectCreateDirectoryErrorCode.directoryExists,
    );
  });
}
