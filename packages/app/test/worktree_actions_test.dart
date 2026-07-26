/// Covers `core/worktree_actions.dart` — in particular the dirty-worktree
/// conflict flow, which is the part a user hits when closing a tab whose
/// worktree has uncommitted changes.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/worktree_actions.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];

  /// Return a payload, or throw, per request type.
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return onRequest?.call(type, payload) ?? const {};
  }
}

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Agent',
  cwd: 'C:/wt/feature',
  provider: 'p1',
  model: 'm',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  projectPath: 'C:/repo',
  branch: 'feature',
  isWorktree: true,
);

/// A plain (non-isolated) agent: archiving it must never ask about worktrees.
/// `copyWith` can't flip `isWorktree`, so this is a separate fixture.
const _localAgent = AgentSummary(
  agentId: 'a2',
  title: 'Local',
  cwd: 'C:/repo',
  provider: 'p1',
  model: 'm',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  projectPath: 'C:/repo',
  isWorktree: false,
);

DaemonRpcException _rpc(String code, String message) =>
    DaemonRpcException(RpcError(code: code, message: message));

void main() {
  /// Pumps a host widget so the actions get a real [BuildContext] + [WidgetRef]
  /// (they show dialogs and toasts, so a bare container isn't enough).
  Future<({BuildContext context, WidgetRef ref})> pumpHost(
    WidgetTester tester,
    FakeDaemonClient client,
  ) async {
    late BuildContext capturedContext;
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [daemonClientProvider.overrideWithValue(client)],
        child: FluentApp(
          home: Consumer(
            builder: (context, ref, _) {
              capturedContext = context;
              capturedRef = ref;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (context: capturedContext, ref: capturedRef);
  }

  group('archiveWorktreeWithConfirm', () {
    testWidgets('archives without prompting when the worktree is clean', (
      tester,
    ) async {
      final client = FakeDaemonClient();
      final host = await pumpHost(tester, client);

      await archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();

      final archives = client.requests
          .where((r) => r.$1 == MessageTypes.worktreeArchiveRequest)
          .toList();
      expect(archives, hasLength(1));
      expect(archives.single.$2['path'], 'C:/wt/feature');
      expect(archives.single.$2.containsKey('force'), isFalse);
      expect(find.byType(ContentDialog), findsNothing);
    });

    testWidgets('a conflict prompts, then retries with force on confirm', (
      tester,
    ) async {
      var attempts = 0;
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.worktreeArchiveRequest) {
            attempts++;
            // First (unforced) attempt reports the dirty worktree.
            if (payload['force'] != true) {
              throw _rpc(RpcErrorCodes.conflict, 'worktree has 3 dirty files');
            }
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      final done = archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();

      expect(find.text('Uncommitted changes'), findsOneWidget);
      // The daemon's message must reach the user — it names what's dirty.
      expect(find.textContaining('worktree has 3 dirty files'), findsOneWidget);

      await tester.tap(find.text('Discard and remove'));
      await tester.pumpAndSettle();
      await done;

      expect(attempts, 2);
      final forced = client.requests
          .where((r) => r.$1 == MessageTypes.worktreeArchiveRequest)
          .last;
      expect(forced.$2['force'], isTrue);
    });

    testWidgets('cancelling the conflict prompt leaves the worktree alone', (
      tester,
    ) async {
      var attempts = 0;
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.worktreeArchiveRequest) {
            attempts++;
            throw _rpc(RpcErrorCodes.conflict, 'dirty');
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      final done = archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await done;

      // No forced retry.
      expect(attempts, 1);
    });

    testWidgets('a forced retry that also fails surfaces a toast', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.worktreeArchiveRequest) {
            if (payload['force'] != true) {
              throw _rpc(RpcErrorCodes.conflict, 'dirty');
            }
            throw StateError('git failed');
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      final done = archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard and remove'));
      await tester.pumpAndSettle();
      await done;

      expect(find.textContaining('Failed to remove worktree'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    // A non-conflict RPC error is a hard failure, not a prompt.
    testWidgets('a non-conflict RPC error toasts without prompting', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.worktreeArchiveRequest) {
            throw _rpc(RpcErrorCodes.notFound, 'no such worktree');
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      await archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();

      expect(find.byType(ContentDialog), findsNothing);
      expect(find.textContaining('no such worktree'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a non-RPC exception toasts', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.worktreeArchiveRequest) {
            throw StateError('socket closed');
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      await archiveWorktreeWithConfirm(
        host.context,
        host.ref,
        'C:/repo',
        'C:/wt/feature',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('socket closed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('archiveAgentWithWorktreeConfirm', () {
    testWidgets('a failed archive toasts and stops', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.agentArchiveRequest) {
            throw StateError('daemon offline');
          }
          return const {};
        };
      final host = await pumpHost(tester, client);

      await archiveAgentWithWorktreeConfirm(host.context, host.ref, _agent);
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to archive'), findsOneWidget);
      // Never reaches the worktree question.
      expect(find.byType(ContentDialog), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a non-worktree agent is archived with no follow-up', (
      tester,
    ) async {
      final client = FakeDaemonClient();
      final host = await pumpHost(tester, client);

      await archiveAgentWithWorktreeConfirm(
        host.context,
        host.ref,
        _localAgent,
      );
      await tester.pumpAndSettle();

      expect(find.byType(ContentDialog), findsNothing);
      expect(
        client.requests.where((r) => r.$1 == MessageTypes.agentArchiveRequest),
        hasLength(1),
      );
    });

    testWidgets('offers to delete the worktree once the last agent is gone', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.agentListRequest) {
            return const {'agents': []};
          }
          return const {};
        };
      final host = await pumpHost(tester, client);
      // Warm the agents provider so `remaining` reads an empty (loaded) map.
      host.ref.read(agentsProvider);
      await tester.pumpAndSettle();

      final done =
          archiveAgentWithWorktreeConfirm(host.context, host.ref, _agent);
      await tester.pumpAndSettle();

      expect(find.text('Delete worktree?'), findsOneWidget);
      expect(find.textContaining('feature'), findsWidgets);

      // Keeping it must not archive the worktree.
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await done;

      expect(
        client.requests.where(
          (r) => r.$1 == MessageTypes.worktreeArchiveRequest,
        ),
        isEmpty,
      );
    });

    testWidgets('Remove archives the worktree too', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.agentListRequest) {
            return const {'agents': []};
          }
          return const {};
        };
      final host = await pumpHost(tester, client);
      host.ref.read(agentsProvider);
      await tester.pumpAndSettle();

      final done =
          archiveAgentWithWorktreeConfirm(host.context, host.ref, _agent);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await done;

      final archives = client.requests
          .where((r) => r.$1 == MessageTypes.worktreeArchiveRequest)
          .toList();
      expect(archives, hasLength(1));
      expect(archives.single.$2['path'], 'C:/wt/feature');
    });
  });
}
