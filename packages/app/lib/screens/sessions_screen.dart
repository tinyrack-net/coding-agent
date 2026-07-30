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

const _allHosts = '__all_hosts__';

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  String _selectedHost = _allHosts;

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostRegistryProvider).hosts;
    if (_selectedHost != _allHosts &&
        !hosts.any((host) => host.serverId == _selectedHost)) {
      _selectedHost = _allHosts;
    }
    final history = ref.watch(agentHistoryProvider);
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Sessions'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: () => ref.read(agentHistoryProvider.notifier).reload(),
            ),
            if (hosts.length > 1) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 220,
                child: ComboBox<String>(
                  value: _selectedHost,
                  items: [
                    const ComboBoxItem(
                      value: _allHosts,
                      child: Text('All hosts'),
                    ),
                    for (final host in hosts)
                      ComboBoxItem(
                        value: host.serverId,
                        child: Text(host.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _selectedHost = value);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      content: history.when(
        loading: () => const Center(child: ProgressRing()),
        error: (error, _) => _SessionsError(
          onRetry: () => ref.read(agentHistoryProvider.notifier).reload(),
        ),
        data: (state) {
          final entries = [
            for (final entry in state.entries)
              if (_selectedHost == _allHosts || entry.serverId == _selectedHost)
                entry,
          ];
          if (entries.isEmpty) {
            return _SessionsEmpty(
              allHosts: _selectedHost == _allHosts,
              onBack: () => context.go('/projects'),
            );
          }
          return AgentList(
            agents: entries,
            showHostColumn: _selectedHost == _allHosts && hosts.length > 1,
            onRefresh: () => ref.read(agentHistoryProvider.notifier).reload(),
            onAgentPressed: (entry) => context.go(
              buildHostAgentDetailRoute(
                entry.serverId,
                entry.agent.agentId,
                workspaceId: entry.agent.workspaceId,
              ),
            ),
            onAgentLongPressed: _archiveEntry,
            footer: state.hasMore
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Center(
                      child: Button(
                        onPressed: state.loadingMore
                            ? null
                            : () => ref
                                  .read(agentHistoryProvider.notifier)
                                  .loadMore(),
                        child: state.loadingMore
                            ? const SizedBox.square(
                                dimension: 16,
                                child: ProgressRing(strokeWidth: 2),
                              )
                            : const Text('Load more'),
                      ),
                    ),
                  )
                : null,
          );
        },
      ),
    );
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

class _SessionsEmpty extends StatelessWidget {
  const _SessionsEmpty({required this.allHosts, required this.onBack});

  final bool allHosts;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          FluentIcons.history,
          size: 32,
          color: context.tokens.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(
          allHosts ? 'No sessions yet' : 'No sessions for this host',
          style: context.textStyles.titleSmall,
        ),
        const SizedBox(height: 16),
        Button(onPressed: onBack, child: const Text('Back')),
      ],
    ),
  );
}

class _SessionsError extends StatelessWidget {
  const _SessionsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Unable to load sessions'),
        const SizedBox(height: 12),
        Button(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
