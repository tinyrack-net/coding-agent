import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/daemon_client.dart';
import '../core/host_routes.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';

class HostAgentRouteScreen extends ConsumerStatefulWidget {
  const HostAgentRouteScreen({
    super.key,
    required this.serverId,
    required this.agentId,
  });

  final String serverId;
  final String agentId;

  @override
  ConsumerState<HostAgentRouteScreen> createState() =>
      _HostAgentRouteScreenState();
}

class _HostAgentRouteScreenState extends ConsumerState<HostAgentRouteScreen> {
  String? _activatedServerId;
  String? _requestKey;
  Future<AgentFetchResult?>? _request;
  String? _redirectTarget;

  void _redirect(String target) {
    if (_redirectTarget == target) return;
    _redirectTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(target);
    });
  }

  void _activateHost() {
    if (_activatedServerId == widget.serverId) return;
    _activatedServerId = widget.serverId;
    scheduleMicrotask(() async {
      await ref.read(hostRegistryProvider.notifier).selectHost(widget.serverId);
    });
  }

  Future<AgentFetchResult?> _fetch(DaemonClient client) {
    final key = '${widget.serverId}:${widget.agentId}';
    if (_requestKey != key) {
      _requestKey = key;
      _request = client.fetchAgent(widget.agentId);
    }
    return _request!;
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    if (!registry.loaded) return const _AgentRouteProgress('Loading hosts…');

    switch (resolveKnownHostRoute(
      routeServerId: widget.serverId,
      serverIds: registry.hosts.map((host) => host.serverId),
    )) {
      case KnownHostRouteResolution.openProject:
        _redirect('/open-project');
        return const _AgentRouteProgress('Opening projects…');
      case KnownHostRouteResolution.welcome:
        _redirect('/welcome');
        return const _AgentRouteProgress('Opening welcome…');
      case KnownHostRouteResolution.render:
        break;
    }

    if (registry.activeServerId != widget.serverId) {
      _activateHost();
      return const _AgentRouteProgress('Connecting to host…');
    }

    final connection = ref.watch(connectionStateProvider);
    if (connection.value != DaemonConnectionState.connected) {
      return _AgentRouteProgress(
        connection.value == DaemonConnectionState.connecting
            ? 'Connecting to host…'
            : 'Host is offline',
      );
    }
    final client = ref.watch(daemonClientProvider);
    return FutureBuilder<AgentFetchResult?>(
      future: _fetch(client),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _AgentRouteProgress('Loading agent…');
        }
        if (snapshot.hasError) {
          return _AgentRouteFailure(
            title: 'Could not load agent',
            detail: '${snapshot.error}',
          );
        }
        final agent = snapshot.data?.agent;
        if (agent == null) {
          return const _AgentRouteFailure(
            title: 'Agent not found',
            detail: 'The requested agent is not available on this host.',
          );
        }
        final workspaceId = agent.workspaceId?.trim();
        final target = buildHostWorkspaceOpenRoute(
          widget.serverId,
          workspaceId == null || workspaceId.isEmpty ? agent.cwd : workspaceId,
          'agent:${agent.agentId}',
        );
        _redirect(target);
        return const _AgentRouteProgress('Opening agent…');
      },
    );
  }
}

class _AgentRouteProgress extends StatelessWidget {
  const _AgentRouteProgress(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const ProgressRing(), const SizedBox(height: 12), Text(label)],
    ),
  );
}

class _AgentRouteFailure extends StatelessWidget {
  const _AgentRouteFailure({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: FluentTheme.of(context).typography.subtitle),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
      ],
    ),
  );
}
