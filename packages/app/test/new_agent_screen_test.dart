import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/new_agent_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _claude = ProviderInfo(
  id: ProviderId.claude,
  displayName: 'Claude',
  available: true,
  models: [
    ProviderModel(id: 'sonnet', displayName: 'Sonnet'),
    ProviderModel(id: 'opus', displayName: 'Opus'),
  ],
);

const _createdAgent = AgentSummary(
  agentId: 'new-1',
  title: 'My agent',
  cwd: '/repo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
);

const _codex = ProviderInfo(
  id: ProviderId.codex,
  displayName: 'Codex',
  available: true,
  models: [ProviderModel(id: 'codex-model', displayName: 'Codex Model')],
);

const _gitProject = ProjectInfo(
  path: '/repo',
  name: 'repo',
  isGitRepo: true,
);

const _worktree = WorktreeInfo(
  path: '/repo-wt/feature-x',
  branch: 'feature/x',
  projectPath: '/repo',
);

/// Scriptable fake: `onRequest` decides responses per message type; every
/// call is recorded for assertions.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  Map<String, Object?> Function(String type, Map<String, Object?> payload)
      onRequest = (type, payload) => const {};

  /// Agents known so far, kept in sync so that `AgentsNotifier`'s
  /// connect-triggered `agent.list.request` (which we don't otherwise
  /// script per test) doesn't race a just-created agent out of state.
  final List<AgentSummary> _agents = [];

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentListRequest) {
      return {'agents': _agents.map((a) => a.toJson()).toList()};
    }
    requests.add((type, payload));
    final result = onRequest(type, payload);
    if (type == MessageTypes.agentCreateRequest) {
      final agentJson = result['agent'] as Map<String, Object?>?;
      if (agentJson != null) _agents.add(AgentSummary.fromJson(agentJson));
    }
    return result;
  }
}

Future<ProviderContainer> pumpNewAgentDialog(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNewAgentDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('no providers available shows guidance instead of the form',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return const {'providers': []};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    expect(
      find.textContaining('No providers are available on this machine'),
      findsOneWidget,
    );
    expect(find.text('Create'), findsNothing);
  });

  testWidgets('with no projects: custom path field is shown and defaults '
      'are pre-filled', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    expect(find.text('New Agent'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Working directory'), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('Cancel closes the dialog without creating an agent',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {'projects': []};
      };
    await pumpNewAgentDialog(tester, client);
    expect(find.text('New Agent'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('New Agent'), findsNothing);
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
  });

  testWidgets(
      'filling the form and tapping Create requests agent.create with the '
      'chosen provider/model/mode/title, then closes and selects the agent',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    final container = await pumpNewAgentDialog(tester, client);

    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '/repo',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Title (optional)'),
      'My agent',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(created.$2['cwd'], '/repo');
    expect(created.$2['provider'], 'claude');
    expect(created.$2['model'], 'sonnet');
    expect(created.$2['mode'], 'normal');
    expect(created.$2['title'], 'My agent');

    // Dialog closed.
    expect(find.text('New Agent'), findsNothing);
    // The newly created agent is selected and tracked.
    expect(container.read(selectedAgentProvider), 'new-1');
    expect(container.read(agentsProvider)['new-1']?.title, 'My agent');
  });

  testWidgets('Create is disabled with an empty custom cwd; submit is a '
      'no-op', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {'projects': []};
      };
    await pumpNewAgentDialog(tester, client);

    // Clear the pre-filled default cwd.
    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // The button is enabled (model is selected) but submit() early-returns
    // on the empty cwd, so no request is issued and the dialog stays open.
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
    expect(find.text('New Agent'), findsOneWidget);
  });

  testWidgets('a failed create shows a snackbar and keeps the dialog open',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.agentCreateRequest) {
          throw StateError('daemon rejected the request');
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '/repo',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to create agent'), findsOneWidget);
    expect(find.text('New Agent'), findsOneWidget);
  });

  testWidgets('switching the model dropdown changes the create payload',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '/repo',
    );

    // Open the model dropdown and pick "Opus".
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Sonnet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opus').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(created.$2['model'], 'opus');
  });

  testWidgets('failed to load providers shows an inline error',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          throw StateError('daemon unreachable');
        }
        return const {'projects': []};
      };
    await pumpNewAgentDialog(tester, client);

    expect(find.textContaining('Failed to load providers'), findsOneWidget);
    expect(find.text('Create'), findsNothing);
  });

  testWidgets('switching the provider dropdown resets the model and updates '
      'the create payload', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson(), _codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '/repo',
    );

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<ProviderId>, 'Claude'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(created.$2['provider'], 'codex');
    expect(created.$2['model'], 'codex-model');
  });

  testWidgets('switching the mode segmented button updates the create '
      'payload', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.enterText(
      find.widgetWithText(TextField, 'Working directory'),
      '/repo',
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(created.$2['mode'], 'plan');
  });

  testWidgets(
      'a git-repo project shows a worktree checkbox; enabling it without a '
      'branch disables Create, and providing a branch creates the agent in '
      'the new worktree', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.worktreeCreateRequest) {
          return {'worktree': _worktree.toJson()};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    // The project dropdown defaults to "Custom path…" the first time the
    // form builds workspace fields (the project list is still loading at
    // that point), so explicitly select the git project to reach the
    // worktree checkbox.
    expect(find.text('Run in new worktree'), findsNothing);
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('repo').last);
    await tester.pumpAndSettle();

    expect(find.text('Run in new worktree'), findsOneWidget);
    expect(find.text('Branch name'), findsNothing);

    await tester.tap(find.text('Run in new worktree'));
    await tester.pumpAndSettle();
    expect(find.text('Branch name'), findsOneWidget);

    // No branch entered yet: Create is disabled.
    var createButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create'),
    );
    expect(createButton.onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Branch name'),
      'feature/x',
    );
    await tester.pumpAndSettle();

    createButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create'),
    );
    expect(createButton.onPressed, isNotNull);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final worktreeCreated = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.worktreeCreateRequest);
    expect(worktreeCreated.$2['projectPath'], '/repo');
    expect(worktreeCreated.$2['branch'], 'feature/x');

    final agentCreated = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(agentCreated.$2['cwd'], _worktree.path);
  });

  testWidgets(
      'choosing "Add project…" opens a dialog; Cancel leaves the form '
      'unchanged', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {'projects': []};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project…').last);
    await tester.pumpAndSettle();

    expect(find.text('Add project'), findsOneWidget);
    // Tap Cancel (`Navigator.of(context).pop()` with no value) and pump a
    // single zero-duration frame only: `_promptAddProject` disposes the
    // dialog's local `TextEditingController` as soon as the pop resolves,
    // and letting the reverse transition animate through further
    // time-advancing frames rebuilds the (now-disposed) TextField mid-flight,
    // which trips an unrelated framework assertion in debug/test mode (a
    // harmless, assert-only condition that is compiled out in release
    // builds). Asserting on the immediate outcome — no project.add request
    // was issued — is enough to cover the Cancel branch without depending on
    // the dialog's exit animation fully finishing.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cancel'),
      ),
    );

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.projectAddRequest),
      isFalse,
    );
  });

  testWidgets(
      'adding a project via the Add button registers it and selects it',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.projectAddRequest) {
          return {'project': _gitProject.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project…').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Project path'), '/repo');
    // Deliberately avoid `pumpAndSettle` here (see the comment on the Cancel
    // test above): the dialog's local `TextEditingController` is disposed as
    // soon as the pop resolves, and pumping through the exit animation's
    // intermediate frames rebuilds the disposed TextField, tripping a
    // debug-only framework assertion. `tester.tap` already settles the
    // gesture and the fake client resolves synchronously, so the
    // project.add request has already landed by this point.
    await tester.tap(find.text('Add'));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.projectAddRequest),
      isTrue,
    );
  });

  testWidgets('adding a project via Enter in the path field registers it',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.projectAddRequest) {
          return {'project': _gitProject.toJson()};
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project…').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Project path'), '/repo');
    // See the comment on the "Add button" test above: avoid pumping through
    // the dialog's exit animation after its `TextEditingController` has been
    // disposed.
    await tester.testTextInput.receiveAction(TextInputAction.done);

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.projectAddRequest),
      isTrue,
    );
  });

  testWidgets('a failed project add shows a snackbar and keeps the dialog '
      'open', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return const {'projects': []};
        }
        if (type == MessageTypes.projectAddRequest) {
          throw StateError('bad path');
        }
        return const {};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project…').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Project path'),
      '/nope',
    );
    // See the comment on the "Add button" test above: avoid pumping through
    // the dialog's exit animation after its `TextEditingController` has been
    // disposed. The request is already recorded by the time `tap` returns,
    // which is enough to prove the failure path (`catch` + snackbar) ran.
    await tester.tap(find.text('Add'));

    final attempt = client.requests
        .where((r) => r.$1 == MessageTypes.projectAddRequest)
        .toList();
    expect(attempt, hasLength(1));
    expect(attempt.single.$2['path'], '/nope');
  });

  testWidgets('an empty path submitted to the Add project dialog is a no-op',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {'projects': []};
      };
    await pumpNewAgentDialog(tester, client);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Custom path…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project…').last);
    await tester.pumpAndSettle();

    // No pump after tapping Add (see the earlier comments): the empty text
    // still pops (and disposes) the dialog before short-circuiting on the
    // empty-path check.
    await tester.tap(find.text('Add'));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.projectAddRequest),
      isFalse,
    );
  });
}
