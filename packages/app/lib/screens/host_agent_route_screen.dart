import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/daemon_client.dart';
import '../core/host_routes.dart';
import '../state/agents_provider.dart';
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

    final host = registry.hosts.firstWhere(
      (candidate) => candidate.serverId == widget.serverId,
    );
    final cachedAgent = ref.watch(
      agentDirectoryReplicaStoreProvider.select(
        (replicas) => replicas[widget.serverId]?[widget.agentId],
      ),
    );
    final cachedWorkspaceId = cachedAgent?.workspaceId?.trim();
    if (cachedWorkspaceId != null && cachedWorkspaceId.isNotEmpty) {
      _redirect(
        buildHostWorkspaceOpenRoute(
          widget.serverId,
          cachedWorkspaceId,
          'agent:${widget.agentId}',
        ),
      );
      return const _AgentRouteProgress('Opening agent…');
    }

    final client = ref.watch(hostDaemonClientProvider(widget.serverId));
    final connection = ref.watch(hostConnectionStateProvider(widget.serverId));
    if (connection.value != DaemonConnectionState.connected) {
      final connecting =
          connection.isLoading ||
          connection.value == DaemonConnectionState.connecting;
      if (connecting) {
        return _AgentRouteProgress(
          'Connecting to ${host.label}...',
          detail: 'This agent will appear when the host is online.',
        );
      }
      final status = switch (connection.value) {
        DaemonConnectionState.disconnected || null => 'Offline',
        DaemonConnectionState.versionMismatch => 'Version mismatch',
        DaemonConnectionState.connecting => 'Connecting',
        DaemonConnectionState.connected => 'Online',
      };
      return _AgentHostUnavailable(
        title: connection.value == DaemonConnectionState.disconnected
            ? '${host.label} is offline'
            : 'Cannot reach ${host.label}',
        detail: 'Host status: $status',
        error: client?.lastConnectionError,
        onRetry: () => client?.connect(),
        onManageHost: () {
          unawaited(
            GoRouter.of(context).push<void>(
              buildSettingsHostSectionRoute(
                widget.serverId,
                HostSectionSlug.connections,
              ),
            ),
          );
        },
      );
    }
    if (client == null) {
      return _AgentHostUnavailable(
        title: 'Cannot reach ${host.label}',
        detail: 'Target host client is unavailable',
        error: null,
        onRetry: () {},
        onManageHost: () {
          unawaited(
            GoRouter.of(context).push<void>(
              buildSettingsHostSectionRoute(
                widget.serverId,
                HostSectionSlug.connections,
              ),
            ),
          );
        },
      );
    }
    return FutureBuilder<AgentFetchResult?>(
      future: _fetch(client),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _AgentRouteProgress(
            'Preparing ${host.label} session...',
            detail: 'We will show this agent in a moment.',
          );
        }
        if (snapshot.hasError) {
          return _AgentRouteFailure(
            title: 'Failed to load agent',
            detail: '${snapshot.error}',
            onRetry: () => setState(() {
              _requestKey = null;
              _request = null;
            }),
            onBack: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(buildHostRootRoute(widget.serverId));
              }
            },
          );
        }
        final agent = snapshot.data?.agent;
        final workspaceId = agent?.workspaceId?.trim();
        if (agent == null || workspaceId == null || workspaceId.isEmpty) {
          _redirect(buildHostRootRoute(widget.serverId));
          return const _AgentRouteProgress('Opening host…');
        }
        final target = buildHostWorkspaceOpenRoute(
          widget.serverId,
          workspaceId,
          'agent:${agent.agentId}',
        );
        _redirect(target);
        return const _AgentRouteProgress('Opening agent…');
      },
    );
  }
}

class _AgentRouteProgress extends StatelessWidget {
  const _AgentRouteProgress(this.label, {this.detail});

  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ProgressRing(),
        const SizedBox(height: 12),
        Text(label),
        if (detail case final value?) ...[
          const SizedBox(height: 8),
          Text(value, textAlign: TextAlign.center),
        ],
      ],
    ),
  );
}

class _AgentHostUnavailable extends StatelessWidget {
  const _AgentHostUnavailable({
    required this.title,
    required this.detail,
    required this.error,
    required this.onRetry,
    required this.onManageHost,
  });

  final String title;
  final String detail;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onManageHost;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: FluentTheme.of(context).typography.subtitle),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
        if (error case final value? when value.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: FluentTheme.of(context).resources.systemFillColorCritical,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            const SizedBox(width: 8),
            Button(onPressed: onManageHost, child: const Text('Manage host')),
          ],
        ),
      ],
    ),
  );
}

class _AgentRouteFailure extends StatelessWidget {
  const _AgentRouteFailure({
    required this.title,
    required this.detail,
    required this.onRetry,
    required this.onBack,
  });

  final String title;
  final String detail;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: FluentTheme.of(context).typography.subtitle),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            const SizedBox(width: 8),
            Button(onPressed: onBack, child: const Text('Back')),
          ],
        ),
      ],
    ),
  );
}
