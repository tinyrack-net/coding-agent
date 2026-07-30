import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/worktree_actions.dart';
import '../import_sessions/import_session_dialog.dart';
import '../keyboard/keyboard_action_dispatcher.dart';
import '../screens/agent_chat_screen.dart';
import '../screens/provider_subagent_screen.dart';
import '../state/agents_provider.dart';
import '../state/appearance_provider.dart';
import '../state/provider_subagents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/subagents_provider.dart';
import '../state/terminal_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../state/workspace_modified_tabs_provider.dart';
import '../state/workspace_focus_mode_provider.dart';
import '../state/workspace_catalog_provider.dart';
import '../state/workspace_tab_keyboard_drag_provider.dart';
import '../state/workspace_setup_provider.dart';
import '../workspace/workspace_file_open.dart';
import '../workspace/workspace_distance_draggable.dart';
import '../workspace/workspace_pane_layout.dart';
import '../workspace/workspace_tab_drag_accessibility.dart';
import '../workspace/workspace_tab_layout.dart';
import '../workspace/workspace_mounted_tab_set.dart';
import 'diff/diff_pane.dart';
import 'draft_session_composer.dart';
import 'terminal_pane.dart';
import 'workspace_file_pane.dart';
import 'workspace_explorer.dart';

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
    this.workspaceId,
  });

  final String worktreePath;

  /// Passed through to a `draft` tab's [DraftSessionComposer] so a submitted
  /// session is created with the right owning-project/branch metadata.
  final String? projectPath;
  final String? branch;
  final bool isWorktree;
  final String? workspaceId;

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
    if (resolveCloseAgentTabPolicy(agent) == CloseAgentTabPolicy.layoutOnly) {
      ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
      return;
    }
    final isActive =
        agent.runState == AgentRunState.running ||
        agent.runState == AgentRunState.awaitingPermission;
    if (isActive) {
      final notifier = ref.read(worktreeTabsProvider(worktreePath).notifier);
      final focusToken = notifier.unfocusPane();
      bool? confirmed;
      try {
        confirmed = await showDialog<bool>(
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
      } finally {
        notifier.restorePaneFocus(focusToken);
      }
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
    final notifier = ref.read(worktreeTabsProvider(worktreePath).notifier);
    final focusToken = notifier.unfocusPane();
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
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
    } finally {
      notifier.restorePaneFocus(focusToken);
    }
    if (confirmed != true) return;
    final key = (
      worktreePath: worktreePath,
      tabId: tab.tabId,
      workspaceId: workspaceId,
    );
    await ref.read(terminalSessionProvider(key).notifier).shutdown();
    if (!context.mounted) return;
    ref.invalidate(terminalSessionProvider(key));
    ref.read(worktreeTabsProvider(worktreePath).notifier).closeTab(tab.tabId);
  }

  Future<void> _closeTab(
    BuildContext context,
    WidgetRef ref,
    WorktreeTab tab,
  ) async {
    if (tab.kind == WorktreeTabKind.file) {
      ref
          .read(workspaceModifiedTabsProvider(worktreePath).notifier)
          .setModified(tab.tabId, modified: false);
    }
    return switch (tab.kind) {
      WorktreeTabKind.agent => _closeAgentTab(context, ref, tab),
      WorktreeTabKind.terminal => _closeTerminalTab(context, ref, tab),
      WorktreeTabKind.draft ||
      WorktreeTabKind.diff ||
      WorktreeTabKind.providerSubagent ||
      WorktreeTabKind.file ||
      WorktreeTabKind.setup => Future.sync(
        () => ref
            .read(worktreeTabsProvider(worktreePath).notifier)
            .closeTab(tab.tabId),
      ),
    };
  }

  String _labelFor(WidgetRef ref, WorktreeTab tab, int terminalOrdinal) {
    switch (tab.kind) {
      case WorktreeTabKind.draft:
        return 'New agent';
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
      case WorktreeTabKind.providerSubagent:
        final descriptor = ref.watch(
          providerSubagentsProvider(
            tab.parentAgentId!,
          ).select((state) => state.descriptors[tab.subagentId!]),
        );
        return descriptor?.title ?? 'Sub-agent';
      case WorktreeTabKind.file:
        return tab.filePath
                ?.replaceAll(r'\', '/')
                .split('/')
                .where((segment) => segment.isNotEmpty)
                .lastOrNull ??
            'File';
      case WorktreeTabKind.setup:
        return 'Setup';
    }
  }

  IconData _iconFor(WidgetRef ref, WorktreeTab tab) {
    if (tab.kind == WorktreeTabKind.setup) {
      final client = ref.watch(daemonClientProvider);
      final serverId =
          ref.watch(activeHostProvider)?.serverId ??
          client.serverInfo?.serverId ??
          'local';
      final status = ref
          .watch(
            workspaceSetupEntryProvider(
              WorkspaceSetupKey(
                serverId: serverId,
                workspaceId: tab.setupWorkspaceId!,
              ),
            ),
          )
          ?.snapshot
          .status;
      return switch (status) {
        WorkspaceSetupStatus.completed => FluentIcons.completed_solid,
        WorkspaceSetupStatus.failed => FluentIcons.error_badge,
        WorkspaceSetupStatus.running || null => FluentIcons.command_prompt,
      };
    }
    return switch (tab.kind) {
      WorktreeTabKind.draft => FluentIcons.add,
      WorktreeTabKind.diff => FluentIcons.branch_compare,
      WorktreeTabKind.terminal => FluentIcons.command_prompt,
      WorktreeTabKind.agent => FluentIcons.chat,
      WorktreeTabKind.providerSubagent => FluentIcons.branch_fork,
      WorktreeTabKind.file => FluentIcons.page,
      WorktreeTabKind.setup => throw StateError('handled above'),
    };
  }

  Widget _bodyFor(
    WidgetRef ref,
    WorktreeTab tab,
    bool isActive,
    void Function(WorkspaceFileOpenRequest request) onOpenWorkspaceFile,
  ) => switch (tab.kind) {
    WorktreeTabKind.draft => DraftSessionComposer(
      worktreePath: worktreePath,
      tabId: tab.tabId,
      workspaceId: workspaceId,
      projectPath: projectPath,
      branch: branch,
      isWorktree: isWorktree,
      isPaneFocused: isActive,
    ),
    WorktreeTabKind.diff => DiffPane(cwd: worktreePath),
    WorktreeTabKind.terminal => TerminalPane(
      worktreePath: worktreePath,
      tabId: tab.tabId,
      workspaceId: workspaceId,
      isWorkspaceFocused: isActive,
      onOpenWorkspaceFile: onOpenWorkspaceFile,
    ),
    WorktreeTabKind.agent => AgentChatScreen(
      agentId: tab.agentId!,
      isScreenFocused: isActive,
      onOpenWorkspaceFile: onOpenWorkspaceFile,
    ),
    WorktreeTabKind.providerSubagent => ProviderSubagentScreen(
      parentAgentId: tab.parentAgentId!,
      subagentId: tab.subagentId!,
      onOpenWorkspaceFile: onOpenWorkspaceFile,
    ),
    WorktreeTabKind.file => WorkspaceFilePane(
      cwd: worktreePath,
      location: WorkspaceFileLocation(
        path: tab.filePath!,
        lineStart: tab.lineStart,
        lineEnd: tab.lineEnd,
      ),
      navigationRevision: tab.fileNavigationRevision,
      onModifiedChanged: (modified) => ref
          .read(workspaceModifiedTabsProvider(worktreePath).notifier)
          .setModified(tab.tabId, modified: modified),
    ),
    WorktreeTabKind.setup => _WorkspaceSetupTab(
      workspaceId: tab.setupWorkspaceId!,
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsState = ref.watch(worktreeTabsProvider(worktreePath));
    final tabs = tabsState.layout.tabs;
    final paneLayout = tabsState.layout.paneLayout;
    if (paneLayout == null) return const SizedBox.shrink();
    final explorerVisible = ref.watch(
      workspaceExplorerVisibilityProvider(worktreePath),
    );
    final focusMode = ref.watch(workspaceFocusModeProvider);
    final daemonClient = ref.watch(daemonClientProvider);
    final activeServerId = ref.watch(activeHostProvider)?.serverId.trim();
    final helloServerId = daemonClient.serverInfo?.serverId.trim();
    final serverId = activeServerId?.isNotEmpty == true
        ? activeServerId!
        : helloServerId?.isNotEmpty == true
        ? helloServerId!
        : 'local';
    final catalog =
        ref.watch(workspaceCatalogCacheProvider)[serverId] ?? const [];
    final workspace = catalog
        .where(
          (candidate) =>
              (workspaceId != null && candidate.id == workspaceId) ||
              candidate.workspaceDirectory == worktreePath,
        )
        .firstOrNull;
    final explorerIsGit = workspace != null
        ? workspace.projectKind == WorkspaceProjectKind.git
        : projectPath != null || isWorktree;

    return _WorkspacePaneShortcutHost(
      worktreePath: worktreePath,
      onCloseCurrentTab: () async {
        final layout = ref.read(worktreeTabsProvider(worktreePath)).layout;
        final activeTab = layout.tabs
            .where((tab) => tab.tabId == layout.activeTabId)
            .firstOrNull;
        if (activeTab != null) {
          await _closeTab(context, ref, activeTab);
        }
      },
      onClosePane: () async {
        final paneId = ref
            .read(worktreeTabsProvider(worktreePath))
            .layout
            .paneLayout
            ?.focusedPaneId;
        final notifier = ref.read(worktreeTabsProvider(worktreePath).notifier);
        final paneTabs = notifier.focusedPaneTabs();
        for (final tab in paneTabs) {
          if (!context.mounted) return;
          await _closeTab(context, ref, tab);
        }
        notifier.removePaneIfEmpty(paneId);
      },
      onArchiveWorkspace: projectPath != null && isWorktree
          ? () => archiveWorktreeWithConfirm(
              context,
              ref,
              projectPath!,
              worktreePath,
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void openWorkspaceFile(WorkspaceFileOpenRequest request) {
            if (request.disposition == OpenFileDisposition.side) {
              ref
                  .read(worktreeTabsProvider(worktreePath).notifier)
                  .openFileInSidePane(request.location);
              return;
            }
            ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .openFile(request.location);
          }

          final focusedPane = findWorkspacePane(
            paneLayout.root,
            paneLayout.focusedPaneId,
          );
          final visibleRoot = focusMode && focusedPane != null
              ? focusedPane
              : paneLayout.root;
          final paneTree = _buildPaneNode(
            context,
            ref,
            visibleRoot,
            paneLayout,
            tabs,
            explorerVisible,
            openWorkspaceFile,
          );
          if (focusMode || constraints.maxWidth < 720 || !explorerVisible) {
            return paneTree;
          }
          final explorerWidth = (constraints.maxWidth * .28).clamp(
            280.0,
            380.0,
          );
          return Row(
            children: [
              Expanded(child: paneTree),
              const Divider(direction: Axis.vertical),
              SizedBox(
                width: explorerWidth,
                child: WorkspaceExplorer(
                  serverId: serverId,
                  workspaceId: workspaceId,
                  cwd: worktreePath,
                  isGit: explorerIsGit,
                  onOpenFile: openWorkspaceFile,
                  onClose: () => ref
                      .read(
                        workspaceExplorerVisibilityProvider(
                          worktreePath,
                        ).notifier,
                      )
                      .hide(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPaneNode(
    BuildContext context,
    WidgetRef ref,
    WorkspacePaneNode node,
    WorkspacePaneLayout layout,
    List<WorktreeTab> allTabs,
    bool explorerVisible,
    void Function(WorkspaceFileOpenRequest request) onOpenWorkspaceFile,
  ) {
    if (node is WorkspacePaneGroup) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final groupExtent =
              node.direction == WorkspaceSplitDirection.horizontal
              ? constraints.maxWidth
              : constraints.maxHeight;
          final children = <Widget>[];
          for (var index = 0; index < node.children.length; index++) {
            final size = index < node.sizes.length ? node.sizes[index] : 1;
            children.add(
              Expanded(
                flex: (size * 1000).round().clamp(1, 1000),
                child: _buildPaneNode(
                  context,
                  ref,
                  node.children[index],
                  layout,
                  allTabs,
                  explorerVisible,
                  onOpenWorkspaceFile,
                ),
              ),
            );
          }
          final content = node.direction == WorkspaceSplitDirection.horizontal
              ? Row(children: children)
              : Column(children: children);
          final normalizedSizes = clampNormalizedWorkspaceSizes(
            node.sizes.length == node.children.length
                ? node.sizes
                : List.filled(node.children.length, 1 / node.children.length),
          );
          var offset = 0.0;
          final handles = <Widget>[];
          for (var index = 0; index < node.children.length - 1; index++) {
            offset += normalizedSizes[index] * groupExtent;
            final handle = _WorkspaceResizeHandle(
              key: ValueKey('workspace-resize-${node.id}-$index'),
              direction: node.direction,
              groupExtent: groupExtent,
              sizes: normalizedSizes,
              index: index,
              onResize: (sizes) => ref
                  .read(worktreeTabsProvider(worktreePath).notifier)
                  .resizeSplit(node.id, sizes),
            );
            handles.add(
              node.direction == WorkspaceSplitDirection.horizontal
                  ? Positioned(
                      left: offset - 5,
                      top: 0,
                      bottom: 0,
                      width: 10,
                      child: handle,
                    )
                  : Positioned(
                      left: 0,
                      right: 0,
                      top: offset - 5,
                      height: 10,
                      child: handle,
                    ),
            );
          }
          return Stack(
            children: [
              Positioned.fill(child: content),
              ...handles,
            ],
          );
        },
      );
    }

    final pane = node as WorkspacePane;
    final byId = {for (final tab in allTabs) tab.tabId: tab};
    final tabs = pane.tabIds.map((id) => byId[id]).nonNulls.toList();
    final focusedTabId =
        pane.focusedTabId ?? (tabs.isEmpty ? null : tabs.first.tabId);
    final activeIndex = tabs.indexWhere((tab) => tab.tabId == focusedTabId);
    void handlePaneDrop(
      _WorkspaceTabDragData data,
      WorkspaceSplitDropPosition position,
    ) {
      final notifier = ref.read(worktreeTabsProvider(worktreePath).notifier);
      if (position == WorkspaceSplitDropPosition.center) {
        if (data.paneId != pane.id) {
          notifier.moveTabToPaneIndex(
            tabId: data.tabId,
            targetPaneId: pane.id,
            insertionIndex: pane.tabIds.length,
          );
        }
      } else {
        notifier.splitTabAtPosition(
          tabId: data.tabId,
          targetPaneId: pane.id,
          position: position,
        );
      }
    }

    void focusPane() => ref
        .read(worktreeTabsProvider(worktreePath).notifier)
        .focusPaneById(pane.id);

    void addDraft() {
      focusPane();
      ref
          .read(worktreeTabsProvider(worktreePath).notifier)
          .addTab(WorktreeTabKind.draft);
    }

    final tabActions = DropDownButton(
      buttonBuilder: (context, onOpen) => IconButton(
        key: ValueKey('workspace-tab-actions-${pane.id}'),
        icon: const Icon(FluentIcons.chevron_down, size: 12),
        onPressed: onOpen,
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
      ),
      items: [
        MenuFlyoutItem(
          text: const Text('New agent session'),
          leading: const Icon(FluentIcons.chat),
          onPressed: () {
            addDraft();
          },
        ),
        MenuFlyoutItem(
          text: const Text(
            'Import session',
            key: ValueKey('workspace-header-import-agent'),
          ),
          leading: const Icon(FluentIcons.download),
          onPressed: () {
            focusPane();
            unawaited(
              showImportSessionDialog(
                context: context,
                client: ref.read(daemonClientProvider),
                cwd: worktreePath,
                workspaceId: workspaceId,
                onImported: (agent) {
                  ref.read(agentsProvider.notifier).upsert(agent);
                  ref
                      .read(worktreeTabsProvider(worktreePath).notifier)
                      .focusAgent(agent.agentId);
                },
              ),
            );
          },
        ),
        MenuFlyoutItem(
          text: const Text('New terminal'),
          leading: const Icon(FluentIcons.command_prompt),
          onPressed: () {
            focusPane();
            ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .addTab(WorktreeTabKind.terminal);
          },
        ),
        if (!explorerVisible)
          MenuFlyoutItem(
            text: const Text('Show explorer'),
            leading: const Icon(FluentIcons.open_pane),
            onPressed: () => ref
                .read(
                  workspaceExplorerVisibilityProvider(worktreePath).notifier,
                )
                .show(),
          ),
      ],
    );
    final terminalTabs = allTabs
        .where((candidate) => candidate.kind == WorktreeTabKind.terminal)
        .toList();
    final paneContent = _WorkspacePaneTabs(
      worktreePath: worktreePath,
      paneId: pane.id,
      isFocused: pane.id == layout.focusedPaneId,
      tabs: tabs,
      activeIndex: activeIndex < 0 ? 0 : activeIndex,
      labels: [
        for (final tab in tabs)
          _labelFor(
            ref,
            tab,
            tab.kind == WorktreeTabKind.terminal
                ? terminalTabs.indexOf(tab) + 1
                : 0,
          ),
      ],
      icons: [for (final tab in tabs) _iconFor(ref, tab)],
      tabBuilder: (index, width, showLabel) {
        final tab = tabs[index];
        return _WorkspaceDraggableTabLabel(
          worktreePath: worktreePath,
          layout: layout,
          paneId: pane.id,
          tabId: tab.tabId,
          tabKind: tab.workspaceTarget?.kind ?? tab.kind.name,
          paneTabIds: pane.tabIds,
          icon: _iconFor(ref, tab),
          label: _labelFor(
            ref,
            tab,
            tab.kind == WorktreeTabKind.terminal
                ? terminalTabs.indexOf(tab) + 1
                : 0,
          ),
          width: width,
          showLabel: showLabel,
          isActive: index == (activeIndex < 0 ? 0 : activeIndex),
          isPaneFocused: pane.id == layout.focusedPaneId,
          onActivate: () {
            focusPane();
            ref
                .read(worktreeTabsProvider(worktreePath).notifier)
                .setActiveTab(tab.tabId);
          },
          onClose: () => _closeTab(context, ref, tab),
          onDrop:
              ({
                required activePaneId,
                required activeTabId,
                required targetPaneId,
                required insertionIndex,
              }) => ref
                  .read(worktreeTabsProvider(worktreePath).notifier)
                  .moveTabToPaneIndex(
                    tabId: activeTabId,
                    targetPaneId: targetPaneId,
                    insertionIndex: insertionIndex,
                  ),
        );
      },
      bodyBuilder: (index) {
        final tab = tabs[index];
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => focusPane(),
          child: _WorkspacePaneDropTarget(
            paneId: pane.id,
            onDrop: handlePaneDrop,
            child: _bodyFor(
              ref,
              tab,
              pane.id == layout.focusedPaneId && tab.tabId == focusedTabId,
              onOpenWorkspaceFile,
            ),
          ),
        );
      },
      onNewTab: addDraft,
      onNewTerminal: () {
        focusPane();
        ref
            .read(worktreeTabsProvider(worktreePath).notifier)
            .addTab(WorktreeTabKind.terminal);
      },
      tabActions: tabActions,
      onSplitRight: () {
        focusPane();
        ref
            .read(worktreeTabsProvider(worktreePath).notifier)
            .splitFocusedPane(WorkspaceSplitDirection.horizontal);
      },
      onSplitDown: () {
        focusPane();
        ref
            .read(worktreeTabsProvider(worktreePath).notifier)
            .splitFocusedPane(WorkspaceSplitDirection.vertical);
      },
      emptyBody: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => focusPane(),
        child: _WorkspacePaneDropTarget(
          paneId: pane.id,
          onDrop: handlePaneDrop,
          child: const Center(child: Text('No tabs in this pane.')),
        ),
      ),
    );
    return Container(
      key: ValueKey('workspace-pane-${pane.id}'),
      color: paseoPaletteFor(
        ref.watch(appearanceProvider),
        FluentTheme.of(context).brightness,
      ).surface0,
      child: paneContent,
    );
  }
}

typedef _WorkspaceTabBuilder =
    Widget Function(int index, double width, bool showLabel);

class _WorkspaceSetupTab extends ConsumerStatefulWidget {
  const _WorkspaceSetupTab({required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<_WorkspaceSetupTab> createState() => _WorkspaceSetupTabState();
}

class _WorkspaceSetupTabState extends ConsumerState<_WorkspaceSetupTab> {
  final Set<int> _expanded = {};
  final Set<int> _manuallyCollapsed = {};
  WorkspaceSetupKey? _requestedKey;

  WorkspaceSetupKey _key() {
    final client = ref.read(daemonClientProvider);
    final serverId =
        ref.read(activeHostProvider)?.serverId ??
        client.serverInfo?.serverId ??
        'local';
    return WorkspaceSetupKey(
      serverId: serverId,
      workspaceId: widget.workspaceId,
    );
  }

  void _ensureStatus(WorkspaceSetupKey key) {
    if (_requestedKey == key) return;
    _requestedKey = key;
    Future.microtask(
      () => ref
          .read(workspaceSetupStoreProvider.notifier)
          .ensureStatus(serverId: key.serverId, workspaceId: key.workspaceId),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(workspaceSetupProgressBridgeProvider);
    final key = _key();
    _ensureStatus(key);
    final snapshot = ref.watch(workspaceSetupEntryProvider(key))?.snapshot;
    final commands = snapshot?.detail.commands ?? const [];
    final log = snapshot?.detail.log ?? '';
    final waiting =
        snapshot == null ||
        (snapshot.status == WorkspaceSetupStatus.running && commands.isEmpty);
    final noCommands =
        snapshot?.status == WorkspaceSetupStatus.completed &&
        commands.isEmpty &&
        log.trim().isEmpty;
    final statusLabel = switch (snapshot?.status) {
      WorkspaceSetupStatus.running => 'Running',
      WorkspaceSetupStatus.completed => 'Completed',
      WorkspaceSetupStatus.failed => 'Failed',
      null => 'Waiting',
    };
    final autoExpandIndex = workspaceSetupAutoExpandIndex(commands);

    return Semantics(
      label: 'Workspace setup',
      child: SingleChildScrollView(
        key: const ValueKey('workspace-setup-panel'),
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.sizeOf(context).height - 96,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Offstage(
                child: Text(
                  statusLabel,
                  key: const ValueKey('workspace-setup-status'),
                ),
              ),
              if (waiting)
                const _WorkspaceSetupWaiting()
              else if (noCommands)
                const _WorkspaceSetupEmpty()
              else ...[
                for (final command in commands)
                  _WorkspaceSetupCommandRow(
                    command: command,
                    fallbackLog: command.index == autoExpandIndex ? log : '',
                    error: snapshot.error,
                    expanded:
                        _expanded.contains(command.index) ||
                        (command.index == autoExpandIndex &&
                            !_manuallyCollapsed.contains(command.index)),
                    onToggle: () {
                      final autoExpanded =
                          command.index == autoExpandIndex &&
                          !_manuallyCollapsed.contains(command.index);
                      setState(() {
                        if (_expanded.remove(command.index) || autoExpanded) {
                          if (autoExpanded) {
                            _manuallyCollapsed.add(command.index);
                          }
                        } else {
                          _expanded.add(command.index);
                          _manuallyCollapsed.remove(command.index);
                        }
                      });
                    },
                  ),
                if (commands.isEmpty && log.trim().isNotEmpty)
                  _WorkspaceSetupLog(log: log),
                if (snapshot.error case final error?
                    when !commands.any(
                      (command) =>
                          command.status == WorkspaceSetupCommandStatus.failed,
                    ))
                  _WorkspaceSetupError(error),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSetupWaiting extends StatelessWidget {
  const _WorkspaceSetupWaiting();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.only(top: 96),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProgressRing(),
          SizedBox(height: 12),
          Text('Setting up workspace…'),
        ],
      ),
    ),
  );
}

class _WorkspaceSetupEmpty extends StatelessWidget {
  const _WorkspaceSetupEmpty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Semantics(
        label: 'No workspace setup commands',
        child: const Text('No setup commands were run.'),
      ),
    ),
  );
}

class _WorkspaceSetupCommandRow extends StatelessWidget {
  const _WorkspaceSetupCommandRow({
    required this.command,
    required this.fallbackLog,
    required this.error,
    required this.expanded,
    required this.onToggle,
  });

  final WorkspaceSetupCommand command;
  final String fallbackLog;
  final String? error;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final commandLog = command.log.isNotEmpty ? command.log : fallbackLog;
    final hasLog = commandLog.trim().isNotEmpty;
    final hasError =
        command.status == WorkspaceSetupCommandStatus.failed && error != null;
    final expandable =
        command.status != WorkspaceSetupCommandStatus.running ||
        hasLog ||
        hasError;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: HoverButton(
              onPressed: expandable ? onToggle : null,
              builder: (context, states) => Container(
                color: states.isPressed
                    ? theme.resources.subtleFillColorSecondary
                    : theme.resources.cardBackgroundFillColorDefault,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: switch (command.status) {
                        WorkspaceSetupCommandStatus.running =>
                          const ProgressRing(strokeWidth: 2),
                        WorkspaceSetupCommandStatus.completed => Icon(
                          FluentIcons.completed_solid,
                          size: 14,
                          color: context.statusColors.success,
                        ),
                        WorkspaceSetupCommandStatus.failed => Icon(
                          FluentIcons.error_badge,
                          size: 14,
                          color: context.statusColors.danger,
                        ),
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        command.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (command.durationMs case final duration?)
                      Text(
                        formatWorkspaceSetupDuration(duration),
                        style: theme.typography.caption,
                      ),
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: expanded ? .25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(FluentIcons.chevron_right, size: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            if (hasLog)
              _WorkspaceSetupLog(
                log: processWorkspaceSetupCarriageReturns(commandLog),
              )
            else
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No output',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            if (hasError) _WorkspaceSetupError(error!),
          ],
        ],
      ),
    );
  }
}

class _WorkspaceSetupLog extends StatelessWidget {
  const _WorkspaceSetupLog({required this.log});

  final String log;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Workspace setup log',
    child: Container(
      key: const ValueKey('workspace-setup-log'),
      constraints: const BoxConstraints(maxHeight: 400),
      padding: const EdgeInsets.all(12),
      color: paseoPaletteFor(
        ProviderScope.containerOf(context).read(appearanceProvider),
        FluentTheme.of(context).brightness,
      ).surface0,
      child: SingleChildScrollView(
        child: SelectionArea(
          child: Text(
            log,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 13,
              height: 20 / 13,
            ),
          ),
        ),
      ),
    ),
  );
}

class _WorkspaceSetupError extends StatelessWidget {
  const _WorkspaceSetupError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    color: context.statusColors.danger.withValues(alpha: .12),
    child: SelectionArea(
      child: Text(
        message,
        style: TextStyle(color: context.statusColors.danger),
      ),
    ),
  );
}

class _WorkspacePaneTabs extends ConsumerWidget {
  const _WorkspacePaneTabs({
    required this.worktreePath,
    required this.paneId,
    required this.isFocused,
    required this.tabs,
    required this.activeIndex,
    required this.labels,
    required this.icons,
    required this.tabBuilder,
    required this.bodyBuilder,
    required this.onNewTab,
    required this.onNewTerminal,
    required this.tabActions,
    required this.onSplitRight,
    required this.onSplitDown,
    required this.emptyBody,
  });

  static const rowHeight = 36.0;
  static const inlineAddReservedWidth = 36.0;
  static const trailingActionsWidth = 104.0;

  final String worktreePath;
  final String paneId;
  final bool isFocused;
  final List<WorktreeTab> tabs;
  final int activeIndex;
  final List<String> labels;
  final List<IconData> icons;
  final _WorkspaceTabBuilder tabBuilder;
  final Widget Function(int index) bodyBuilder;
  final VoidCallback onNewTab;
  final VoidCallback onNewTerminal;
  final Widget tabActions;
  final VoidCallback onSplitRight;
  final VoidCallback onSplitDown;
  final Widget emptyBody;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = FluentTheme.of(context);
    final palette = paseoPaletteFor(
      ref.watch(appearanceProvider),
      theme.brightness,
    );
    final divider = palette.borderAccent;
    final muted = palette.foregroundMuted;

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final layout = computeWorkspaceTabLayout(
              viewportWidth: constraints.maxWidth,
              tabLabelLengths: labels.map((label) => label.length).toList(),
              metrics: const WorkspaceTabLayoutMetrics(
                rowHorizontalInset: 0,
                actionsReservedWidth:
                    inlineAddReservedWidth + trailingActionsWidth,
                rowPaddingHorizontal: 0,
                tabGap: 0,
                maxTabWidth: 200,
                tabIconWidth: 14,
                tabHorizontalPadding: 12,
                estimatedCharWidth: 7,
                closeButtonWidth: 22,
              ),
            );
            final tabChildren = [
              for (var index = 0; index < tabs.length; index++)
                tabBuilder(
                  index,
                  layout.items[index].width,
                  layout.items[index].showLabel,
                ),
              SizedBox(
                key: ValueKey('workspace-inline-add-slot-$paneId'),
                width: inlineAddReservedWidth,
                child: Center(
                  child: SizedBox.square(
                    dimension: 28,
                    child: IconButton(
                      key: ValueKey('workspace-inline-add-$paneId'),
                      icon: Icon(FluentIcons.add, size: 14, color: muted),
                      onPressed: onNewTab,
                      style: ButtonStyle(
                        padding: WidgetStateProperty.all(EdgeInsets.zero),
                      ),
                    ),
                  ),
                ),
              ),
            ];
            final tabsStrip = SingleChildScrollView(
              key: ValueKey('workspace-tabs-scroll-$paneId'),
              scrollDirection: Axis.horizontal,
              physics: layout.requiresHorizontalScrollFallback
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: Row(children: tabChildren),
            );

            return RepaintBoundary(
              key: ValueKey('workspace-tabs-row-$paneId'),
              child: Container(
                height: rowHeight,
                decoration: BoxDecoration(
                  color: palette.surface0,
                  border: Border(bottom: BorderSide(color: divider)),
                ),
                child: Row(
                  children: [
                    Expanded(child: tabsStrip),
                    Container(
                      key: ValueKey('workspace-tab-trailing-actions-$paneId'),
                      width: trailingActionsWidth,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox.square(dimension: 22, child: tabActions),
                          SizedBox.square(
                            dimension: 22,
                            child: IconButton(
                              key: ValueKey(
                                'workspace-pinned-terminal-$paneId',
                              ),
                              icon: Icon(
                                FluentIcons.command_prompt,
                                size: 14,
                                color: muted,
                              ),
                              onPressed: onNewTerminal,
                              style: ButtonStyle(
                                padding: WidgetStateProperty.all(
                                  EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ),
                          SizedBox.square(
                            dimension: 22,
                            child: IconButton(
                              key: ValueKey('workspace-split-right-$paneId'),
                              icon: Icon(
                                FluentIcons.split_object,
                                size: 14,
                                color: muted,
                              ),
                              onPressed: onSplitRight,
                              style: ButtonStyle(
                                padding: WidgetStateProperty.all(
                                  EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ),
                          SizedBox.square(
                            dimension: 22,
                            child: IconButton(
                              key: ValueKey('workspace-split-down-$paneId'),
                              icon: Icon(
                                FluentIcons.rows_group,
                                size: 14,
                                color: muted,
                              ),
                              onPressed: onSplitDown,
                              style: ButtonStyle(
                                padding: WidgetStateProperty.all(
                                  EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        Expanded(
          child: tabs.isEmpty
              ? emptyBody
              : _RetainedWorkspaceTabBodies(
                  key: ValueKey('workspace-tab-bodies-$paneId'),
                  worktreePath: worktreePath,
                  tabs: tabs,
                  activeIndex: activeIndex,
                  bodyBuilder: bodyBuilder,
                ),
        ),
      ],
    );
  }
}

class _RetainedWorkspaceTabBodies extends ConsumerStatefulWidget {
  const _RetainedWorkspaceTabBodies({
    super.key,
    required this.worktreePath,
    required this.tabs,
    required this.activeIndex,
    required this.bodyBuilder,
  });

  final String worktreePath;
  final List<WorktreeTab> tabs;
  final int activeIndex;
  final Widget Function(int index) bodyBuilder;

  @override
  ConsumerState<_RetainedWorkspaceTabBodies> createState() =>
      _RetainedWorkspaceTabBodiesState();
}

class _RetainedWorkspaceTabBodiesState
    extends ConsumerState<_RetainedWorkspaceTabBodies> {
  static const _mountedTabCap = 3;
  List<String> _committedLru = const [];

  @override
  Widget build(BuildContext context) {
    final activeIndex = widget.activeIndex.clamp(0, widget.tabs.length - 1);
    final activeTabId = widget.tabs[activeIndex].tabId;
    final availableTabIds = widget.tabs.map((tab) => tab.tabId).toSet();
    final retainedTabIds = ref
        .watch(workspaceModifiedTabsProvider(widget.worktreePath))
        .intersection(availableTabIds);
    final mountedLru = deriveMountedTabLru(
      activeTabId: activeTabId,
      availableTabIds: availableTabIds,
      cap: _mountedTabCap,
      previousLru: _committedLru,
      retainedTabIds: retainedTabIds,
    );
    _committedLru = mountedLru;
    final mountedIds = mountedLru.toSet();
    final mountedIndexes = <int>[
      for (var index = 0; index < widget.tabs.length; index++)
        if (mountedIds.contains(widget.tabs[index].tabId)) index,
    ];
    final visibleIndex = mountedIndexes.indexOf(activeIndex);

    return IndexedStack(
      index: visibleIndex < 0 ? 0 : visibleIndex,
      children: [
        for (final index in mountedIndexes)
          KeyedSubtree(
            key: ValueKey('workspace-tab-body-${widget.tabs[index].tabId}'),
            child: widget.bodyBuilder(index),
          ),
      ],
    );
  }
}

typedef _WorkspaceTabDropCallback =
    void Function({
      required String activePaneId,
      required String activeTabId,
      required String targetPaneId,
      required int insertionIndex,
    });

class _WorkspaceTabDragData {
  const _WorkspaceTabDragData({
    required this.paneId,
    required this.tabId,
    required this.width,
    required this.height,
    required this.accessibility,
  });

  final String paneId;
  final String tabId;
  final double width;
  final double height;
  final WorkspaceTabDragAccessibilitySession accessibility;
}

class _WorkspaceDraggableTabLabel extends ConsumerStatefulWidget {
  const _WorkspaceDraggableTabLabel({
    required this.worktreePath,
    required this.layout,
    required this.paneId,
    required this.tabId,
    required this.tabKind,
    required this.paneTabIds,
    required this.icon,
    required this.label,
    required this.width,
    required this.showLabel,
    required this.isActive,
    required this.isPaneFocused,
    required this.onActivate,
    required this.onClose,
    required this.onDrop,
  });

  final String worktreePath;
  final WorkspacePaneLayout layout;
  final String paneId;
  final String tabId;
  final String tabKind;
  final List<String> paneTabIds;
  final IconData icon;
  final String label;
  final double width;
  final bool showLabel;
  final bool isActive;
  final bool isPaneFocused;
  final VoidCallback onActivate;
  final VoidCallback onClose;
  final _WorkspaceTabDropCallback onDrop;

  @override
  ConsumerState<_WorkspaceDraggableTabLabel> createState() =>
      _WorkspaceDraggableTabLabelState();
}

class _WorkspaceDraggableTabLabelState
    extends ConsumerState<_WorkspaceDraggableTabLabel> {
  final _labelKey = GlobalKey();
  final _keyboardFocusNode = FocusNode();
  WorkspaceTabDropPreview? _preview;
  WorkspaceTabDragAccessibilitySession? _pointerAccessibility;
  WorkspaceTabDragAccessibilitySession? _keyboardAccessibility;
  int? _activePointer;
  bool _pointerKeyHandlerRegistered = false;
  bool _hovered = false;
  bool _closeHovered = false;

  @override
  void dispose() {
    _unregisterPointerKeyHandler();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _activePointer == null ||
        !(_pointerAccessibility?.isStarted ?? false)) {
      return false;
    }
    final pointer = _activePointer!;
    _activePointer = null;
    _cancelPointerDrag(_pointerAccessibility!);
    GestureBinding.instance.cancelPointer(pointer);
    return true;
  }

  void _startPointerDrag(WorkspaceTabDragAccessibilitySession accessibility) {
    accessibility.start();
    if (_pointerKeyHandlerRegistered) return;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    _pointerKeyHandlerRegistered = true;
  }

  void _endPointerDrag(WorkspaceTabDragAccessibilitySession accessibility) {
    _unregisterPointerKeyHandler();
    accessibility.end();
  }

  void _cancelPointerDrag(WorkspaceTabDragAccessibilitySession accessibility) {
    _unregisterPointerKeyHandler();
    accessibility.cancel();
  }

  void _unregisterPointerKeyHandler() {
    if (!_pointerKeyHandlerRegistered) return;
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _pointerKeyHandlerRegistered = false;
  }

  Rect? get _labelBounds {
    final box = _labelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String get _dragId => '${widget.tabId}:${widget.tabKind}';

  String _dragIdForTab(String tabId) {
    final tabs = ref
        .read(worktreeTabsProvider(widget.worktreePath))
        .layout
        .tabs;
    for (final tab in tabs) {
      if (tab.tabId == tabId) {
        final kind = tab.workspaceTarget?.kind;
        return kind == null ? tabId : '$tabId:$kind';
      }
    }
    return tabId;
  }

  WorkspaceTabDragAccessibilitySession _newAccessibilitySession(
    String activeId,
  ) {
    final announcer = ref.read(workspaceTabDragAnnouncerProvider);
    return WorkspaceTabDragAccessibilitySession(
      activeId: activeId,
      announcementSink: (message) {
        if (mounted) announcer(context, message);
      },
    );
  }

  _WorkspaceTabDragData _dragData(
    WorkspaceTabDragAccessibilitySession accessibility,
  ) => _WorkspaceTabDragData(
    paneId: widget.paneId,
    tabId: widget.tabId,
    width: _labelBounds?.width ?? widget.width,
    height: _labelBounds?.height ?? 35,
    accessibility: accessibility,
  );

  WorkspaceTabDropPreview? _computePreview(
    _WorkspaceTabDragData data,
    Offset feedbackOffset,
  ) {
    final bounds = _labelBounds;
    if (bounds == null) return null;
    return computeWorkspaceTabDropPreview(
      activePaneId: data.paneId,
      activeTabId: data.tabId,
      overPaneId: widget.paneId,
      overTabId: widget.tabId,
      targetTabIds: widget.paneTabIds,
      activeCenterX: feedbackOffset.dx + data.width / 2,
      overCenterX: bounds.center.dx,
      overWidth: bounds.width,
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final notifier = ref.read(
      workspaceTabKeyboardDragProvider(widget.worktreePath).notifier,
    );
    final drag = ref.read(
      workspaceTabKeyboardDragProvider(widget.worktreePath),
    );
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      if (drag == null) {
        final accessibility = _newAccessibilitySession(_dragId);
        _keyboardAccessibility = accessibility;
        accessibility.start();
        accessibility.moveOver(_dragId);
        notifier.start(
          paneId: widget.paneId,
          tabId: widget.tabId,
          tabIndex: widget.paneTabIds.indexOf(widget.tabId),
        );
      } else if (drag.activeTabId == widget.tabId) {
        final completed = notifier.finish();
        if (completed != null &&
            (completed.overPaneId != completed.activePaneId ||
                completed.overIndex !=
                    widget.paneTabIds.indexOf(widget.tabId))) {
          widget.onDrop(
            activePaneId: completed.activePaneId,
            activeTabId: completed.activeTabId,
            targetPaneId: completed.overPaneId,
            insertionIndex: completed.overIndex,
          );
        }
        _keyboardAccessibility?.end();
        _keyboardAccessibility = null;
      }
      return KeyEventResult.handled;
    }
    if (drag == null || drag.activeTabId != widget.tabId) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      notifier.cancel();
      _keyboardAccessibility?.cancel();
      _keyboardAccessibility = null;
      return KeyEventResult.handled;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => WorkspaceKeyboardDragDirection.left,
      LogicalKeyboardKey.arrowRight => WorkspaceKeyboardDragDirection.right,
      LogicalKeyboardKey.arrowUp => WorkspaceKeyboardDragDirection.up,
      LogicalKeyboardKey.arrowDown => WorkspaceKeyboardDragDirection.down,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    notifier.move(widget.layout, direction);
    final moved = ref.read(
      workspaceTabKeyboardDragProvider(widget.worktreePath),
    );
    if (moved != null) {
      _keyboardAccessibility?.moveOver(_dragIdForTab(moved.overTabId));
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final palette = paseoPaletteFor(
      ref.watch(appearanceProvider),
      theme.brightness,
    );
    final keyboardDrag = ref.watch(
      workspaceTabKeyboardDragProvider(widget.worktreePath),
    );
    final keyboardPreview = keyboardDrag?.overTabId == widget.tabId;
    final activeKeyboardIndex = keyboardDrag?.activePaneId == widget.paneId
        ? widget.paneTabIds.indexOf(keyboardDrag!.activeTabId)
        : -1;
    final keyboardIndicatorIndex = !keyboardPreview
        ? null
        : keyboardDrag!.overIndex +
              (activeKeyboardIndex >= 0 &&
                      activeKeyboardIndex < keyboardDrag.overIndex
                  ? 1
                  : 0);
    if (_pointerAccessibility?.activeId != _dragId) {
      _pointerAccessibility = _newAccessibilitySession(_dragId);
    }
    final dragData = _dragData(_pointerAccessibility!);
    final isHighlighted = widget.isActive || _hovered || _closeHovered;
    final indicatorColor = widget.isPaneFocused
        ? palette.accent
        : palette.borderAccent;
    final label = Container(
      key: _labelKey,
      width: widget.width,
      height: 35,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: palette.borderAccent),
          left: _preview == null && !keyboardPreview
              ? BorderSide.none
              : (_preview?.indicatorIndex ?? keyboardIndicatorIndex) ==
                    widget.paneTabIds.indexOf(widget.tabId)
              ? BorderSide(color: palette.accent, width: 5)
              : BorderSide.none,
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (widget.isActive)
            Positioned(
              left: -12,
              right: -12,
              top: -8,
              height: 2,
              child: ColoredBox(color: indicatorColor),
            ),
          Row(
            children: [
              Expanded(
                child: widget.showLabel
                    ? Row(
                        children: [
                          Icon(
                            widget.icon,
                            size: 14,
                            color: isHighlighted
                                ? palette.foreground
                                : palette.foregroundMuted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isHighlighted
                                    ? palette.foreground
                                    : palette.foregroundMuted,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(
                          widget.icon,
                          size: 14,
                          color: isHighlighted
                              ? palette.foreground
                              : palette.foregroundMuted,
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              MouseRegion(
                onEnter: (_) => setState(() => _closeHovered = true),
                onExit: (_) => setState(() => _closeHovered = false),
                child: Semantics(
                  key: ValueKey('workspace-tab-close-label-${widget.label}'),
                  label: 'Close ${widget.label}',
                  button: true,
                  child: SizedBox.square(
                    dimension: 18,
                    child: IconButton(
                      key: ValueKey('workspace-tab-close-${widget.tabId}'),
                      icon: Icon(
                        FluentIcons.chrome_close,
                        size: 12,
                        color: _closeHovered
                            ? palette.foreground
                            : palette.foregroundMuted,
                      ),
                      onPressed: widget.onClose,
                      style: ButtonStyle(
                        padding: WidgetStateProperty.all(EdgeInsets.zero),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if ((_preview?.indicatorIndex ?? keyboardIndicatorIndex) ==
              widget.paneTabIds.indexOf(widget.tabId) + 1)
            Positioned(
              right: -15,
              top: 0,
              bottom: 0,
              width: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
    );

    return Listener(
      onPointerDown: (event) => _activePointer ??= event.pointer,
      onPointerUp: (_) {
        _activePointer = null;
        widget.onActivate();
        ref
            .read(worktreeTabsProvider(widget.worktreePath).notifier)
            .focusPaneById(widget.paneId);
        _keyboardFocusNode.requestFocus();
      },
      onPointerCancel: (_) => _activePointer = null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          key: ValueKey('workspace-tab-keyboard-${widget.tabId}'),
          focusNode: _keyboardFocusNode,
          onKeyEvent: _handleKeyEvent,
          child: Semantics(
            label: widget.label,
            selected: widget.isActive,
            hint: workspaceTabDragScreenReaderInstructions,
            child: DragTarget<_WorkspaceTabDragData>(
              key: ValueKey('workspace-tab-drop-${widget.tabId}'),
              onWillAcceptWithDetails: (details) {
                final preview = _computePreview(details.data, details.offset);
                if (preview == null) return false;
                details.data.accessibility.moveOver(_dragId);
                setState(() => _preview = preview);
                return true;
              },
              onMove: (details) {
                final preview = _computePreview(details.data, details.offset);
                if (preview != null) {
                  details.data.accessibility.moveOver(_dragId);
                }
                if (preview != _preview) setState(() => _preview = preview);
              },
              onLeave: (data) {
                data?.accessibility.leave(_dragId);
                setState(() => _preview = null);
              },
              onAcceptWithDetails: (details) {
                final preview =
                    _computePreview(details.data, details.offset) ?? _preview;
                setState(() => _preview = null);
                if (preview == null) return;
                widget.onDrop(
                  activePaneId: details.data.paneId,
                  activeTabId: details.data.tabId,
                  targetPaneId: widget.paneId,
                  insertionIndex: preview.insertionIndex,
                );
              },
              builder: (context, candidateData, rejectedData) =>
                  WorkspaceDistanceDraggable<_WorkspaceTabDragData>(
                    key: ValueKey('workspace-tab-drag-${widget.tabId}'),
                    activationDistance: 8,
                    maxSimultaneousDrags: 1,
                    data: dragData,
                    onDragStarted: () =>
                        _startPointerDrag(dragData.accessibility),
                    onPointerCancel: () =>
                        _cancelPointerDrag(dragData.accessibility),
                    onDragEnd: (_) {
                      _activePointer = null;
                      _endPointerDrag(dragData.accessibility);
                    },
                    feedback: Container(
                      key: ValueKey(
                        'workspace-tab-drag-feedback-${widget.tabId}',
                      ),
                      constraints: BoxConstraints.tightFor(
                        width: widget.width,
                        height: 29,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: palette.surface1,
                        border: Border.all(
                          color: palette.borderAccent,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.icon,
                            key: ValueKey(
                              'workspace-tab-drag-feedback-icon-${widget.tabId}',
                            ),
                            size: 14,
                            color: palette.foreground,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.foreground,
                                fontSize: 14,
                              ),
                              textDirection: Directionality.of(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    childWhenDragging: Opacity(opacity: .3, child: label),
                    child: keyboardDrag?.activeTabId == widget.tabId
                        ? Opacity(opacity: .3, child: label)
                        : label,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _WorkspacePaneDropCallback =
    void Function(
      _WorkspaceTabDragData data,
      WorkspaceSplitDropPosition position,
    );

class _WorkspacePaneDropTarget extends StatefulWidget {
  const _WorkspacePaneDropTarget({
    required this.paneId,
    required this.onDrop,
    required this.child,
  });

  final String paneId;
  final _WorkspacePaneDropCallback onDrop;
  final Widget child;

  @override
  State<_WorkspacePaneDropTarget> createState() =>
      _WorkspacePaneDropTargetState();
}

class _WorkspacePaneDropTargetState extends State<_WorkspacePaneDropTarget> {
  final _targetKey = GlobalKey();
  WorkspaceSplitDropPosition? _preview;

  Rect? get _bounds {
    final box = _targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String get _dragId => 'split-pane-drop:${widget.paneId}';

  WorkspaceSplitDropPosition? _resolve(
    _WorkspaceTabDragData data,
    Offset dragOffset,
  ) {
    final bounds = _bounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return null;
    final center = dragOffset + Offset(data.width / 2, data.height / 2);
    final relative = center - bounds.topLeft;
    if (relative.dx < 0 ||
        relative.dx > bounds.width ||
        relative.dy < 0 ||
        relative.dy > bounds.height) {
      return null;
    }
    return resolveWorkspaceSplitDropPosition(
      width: bounds.width,
      height: bounds.height,
      x: relative.dx,
      y: relative.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor.normal;
    return DragTarget<_WorkspaceTabDragData>(
      key: ValueKey('workspace-pane-drop-${widget.paneId}'),
      onWillAcceptWithDetails: (details) {
        final preview = _resolve(details.data, details.offset);
        if (preview == null) return false;
        details.data.accessibility.moveOver(_dragId);
        setState(() => _preview = preview);
        return true;
      },
      onMove: (details) {
        final preview = _resolve(details.data, details.offset);
        if (preview != null) {
          details.data.accessibility.moveOver(_dragId);
        }
        if (preview != _preview) setState(() => _preview = preview);
      },
      onLeave: (data) {
        data?.accessibility.leave(_dragId);
        setState(() => _preview = null);
      },
      onAcceptWithDetails: (details) {
        final preview = _resolve(details.data, details.offset) ?? _preview;
        setState(() => _preview = null);
        if (preview != null) widget.onDrop(details.data, preview);
      },
      builder: (context, candidateData, rejectedData) => Stack(
        key: _targetKey,
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_preview case final preview?)
            IgnorePointer(
              child: _WorkspaceSplitDropPreview(
                position: preview,
                accent: accent,
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkspaceSplitDropPreview extends StatelessWidget {
  const _WorkspaceSplitDropPreview({
    required this.position,
    required this.accent,
  });

  final WorkspaceSplitDropPosition position;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final inset = position == WorkspaceSplitDropPosition.center ? 8.0 : 0.0;
    final alignment = switch (position) {
      WorkspaceSplitDropPosition.left => Alignment.centerLeft,
      WorkspaceSplitDropPosition.right => Alignment.centerRight,
      WorkspaceSplitDropPosition.top => Alignment.topCenter,
      WorkspaceSplitDropPosition.bottom => Alignment.bottomCenter,
      WorkspaceSplitDropPosition.center => Alignment.center,
    };
    final widthFactor = switch (position) {
      WorkspaceSplitDropPosition.left || WorkspaceSplitDropPosition.right => .5,
      _ => 1.0,
    };
    final heightFactor = switch (position) {
      WorkspaceSplitDropPosition.top || WorkspaceSplitDropPosition.bottom => .5,
      _ => 1.0,
    };
    return Padding(
      padding: EdgeInsets.all(inset),
      child: Align(
        alignment: alignment,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          heightFactor: heightFactor,
          child: Container(
            key: const ValueKey('workspace-split-drop-preview'),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .6),
              border: Border.all(color: accent, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceResizeHandle extends StatefulWidget {
  const _WorkspaceResizeHandle({
    super.key,
    required this.direction,
    required this.groupExtent,
    required this.sizes,
    required this.index,
    required this.onResize,
  });

  final WorkspaceSplitDirection direction;
  final double groupExtent;
  final List<double> sizes;
  final int index;
  final ValueChanged<List<double>> onResize;

  @override
  State<_WorkspaceResizeHandle> createState() => _WorkspaceResizeHandleState();
}

class _WorkspaceResizeHandleState extends State<_WorkspaceResizeHandle> {
  List<double>? _startSizes;
  double _cumulativeDelta = 0;
  bool _hovered = false;
  bool _dragging = false;

  void _startDrag() {
    _startSizes = List<double>.of(widget.sizes);
    _cumulativeDelta = 0;
    setState(() => _dragging = true);
  }

  void _updateDrag(double delta) {
    final startSizes = _startSizes;
    if (startSizes == null ||
        !widget.groupExtent.isFinite ||
        widget.groupExtent <= 0) {
      return;
    }
    _cumulativeDelta += delta;
    widget.onResize(
      computeWorkspaceResizeHandleSizes(
        sizes: startSizes,
        index: widget.index,
        deltaRatio: _cumulativeDelta / widget.groupExtent,
      ),
    );
  }

  void _endDrag() {
    _startSizes = null;
    _cumulativeDelta = 0;
    if (mounted) setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.direction == WorkspaceSplitDirection.horizontal;
    final active = _hovered || _dragging;
    final accent = FluentTheme.of(context).accentColor.normal;
    final divider = Container(
      width: horizontal ? (active ? 3 : 1) : double.infinity,
      height: horizontal ? double.infinity : (active ? 3 : 1),
      color: active
          ? accent
          : FluentTheme.of(context).resources.dividerStrokeColorDefault,
    );
    return Semantics(
      label: 'Resize workspace panes',
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: horizontal ? (_) => _startDrag() : null,
          onHorizontalDragUpdate: horizontal
              ? (details) => _updateDrag(details.delta.dx)
              : null,
          onHorizontalDragEnd: horizontal ? (_) => _endDrag() : null,
          onHorizontalDragCancel: horizontal ? _endDrag : null,
          onVerticalDragStart: horizontal ? null : (_) => _startDrag(),
          onVerticalDragUpdate: horizontal
              ? null
              : (details) => _updateDrag(details.delta.dy),
          onVerticalDragEnd: horizontal ? null : (_) => _endDrag(),
          onVerticalDragCancel: horizontal ? null : _endDrag,
          child: SizedBox(
            width: horizontal ? 10 : double.infinity,
            height: horizontal ? double.infinity : 10,
            child: Center(child: divider),
          ),
        ),
      ),
    );
  }
}

class _WorkspacePaneShortcutHost extends ConsumerStatefulWidget {
  const _WorkspacePaneShortcutHost({
    required this.worktreePath,
    required this.onCloseCurrentTab,
    required this.onClosePane,
    this.onArchiveWorkspace,
    required this.child,
  });

  final String worktreePath;
  final Future<void> Function() onCloseCurrentTab;
  final Future<void> Function() onClosePane;
  final Future<void> Function()? onArchiveWorkspace;
  final Widget child;

  @override
  ConsumerState<_WorkspacePaneShortcutHost> createState() =>
      _WorkspacePaneShortcutHostState();
}

class _WorkspacePaneShortcutHostState
    extends ConsumerState<_WorkspacePaneShortcutHost> {
  late final void Function() _disposeKeyboardHandler;

  @override
  void initState() {
    super.initState();
    _disposeKeyboardHandler = keyboardActionDispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'workspace-pane-${widget.worktreePath}',
        actions: {
          'workspace.focus.toggle',
          'workspace.tab.close.current',
          'workspace.pane.split.right',
          'workspace.pane.split.down',
          'workspace.pane.focus.left',
          'workspace.pane.focus.right',
          'workspace.pane.focus.up',
          'workspace.pane.focus.down',
          'workspace.pane.move-tab.left',
          'workspace.pane.move-tab.right',
          'workspace.pane.move-tab.up',
          'workspace.pane.move-tab.down',
          'workspace.pane.close',
          if (widget.onArchiveWorkspace != null) 'workspace.archive',
        },
        enabled: true,
        priority: 20,
        isActive: () => mounted,
        handle: _handleAction,
      ),
    );
  }

  @override
  void dispose() {
    _disposeKeyboardHandler();
    super.dispose();
  }

  bool _handleAction(KeyboardActionDefinition action) {
    final notifier = ref.read(
      worktreeTabsProvider(widget.worktreePath).notifier,
    );
    switch (action.id) {
      case 'workspace.focus.toggle':
        ref.read(workspaceFocusModeProvider.notifier).toggle();
        return true;
      case 'workspace.tab.close.current':
        widget.onCloseCurrentTab();
        return true;
      case 'workspace.archive':
        widget.onArchiveWorkspace?.call();
        return widget.onArchiveWorkspace != null;
      case 'workspace.pane.split.right':
        notifier.splitFocusedPane(WorkspaceSplitDirection.horizontal);
        return true;
      case 'workspace.pane.split.down':
        notifier.splitFocusedPane(WorkspaceSplitDirection.vertical);
        return true;
      case 'workspace.pane.focus.left':
        notifier.focusPane(WorkspacePaneDirection.left);
        return true;
      case 'workspace.pane.focus.right':
        notifier.focusPane(WorkspacePaneDirection.right);
        return true;
      case 'workspace.pane.focus.up':
        notifier.focusPane(WorkspacePaneDirection.up);
        return true;
      case 'workspace.pane.focus.down':
        notifier.focusPane(WorkspacePaneDirection.down);
        return true;
      case 'workspace.pane.move-tab.left':
        notifier.moveActiveTab(WorkspacePaneDirection.left);
        return true;
      case 'workspace.pane.move-tab.right':
        notifier.moveActiveTab(WorkspacePaneDirection.right);
        return true;
      case 'workspace.pane.move-tab.up':
        notifier.moveActiveTab(WorkspacePaneDirection.up);
        return true;
      case 'workspace.pane.move-tab.down':
        notifier.moveActiveTab(WorkspacePaneDirection.down);
        return true;
      case 'workspace.pane.close':
        widget.onClosePane();
        return true;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
