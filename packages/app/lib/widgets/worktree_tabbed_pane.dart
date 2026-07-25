import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/worktree_actions.dart';
import '../screens/agent_chat_screen.dart';
import '../state/agents_provider.dart';
import '../state/terminal_providers.dart';
import '../state/worktree_tabs_provider.dart';
import 'diff/diff_pane.dart';
import 'draft_session_composer.dart';
import 'terminal_pane.dart';

/// One worktree's tab strip — Paseo parity: a session opens in a tab by
/// default, and the user can freely add more agent sessions, terminals, or
/// the working diff as sibling top-level tabs (never nested inside an agent
/// tab).
class WorktreeTabbedPane extends ConsumerWidget {
  const WorktreeTabbedPane({
    super.key,
    required this.worktreePath,
    this.projectPath,
    this.branch,
    this.isWorktree = false,
  });

  final String worktreePath;

  /// Passed through to a `draft` tab's [DraftSessionComposer] so a submitted
  /// session is created with the right owning-project/branch metadata.
  final String? projectPath;
  final String? branch;
  final bool isWorktree;

  Future<void> _closeAgentTab(
    BuildContext context,
    WidgetRef ref,
    WorktreeTab tab,
  ) async {
    final agent = ref.read(agentsProvider)[tab.agentId];
    if (agent == null) {
      ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
      return;
    }
    final isActive = agent.runState == AgentRunState.running ||
        agent.runState == AgentRunState.awaitingPermission;
    if (isActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('Archive running agent?'),
          content: const Text(
            'This agent is still running. Closing its tab will archive it.',
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Archive'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!context.mounted) return;
    await archiveAgentWithWorktreeConfirm(context, ref, agent);
    ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
  }

  Future<void> _closeTerminalTab(
    BuildContext context,
    WidgetRef ref,
    WorktreeTab tab,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Close terminal?'),
        content: const Text('This will end the running shell session.'),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final key = (worktreePath: worktreePath, tabId: tab.tabId);
    await ref.read(terminalSessionProvider(key).notifier).shutdown();
    if (!context.mounted) return;
    ref.invalidate(terminalSessionProvider(key));
    ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
  }

  void _closeTab(BuildContext context, WidgetRef ref, WorktreeTab tab) {
    switch (tab.kind) {
      case WorktreeTabKind.agent:
        _closeAgentTab(context, ref, tab);
      case WorktreeTabKind.terminal:
        _closeTerminalTab(context, ref, tab);
      case WorktreeTabKind.draft:
      case WorktreeTabKind.diff:
        ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
    }
  }

  String _labelFor(WidgetRef ref, WorktreeTab tab, int terminalOrdinal) {
    switch (tab.kind) {
      case WorktreeTabKind.draft:
        return 'New session';
      case WorktreeTabKind.diff:
        return 'Diff';
      case WorktreeTabKind.terminal:
        return 'Terminal $terminalOrdinal';
      case WorktreeTabKind.agent:
        final agent = ref.watch(agentSummaryProvider(tab.agentId!));
        if (agent == null) return 'Agent';
        return agent.title.isNotEmpty
            ? agent.title
            : '${agent.provider} · ${agent.model}';
    }
  }

  IconData _iconFor(WorktreeTabKind kind) => switch (kind) {
        WorktreeTabKind.draft => FluentIcons.add,
        WorktreeTabKind.diff => FluentIcons.branch_compare,
        WorktreeTabKind.terminal => FluentIcons.command_prompt,
        WorktreeTabKind.agent => FluentIcons.chat,
      };

  Widget _bodyFor(WorktreeTab tab) => switch (tab.kind) {
        WorktreeTabKind.draft => DraftSessionComposer(
            worktreePath: worktreePath,
            tabId: tab.tabId,
            projectPath: projectPath,
            branch: branch,
            isWorktree: isWorktree,
          ),
        WorktreeTabKind.diff => DiffPane(cwd: worktreePath),
        WorktreeTabKind.terminal =>
          TerminalPane(worktreePath: worktreePath, tabId: tab.tabId),
        WorktreeTabKind.agent => AgentChatScreen(agentId: tab.agentId!),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsState = ref.watch(worktreeTabsProvider(worktreePath));
    final tabs = tabsState.layout.tabs;
    final activeTabId = tabsState.layout.activeTabId;
    final activeIndex = activeTabId == null
        ? 0
        : tabs.indexWhere((t) => t.tabId == activeTabId).clamp(0, tabs.length - 1);

    var terminalOrdinal = 0;

    return TabView(
      currentIndex: activeIndex < 0 ? 0 : activeIndex,
      onChanged: (index) => ref
          .read(worktreeTabsProvider(worktreePath).notifier)
          .setActiveTab(tabs[index].tabId),
      onNewPressed: () => ref
          .read(worktreeTabsProvider(worktreePath).notifier)
          .addTab(WorktreeTabKind.draft),
      footer: DropDownButton(
        buttonBuilder: (context, onOpen) => IconButton(
          icon: const Icon(FluentIcons.chevron_down, size: 12),
          onPressed: onOpen,
        ),
        items: [
          MenuFlyoutItem(
            text: const Text('New agent session'),
            leading: const Icon(FluentIcons.chat),
            onPressed: () => ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .addTab(WorktreeTabKind.draft),
          ),
          MenuFlyoutItem(
            text: const Text('New terminal'),
            leading: const Icon(FluentIcons.command_prompt),
            onPressed: () => ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .addTab(WorktreeTabKind.terminal),
          ),
          MenuFlyoutItem(
            text: const Text('View diff'),
            leading: const Icon(FluentIcons.branch_compare),
            onPressed: () => ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .showDiffTab(),
          ),
        ],
      ),
      tabs: [
        for (final tab in tabs)
          Tab(
            key: ValueKey(tab.tabId),
            icon: Icon(_iconFor(tab.kind), size: 14),
            text: Text(
              _labelFor(
                ref,
                tab,
                tab.kind == WorktreeTabKind.terminal ? ++terminalOrdinal : 0,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            body: _bodyFor(tab),
            onClosed: () => _closeTab(context, ref, tab),
          ),
      ],
    );
  }
}
