// Ports of the upstream test suites for Paseo 0.2.0's new-workspace decision
// modules: new-workspace-empty, new-workspace-fork-context,
// new-workspace-picker-item and new-workspace-initial-context. Cases the
// upstream suites leave unpinned (blank/whitespace forge fields, POSIX case
// sensitivity, empty host lists, the automatic-host fallbacks) are covered
// here too.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_new_workspace_rules.dart';
import 'package:coding_agent_app/widgets/host_status_dot.dart'
    show HostRuntimeConnectionStatus;
import 'package:flutter_test/flutter_test.dart';

NewWorkspaceMessagePayload _payload({
  String text = '',
  List<Object?> attachments = const [],
}) => NewWorkspaceMessagePayload(
  text: text,
  cwd: '/sample/repo',
  attachments: attachments,
);

/// Records `(serverId, workspaceId)` pairs the way upstream's
/// `createRecordingNavigate` helper does.
final class _RecordingNavigate {
  final recorded = <(String, String)>[];

  void call(String serverId, String workspaceId) =>
      recorded.add((serverId, workspaceId));
}

final class _RecordingEnsureWorkspace {
  _RecordingEnsureWorkspace(this.workspaceId);

  final String workspaceId;
  final calls = <EnsureWorkspaceInput>[];

  Future<String> call(EnsureWorkspaceInput input) async {
    calls.add(input);
    return workspaceId;
  }
}

ForgeSearchItem _prItem({
  int number = 42,
  String title = 'Add picker',
  String url = 'https://example.com/pull/42',
  String? forge,
  String? projectPath,
  String? baseRefName = 'main',
  String? headRefName = 'feature/picker',
}) => ForgeSearchItem(
  kind: ForgeSearchKind.changeRequest,
  number: number,
  title: title,
  url: url,
  state: 'open',
  body: null,
  labels: const [],
  forge: forge,
  projectPath: projectPath,
  baseRefName: baseRefName,
  headRefName: headRefName,
);

/// Mirrors upstream's `projectFor` helper: one project, one host, worktree
/// creation allowed unless the test says otherwise.
NewWorkspaceHostProject _projectFor(
  String serverId, [
  String key = 'project',
  bool canCreateWorktree = true,
]) => NewWorkspaceHostProject(
  projectKey: key,
  hosts: [
    NewWorkspaceProjectHost(
      serverId: serverId,
      canCreateWorktree: canCreateWorktree,
    ),
  ],
);

void main() {
  group('isEmptyWorkspaceSubmission', () {
    test('treats whitespace-only text with no attachments as empty, but any '
        'attachment as non-empty', () {
      expect(isEmptyWorkspaceSubmission(_payload(text: ' \n\t ')), isTrue);
      expect(
        isEmptyWorkspaceSubmission(_payload(attachments: const [Object()])),
        isFalse,
      );
    });

    test('treats a fully blank payload as empty', () {
      expect(isEmptyWorkspaceSubmission(_payload()), isTrue);
    });

    test('treats any real text as non-empty', () {
      expect(isEmptyWorkspaceSubmission(_payload(text: 'hi')), isFalse);
      expect(isEmptyWorkspaceSubmission(_payload(text: ' hi ')), isFalse);
    });

    test('an attachment outweighs whitespace-only text', () {
      expect(
        isEmptyWorkspaceSubmission(
          _payload(text: '   ', attachments: const [Object()]),
        ),
        isFalse,
      );
    });
  });

  group('runCreateEmptyWorkspace', () {
    test(
      'creates a workspace without prompt or attachments and navigates to it',
      () async {
        final ensureWorkspace = _RecordingEnsureWorkspace('workspace-123');
        final navigate = _RecordingNavigate();

        await runCreateEmptyWorkspace(
          payload: _payload(),
          ensureWorkspace: ensureWorkspace.call,
          serverId: 'server-abc',
          navigate: navigate.call,
        );

        expect(ensureWorkspace.calls, hasLength(1));
        expect(
          ensureWorkspace.calls.single,
          const EnsureWorkspaceInput(
            cwd: '/sample/repo',
            prompt: '',
            attachments: [],
            withInitialAgent: false,
          ),
        );
        expect(navigate.recorded, [('server-abc', 'workspace-123')]);
      },
    );

    test('discards draft text and attachments, keeping only the cwd', () async {
      final ensureWorkspace = _RecordingEnsureWorkspace('workspace-9');
      final navigate = _RecordingNavigate();

      await runCreateEmptyWorkspace(
        payload: _payload(text: 'ignored', attachments: const [Object()]),
        ensureWorkspace: ensureWorkspace.call,
        serverId: 'server-1',
        navigate: navigate.call,
      );

      expect(ensureWorkspace.calls.single.prompt, '');
      expect(ensureWorkspace.calls.single.attachments, isEmpty);
      expect(ensureWorkspace.calls.single.withInitialAgent, isFalse);
      expect(ensureWorkspace.calls.single.cwd, '/sample/repo');
      expect(navigate.recorded, [('server-1', 'workspace-9')]);
    });
  });

  group('remapDraftCwdToWorkspace', () {
    test(
      'preserves a Windows subdirectory when source path casing differs',
      () {
        expect(
          remapDraftCwdToWorkspace(
            cwd: r'c:\Repo\packages\app',
            sourceDirectory: r'C:\Repo',
            workspaceDirectory: r'D:\Worktrees\fork',
          ),
          r'D:\Worktrees\fork\packages\app',
        );
      },
    );

    test('falls back to the workspace root when the cwd is outside the source '
        'directory', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/other/repo/packages/app',
          sourceDirectory: '/repo',
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
    });

    test('falls back to the workspace root without a usable source', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/repo/packages/app',
          sourceDirectory: null,
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/repo/packages/app',
          sourceDirectory: '   ',
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
    });

    test('falls back to the workspace root for a blank cwd', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '   ',
          sourceDirectory: '/repo',
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
    });

    test('maps the source root itself onto the workspace root', () {
      // The fallback returns the workspace directory verbatim (trimmed only),
      // so a trailing separator survives; it is stripped only on the join path.
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/repo/',
          sourceDirectory: '/repo',
          workspaceDirectory: '/worktrees/fork/',
        ),
        '/worktrees/fork/',
      );
      expect(
        remapDraftCwdToWorkspace(
          cwd: r'C:\Repo\',
          sourceDirectory: 'c:/repo',
          workspaceDirectory: r'D:\Worktrees\fork',
        ),
        r'D:\Worktrees\fork',
      );
    });

    test('keeps POSIX comparisons case-sensitive', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/Repo/packages/app',
          sourceDirectory: '/repo',
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
    });

    test('preserves the original casing of the surviving subpath', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: r'c:\Repo\Packages\App',
          sourceDirectory: r'C:\repo',
          workspaceDirectory: r'D:\fork',
        ),
        r'D:\fork\Packages\App',
      );
    });

    test(
      'uses forward slashes when the workspace path is not pure Windows',
      () {
        expect(
          remapDraftCwdToWorkspace(
            cwd: '/repo/packages/app',
            sourceDirectory: '/repo',
            workspaceDirectory: '/worktrees/fork',
          ),
          '/worktrees/fork/packages/app',
        );
        // Mixed separators are not "pure backslash", so the join uses "/".
        expect(
          remapDraftCwdToWorkspace(
            cwd: '/repo/packages/app',
            sourceDirectory: '/repo',
            workspaceDirectory: r'C:/Worktrees\fork',
          ),
          r'C:/Worktrees\fork/packages/app',
        );
      },
    );

    test('collapses redundant separators around the join', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/repo/packages/app//',
          sourceDirectory: '/repo//',
          workspaceDirectory: '/worktrees/fork//',
        ),
        '/worktrees/fork/packages/app',
      );
    });

    test('does not treat a sibling directory as a subpath', () {
      expect(
        remapDraftCwdToWorkspace(
          cwd: '/repo-two/packages',
          sourceDirectory: '/repo',
          workspaceDirectory: '/worktrees/fork',
        ),
        '/worktrees/fork',
      );
    });
  });

  group('getWorkspaceNamingAttachments', () {
    test('removes full chat history from workspace naming context', () {
      // Upstream pairs the chat history with a `github_pr` attachment; this
      // repo's AgentAttachment union does not model that kind, so a review
      // attachment stands in as the non-text context that must survive.
      const chatHistory = TextAgentAttachment(
        title: 'Chat history',
        contextKind: 'chat_history',
        text: 'Long prior conversation',
      );
      const reviewContext = ReviewAgentAttachment(
        cwd: '/repo',
        mode: ReviewAttachmentMode.uncommitted,
        comments: [],
      );

      expect(
        getWorkspaceNamingAttachments(const [chatHistory, reviewContext]),
        const [reviewContext],
      );
    });

    test('keeps text attachments that are not chat history', () {
      const untagged = TextAgentAttachment(text: 'user note');
      const otherKind = TextAgentAttachment(
        text: 'pr body',
        contextKind: 'pull_request',
      );

      expect(getWorkspaceNamingAttachments(const [untagged, otherKind]), const [
        untagged,
        otherKind,
      ]);
    });

    test('preserves order and handles an empty list', () {
      const first = TextAgentAttachment(text: 'first');
      const history = TextAgentAttachment(
        text: 'history',
        contextKind: 'chat_history',
      );
      const last = TextAgentAttachment(text: 'last');

      expect(getWorkspaceNamingAttachments(const []), isEmpty);
      expect(
        getWorkspaceNamingAttachments(const [first, history, last]),
        const [first, last],
      );
    });
  });

  group('pickerItemToCheckoutRequest', () {
    test('returns null for no selection', () {
      expect(pickerItemToCheckoutRequest(null), isNull);
    });

    test('maps a branch row to branch-off with the branch name', () {
      expect(
        pickerItemToCheckoutRequest(const BranchPickerItem('dev'))?.toJson(),
        {'action': 'branch-off', 'refName': 'dev'},
      );
    });

    test(
      'maps a change-request row to checkout using the head ref and number',
      () {
        expect(
          pickerItemToCheckoutRequest(
            ChangeRequestPickerItem(_prItem()),
          )?.toJson(),
          {
            'action': 'checkout',
            'refName': 'feature/picker',
            'checkoutSource': {
              'kind': 'change_request',
              'forge': 'github',
              'number': 42,
            },
            'githubPrNumber': 42,
          },
        );
      },
    );

    test('handles a change request with a null baseRef', () {
      expect(
        pickerItemToCheckoutRequest(
          ChangeRequestPickerItem(
            _prItem(
              number: 7,
              title: 'Orphan branch',
              baseRefName: null,
              headRefName: 'orphan',
            ),
          ),
        )?.toJson(),
        {
          'action': 'checkout',
          'refName': 'orphan',
          'checkoutSource': {
            'kind': 'change_request',
            'forge': 'github',
            'number': 7,
          },
          'githubPrNumber': 7,
        },
      );
    });

    test(
      'does not send the legacy githubPrNumber for non-GitHub change requests',
      () {
        expect(
          pickerItemToCheckoutRequest(
            ChangeRequestPickerItem(
              _prItem(
                forge: 'gitlab',
                number: 21,
                projectPath: 'acme/repo',
                url: 'https://gitlab.example.com/acme/repo/-/merge_requests/21',
              ),
            ),
          )?.toJson(),
          {
            'action': 'checkout',
            'refName': 'feature/picker',
            'checkoutSource': {
              'kind': 'change_request',
              'forge': 'gitlab',
              'number': 21,
              'projectPath': 'acme/repo',
            },
          },
        );
      },
    );

    test('omits refName when the forge reported no usable head ref', () {
      for (final headRefName in <String?>[null, '', '   ']) {
        final request = pickerItemToCheckoutRequest(
          ChangeRequestPickerItem(_prItem(headRefName: headRefName)),
        );
        expect(request?.refName, isNull, reason: 'headRefName=$headRefName');
        expect(request?.toJson().containsKey('refName'), isFalse);
      }
    });

    test('trims a padded head ref', () {
      expect(
        pickerItemToCheckoutRequest(
          ChangeRequestPickerItem(_prItem(headRefName: '  orphan  ')),
        )?.refName,
        'orphan',
      );
    });

    test('omits an empty projectPath', () {
      final json = pickerItemToCheckoutRequest(
        ChangeRequestPickerItem(_prItem(forge: 'gitlab', projectPath: '')),
      )!.toJson();
      expect(
        (json['checkoutSource']! as Map).containsKey('projectPath'),
        isFalse,
      );
    });

    test('an explicitly blank forge is not GitHub', () {
      // `?? "github"` is nullish, so "" survives and fails the === "github"
      // test that gates the legacy PR-number field.
      final json = pickerItemToCheckoutRequest(
        ChangeRequestPickerItem(_prItem(forge: '')),
      )!.toJson();
      expect((json['checkoutSource']! as Map)['forge'], '');
      expect(json.containsKey('githubPrNumber'), isFalse);
    });

    test('equal selections produce equal requests', () {
      expect(
        pickerItemToCheckoutRequest(ChangeRequestPickerItem(_prItem())),
        pickerItemToCheckoutRequest(ChangeRequestPickerItem(_prItem())),
      );
      expect(
        pickerItemToCheckoutRequest(const BranchPickerItem('dev')),
        isNot(pickerItemToCheckoutRequest(const BranchPickerItem('main'))),
      );
    });
  });

  group('resolveNewWorkspaceInitialServerId', () {
    test('prefers explicit route host context over online-host fallback', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'online'],
            routeServerId: 'offline',
            projects: [_projectFor('online')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'online': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'offline',
      );
    });

    test('prefers the sole online host over a stale offline project', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'online'],
            lastActiveProject: _projectFor('offline'),
            projects: [_projectFor('offline')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'online': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'online',
      );

      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'online'],
            projects: [_projectFor('online')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'online': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'online',
      );
    });

    test('uses the last active project when there is no sole online host', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'other'],
            lastActiveProject: _projectFor('offline'),
            projects: [_projectFor('offline')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'other': HostRuntimeConnectionStatus.offline,
            },
          ),
        ),
        'offline',
      );
    });

    test('prefers a connecting project host over a stale offline last active '
        'project', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'connecting'],
            lastActiveProject: _projectFor('offline', 'remembered'),
            projects: [
              _projectFor('offline', 'remembered'),
              _projectFor('connecting', 'current'),
            ],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'connecting': HostRuntimeConnectionStatus.connecting,
            },
          ),
        ),
        'connecting',
      );
    });

    test('prefers the online last active project over another hydrated online '
        'project', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['host-a', 'host-b'],
            lastActiveProject: _projectFor('host-b', 'remembered'),
            projects: [_projectFor('host-a')],
            hostConnectionStatusByServerId: const {
              'host-a': HostRuntimeConnectionStatus.online,
              'host-b': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'host-b',
      );
    });

    test('falls back to the only online host even before projects hydrate', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          const NewWorkspaceInitialServerInput(
            allServerIds: ['offline-a', 'online', 'offline-b'],
            projects: [],
            hostConnectionStatusByServerId: {
              'offline-a': HostRuntimeConnectionStatus.offline,
              'online': HostRuntimeConnectionStatus.online,
              'offline-b': HostRuntimeConnectionStatus.offline,
            },
          ),
        ),
        'online',
      );
    });

    test('prefers an online host over the only cached offline project', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'online-a', 'online-b'],
            lastActiveProject: _projectFor('offline'),
            projects: [_projectFor('offline')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'online-a': HostRuntimeConnectionStatus.online,
              'online-b': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'online-a',
      );
    });

    test('prefers the first online project host over an empty online host', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const [
              'empty-online',
              'project-online-a',
              'project-online-b',
            ],
            projects: [
              _projectFor('project-online-a', 'a'),
              _projectFor('project-online-b', 'b'),
            ],
            hostConnectionStatusByServerId: const {
              'empty-online': HostRuntimeConnectionStatus.online,
              'project-online-a': HostRuntimeConnectionStatus.online,
              'project-online-b': HostRuntimeConnectionStatus.online,
            },
          ),
        ),
        'project-online-a',
      );
    });

    test(
      'uses the only host with selectable projects even before runtime status '
      'is online',
      () {
        expect(
          resolveNewWorkspaceInitialServerId(
            NewWorkspaceInitialServerInput(
              allServerIds: const ['offline', 'connected'],
              projects: [_projectFor('connected')],
              hostConnectionStatusByServerId: const {
                'offline': HostRuntimeConnectionStatus.offline,
                'connected': HostRuntimeConnectionStatus.connecting,
              },
            ),
          ),
          'connected',
        );
      },
    );

    test('returns the empty string when there are no hosts', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          const NewWorkspaceInitialServerInput(
            allServerIds: [],
            projects: [],
            routeServerId: 'ghost',
          ),
        ),
        '',
      );
    });

    test('trims the route host id before matching', () {
      expect(
        resolveNewWorkspaceInitialServerId(
          const NewWorkspaceInitialServerInput(
            allServerIds: ['host-a', 'host-b'],
            projects: [],
            routeServerId: '  host-b  ',
          ),
        ),
        'host-b',
      );
    });

    test('ignores a route host id that is unknown or blank', () {
      for (final routeServerId in <String?>['ghost', '   ', null]) {
        expect(
          resolveNewWorkspaceInitialServerId(
            NewWorkspaceInitialServerInput(
              allServerIds: const ['host-a', 'host-b'],
              projects: const [],
              routeServerId: routeServerId,
              hostConnectionStatusByServerId: const {
                'host-a': HostRuntimeConnectionStatus.offline,
                'host-b': HostRuntimeConnectionStatus.offline,
              },
            ),
          ),
          'host-a',
          reason: 'routeServerId=$routeServerId',
        );
      }
    });

    test('workspace multiplicity makes a non-worktree project selectable', () {
      final input = NewWorkspaceInitialServerInput(
        allServerIds: const ['plain', 'restricted'],
        projects: [_projectFor('restricted', 'project', false)],
        hostConnectionStatusByServerId: const {
          'plain': HostRuntimeConnectionStatus.connecting,
          'restricted': HostRuntimeConnectionStatus.connecting,
        },
      );
      // Without multiplicity the project is unusable, so no host stands out
      // and the first configured host wins.
      expect(resolveNewWorkspaceInitialServerId(input), 'plain');

      expect(
        resolveNewWorkspaceInitialServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: input.allServerIds,
            projects: input.projects,
            hostConnectionStatusByServerId:
                input.hostConnectionStatusByServerId,
            workspaceMultiplicityByServerId: const {'restricted': true},
          ),
        ),
        'restricted',
      );
    });
  });

  group('resolveNewWorkspaceAutomaticServerId', () {
    test('keeps a usable automatic host stable when the default changes', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['host-a', 'host-b'],
            projects: [_projectFor('host-a'), _projectFor('host-b')],
            hostConnectionStatusByServerId: const {
              'host-a': HostRuntimeConnectionStatus.online,
              'host-b': HostRuntimeConnectionStatus.online,
            },
          ),
          currentServerId: 'host-a',
          nextServerId: 'host-b',
        ),
        'host-a',
      );
    });

    test('switches to the remembered online host after it hydrates', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['host-a', 'host-b'],
            lastActiveProject: _projectFor('host-b', 'remembered'),
            projects: [
              _projectFor('host-a'),
              _projectFor('host-b', 'remembered'),
            ],
            hostConnectionStatusByServerId: const {
              'host-a': HostRuntimeConnectionStatus.online,
              'host-b': HostRuntimeConnectionStatus.online,
            },
          ),
          currentServerId: 'host-a',
          nextServerId: 'host-b',
        ),
        'host-b',
      );
    });

    test('switches from an offline automatic host to the online default', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'online'],
            projects: [_projectFor('offline')],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'online': HostRuntimeConnectionStatus.online,
            },
          ),
          currentServerId: 'offline',
          nextServerId: 'online',
        ),
        'online',
      );
    });

    test('switches from an offline automatic host to a connecting default with '
        'projects', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['offline', 'connecting'],
            lastActiveProject: _projectFor('offline', 'remembered'),
            projects: [
              _projectFor('offline', 'remembered'),
              _projectFor('connecting', 'current'),
            ],
            hostConnectionStatusByServerId: const {
              'offline': HostRuntimeConnectionStatus.offline,
              'connecting': HostRuntimeConnectionStatus.connecting,
            },
          ),
          currentServerId: 'offline',
          nextServerId: 'connecting',
        ),
        'connecting',
      );
    });

    test('switches to the default when the current host has no selectable '
        'projects', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          NewWorkspaceInitialServerInput(
            allServerIds: const ['empty', 'with-project'],
            projects: [_projectFor('with-project')],
            hostConnectionStatusByServerId: const {
              'empty': HostRuntimeConnectionStatus.connecting,
              'with-project': HostRuntimeConnectionStatus.connecting,
            },
          ),
          currentServerId: 'empty',
          nextServerId: 'with-project',
        ),
        'with-project',
      );
    });

    test(
      'does not switch from an online host to an offline cached project',
      () {
        expect(
          resolveNewWorkspaceAutomaticServerId(
            NewWorkspaceInitialServerInput(
              allServerIds: const ['online-empty', 'offline-project'],
              projects: [_projectFor('offline-project')],
              hostConnectionStatusByServerId: const {
                'online-empty': HostRuntimeConnectionStatus.online,
                'offline-project': HostRuntimeConnectionStatus.offline,
              },
            ),
            currentServerId: 'online-empty',
            nextServerId: 'offline-project',
          ),
          'online-empty',
        );
      },
    );

    test('takes the default when nothing is being preserved', () {
      for (final currentServerId in <String?>[null, '   ', 'ghost']) {
        expect(
          resolveNewWorkspaceAutomaticServerId(
            const NewWorkspaceInitialServerInput(
              allServerIds: ['host-a', 'host-b'],
              projects: [],
            ),
            currentServerId: currentServerId,
            nextServerId: 'host-b',
          ),
          'host-b',
          reason: 'currentServerId=$currentServerId',
        );
      }
    });

    test('keeps the current host when it already is the default', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          const NewWorkspaceInitialServerInput(
            allServerIds: ['host-a', 'host-b'],
            projects: [],
          ),
          currentServerId: 'host-a',
          nextServerId: 'host-a',
        ),
        'host-a',
      );
    });

    test('falls back to the first host when the default is unknown', () {
      expect(
        resolveNewWorkspaceAutomaticServerId(
          const NewWorkspaceInitialServerInput(
            allServerIds: ['host-a', 'host-b'],
            projects: [],
          ),
          currentServerId: null,
          nextServerId: 'ghost',
        ),
        'host-a',
      );
      expect(
        resolveNewWorkspaceAutomaticServerId(
          const NewWorkspaceInitialServerInput(allServerIds: [], projects: []),
          currentServerId: null,
          nextServerId: null,
        ),
        '',
      );
    });

    test('moves to the remembered host when no host is online at all, but not '
        'while some other host is', () {
      NewWorkspaceInitialServerInput inputFor(List<String> allServerIds) =>
          NewWorkspaceInitialServerInput(
            allServerIds: allServerIds,
            lastActiveProject: _projectFor('b', 'remembered'),
            projects: [_projectFor('a'), _projectFor('b', 'remembered')],
            hostConnectionStatusByServerId: const {
              'a': HostRuntimeConnectionStatus.connecting,
              'b': HostRuntimeConnectionStatus.connecting,
              'c': HostRuntimeConnectionStatus.online,
            },
          );

      expect(
        resolveNewWorkspaceAutomaticServerId(
          inputFor(const ['a', 'b']),
          currentServerId: 'a',
          nextServerId: 'b',
        ),
        'b',
      );
      expect(
        resolveNewWorkspaceAutomaticServerId(
          inputFor(const ['a', 'b', 'c']),
          currentServerId: 'a',
          nextServerId: 'b',
        ),
        'a',
      );
    });
  });
}
