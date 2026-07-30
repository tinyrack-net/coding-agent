import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../core/theme.dart';
import '../state/agent_history_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../widgets/adaptive_modal_sheet.dart';
import '../widgets/agent_list.dart';
import '../widgets/host_filter.dart';
import '../widgets/host_picker.dart';

List<AgentHistoryEntry> sortSessionsByLatestActivity(
  Iterable<AgentHistoryEntry> entries,
) {
  final indexed = entries.indexed.toList();
  indexed.sort((left, right) {
    final activity = right.$2.activityAt.compareTo(left.$2.activityAt);
    return activity != 0 ? activity : left.$1.compareTo(right.$1);
  });
  return List.unmodifiable(indexed.map((entry) => entry.$2));
}

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  String _selectedHost = allHostsOptionId;
  bool _manualRefresh = false;

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostRegistryProvider).hosts;
    if (_selectedHost != allHostsOptionId &&
        !hosts.any((host) => host.serverId == _selectedHost)) {
      _selectedHost = allHostsOptionId;
    }
    final history = ref.watch(agentHistoryProvider);
    return ScaffoldPage(
      header: const PageHeader(title: Text('Sessions')),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hosts.length > 1)
            LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsets.fromLTRB(
                  constraints.maxWidth < 720 ? 12 : 24,
                  16,
                  constraints.maxWidth < 720 ? 12 : 24,
                  0,
                ),
                child: HostFilter(
                  hosts: hosts,
                  selectedHost: _selectedHost,
                  triggerKey: const ValueKey('sessions-host-filter-trigger'),
                  onSelectHost: (value) =>
                      setState(() => _selectedHost = value),
                ),
              ),
            ),
          Expanded(
            child: history.when(
              loading: () => const Center(child: ProgressRing()),
              error: (error, _) => _SessionsMessage(
                text: 'Unable to load sessions',
                action: 'Try again',
                onAction: () =>
                    ref.read(agentHistoryProvider.notifier).reload(),
              ),
              data: (state) => _buildHistory(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistory(BuildContext context, AgentHistoryState state) {
    final allHosts = _selectedHost == allHostsOptionId;
    final entries = sortSessionsByLatestActivity([
      for (final entry in state.entries)
        if (allHosts || entry.serverId == _selectedHost) entry,
    ]);
    final selectedHostFailed =
        !allHosts && state.failedServerIds.contains(_selectedHost);
    if (entries.isEmpty) {
      if (selectedHostFailed) {
        return _SessionsMessage(
          text: 'Unable to load sessions',
          action: 'Try again',
          onAction: _refresh,
        );
      }
      return _SessionsMessage(
        text: allHosts ? 'No sessions yet' : 'No sessions for this host',
        action: 'Back',
        actionIcon: FluentIcons.chevron_left,
        onAction: () => context.go(buildOpenProjectRoute()),
      );
    }
    final hasMore = allHosts
        ? state.hasMore
        : state.nextCursorByServerId.containsKey(_selectedHost);
    return AgentList(
      agents: entries,
      refreshing: _manualRefresh,
      showAttentionIndicator: false,
      showHostColumn: true,
      onRefresh: _refresh,
      onAgentPressed: (entry) => context.go(
        buildHostAgentDetailRoute(
          entry.serverId,
          entry.agent.agentId,
          workspaceId: entry.agent.workspaceId,
        ),
      ),
      onAgentLongPressed: _archiveEntry,
      footer: hasMore
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Button(
                  onPressed: state.loadingMore
                      ? null
                      : () => ref
                            .read(agentHistoryProvider.notifier)
                            .loadMore(
                              serverId: allHosts ? null : _selectedHost,
                            ),
                  child: Text(state.loadingMore ? 'Loading...' : 'Load more'),
                ),
              ),
            )
          : null,
    );
  }

  Future<void> _refresh() async {
    if (_manualRefresh) return;
    setState(() => _manualRefresh = true);
    try {
      await ref
          .read(agentHistoryProvider.notifier)
          .refreshPreservingData(
            serverId: _selectedHost == allHostsOptionId ? null : _selectedHost,
          );
    } finally {
      if (mounted) setState(() => _manualRefresh = false);
    }
  }

  Future<void> _archiveEntry(AgentHistoryEntry entry) async {
    final client = ref.read(hostRuntimeClientsProvider)[entry.serverId];
    if (client == null ||
        entry.agent.runState == AgentRunState.running ||
        entry.agent.runState == AgentRunState.awaitingPermission) {
      await showAdaptiveModalSheet<void>(
        context: context,
        builder: (sheetContext) {
          final unavailable = client == null;
          return AdaptiveModalSheet(
            title: unavailable
                ? 'Host offline'
                : 'This agent is still running. Archiving it will stop the agent.',
            content: const SizedBox.shrink(),
            contentScrollable: false,
            sizeContentToCurrentSnapPoint: true,
            onClose: () => Navigator.of(sheetContext).pop(),
            actions: [
              Button(
                key: const ValueKey('agent-action-cancel'),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('agent-action-archive'),
                onPressed: unavailable
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _sendArchive(entry);
                      },
                child: const Text('Archive'),
              ),
            ],
          );
        },
      );
      return;
    }
    await _sendArchive(entry);
  }

  Future<void> _sendArchive(AgentHistoryEntry entry) async {
    final client = ref.read(hostRuntimeClientsProvider)[entry.serverId];
    if (client == null) return;
    try {
      await client.request(MessageTypes.agentArchiveRequest, {
        'agentId': entry.agent.agentId,
      });
    } on Object {
      // Paseo deliberately swallows archive timeouts: the daemon may still
      // process the mutation after the client-side deadline.
    }
    if (mounted) {
      await ref.read(agentHistoryProvider.notifier).reload();
    }
  }
}

class _SessionsMessage extends StatelessWidget {
  const _SessionsMessage({
    required this.text,
    required this.action,
    required this.onAction,
    this.actionIcon,
  });

  final String text;
  final String action;
  final VoidCallback onAction;
  final IconData? actionIcon;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            color: context.paseoPalette.foregroundMuted,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 24),
        Button(
          onPressed: onAction,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (actionIcon != null) ...[
                Icon(actionIcon, size: 14),
                const SizedBox(width: 6),
              ],
              Text(action),
            ],
          ),
        ),
      ],
    ),
  );
}
