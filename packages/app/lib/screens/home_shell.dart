import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import 'agent_chat_screen.dart';
import 'new_agent_screen.dart';
import 'settings_screen.dart';
import 'status_screen.dart';

/// Desktop-style shell: agent sidebar on the left, chat on the right.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedAgentProvider);

    return Scaffold(
      body: Row(
        children: [
          const SizedBox(width: 280, child: _Sidebar()),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const _EmptyPlaceholder()
                : AgentChatScreen(
                    key: ValueKey(selected),
                    agentId: selected,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined, size: 48, color: outline),
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

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(sortedAgentsProvider);
    final selected = ref.watch(selectedAgentProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text('Agents', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Daemon status',
                icon: const Icon(Icons.monitor_heart_outlined, size: 20),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const StatusScreen(),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Connection settings',
                icon: const Icon(Icons.settings_outlined, size: 20),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => showNewAgentDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('New Agent'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: agents.isEmpty
              ? Center(
                  child: Text(
                    'No agents yet',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: agents.length,
                  itemBuilder: (context, index) {
                    final agent = agents[index];
                    return _AgentTile(
                      agent: agent,
                      selected: agent.agentId == selected,
                      onTap: () => ref
                          .read(selectedAgentProvider.notifier)
                          .select(agent.agentId),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        const _ConnectionFooter(),
      ],
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.agent,
    required this.selected,
    required this.onTap,
  });

  final AgentSummary agent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: _RunStateIndicator(runState: agent.runState),
      title: Text(
        agent.title.isEmpty ? agent.agentId : agent.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${agent.provider} · ${agent.model}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
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
          AgentRunState.running => const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.amber,
              ),
            ),
          AgentRunState.awaitingPermission => const Icon(
              Icons.notification_important,
              size: 16,
              color: Colors.redAccent,
            ),
          AgentRunState.error => const Icon(
              Icons.circle,
              size: 10,
              color: Colors.redAccent,
            ),
          AgentRunState.initializing || AgentRunState.idle => const Icon(
              Icons.circle,
              size: 10,
              color: Colors.grey,
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
      DaemonConnectionState.connected => (
          Colors.greenAccent,
          'Daemon connected',
        ),
      DaemonConnectionState.connecting => (Colors.amber, 'Connecting…'),
      DaemonConnectionState.disconnected => (
          Colors.redAccent,
          'Daemon offline (retrying)',
        ),
      DaemonConnectionState.versionMismatch => (
          Colors.orangeAccent,
          'Daemon version incompatible',
        ),
    };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
