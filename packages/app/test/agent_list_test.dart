import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/agent_history_provider.dart';
import 'package:coding_agent_app/widgets/agent_list.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 7, 30, 12);

  test('matches frozen date-section and relative-time boundaries', () {
    expect(
      deriveAgentDateSection(DateTime(2026, 7, 30), now),
      AgentDateSection.today,
    );
    expect(
      deriveAgentDateSection(DateTime(2026, 7, 29), now),
      AgentDateSection.yesterday,
    );
    expect(
      deriveAgentDateSection(DateTime(2026, 7, 23), now),
      AgentDateSection.thisWeek,
    );
    expect(
      deriveAgentDateSection(DateTime(2026, 6, 30), now),
      AgentDateSection.thisMonth,
    );
    expect(
      deriveAgentDateSection(DateTime(2026, 6, 29), now),
      AgentDateSection.older,
    );
    expect(
      formatAgentTimeAgo(now.subtract(const Duration(seconds: 9)), now),
      'just now',
    );
    expect(
      formatAgentTimeAgo(now.subtract(const Duration(seconds: 15)), now),
      '15s ago',
    );
    expect(
      formatAgentTimeAgo(now.subtract(const Duration(minutes: 5)), now),
      '5m ago',
    );
    expect(
      formatAgentTimeAgo(now.subtract(const Duration(hours: 2)), now),
      '2h ago',
    );
    expect(
      formatAgentTimeAgo(now.subtract(const Duration(days: 3)), now),
      '3d ago',
    );
    expect(formatAgentTimeAgo(DateTime(2026, 1, 15), now), 'Jan 15');
  });

  testWidgets(
    'renders frozen desktop metadata, badges, selection and gestures',
    (tester) async {
      AgentHistoryEntry? pressed;
      AgentHistoryEntry? longPressed;
      final entry = _entry(
        activity: now.subtract(const Duration(minutes: 5)),
        archived: true,
        pending: 2,
        attention: true,
      );
      await tester.pumpWidget(
        FluentApp(
          theme: buildAppTheme(),
          home: SizedBox(
            width: 1100,
            height: 600,
            child: AgentList(
              agents: [entry],
              now: now,
              selectedAgentId: 'server-a:agent-a',
              showHostColumn: true,
              onAgentPressed: (value) => pressed = value,
              onAgentLongPressed: (value) => longPressed = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Session title'), findsOneWidget);
      expect(find.text('Project'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('5m ago'), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('2 pending'), findsOneWidget);
      expect(find.text('Attention'), findsOneWidget);

      final row = find.byKey(const ValueKey('agent-row-server-a-agent-a'));
      await tester.tap(row);
      expect(pressed, same(entry));
      await tester.longPress(row);
      expect(longPressed, same(entry));
    },
  );

  testWidgets('uses compact metadata and the frozen fallback title', (
    tester,
  ) async {
    final entry = _entry(
      activity: now.subtract(const Duration(days: 1)),
      title: '',
    );
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: SizedBox(
          width: 500,
          height: 600,
          child: AgentList(
            agents: [entry],
            now: now,
            showHostColumn: true,
            onAgentPressed: (_) {},
            onAgentLongPressed: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
  });
}

AgentHistoryEntry _entry({
  required DateTime activity,
  String title = 'Session title',
  bool archived = false,
  int pending = 0,
  bool attention = false,
}) => AgentHistoryEntry(
  serverId: 'server-a',
  serverLabel: 'Local',
  pendingPermissionCount: pending,
  agent: AgentSummary(
    agentId: 'agent-a',
    title: title,
    cwd: '/repo',
    provider: 'codex',
    model: 'gpt-5',
    mode: AgentMode.normal,
    runState: AgentRunState.idle,
    createdAtMs: activity.millisecondsSinceEpoch,
    updatedAt: activity.toUtc().toIso8601String(),
    workspaceId: 'workspace-a',
    requiresAttention: attention,
    archivedAt: archived ? activity.toUtc().toIso8601String() : null,
  ),
  project: const {
    'projectKey': '/repo',
    'projectName': 'Project',
    'workspaceName': 'Workspace',
    'checkout': {'currentBranch': 'main'},
  },
);
