import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../core/theme.dart';
import '../state/agent_history_provider.dart';
import '../state/host_registry_provider.dart';

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
        commandBar: hosts.length > 1
            ? SizedBox(
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
              )
            : null,
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: context.tokens.surfaceContainerHighest,
                  border: Border.all(color: context.tokens.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    for (var index = 0; index < entries.length; index++)
                      _SessionRow(
                        entry: entries[index],
                        showDivider: index > 0,
                      ),
                  ],
                ),
              ),
              if (state.hasMore) ...[
                const SizedBox(height: 16),
                Center(
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
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.entry, required this.showDivider});

  final AgentHistoryEntry entry;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final title = entry.agent.title.trim().isEmpty
        ? entry.agent.agentId
        : entry.agent.title;
    return Column(
      children: [
        if (showDivider)
          Divider(
            style: DividerThemeData(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.tokens.outlineVariant),
                ),
              ),
            ),
          ),
        ListTile(
          leading: const Icon(FluentIcons.history),
          title: Text(title),
          subtitle: Text('${entry.serverLabel} · ${entry.agent.cwd}'),
          trailing: Text(
            entry.agent.runState == AgentRunState.closed
                ? 'Archived'
                : entry.agent.runState.name,
            style: TextStyle(color: context.tokens.onSurfaceVariant),
          ),
          onPressed: entry.agent.workspaceId == null
              ? null
              : () => context.go(
                  buildHostWorkspaceRoute(
                    entry.serverId,
                    entry.agent.workspaceId!,
                  ),
                ),
        ),
      ],
    );
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
