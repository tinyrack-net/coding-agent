import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('workspace descriptor', () {
    test('applies Paseo compatibility defaults', () {
      final workspace = WorkspaceDescriptor.fromJson({
        'id': 'wks_1234',
        'projectId': 'prj_1234',
        'projectDisplayName': 'paseo',
        'projectRootPath': r'C:\src\paseo',
        'projectKind': 'git',
        'workspaceKind': 'checkout',
        'name': 'main',
        'status': 'needs_input',
        'activityAt': null,
      });

      expect(workspace.workspaceDirectory, r'C:\src\paseo');
      expect(workspace.status, WorkspaceStateBucket.needsInput);
      expect(workspace.statusEnteredAt, isNull);
      expect(workspace.archivingAt, isNull);
      expect(workspace.scripts, isEmpty);
      expect(workspace.toJson(), containsPair('scripts', isEmpty));
      expect(workspace.toJson(), containsPair('archivingAt', null));
    });

    test('round trips complete runtime state', () {
      final workspace = WorkspaceDescriptor.fromJson({
        'id': 'wks_a',
        'projectId': 'prj_a',
        'projectDisplayName': 'Tinyrack',
        'projectCustomName': 'Tiny',
        'projectRootPath': '/repo',
        'workspaceDirectory': '/repo/.worktrees/feature',
        'projectKind': 'directory',
        'workspaceKind': 'worktree',
        'name': 'Feature',
        'title': 'Feature',
        'pinnedAt': '2026-07-26T00:00:00Z',
        'archivingAt': '2026-07-26T01:00:00Z',
        'status': 'running',
        'statusEnteredAt': '2026-07-26T00:30:00Z',
        'activityAt': '2026-07-26T00:31:00Z',
        'diffStat': {'additions': 3, 'deletions': 2},
        'scripts': [
          {
            'scriptName': 'dev',
            'type': 'script',
            'hostname': 'localhost',
            'port': 3000,
            'localProxyUrl': 'http://localhost:3000',
            'publicProxyUrl': null,
            'lifecycle': 'running',
            'health': 'healthy',
            'exitCode': null,
            'terminalId': 'term_1',
          },
          {
            'scriptName': 'api',
            'hostname': '127.0.0.1',
            'port': null,
            'proxyUrl': null,
            'lifecycle': 'stopped',
            'health': 'unhealthy',
          },
        ],
        'gitRuntime': {
          'currentBranch': 'feature',
          'remoteUrl': 'git@example/repo.git',
          'isPaseoOwnedWorktree': true,
          'isDirty': false,
          'aheadBehind': {'ahead': 2, 'behind': 1},
          'aheadOfOrigin': 2,
          'behindOfOrigin': 1,
        },
        'githubRuntime': {'featuresEnabled': true},
        'forge': 'github',
        'project': {'projectKey': 'repo'},
      });

      expect(workspace.projectKind, WorkspaceProjectKind.directory);
      expect(workspace.workspaceKind, WorkspaceKind.worktree);
      expect(workspace.diffStat?.additions, 3);
      expect(workspace.scripts.first.type, WorkspaceScriptType.script);
      expect(workspace.scripts.last.type, WorkspaceScriptType.service);
      expect(workspace.gitRuntime?.aheadBehind?.behind, 1);
      expect(
        WorkspaceDescriptor.fromJson(workspace.toJson()).toJson(),
        workspace.toJson(),
      );
    });

    test('rejects invalid enum and scalar values', () {
      final base = <String, Object?>{
        'id': 'wks_a',
        'projectId': 'prj_a',
        'projectDisplayName': 'p',
        'projectRootPath': '/repo',
        'projectKind': 'git',
        'workspaceKind': 'directory',
        'name': 'repo',
        'status': 'done',
        'activityAt': null,
      };

      expect(
        () => WorkspaceDescriptor.fromJson({...base, 'status': 'idle'}),
        throwsFormatException,
      );
      expect(
        () => WorkspaceDescriptor.fromJson({...base, 'projectKind': 'svn'}),
        throwsFormatException,
      );
      expect(
        () => WorkspaceDescriptor.fromJson({...base, 'workspaceKind': 'copy'}),
        throwsFormatException,
      );
      expect(
        () => WorkspaceDescriptor.fromJson({...base, 'id': 1}),
        throwsFormatException,
      );
    });
  });

  group('workspace fetch', () {
    test('decodes filters, sort, pagination, and subscription', () {
      final request = FetchWorkspacesRequest.fromJson({
        'type': 'fetch_workspaces_request',
        'requestId': 'req_1',
        'filter': {'query': 'tiny', 'projectId': 'prj_1', 'idPrefix': 'wks_'},
        'sort': [
          {'key': 'status_priority', 'direction': 'asc'},
          {'key': 'activity_at', 'direction': 'desc'},
          {'key': 'name', 'direction': 'asc'},
          {'key': 'project_id', 'direction': 'desc'},
        ],
        'page': {'limit': 200, 'cursor': 'next'},
        'subscribe': {'subscriptionId': 'sub_1'},
      });

      expect(request.sort, hasLength(4));
      expect(request.sort.first.key, WorkspaceSortKey.statusPriority);
      expect(request.sort.last.direction, SortDirection.desc);
      expect(request.hasSubscription, isTrue);
      expect(request.toJson(), containsPair('requestId', 'req_1'));
      expect(
        FetchWorkspacesRequest.fromJson(request.toJson()).subscriptionId,
        'sub_1',
      );
    });

    test('preserves an empty subscription object', () {
      final request = FetchWorkspacesRequest.fromJson({
        'type': 'fetch_workspaces_request',
        'requestId': 'req',
        'subscribe': <String, Object?>{},
      });

      expect(request.hasSubscription, isTrue);
      expect(request.subscriptionId, isNull);
      expect(request.toJson()['subscribe'], isEmpty);
    });

    test('enforces page and sort schema', () {
      Map<String, Object?> request(Object page) => {
        'type': 'fetch_workspaces_request',
        'requestId': 'req',
        'page': page,
      };

      expect(
        () => FetchWorkspacesRequest.fromJson(request({'limit': 0})),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesRequest.fromJson(request({'limit': 201})),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesRequest.fromJson(request({'limit': 1.5})),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesRequest.fromJson(
          request({'limit': 1, 'cursor': ''}),
        ),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesRequest.fromJson(request({'cursor': 'next'})),
        throwsFormatException,
      );
      expect(
        const FetchWorkspacesRequest(
          requestId: 'req',
          cursor: 'next',
        ).toJson()['page'],
        {'limit': 200, 'cursor': 'next'},
      );
      expect(
        () => FetchWorkspacesRequest.fromJson({
          'type': 'fetch_workspaces_request',
          'requestId': 'req',
          'sort': [
            {'key': 'bad', 'direction': 'asc'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('round trips response and empty project parents', () {
      final response = FetchWorkspacesResponse(
        requestId: 'req',
        subscriptionId: 'sub',
        entries: [_workspace()],
        emptyProjects: [
          const WorkspaceProjectDescriptor(
            projectId: 'prj_empty',
            projectDisplayName: 'Empty',
            projectCustomName: 'Renamed',
            projectRootPath: '/empty',
            projectKind: WorkspaceProjectKind.nonGit,
          ),
        ],
        pageInfo: const WorkspacePageInfo(
          nextCursor: 'next',
          prevCursor: null,
          hasMore: true,
        ),
      );

      final decoded = FetchWorkspacesResponse.fromJson(response.toJson());
      expect(decoded.entries.single.id, 'wks_1');
      expect(
        decoded.emptyProjects.single.projectKind,
        WorkspaceProjectKind.nonGit,
      );
      expect(decoded.pageInfo.nextCursor, 'next');
      expect(decoded.toJson(), response.toJson());
    });

    test('requires frozen response fields while defaulting empty projects', () {
      Map<String, Object?> response(Map<String, Object?> payload) => {
        'type': 'fetch_workspaces_response',
        'payload': payload,
      };
      final base = <String, Object?>{
        'requestId': 'req',
        'entries': const [],
        'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
      };

      expect(
        FetchWorkspacesResponse.fromJson(response(base)).emptyProjects,
        isEmpty,
      );
      expect(
        () => FetchWorkspacesResponse.fromJson(
          response({...base}..remove('entries')),
        ),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesResponse.fromJson(
          response({...base, 'entries': null}),
        ),
        throwsFormatException,
      );
      expect(
        () => FetchWorkspacesResponse.fromJson(
          response({
            ...base,
            'pageInfo': {'prevCursor': null, 'hasMore': false},
          }),
        ),
        throwsFormatException,
      );
    });
  });

  group('workspace create', () {
    test('uses a sealed directory source', () {
      final request = WorkspaceCreateRequest.fromJson({
        'type': 'workspace.create.request',
        'requestId': 'req',
        'title': 'Local',
        'firstAgentContext': {'prompt': 'fix it'},
        'source': {'kind': 'directory', 'path': '/repo', 'projectId': 'prj_1'},
      });

      expect(request.source, isA<DirectoryWorkspaceCreateSource>());
      expect(request.toJson()['source'], containsPair('kind', 'directory'));
      expect(WorkspaceCreateRequest.fromJson(request.toJson()).title, 'Local');
    });

    test('round trips every worktree option', () {
      final request = WorkspaceCreateRequest.fromJson({
        'type': 'workspace.create.request',
        'requestId': 'req',
        'source': {
          'kind': 'worktree',
          'cwd': '/repo',
          'projectId': 'prj_1',
          'action': 'branch-off',
          'refName': 'main',
          'baseBranch': 'main',
          'branchName': 'feature',
          'checkoutSource': {'kind': 'github_pr', 'number': 42},
          'githubPrNumber': 42,
          'worktreeSlug': 'feature',
        },
      });

      final source = request.source as WorktreeWorkspaceCreateSource;
      expect(source.action, WorktreeCreateAction.branchOff);
      expect(source.githubPrNumber, 42);
      expect(
        WorkspaceCreateRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    });

    test('validates worktree discriminators and positive PR number', () {
      Map<String, Object?> request(Map<String, Object?> source) => {
        'type': 'workspace.create.request',
        'requestId': 'req',
        'source': source,
      };

      expect(
        () => WorkspaceCreateRequest.fromJson(request({'kind': 'unknown'})),
        throwsFormatException,
      );
      expect(
        () => WorkspaceCreateRequest.fromJson(
          request({'kind': 'worktree', 'action': 'copy'}),
        ),
        throwsFormatException,
      );
      expect(
        () => WorkspaceCreateRequest.fromJson(
          request({'kind': 'worktree', 'refName': ''}),
        ),
        throwsFormatException,
      );
      expect(
        () => WorkspaceCreateRequest.fromJson(
          request({'kind': 'worktree', 'branchName': ''}),
        ),
        throwsFormatException,
      );
      expect(
        () => WorkspaceCreateRequest.fromJson(
          request({'kind': 'worktree', 'githubPrNumber': 0}),
        ),
        throwsFormatException,
      );
    });

    test('round trips nullable create response', () {
      const response = WorkspaceCreateResponse(
        requestId: 'req',
        workspace: null,
        setupTerminalId: null,
        error: 'directory missing',
        errorCode: 'directory_not_found',
      );

      final decoded = WorkspaceCreateResponse.fromJson(response.toJson());
      expect(decoded.errorCode, 'directory_not_found');
      expect(decoded.workspace, isNull);
    });
  });

  group('archive and update events', () {
    test('round trips archive request and response', () {
      const request = ArchiveWorkspaceRequest(
        workspaceId: 'wks_1',
        requestId: 'req',
      );
      expect(
        ArchiveWorkspaceRequest.fromJson(request.toJson()).workspaceId,
        'wks_1',
      );

      const response = ArchiveWorkspaceResponse(
        requestId: 'req',
        workspaceId: 'wks_1',
        archivedAt: '2026-07-26T00:00:00Z',
        error: null,
      );
      expect(
        ArchiveWorkspaceResponse.fromJson(response.toJson()).archivedAt,
        isNotNull,
      );
      expect(
        () => ArchiveWorkspaceResponse.fromJson({
          'type': 'archive_workspace_response',
          'payload': {
            'requestId': 'req',
            'workspaceId': 'wks_1',
            'archivedAt': null,
          },
        }),
        throwsFormatException,
      );
    });

    test('decodes both workspace update variants', () {
      final upsert = WorkspaceUpdate.fromJson(
        WorkspaceUpsertUpdate(_workspace()).toJson(),
      );
      expect(upsert, isA<WorkspaceUpsertUpdate>());

      const remove = WorkspaceRemoveUpdate(
        id: 'wks_1',
        emptyProject: WorkspaceProjectDescriptor(
          projectId: 'prj_1',
          projectDisplayName: 'P',
          projectRootPath: '/p',
          projectKind: WorkspaceProjectKind.git,
        ),
        removedProjectId: 'prj_removed',
      );
      final decoded = WorkspaceUpdate.fromJson(remove.toJson());
      expect(decoded, isA<WorkspaceRemoveUpdate>());
      expect(
        (decoded as WorkspaceRemoveUpdate).removedProjectId,
        'prj_removed',
      );
    });

    test('decodes both project update variants', () {
      const descriptor = WorkspaceProjectDescriptor(
        projectId: 'prj_1',
        projectDisplayName: 'P',
        projectRootPath: '/p',
        projectKind: WorkspaceProjectKind.git,
      );
      expect(
        ProjectUpdate.fromJson(const ProjectUpsertUpdate(descriptor).toJson()),
        isA<ProjectUpsertUpdate>(),
      );
      final remove = ProjectUpdate.fromJson(
        const ProjectRemoveUpdate('prj_1').toJson(),
      );
      expect((remove as ProjectRemoveUpdate).projectId, 'prj_1');
    });

    test('rejects wrong message types and update variants', () {
      expect(
        () => ArchiveWorkspaceRequest.fromJson({
          'type': 'wrong',
          'workspaceId': 'wks_1',
          'requestId': 'req',
        }),
        throwsFormatException,
      );
      expect(
        () => WorkspaceUpdate.fromJson({
          'type': 'workspace_update',
          'payload': {'kind': 'replace'},
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectUpdate.fromJson({
          'type': 'project.update',
          'payload': {'kind': 'replace'},
        }),
        throwsFormatException,
      );
    });
  });

  group('project mutations', () {
    test('round trips add request and both response outcomes', () {
      const request = ProjectAddRequest(cwd: '/repo', requestId: 'req');
      expect(ProjectAddRequest.fromJson(request.toJson()).cwd, '/repo');

      final success = ProjectAddResponse(
        requestId: 'req',
        project: const WorkspaceProjectDescriptor(
          projectId: 'prj_1',
          projectDisplayName: 'Repo',
          projectRootPath: '/repo',
          projectKind: WorkspaceProjectKind.git,
        ),
        error: null,
      );
      expect(
        ProjectAddResponse.fromJson(success.toJson()).project?.projectId,
        'prj_1',
      );

      const failure = ProjectAddResponse(
        requestId: 'req',
        project: null,
        error: 'missing',
        errorCode: 'directory_not_found',
      );
      expect(
        ProjectAddResponse.fromJson(failure.toJson()).errorCode,
        'directory_not_found',
      );
    });

    test('round trips rename request and response', () {
      const request = ProjectRenameRequest(
        projectId: 'prj_1',
        customName: null,
        requestId: 'req',
      );
      expect(
        ProjectRenameRequest.fromJson(request.toJson()).customName,
        isNull,
      );

      const response = ProjectRenameResponse(
        requestId: 'req',
        projectId: 'prj_1',
        accepted: true,
        customName: 'Tiny',
        error: null,
      );
      expect(
        ProjectRenameResponse.fromJson(response.toJson()).customName,
        'Tiny',
      );
    });

    test('round trips remove request and defaults removed ids', () {
      const request = ProjectRemoveRequest(
        projectId: 'prj_1',
        requestId: 'req',
      );
      expect(
        ProjectRemoveRequest.fromJson(request.toJson()).projectId,
        'prj_1',
      );
      final response = ProjectRemoveResponse.fromJson({
        'type': 'project.remove.response',
        'payload': {
          'requestId': 'req',
          'projectId': 'prj_1',
          'accepted': true,
          'error': null,
        },
      });
      expect(response.removedWorkspaceIds, isEmpty);
      expect(
        ProjectRemoveResponse.fromJson(
          ProjectRemoveResponse(
            requestId: 'req',
            projectId: 'prj_1',
            accepted: true,
            removedWorkspaceIds: const ['wks_1'],
            error: null,
          ).toJson(),
        ).removedWorkspaceIds,
        ['wks_1'],
      );
    });

    test('rejects malformed project response arrays', () {
      expect(
        () => ProjectRemoveResponse.fromJson({
          'type': 'project.remove.response',
          'payload': {
            'requestId': 'req',
            'projectId': 'prj',
            'accepted': true,
            'removedWorkspaceIds': 'wks',
            'error': null,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectRemoveResponse.fromJson({
          'type': 'project.remove.response',
          'payload': {
            'requestId': 'req',
            'projectId': 'prj',
            'accepted': true,
            'removedWorkspaceIds': [1],
            'error': null,
          },
        }),
        throwsFormatException,
      );
    });
  });

  group('workspace metadata mutations', () {
    test('round trips title request and response', () {
      const request = WorkspaceTitleSetRequest(
        workspaceId: 'wks_1',
        title: '',
        requestId: 'req',
      );
      expect(WorkspaceTitleSetRequest.fromJson(request.toJson()).title, '');
      const response = WorkspaceTitleSetResponse(
        requestId: 'req',
        workspaceId: 'wks_1',
        accepted: true,
        title: null,
        error: null,
      );
      expect(
        WorkspaceTitleSetResponse.fromJson(response.toJson()).accepted,
        isTrue,
      );
    });

    test('round trips pin request and response', () {
      const request = WorkspacePinSetRequest(
        workspaceId: 'wks_1',
        pinned: true,
        requestId: 'req',
      );
      expect(WorkspacePinSetRequest.fromJson(request.toJson()).pinned, isTrue);
      const response = WorkspacePinSetResponse(
        requestId: 'req',
        workspaceId: 'wks_1',
        accepted: true,
        pinnedAt: '2026-07-26T00:00:00Z',
        error: null,
      );
      expect(
        WorkspacePinSetResponse.fromJson(response.toJson()).pinnedAt,
        isNotNull,
      );
    });
  });

  group('workspace recovery', () {
    test('round trips inspect request and recoverable state', () {
      const request = WorkspaceRecoveryInspectRequest(
        workspaceId: 'wks_1',
        requestId: 'req',
      );
      expect(
        WorkspaceRecoveryInspectRequest.fromJson(request.toJson()).workspaceId,
        'wks_1',
      );
      const response = WorkspaceRecoveryInspectResponse(
        requestId: 'req',
        state: RecoverableWorkspaceState(
          workspaceId: 'wks_1',
          workspaceName: 'Feature',
          action: 'restore',
          branch: 'feature',
        ),
      );
      final decoded = WorkspaceRecoveryInspectResponse.fromJson(
        response.toJson(),
      );
      expect(decoded.state, isA<RecoverableWorkspaceState>());
      expect((decoded.state as RecoverableWorkspaceState).action, 'restore');
    });

    test('round trips unavailable state and restore response', () {
      const inspect = WorkspaceRecoveryInspectResponse(
        requestId: 'req',
        state: UnavailableWorkspaceState(
          workspaceId: 'wks_1',
          reason: 'workspace_not_found',
          message: 'missing',
        ),
      );
      final state = WorkspaceRecoveryInspectResponse.fromJson(
        inspect.toJson(),
      ).state;
      expect(
        (state as UnavailableWorkspaceState).reason,
        'workspace_not_found',
      );

      const request = WorkspaceRecoveryRestoreRequest(
        workspaceId: 'wks_1',
        requestId: 'req',
      );
      expect(
        WorkspaceRecoveryRestoreRequest.fromJson(request.toJson()).requestId,
        'req',
      );
      const response = WorkspaceRecoveryRestoreResponse(
        requestId: 'req',
        workspaceId: 'wks_1',
        accepted: false,
        error: 'missing',
      );
      expect(
        WorkspaceRecoveryRestoreResponse.fromJson(response.toJson()).error,
        'missing',
      );
    });

    test('rejects an unknown recovery state', () {
      expect(
        () => WorkspaceRecoveryState.fromJson({
          'kind': 'future',
          'workspaceId': 'wks_1',
        }),
        throwsFormatException,
      );
    });
  });
}

WorkspaceDescriptor _workspace() => const WorkspaceDescriptor(
  id: 'wks_1',
  projectId: 'prj_1',
  projectDisplayName: 'Paseo',
  projectRootPath: '/repo',
  workspaceDirectory: '/repo',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.localCheckout,
  name: 'main',
  status: WorkspaceStateBucket.done,
  activityAt: null,
);
