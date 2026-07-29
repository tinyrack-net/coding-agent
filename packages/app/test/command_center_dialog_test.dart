import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/command_center/command_center.dart';
import 'package:coding_agent_app/widgets/command_center_dialog.dart';
import 'package:coding_agent_app/widgets/keyboard_shortcuts_dialog.dart';
import 'package:coding_agent_app/widgets/shortcut_badge.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<CommandCenterResultSection> sections(String query, void Function() run) {
  final all = <CommandCenterResult>[
    CommandCenterWorkspaceResult(
      id: 'workspace:one',
      title: 'Workspace One',
      subtitle: 'main',
      searchText: 'workspace one main',
      run: run,
    ),
    CommandCenterAgentResult(
      id: 'agent:one',
      title: 'Agent One',
      subtitle: 'codex · main',
      searchText: 'agent one codex main',
      agent: const AgentSummary(
        agentId: 'one',
        title: 'Agent One',
        cwd: '/work/main',
        provider: 'codex',
        model: 'main',
        mode: AgentMode.normal,
        runState: AgentRunState.running,
        createdAtMs: 1,
      ),
      run: run,
    ),
    CommandCenterContributionResult(
      id: 'action:settings',
      title: 'Settings',
      searchText: 'settings preferences',
      run: run,
      contribution: CommandCenterContribution(
        id: 'action:settings',
        group: 'actions',
        groupRank: 0,
        rank: 0,
        presentation: const CommandCenterActionPresentation(
          title: 'Settings',
          subtitle: 'Open preferences',
          sectionTitle: 'Actions',
          shortcutKeys: [
            ['mod', ','],
          ],
        ),
        run: run,
      ),
    ),
    CommandCenterContributionResult(
      id: 'model:gpt',
      title: 'GPT',
      searchText: 'models openai gpt',
      run: run,
      contribution: CommandCenterContribution(
        id: 'model:gpt',
        group: 'models',
        groupRank: 1,
        rank: 0,
        presentation: const CommandCenterChoicePresentation(
          path: ['Models', 'OpenAI', 'GPT'],
          selected: true,
          providerIcon: 'codex',
        ),
        run: run,
      ),
    ),
  ];
  final normalized = query.toLowerCase();
  final filtered = all
      .where(
        (result) =>
            normalized.isEmpty || result.searchText.contains(normalized),
      )
      .toList();
  return [
    CommandCenterResultSection(
      id: 'all',
      rank: 0,
      title: 'Results',
      results: filtered,
    ),
  ];
}

Widget commandDialog({
  required VoidCallback onClose,
  required VoidCallback onRun,
}) => FluentApp(
  home: SizedBox.expand(
    child: Center(
      child: CommandCenterDialog(
        sectionsBuilder: (query) => sections(query, onRun),
        isMac: false,
        onClose: onClose,
      ),
    ),
  ),
);

void main() {
  testWidgets('renders all result kinds and executes a tapped action', (
    tester,
  ) async {
    var runs = 0;
    await tester.pumpWidget(commandDialog(onClose: () {}, onRun: () => runs++));
    await tester.pumpAndSettle();

    expect(find.text('Workspace One'), findsOneWidget);
    expect(find.text('Agent One'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-status-dot-running')),
      findsOneWidget,
    );
    expect(find.byIcon(FluentIcons.robot), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('GPT'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('command-center-provider-icon-codex')),
      findsOneWidget,
    );
    expect(find.byIcon(FluentIcons.check_mark), findsOneWidget);
    expect(find.byType(ShortcutBadge), findsNWidgets(2));

    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(runs, 1);
  });

  testWidgets('search filters and shows empty state', (tester) async {
    await tester.pumpWidget(commandDialog(onClose: () {}, onRun: () {}));
    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'missing',
    );
    await tester.pump();
    expect(find.text('No results'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'agent',
    );
    await tester.pump();
    expect(find.text('Agent One'), findsOneWidget);
    expect(find.text('Workspace One'), findsNothing);
  });

  testWidgets('arrow navigation wraps and enter selects active row', (
    tester,
  ) async {
    var runs = 0;
    await tester.pumpWidget(commandDialog(onClose: () {}, onRun: () => runs++));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(runs, 1);
  });

  testWidgets('escape closes command center', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      commandDialog(onClose: () => closes++, onRun: () {}),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closes, 1);
  });

  testWidgets('shortcut dialog searches and closes', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      FluentApp(
        home: SizedBox.expand(
          child: Center(
            child: KeyboardShortcutsDialog(
              isMac: false,
              onClose: () => closes++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Navigation'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      'command center',
    );
    await tester.pump();
    expect(find.text('Toggle command center'), findsOneWidget);
    expect(find.text('Jump to workspace'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      'not-a-shortcut',
    );
    await tester.pump();
    expect(find.text('No results'), findsOneWidget);

    await tester.tap(find.byIcon(FluentIcons.chrome_close));
    await tester.pump(const Duration(milliseconds: 150));
    expect(closes, 1);
  });

  testWidgets('shortcut dialog displays and searches persisted overrides', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: SizedBox.expand(
          child: Center(
            child: KeyboardShortcutsDialog(
              isMac: false,
              overrides: const {
                'command-center-toggle-ctrl-k-non-mac': 'Ctrl+J',
              },
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      'ctrl+j',
    );
    await tester.pump();

    expect(find.text('Toggle command center'), findsOneWidget);
    expect(find.text('Ctrl+J'), findsOneWidget);
    expect(find.byType(ShortcutValueBadge), findsOneWidget);
  });
}
