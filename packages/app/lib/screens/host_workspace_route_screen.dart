import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/daemon_client.dart';
import '../core/host_route_browser.dart';
import '../core/host_routes.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/workspace_catalog_provider.dart';
import '../state/workspace_recovery_provider.dart';
import '../state/worktree_tabs_provider.dart';
import '../workspace/workspace_file_open.dart';
import '../workspace/workspace_tab_model.dart';
import 'home_shell.dart';

class HostWorkspaceRouteScreen extends ConsumerStatefulWidget {
  const HostWorkspaceRouteScreen({
    super.key,
    required this.serverId,
    required this.workspaceId,
    this.openIntent,
    this.onOpenIntentConsumed,
  });

  final String serverId;
  final String workspaceId;
  final WorkspaceOpenIntent? openIntent;
  final VoidCallback? onOpenIntentConsumed;

  @override
  ConsumerState<HostWorkspaceRouteScreen> createState() =>
      _HostWorkspaceRouteScreenState();
}

class _HostWorkspaceRouteScreenState
    extends ConsumerState<HostWorkspaceRouteScreen> {
  String? _activatedServerId;
  String? _selectedWorkspaceKey;
  String? _appliedOpenIntentKey;
  String? _redirectTarget;
  String? _canonicalizedBrowserRouteKey;

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

  void _canonicalizeBrowserRoute() {
    final key = '${widget.serverId}:${widget.workspaceId}';
    if (_canonicalizedBrowserRouteKey == key) return;
    _canonicalizedBrowserRouteKey = key;
    stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit();
  }

  void _selectWorkspace(String directory) {
    final key = '${widget.serverId}:${widget.workspaceId}:$directory';
    if (_selectedWorkspaceKey == key) return;
    _selectedWorkspaceKey = key;
    scheduleMicrotask(() {
      ref.read(selectedWorktreeProvider.notifier).select(directory);
    });
  }

  void _applyOpenIntent(String directory) {
    final intent = widget.openIntent;
    if (intent == null) return;
    final key = '${widget.serverId}:${widget.workspaceId}:$intent';
    if (_appliedOpenIntentKey == key) return;
    _appliedOpenIntentKey = key;
    scheduleMicrotask(() {
      final tabs = ref.read(worktreeTabsProvider(directory).notifier);
      switch (intent) {
        case AgentWorkspaceOpenIntent():
          tabs.focusAgent(intent.agentId, pin: true);
        case FileWorkspaceOpenIntent():
          tabs.openFile(WorkspaceFileLocation(path: intent.path));
        case TerminalWorkspaceOpenIntent():
          tabs.focusOpenIntentTarget(
            WorkspaceTerminalTabTarget(terminalId: intent.terminalId),
          );
        case DraftWorkspaceOpenIntent():
          tabs.focusOpenIntentTarget(
            WorkspaceDraftTabTarget(draftId: intent.draftId),
          );
        case SetupWorkspaceOpenIntent():
          tabs.focusOpenIntentTarget(
            WorkspaceSetupTabTarget(workspaceId: intent.workspaceId),
          );
      }
      widget.onOpenIntentConsumed?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    if (!registry.loaded) return const _RouteProgress('Loading hosts…');

    switch (resolveKnownHostRoute(
      routeServerId: widget.serverId,
      serverIds: registry.hosts.map((host) => host.serverId),
    )) {
      case KnownHostRouteResolution.openProject:
        _redirect('/open-project');
        return const _RouteProgress('Opening projects…');
      case KnownHostRouteResolution.welcome:
        _redirect('/welcome');
        return const _RouteProgress('Opening welcome…');
      case KnownHostRouteResolution.render:
        break;
    }
    _canonicalizeBrowserRoute();

    if (registry.activeServerId != widget.serverId) {
      _activateHost();
      return const _RouteProgress('Connecting to host…');
    }

    final catalog = ref.watch(workspaceCatalogProvider);
    return catalog.when(
      loading: () => const _RouteProgress('Loading workspace…'),
      error: (error, _) => _RouteFailure(
        title: 'Could not load workspace',
        detail: error.toString(),
        onRetry: () => ref.invalidate(workspaceCatalogProvider),
      ),
      data: (workspaces) {
        final connection = ref.watch(connectionStateProvider);
        final host = registry.hosts.firstWhere(
          (candidate) => candidate.serverId == widget.serverId,
        );
        final hostOffline =
            connection.hasValue &&
            connection.value != DaemonConnectionState.connected;
        final matches = workspaces.where(
          (workspace) => workspace.id == widget.workspaceId,
        );
        if (matches.isEmpty) {
          if (hostOffline) {
            return _RouteFailure(
              title: connection.value == DaemonConnectionState.connecting
                  ? 'Connecting'
                  : '${host.label} is offline',
              detail: 'Host status: ${connection.value?.name ?? 'offline'}',
              onRetry: () => ref.read(daemonClientProvider).connect(),
              onOpenProjects: () =>
                  context.go('/settings/hosts/${widget.serverId}/connections'),
              secondaryLabel: 'Manage host',
            );
          }
          if (widget.openIntent case AgentWorkspaceOpenIntent(:final agentId)) {
            final request = WorkspaceRecoveryRequest(
              workspaceId: widget.workspaceId,
              agentId: agentId,
            );
            final recovery = ref.watch(workspaceRecoveryProvider(request));
            return _WorkspaceRecoveryView(
              model: recovery,
              onRecover: () => ref
                  .read(workspaceRecoveryProvider(request).notifier)
                  .restore(),
              onRetry: () => ref
                  .read(workspaceRecoveryProvider(request).notifier)
                  .inspect(),
              onOpenProjects: () => context.go('/open-project'),
            );
          }
          return _RouteFailure(
            title: 'Workspace not found',
            detail:
                'The workspace “${widget.workspaceId}” is not available on '
                'this host.',
            onRetry: () => ref.invalidate(workspaceCatalogProvider),
            onOpenProjects: () => context.go('/open-project'),
          );
        }
        final workspace = matches.first;
        ref.watch(worktreeTabLayoutsProvider);
        final layoutHydrated = ref.watch(worktreeTabLayoutsHydratedProvider);
        if (widget.openIntent != null && !layoutHydrated) {
          return const _RouteProgress('Loading workspace layout…');
        }
        _selectWorkspace(workspace.workspaceDirectory);
        _applyOpenIntent(workspace.workspaceDirectory);
        return WorkspaceDeckPane(worktreePath: workspace.workspaceDirectory);
      },
    );
  }
}

class _WorkspaceRecoveryView extends StatelessWidget {
  const _WorkspaceRecoveryView({
    required this.model,
    required this.onRecover,
    required this.onRetry,
    required this.onOpenProjects,
  });

  final WorkspaceRecoveryModel model;
  final VoidCallback onRecover;
  final VoidCallback onRetry;
  final VoidCallback onOpenProjects;

  @override
  Widget build(BuildContext context) => switch (model) {
    WorkspaceRecoveryIdle() ||
    WorkspaceRecoveryChecking() => const _RouteProgress('Loading workspace…'),
    WorkspaceRecoveryNeedsHostUpgrade() => _RouteFailure(
      title: 'Update your host to restore this workspace',
      detail: 'This host does not support workspace recovery.',
      onRetry: onRetry,
      onOpenProjects: onOpenProjects,
    ),
    WorkspaceRecoveryUnavailable(:final recovery) => _RouteFailure(
      title: 'Workspace unavailable',
      detail: recovery.message,
      onRetry: onRetry,
      onOpenProjects: onOpenProjects,
    ),
    WorkspaceRecoveryUnsupportedAction() => _RouteFailure(
      title: 'Workspace unavailable',
      detail: 'Update Tinyrack to recover this workspace.',
      onRetry: onRetry,
      onOpenProjects: onOpenProjects,
    ),
    WorkspaceRecoveryInspectionFailed(:final error) => _RouteFailure(
      title: "Couldn't check workspace",
      detail: error,
      onRetry: onRetry,
      onOpenProjects: onOpenProjects,
    ),
    WorkspaceRecoveryRecoverable(:final recovery, :final phase, :final error) =>
      _ArchivedWorkspaceRecovery(
        recovery: recovery,
        phase: phase,
        error: error,
        onRecover: onRecover,
      ),
  };
}

class _ArchivedWorkspaceRecovery extends StatelessWidget {
  const _ArchivedWorkspaceRecovery({
    required this.recovery,
    required this.phase,
    required this.error,
    required this.onRecover,
  });

  final RecoverableWorkspaceState recovery;
  final WorkspaceRecoveryPhase phase;
  final String? error;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final restoring = phase == WorkspaceRecoveryPhase.restoring;
    final restore = recovery.action == 'restore';
    final actionLabel = switch (phase) {
      WorkspaceRecoveryPhase.restoring => 'Restoring...',
      WorkspaceRecoveryPhase.failed => 'Retry',
      WorkspaceRecoveryPhase.ready => restore ? 'Restore' : 'Unarchive',
    };
    final description = restore
        ? '${recovery.workspaceName} was archived and its worktree was '
              'removed. Restore branch ${recovery.branch ?? ''} to open it '
              'again.'
        : '${recovery.workspaceName} is archived. Unarchive it to open it '
              'again.';
    return Center(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (restoring) ...[
              const ProgressRing(),
              const SizedBox(height: 12),
            ],
            Text(
              restoring ? 'Restoring workspace' : 'Workspace archived',
              style: FluentTheme.of(context).typography.subtitle,
            ),
            const SizedBox(height: 8),
            Text(description, textAlign: TextAlign.center),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                key: const ValueKey('workspace-recovery-error'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: FluentTheme.of(
                    context,
                  ).resources.systemFillColorCritical,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('workspace-recovery-action'),
              onPressed: restoring ? null : onRecover,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteProgress extends StatelessWidget {
  const _RouteProgress(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const ProgressRing(), const SizedBox(height: 12), Text(label)],
    ),
  );
}

class _RouteFailure extends StatelessWidget {
  const _RouteFailure({
    required this.title,
    required this.detail,
    required this.onRetry,
    this.onOpenProjects,
    this.secondaryLabel = 'Open projects',
  });

  final String title;
  final String detail;
  final VoidCallback onRetry;
  final VoidCallback? onOpenProjects;
  final String secondaryLabel;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 8),
          Text(detail, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Button(onPressed: onRetry, child: const Text('Retry')),
              if (onOpenProjects != null) ...[
                const SizedBox(width: 8),
                Button(onPressed: onOpenProjects, child: Text(secondaryLabel)),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
