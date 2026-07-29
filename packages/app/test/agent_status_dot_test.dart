import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/sidebar/status_dot_color.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/agent_status_dot.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpDot(
  WidgetTester tester, {
  AgentRunState? status,
  bool? requiresAttention = false,
  AgentAttentionReason? attentionReason,
  int pendingPermissionCount = 0,
  bool showInactive = false,
}) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(),
    home: Center(
      child: AgentStatusDot(
        status: status,
        requiresAttention: requiresAttention,
        attentionReason: attentionReason,
        pendingPermissionCount: pendingPermissionCount,
        showInactive: showInactive,
      ),
    ),
  ),
);

void main() {
  testWidgets('renders an exact 8px running dot', (tester) async {
    await pumpDot(tester, status: AgentRunState.running);

    final dot = find.byKey(const ValueKey('agent-status-dot-running'));
    expect(tester.getSize(dot), const Size.square(8));
    final decoration =
        tester.widget<DecoratedBox>(dot).decoration as BoxDecoration;
    expect(decoration.color, agentStatusRunningColor);
    expect(decoration.shape, BoxShape.circle);
  });

  testWidgets('applies permission, failure, and attention precedence', (
    tester,
  ) async {
    await pumpDot(
      tester,
      status: AgentRunState.error,
      requiresAttention: true,
      attentionReason: AgentAttentionReason.error,
      pendingPermissionCount: 1,
    );
    expect(
      find.byKey(const ValueKey('agent-status-dot-needsInput')),
      findsOneWidget,
    );

    await pumpDot(
      tester,
      status: AgentRunState.running,
      attentionReason: AgentAttentionReason.error,
    );
    expect(
      find.byKey(const ValueKey('agent-status-dot-failed')),
      findsOneWidget,
    );

    await pumpDot(
      tester,
      status: AgentRunState.idle,
      requiresAttention: true,
      attentionReason: AgentAttentionReason.finished,
    );
    expect(
      find.byKey(const ValueKey('agent-status-dot-attention')),
      findsOneWidget,
    );
  });

  testWidgets('hides done/null unless inactive dots are requested', (
    tester,
  ) async {
    await pumpDot(tester, status: AgentRunState.idle);
    expect(find.byKey(const ValueKey('agent-status-dot-done')), findsNothing);

    await pumpDot(tester);
    expect(find.byKey(const ValueKey('agent-status-dot-done')), findsNothing);

    await pumpDot(tester, status: AgentRunState.idle, showInactive: true);
    final dot = find.byKey(const ValueKey('agent-status-dot-done'));
    expect(dot, findsOneWidget);
    final decoration =
        tester.widget<DecoratedBox>(dot).decoration as BoxDecoration;
    expect(decoration.color, paseoPaletteFor(AppThemeName.dark).border);
  });
}
