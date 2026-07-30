import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String projectsPath;
  late String workspacesPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('workspace-registry-test-');
    projectsPath = '${temp.path}${Platform.pathSeparator}projects.json';
    workspacesPath = '${temp.path}${Platform.pathSeparator}workspaces.json';
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('persisted records', () {
    test('applies workspace compatibility defaults', () {
      final workspace = PersistedWorkspaceRecord.fromJson({
        'workspaceId': 'wks_1',
        'projectId': 'prj_1',
        'cwd': '/repo',
        'kind': 'local_checkout',
        'displayName': 'main',
        'createdAt': '1',
        'updatedAt': '1',
        'archivedAt': null,
      });

      expect(workspace.title, isNull);
      expect(workspace.branch, isNull);
      expect(workspace.worktreeRoot, isNull);
      expect(workspace.baseBranch, isNull);
      expect(workspace.isPaseoOwnedWorktree, isFalse);
      expect(workspace.mainRepoRoot, isNull);
      expect(workspace.pinnedAt, isNull);
      expect(
        PersistedWorkspaceRecord.fromJson(workspace.toJson()).toJson(),
        workspace.toJson(),
      );
    });

    test('round trips projects and rejects invalid shapes', () {
      final project = createPersistedProjectRecord(
        projectId: 'prj_1',
        rootPath: '/repo',
        kind: PersistedProjectKind.nonGit,
        displayName: 'Repo',
        customName: 'Custom',
        createdAt: '1',
        updatedAt: '2',
        archivedAt: '3',
      );

      expect(
        PersistedProjectRecord.fromJson(project.toJson()).toJson(),
        project.toJson(),
      );
      expect(resolveProjectDisplayName(project), 'Custom');
      expect(
        resolveProjectDisplayName(project.copyWith(customName: null)),
        'Repo',
      );
      expect(
        () => PersistedProjectRecord.fromJson({
          ...project.toJson(),
          'kind': 'directory',
        }),
        throwsFormatException,
      );
      expect(
        () => PersistedProjectRecord.fromJson({
          ...project.toJson(),
          'projectId': 1,
        }),
        throwsFormatException,
      );
    });

    test('copyWith can set and clear nullable placement fields', () {
      final workspace = _workspace().copyWith(
        projectId: 'prj_2',
        cwd: '/new',
        kind: PersistedWorkspaceKind.directory,
        displayName: 'new',
        title: 'Title',
        branch: 'feature',
        worktreeRoot: '/root',
        baseBranch: 'main',
        isPaseoOwnedWorktree: true,
        mainRepoRoot: '/main',
        updatedAt: '2',
        archivedAt: '3',
        pinnedAt: '4',
      );
      expect(resolveWorkspaceDisplayName(workspace), 'Title');
      final cleared = workspace.copyWith(
        title: null,
        branch: null,
        worktreeRoot: null,
        baseBranch: null,
        mainRepoRoot: null,
        archivedAt: null,
        pinnedAt: null,
      );
      expect(resolveWorkspaceDisplayName(cleared), 'new');
      expect(cleared.branch, isNull);
      expect(cleared.archivedAt, isNull);
    });

    test('rejects invalid workspace kind and boolean', () {
      final json = _workspace().toJson();
      expect(
        () => PersistedWorkspaceRecord.fromJson({...json, 'kind': 'checkout'}),
        throwsFormatException,
      );
      expect(
        () => PersistedWorkspaceRecord.fromJson({
          ...json,
          'isPaseoOwnedWorktree': 'yes',
        }),
        throwsFormatException,
      );
    });
  });

  group('project registry', () {
    test('creates exact array persistence and reloads it', () async {
      final registry = FileBackedProjectRegistry(
        filePath: projectsPath,
        projectIdFactory: () => 'prj_fixed',
      );
      expect(await registry.existsOnDisk(), isFalse);
      await registry.initialize();

      final project = await registry.getOrCreateActiveByRoot(
        rootPath: '/repo',
        kind: PersistedProjectKind.git,
        displayName: 'repo',
        timestamp: '2026-07-26T00:00:00Z',
      );

      expect(project.projectId, 'prj_fixed');
      expect(await registry.existsOnDisk(), isTrue);
      final disk = jsonDecode(await File(projectsPath).readAsString()) as List;
      expect(disk, hasLength(1));
      expect((disk.single as Map)['projectId'], 'prj_fixed');

      final reloaded = FileBackedProjectRegistry(filePath: projectsPath);
      expect((await reloaded.list()).single.toJson(), project.toJson());
    });

    test('deduplicates active equivalent roots and refreshes kind', () async {
      final ids = ['prj_old', 'prj_new'].iterator;
      final registry = FileBackedProjectRegistry(
        filePath: projectsPath,
        projectIdFactory: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final original = await registry.getOrCreateActiveByRoot(
        rootPath: '${temp.path}${Platform.pathSeparator}repo',
        kind: PersistedProjectKind.nonGit,
        displayName: 'old',
        timestamp: '1',
      );
      final duplicate = await registry.getOrCreateActiveByRoot(
        rootPath:
            '${temp.path}${Platform.pathSeparator}repo${Platform.pathSeparator}.',
        kind: PersistedProjectKind.git,
        displayName: 'new',
        timestamp: '2',
      );

      expect(duplicate.projectId, original.projectId);
      expect(duplicate.kind, PersistedProjectKind.git);
      expect(duplicate.displayName, 'old');
      expect(duplicate.updatedAt, '2');
      expect(await registry.list(), hasLength(1));
    });

    test(
      'selects oldest duplicate and serializes concurrent allocation',
      () async {
        var nextId = 0;
        final registry = FileBackedProjectRegistry(
          filePath: projectsPath,
          projectIdFactory: () => 'prj_${nextId++}',
        );
        await registry.upsert(
          createPersistedProjectRecord(
            projectId: 'prj_z',
            rootPath: '/repo',
            kind: PersistedProjectKind.git,
            displayName: 'z',
            createdAt: '2',
            updatedAt: '2',
          ),
        );
        await registry.upsert(
          createPersistedProjectRecord(
            projectId: 'prj_a',
            rootPath: '/repo',
            kind: PersistedProjectKind.git,
            displayName: 'a',
            createdAt: '1',
            updatedAt: '1',
          ),
        );
        final oldest = await registry.getOrCreateActiveByRoot(
          rootPath: '/repo',
          kind: PersistedProjectKind.git,
          displayName: 'ignored',
          timestamp: '3',
        );
        expect(oldest.projectId, 'prj_a');

        final concurrent = await Future.wait([
          registry.getOrCreateActiveByRoot(
            rootPath: '/other',
            kind: PersistedProjectKind.git,
            displayName: 'other',
            timestamp: '4',
          ),
          registry.getOrCreateActiveByRoot(
            rootPath: '/other',
            kind: PersistedProjectKind.git,
            displayName: 'other',
            timestamp: '4',
          ),
        ]);
        expect(concurrent[0].projectId, concurrent[1].projectId);
      },
    );

    test('retries colliding ids and archives only active projects', () async {
      final ids = ['prj_same', 'prj_same', 'prj_next'].iterator;
      final registry = FileBackedProjectRegistry(
        filePath: projectsPath,
        projectIdFactory: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final first = await registry.getOrCreateActiveByRoot(
        rootPath: '/one',
        kind: PersistedProjectKind.git,
        displayName: 'one',
        timestamp: '1',
      );
      final second = await registry.getOrCreateActiveByRoot(
        rootPath: '/two',
        kind: PersistedProjectKind.git,
        displayName: 'two',
        timestamp: '1',
      );
      expect(first.projectId, 'prj_same');
      expect(second.projectId, 'prj_next');

      await registry.archive(first.projectId, '2');
      await registry.archive(first.projectId, '3');
      expect((await registry.get(first.projectId))?.archivedAt, '2');
    });

    test('emits upsert, archive, remove mutations and unsubscribes', () async {
      final registry = FileBackedProjectRegistry(filePath: projectsPath);
      final mutations = <ProjectMutation>[];
      final unsubscribe = registry.subscribeToMutations(mutations.add);
      final record = createPersistedProjectRecord(
        projectId: 'prj_1',
        rootPath: '/repo',
        kind: PersistedProjectKind.git,
        displayName: 'repo',
        createdAt: '1',
        updatedAt: '1',
      );

      await registry.upsert(record);
      await registry.archive(record.projectId, '2');
      await registry.remove(record.projectId);
      unsubscribe();
      await registry.upsert(record);

      expect(mutations.map((mutation) => mutation.kind), [
        RegistryMutationKind.upsert,
        RegistryMutationKind.archive,
        RegistryMutationKind.remove,
      ]);
      expect(mutations.last.project, isNull);
    });
  });

  group('workspace registry', () {
    test('persists, updates, archives again, restores, and removes', () async {
      final registry = FileBackedWorkspaceRegistry(filePath: workspacesPath);
      final mutations = <WorkspaceMutation>[];
      registry.subscribeToMutations(mutations.add);
      final workspace = _workspace();

      await registry.upsert(workspace, expectsInitialAgent: true);
      final updated = await registry.update(
        workspace.workspaceId,
        (record) => record.copyWith(title: 'Named', updatedAt: '2'),
      );
      expect(updated?.title, 'Named');
      await registry.archive(workspace.workspaceId, '3');
      await registry.archive(workspace.workspaceId, '4');
      expect((await registry.get(workspace.workspaceId))?.archivedAt, '4');
      expect(
        (await registry.restore(workspace.workspaceId, '5'))?.archivedAt,
        isNull,
      );
      await registry.remove(workspace.workspaceId);

      expect(await registry.get(workspace.workspaceId), isNull);
      expect(mutations.first.expectsInitialAgent, isTrue);
      expect(mutations.map((mutation) => mutation.kind), [
        RegistryMutationKind.upsert,
        RegistryMutationKind.upsert,
        RegistryMutationKind.archive,
        RegistryMutationKind.archive,
        RegistryMutationKind.upsert,
        RegistryMutationKind.remove,
      ]);
    });

    test('counts only active equivalent worktree roots', () async {
      final registry = FileBackedWorkspaceRegistry(filePath: workspacesPath);
      await registry.upsert(
        _workspace().copyWith(
          worktreeRoot: '${temp.path}${Platform.pathSeparator}root',
        ),
      );
      await registry.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'wks_2',
          projectId: 'prj_1',
          cwd: '/repo/two',
          kind: PersistedWorkspaceKind.worktree,
          displayName: 'two',
          worktreeRoot:
              '${temp.path}${Platform.pathSeparator}root${Platform.pathSeparator}.',
          createdAt: '1',
          updatedAt: '1',
        ),
      );
      await registry.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'wks_3',
          projectId: 'prj_1',
          cwd: '/repo/three',
          kind: PersistedWorkspaceKind.worktree,
          displayName: 'three',
          worktreeRoot: '${temp.path}${Platform.pathSeparator}root',
          createdAt: '1',
          updatedAt: '2',
          archivedAt: '2',
        ),
      );

      expect(
        await registry.activeWorktreeReferenceCount(
          '${temp.path}${Platform.pathSeparator}root',
        ),
        2,
      );
      expect(
        await registry.activeSharingWorktreeRoot(
          '${temp.path}${Platform.pathSeparator}root',
        ),
        hasLength(2),
      );
    });

    test('missing mutations are no-ops and listener can unsubscribe', () async {
      final registry = FileBackedWorkspaceRegistry(filePath: workspacesPath);
      var calls = 0;
      final unsubscribe = registry.subscribeToMutations((_) => calls++);
      expect(await registry.update('missing', (record) => record), isNull);
      await registry.archive('missing', '1');
      expect(await registry.restore('missing', '1'), isNull);
      await registry.remove('missing');
      unsubscribe();
      await registry.upsert(_workspace());
      expect(calls, 0);
    });

    test(
      'indexes active records deterministically with thousands archived',
      () async {
        final records = <PersistedWorkspaceRecord>[
          for (var index = 1999; index >= 0; index--)
            createPersistedWorkspaceRecord(
              workspaceId: 'wks_archived_$index',
              projectId: 'prj_archive_${index % 7}',
              cwd: '${temp.path}${Platform.pathSeparator}archive-$index',
              kind: PersistedWorkspaceKind.directory,
              displayName: 'archived-$index',
              createdAt: index.toString().padLeft(4, '0'),
              updatedAt: '2000',
              archivedAt: '2000',
            ),
          createPersistedWorkspaceRecord(
            workspaceId: 'wks_z',
            projectId: 'prj_active',
            cwd: '${temp.path}${Platform.pathSeparator}shared',
            kind: PersistedWorkspaceKind.localCheckout,
            displayName: 'z',
            createdAt: '3000',
            updatedAt: '3000',
          ),
          createPersistedWorkspaceRecord(
            workspaceId: 'wks_b',
            projectId: 'prj_active',
            cwd: '${temp.path}${Platform.pathSeparator}shared',
            kind: PersistedWorkspaceKind.localCheckout,
            displayName: 'b',
            createdAt: '2001',
            updatedAt: '2001',
          ),
          createPersistedWorkspaceRecord(
            workspaceId: 'wks_a',
            projectId: 'prj_active',
            cwd: '${temp.path}${Platform.pathSeparator}other',
            kind: PersistedWorkspaceKind.directory,
            displayName: 'a',
            createdAt: '2001',
            updatedAt: '2001',
          ),
        ];
        await File(workspacesPath)
          ..parent.createSync(recursive: true)
          ..writeAsString(
            jsonEncode(records.map((record) => record.toJson()).toList()),
          );
        final registry = FileBackedWorkspaceRegistry(filePath: workspacesPath);
        await registry.initialize();

        expect(
          (await registry.listActive()).map((record) => record.workspaceId),
          ['wks_a', 'wks_b', 'wks_z'],
        );
        expect(
          (await registry.activeForProject(
            'prj_active',
          )).map((record) => record.workspaceId),
          ['wks_a', 'wks_b', 'wks_z'],
        );
        expect(
          (await registry.activeForCwd(
            '${temp.path}${Platform.pathSeparator}shared',
          )).map((record) => record.workspaceId),
          ['wks_b', 'wks_z'],
        );

        await registry.archive('wks_b', '4000');
        await registry.restore('wks_b', '4001');
        await registry.update(
          'wks_b',
          (record) => record.copyWith(
            cwd: '${temp.path}${Platform.pathSeparator}moved',
          ),
        );
        await registry.remove('wks_z');

        expect(
          await registry.activeForCwd(
            '${temp.path}${Platform.pathSeparator}shared',
          ),
          isEmpty,
        );
        expect(
          (await registry.activeForCwd(
            '${temp.path}${Platform.pathSeparator}moved',
          )).map((record) => record.workspaceId),
          ['wks_b'],
        );
        expect(
          (await registry.activeForProject(
            'prj_active',
          )).map((record) => record.workspaceId),
          ['wks_a', 'wks_b'],
        );
      },
    );

    test(
      'serializes concurrent replacements without stale project or cwd ids',
      () async {
        final registry = FileBackedWorkspaceRegistry(filePath: workspacesPath);
        await registry.upsert(_workspace());

        final second = _workspace().copyWith(
          projectId: 'prj_second',
          cwd: '${temp.path}${Platform.pathSeparator}second',
          updatedAt: '2',
        );
        final third = _workspace().copyWith(
          projectId: 'prj_third',
          cwd: '${temp.path}${Platform.pathSeparator}third',
          updatedAt: '3',
        );

        await Future.wait([registry.upsert(second), registry.upsert(third)]);

        expect(await registry.activeForProject('prj_1'), isEmpty);
        expect(await registry.activeForProject('prj_second'), isEmpty);
        expect(
          (await registry.activeForProject(
            'prj_third',
          )).map((record) => record.workspaceId),
          ['wks_1'],
        );
        expect(await registry.activeForCwd('/repo'), isEmpty);
        expect(await registry.activeForCwd(second.cwd), isEmpty);
        expect(
          (await registry.activeForCwd(
            third.cwd,
          )).map((record) => record.workspaceId),
          ['wks_1'],
        );

        PersistedWorkspaceRecord record({
          required String workspaceId,
          required String projectId,
          required String cwd,
          required String updatedAt,
          String? archivedAt,
        }) => createPersistedWorkspaceRecord(
          workspaceId: workspaceId,
          projectId: projectId,
          cwd: cwd,
          kind: PersistedWorkspaceKind.directory,
          displayName: workspaceId,
          createdAt: '1',
          updatedAt: updatedAt,
          archivedAt: archivedAt,
        );

        final archivedId = 'wks_concurrent_archive';
        await registry.upsert(
          record(
            workspaceId: archivedId,
            projectId: 'prj_archive_old',
            cwd: '/archive-old',
            updatedAt: '1',
          ),
        );
        await Future.wait([
          registry.update(
            archivedId,
            (workspace) => workspace.copyWith(
              projectId: 'prj_archive_moved',
              cwd: '/archive-moved',
              updatedAt: '2',
            ),
          ),
          registry.archive(archivedId, '3'),
        ]);
        expect(await registry.activeForProject('prj_archive_old'), isEmpty);
        expect(await registry.activeForProject('prj_archive_moved'), isEmpty);
        expect(await registry.activeForCwd('/archive-old'), isEmpty);
        expect(await registry.activeForCwd('/archive-moved'), isEmpty);

        final restoredId = 'wks_concurrent_restore';
        await registry.upsert(
          record(
            workspaceId: restoredId,
            projectId: 'prj_restore_old',
            cwd: '/restore-old',
            updatedAt: '1',
            archivedAt: '1',
          ),
        );
        await Future.wait([
          registry.restore(restoredId, '2'),
          registry.update(
            restoredId,
            (workspace) => workspace.copyWith(
              projectId: 'prj_restore_moved',
              cwd: '/restore-moved',
              updatedAt: '3',
            ),
          ),
        ]);
        expect(await registry.activeForProject('prj_restore_old'), isEmpty);
        expect(
          (await registry.activeForProject(
            'prj_restore_moved',
          )).map((workspace) => workspace.workspaceId),
          [restoredId],
        );
        expect(await registry.activeForCwd('/restore-old'), isEmpty);
        expect(
          (await registry.activeForCwd(
            '/restore-moved',
          )).map((workspace) => workspace.workspaceId),
          [restoredId],
        );

        final removedId = 'wks_concurrent_remove';
        await registry.upsert(
          record(
            workspaceId: removedId,
            projectId: 'prj_remove_old',
            cwd: '/remove-old',
            updatedAt: '1',
          ),
        );
        await Future.wait([
          registry.update(
            removedId,
            (workspace) => workspace.copyWith(
              projectId: 'prj_remove_moved',
              cwd: '/remove-moved',
              updatedAt: '2',
            ),
          ),
          registry.remove(removedId),
        ]);
        await registry.upsert(
          record(
            workspaceId: removedId,
            projectId: 'prj_remove_final',
            cwd: '/remove-final',
            updatedAt: '3',
          ),
        );
        expect(await registry.activeForProject('prj_remove_old'), isEmpty);
        expect(await registry.activeForProject('prj_remove_moved'), isEmpty);
        expect(await registry.activeForCwd('/remove-old'), isEmpty);
        expect(await registry.activeForCwd('/remove-moved'), isEmpty);
        expect(
          (await registry.activeForProject(
            'prj_remove_final',
          )).map((workspace) => workspace.workspaceId),
          [removedId],
        );
      },
    );
  });

  group('registry robustness', () {
    test('ignores corrupt and non-array files', () async {
      await File(projectsPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{bad');
      expect(
        await FileBackedProjectRegistry(filePath: projectsPath).list(),
        isEmpty,
      );

      await File(workspacesPath).writeAsString('{}');
      expect(
        await FileBackedWorkspaceRegistry(filePath: workspacesPath).list(),
        isEmpty,
      );
    });

    test('ignores invalid entries as an invalid registry', () async {
      await File(projectsPath).writeAsString('[1]');
      expect(
        await FileBackedProjectRegistry(filePath: projectsPath).list(),
        isEmpty,
      );
    });

    test('constructs paired default files and initializes both', () async {
      final registries = WorkspaceRegistries(dataDir: temp.path);
      await registries.initialize();
      expect(await registries.projects.list(), isEmpty);
      expect(await registries.workspaces.list(), isEmpty);
    });

    test('generated ids use Paseo prefixes and 8 random bytes', () {
      expect(generateProjectId(), matches(RegExp(r'^prj_[0-9a-f]{16}$')));
      expect(generateWorkspaceId(), matches(RegExp(r'^wks_[0-9a-f]{16}$')));
    });

    test('path equivalence normalizes absolute dot segments', () {
      expect(areEquivalentPaths('.', './foo/..'), isTrue);
    });
  });
}

PersistedWorkspaceRecord _workspace() => createPersistedWorkspaceRecord(
  workspaceId: 'wks_1',
  projectId: 'prj_1',
  cwd: '/repo',
  kind: PersistedWorkspaceKind.localCheckout,
  displayName: 'main',
  createdAt: '1',
  updatedAt: '1',
);
