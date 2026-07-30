import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../state/host_registry_provider.dart';
import '../state/last_workspace_route_selection.dart';
import '../state/workspace_catalog_provider.dart';

enum WorkspaceSelectionStatus { unknown, exists, missing }

WorkspaceSelectionStatus resolveWorkspaceSelectionStatus({
  required bool hasHydratedWorkspaces,
  required bool workspaceExists,
}) {
  if (workspaceExists) return WorkspaceSelectionStatus.exists;
  return hasHydratedWorkspaces
      ? WorkspaceSelectionStatus.missing
      : WorkspaceSelectionStatus.unknown;
}

String resolveHostIndexRoute({
  required String serverId,
  required HostWorkspaceRoute? workspaceSelection,
  required WorkspaceSelectionStatus workspaceSelectionStatus,
}) {
  if (workspaceSelection?.serverId == serverId &&
      workspaceSelectionStatus != WorkspaceSelectionStatus.missing) {
    return buildHostWorkspaceRoute(serverId, workspaceSelection!.workspaceId);
  }
  return buildOpenProjectRoute();
}

class HostIndexRouteScreen extends ConsumerStatefulWidget {
  const HostIndexRouteScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<HostIndexRouteScreen> createState() =>
      _HostIndexRouteScreenState();
}

class _HostIndexRouteScreenState extends ConsumerState<HostIndexRouteScreen> {
  String? _activatedServerId;
  String? _redirectTarget;

  void _redirect(String target) {
    if (_redirectTarget == target) return;
    _redirectTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.replace(target);
    });
  }

  void _activateHost() {
    if (_activatedServerId == widget.serverId) return;
    _activatedServerId = widget.serverId;
    scheduleMicrotask(() async {
      await ref.read(hostRegistryProvider.notifier).selectHost(widget.serverId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    if (!registry.loaded) {
      return const _HostIndexProgress('Loading hosts…');
    }

    switch (resolveKnownHostRoute(
      routeServerId: widget.serverId,
      serverIds: registry.hosts.map((host) => host.serverId),
    )) {
      case KnownHostRouteResolution.openProject:
        _redirect(buildOpenProjectRoute());
        return const _HostIndexProgress('Opening projects…');
      case KnownHostRouteResolution.welcome:
        _redirect('/welcome');
        return const _HostIndexProgress('Opening welcome…');
      case KnownHostRouteResolution.render:
        break;
    }

    if (registry.activeServerId != widget.serverId) {
      _activateHost();
      return const _HostIndexProgress('Connecting to host…');
    }

    final selectionValue = ref.watch(lastWorkspaceRouteSelectionProvider);
    if (selectionValue.isLoading) {
      return const _HostIndexProgress('Loading workspace selection…');
    }
    final selection = switch (selectionValue) {
      AsyncData(:final value) => value,
      AsyncError() || AsyncLoading() => null,
    };
    if (selection?.serverId != widget.serverId) {
      _redirect(buildOpenProjectRoute());
      return const _HostIndexProgress('Opening projects…');
    }

    final catalog = ref.watch(workspaceCatalogProvider);
    final status = switch (catalog) {
      AsyncData(:final value) => resolveWorkspaceSelectionStatus(
        hasHydratedWorkspaces: true,
        workspaceExists: value.any(
          (workspace) => workspace.id == selection?.workspaceId,
        ),
      ),
      AsyncLoading() || AsyncError() => resolveWorkspaceSelectionStatus(
        hasHydratedWorkspaces: false,
        workspaceExists: false,
      ),
    };
    final target = resolveHostIndexRoute(
      serverId: widget.serverId,
      workspaceSelection: selection,
      workspaceSelectionStatus: status,
    );
    _redirect(target);
    return _HostIndexProgress(
      target == buildOpenProjectRoute()
          ? 'Opening projects…'
          : 'Opening workspace…',
    );
  }
}

class _HostIndexProgress extends StatelessWidget {
  const _HostIndexProgress(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      key: const ValueKey('host-index-progress'),
      mainAxisSize: MainAxisSize.min,
      children: [const ProgressRing(), const SizedBox(height: 12), Text(label)],
    ),
  );
}
