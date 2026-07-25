import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../core/worktree_actions.dart';
import '../state/daemon_providers.dart';
import '../state/sidebar_grouping_provider.dart';
import '../state/sidebar_pins_provider.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../state/worktree_titles_provider.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/worktree_tabbed_pane.dart';

/// Desktop-style shell: agent sidebar on the left, persistent across every
/// route, with [child] (the currently routed page) filling the rest.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: FluentTheme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          const SizedBox(width: 280, child: _Sidebar()),
          const Divider(direction: Axis.vertical),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The "/" route's content: the selected worktree's tab strip, or an empty
/// placeholder when none is selected.
class HomeChatPane extends ConsumerWidget {
  const HomeChatPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedWorktreeProvider);
    if (selected == null) return const _EmptyPlaceholder();
    final agentContext = ref.watch(worktreeAgentContextProvider(selected));
    return WorktreeTabbedPane(
      key: ValueKey(selected),
      worktreePath: selected,
      projectPath: agentContext.projectPath,
      branch: agentContext.branch,
      isWorktree: agentContext.isWorktree,
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final outline = context.tokens.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.robot, size: 48, color: outline),
          const SizedBox(height: 12),
          Text(
            'Select an agent or create a new one',
            style: TextStyle(color: outline),
          ),
        ],
      ),
    );
  }
}

/// A full-width, hover-highlighted icon+label row — Paseo's
/// `SidebarHeaderRow` pattern, used for the header group's global actions.
class _SidebarHeaderRow extends StatelessWidget {
  const _SidebarHeaderRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        onPressed: onTap,
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: hovering
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A collapsible project section header: icon + name + a chevron that
/// flips to indicate expanded/collapsed (Paseo's `ProjectHeaderRow`, minus
/// drag-reorder and the project-level kebab menu — out of scope here).
class _ProjectHeaderRow extends StatelessWidget {
  const _ProjectHeaderRow({
    required this.name,
    required this.isGitRepo,
    required this.collapsed,
    required this.onTap,
  });

  final String name;
  final bool isGitRepo;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        onPressed: onTap,
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: hovering
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                Icon(
                  isGitRepo ? FluentIcons.folder_horizontal : FluentIcons.folder,
                  size: 14,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textStyles.bodyMedium,
                  ),
                ),
                Icon(
                  collapsed ? FluentIcons.chevron_right : FluentIcons.chevron_down,
                  size: 12,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        text,
        style: context.textStyles.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
      ),
    );
  }
}

class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar();

  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  final _collapsedProjectPaths = <String>{};

  void _toggleProject(String projectPath) {
    setState(() {
      if (!_collapsedProjectPaths.remove(projectPath)) {
        _collapsedProjectPaths.add(projectPath);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedWorktreeProvider);
    final groups = ref.watch(sidebarGroupsProvider);

    void selectRow(SidebarWorktreeRow row) {
      ref.read(selectedWorktreeProvider.notifier).select(row.key);
      // Selecting only updates state — it has no visible effect unless the
      // content area is actually showing HomeChatPane. Without this, a
      // worktree row tapped while on a pushed screen (New workspace/
      // Projects/Status/Settings) silently does nothing, since none of
      // those routes pop themselves in response to a selection change.
      if (GoRouterState.of(context).matchedLocation != '/') {
        context.go('/');
      }
    }

    return Column(
      children: [
        const SizedBox(height: 4),
        _SidebarHeaderRow(
          icon: FluentIcons.add,
          label: 'New workspace',
          onTap: () => context.push('/new-workspace'),
        ),
        _SidebarHeaderRow(
          icon: FluentIcons.branch_fork2,
          label: 'Projects & worktrees',
          onTap: () => context.push('/projects'),
        ),
        _SidebarHeaderRow(
          icon: FluentIcons.health,
          label: 'Status',
          onTap: () => context.push('/status'),
        ),
        const Divider(),
        Expanded(
          child: groups.isEmpty
              ? Center(
                  child: Text(
                    'No agents yet',
                    style: TextStyle(color: context.tokens.outline),
                  ),
                )
              : ListView(
                  children: [
                    if (groups.pinned.isNotEmpty) ...[
                      const _SectionLabel('Pinned'),
                      for (final row in groups.pinned)
                        _SidebarWorktreeRow(
                          row: row,
                          selected: row.key == selected,
                          onTap: () => selectRow(row),
                        ),
                    ],
                    for (final section in groups.projectSections) ...[
                      _ProjectHeaderRow(
                        name: section.project.name.isEmpty
                            ? section.project.path
                            : section.project.name,
                        isGitRepo: section.project.isGitRepo,
                        collapsed:
                            _collapsedProjectPaths.contains(section.project.path),
                        onTap: () => _toggleProject(section.project.path),
                      ),
                      if (!_collapsedProjectPaths.contains(section.project.path))
                        for (final row in section.rows)
                          _SidebarWorktreeRow(
                            row: row,
                            selected: row.key == selected,
                            onTap: () => selectRow(row),
                          ),
                    ],
                    for (final row in groups.other)
                      _SidebarWorktreeRow(
                        row: row,
                        selected: row.key == selected,
                        onTap: () => selectRow(row),
                      ),
                  ],
                ),
        ),
        const Divider(),
        const _ConnectionFooter(),
      ],
    );
  }
}

/// The most urgent run state among a worktree row's agents (or `null` when
/// it has none), used to roll up the leading status dot for the whole row.
AgentRunState? _aggregateRunState(List<AgentSummary> agents) {
  const urgency = {
    AgentRunState.awaitingPermission: 0,
    AgentRunState.error: 1,
    AgentRunState.running: 2,
    AgentRunState.initializing: 3,
    AgentRunState.idle: 3,
  };
  AgentRunState? worst;
  for (final agent in agents) {
    if (worst == null || urgency[agent.runState]! < urgency[worst]!) {
      worst = agent.runState;
    }
  }
  return worst;
}

/// One sidebar row per worktree/session-group (Paseo parity: exactly one
/// row regardless of how many agent sessions share it). Always
/// tappable/selectable — even with zero agents, selecting it opens
/// [WorktreeTabbedPane], which seeds a draft composer tab.
class _SidebarWorktreeRow extends ConsumerWidget {
  const _SidebarWorktreeRow({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final SidebarWorktreeRow row;
  final bool selected;
  final VoidCallback onTap;

  String get _fallbackName {
    // A single session's own title is more informative than the branch name
    // (preserves the pre-unification per-agent row's look); branch/path is
    // only a fallback for empty or multi-session rows.
    if (row.agents.length == 1) {
      final agent = row.agents.single;
      return agent.title.isEmpty ? agent.agentId : agent.title;
    }
    final worktree = row.worktree;
    if (worktree != null) {
      return worktree.branch.isEmpty ? '(detached)' : worktree.branch;
    }
    return row.key;
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final current = ref.read(worktreeTitlesProvider)[row.key] ?? '';
    final controller = TextEditingController(text: current);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Rename'),
        // Without this, TextBox greedily fills ContentDialog's unconstrained
        // body height instead of sizing to its single line of text.
        content: IntrinsicHeight(
          child: TextBox(
            controller: controller,
            autofocus: true,
            placeholder: _fallbackName,
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null) return;
    await ref.read(worktreeTitlesProvider.notifier).setTitle(row.key, title);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(sidebarPinsProvider).contains(row.key);
    final override = ref.watch(worktreeTitlesProvider)[row.key];
    final title = override ?? _fallbackName;
    final subtitle = switch (row.agents.length) {
      0 => row.key,
      1 => '${row.agents.single.provider} · ${row.agents.single.model}',
      final n => '$n sessions',
    };
    final runState = _aggregateRunState(row.agents);
    final worktree = row.worktree;
    final branch = worktree?.branch ??
        (row.agents.length == 1 ? row.agents.single.branch : null);
    final canArchiveWorktree =
        worktree != null && !worktree.isMain && row.agents.isEmpty;

    return ListTile.selectable(
      selected: selected,
      leading: runState == null
          ? Icon(
              worktree == null || worktree.isMain
                  ? FluentIcons.home
                  : FluentIcons.branch_fork2,
              size: 16,
            )
          : _RunStateIndicator(runState: runState),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: DropDownButton(
        // scaffoldBackgroundColor is a semi-transparent white overlay (not a
        // solid color), so it only reads as near-black because nothing
        // bright sits behind it elsewhere. MenuFlyout wraps its content in
        // an Acrylic (blur+tint) layer — passing the same translucent color
        // here would let that layer bleed through, so flatten it opaque
        // first to fully occlude the acrylic tint underneath.
        menuColor: Color.alphaBlend(
          FluentTheme.of(context).scaffoldBackgroundColor,
          Colors.black,
        ),
        buttonBuilder: (context, onOpen) => IconButton(
          icon: const Icon(FluentIcons.more_vertical, size: 14),
          onPressed: onOpen,
        ),
        items: [
          MenuFlyoutItem(
            text: const Text('Copy path'),
            leading: const Icon(FluentIcons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: row.key));
              AppToast.show(context, 'Path copied');
            },
          ),
          if (branch != null && branch.isNotEmpty)
            MenuFlyoutItem(
              text: const Text('Copy branch'),
              leading: const Icon(FluentIcons.branch_fork2),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: branch));
                AppToast.show(context, 'Branch copied');
              },
            ),
          MenuFlyoutItem(
            text: const Text('Rename'),
            leading: const Icon(FluentIcons.rename),
            onPressed: () => _rename(context, ref),
          ),
          MenuFlyoutItem(
            text: Text(pinned ? 'Unpin' : 'Pin'),
            leading: Icon(pinned ? FluentIcons.unpin : FluentIcons.pin),
            onPressed: () =>
                ref.read(sidebarPinsProvider.notifier).togglePin(row.key),
          ),
          for (final agent in row.agents)
            MenuFlyoutItem(
              text: Text(
                row.agents.length == 1
                    ? 'Archive'
                    : 'Archive ${agent.title.isEmpty ? agent.agentId : agent.title}',
              ),
              leading: const Icon(FluentIcons.archive),
              onPressed: () =>
                  archiveAgentWithWorktreeConfirm(context, ref, agent),
            ),
          if (canArchiveWorktree)
            MenuFlyoutItem(
              text: const Text('Archive worktree'),
              leading: const Icon(FluentIcons.archive),
              onPressed: () => archiveWorktreeWithConfirm(
                context,
                ref,
                worktree.projectPath,
                worktree.path,
              ),
            ),
        ],
      ),
      onPressed: onTap,
    );
  }
}

class _RunStateIndicator extends StatelessWidget {
  const _RunStateIndicator({required this.runState});

  final AgentRunState runState;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: switch (runState) {
          AgentRunState.running => SizedBox(
              width: 14,
              height: 14,
              child: ProgressRing(strokeWidth: 2, activeColor: Colors.yellow),
            ),
          AgentRunState.awaitingPermission => Icon(
              FluentIcons.ringer,
              size: 16,
              color: Colors.red,
            ),
          AgentRunState.error => Icon(
              FluentIcons.circle_fill,
              size: 10,
              color: Colors.red,
            ),
          AgentRunState.initializing || AgentRunState.idle => Icon(
              FluentIcons.circle_fill,
              size: 10,
              color: Colors.grey[100],
            ),
        },
      ),
    );
  }
}

class _ConnectionFooter extends ConsumerWidget {
  const _ConnectionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionStateProvider).value ??
        DaemonConnectionState.connecting;
    final (color, label) = switch (connection) {
      DaemonConnectionState.connected => (Colors.green, 'Daemon connected'),
      DaemonConnectionState.connecting => (Colors.yellow, 'Connecting…'),
      DaemonConnectionState.disconnected => (
          Colors.red,
          'Daemon offline (retrying)',
        ),
      DaemonConnectionState.versionMismatch => (
          Colors.orange,
          'Daemon version incompatible',
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(FluentIcons.circle_fill, size: 10, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: context.textStyles.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: 'Connection settings',
            child: IconButton(
              icon: const Icon(FluentIcons.settings, size: 16),
              onPressed: () => context.go('/settings'),
            ),
          ),
        ],
      ),
    );
  }
}
