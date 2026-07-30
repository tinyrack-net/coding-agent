import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../core/theme.dart';
import '../core/worktree_actions.dart';
import '../layout/desktop_sidebar_layout.dart';
import '../mobile_panels/compact_explorer_sidebar_host_model.dart';
import '../mobile_panels/mobile_panel_model.dart';
import '../sidebar/sidebar_project_row_model.dart';
import '../sidebar/sidebar_gesture_interaction.dart';
import '../sidebar/sidebar_reorder.dart';
import '../sidebar/workspace_agent_activity.dart';
import '../state/agents_provider.dart';
import '../state/add_project_flow_provider.dart';
import '../state/command_center_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/app_sidebar_visibility_provider.dart';
import '../state/workspace_focus_mode_provider.dart';
import '../state/workspace_checkout_status_provider.dart';
import '../state/workspace_catalog_provider.dart';
import '../state/workspace_agent_activity_provider.dart';
import '../state/sidebar_grouping_provider.dart';
import '../state/sidebar_order_provider.dart';
import '../state/sidebar_pins_provider.dart';
import '../state/sidebar_width_provider.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../state/worktree_titles_provider.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/add_project_flow_host.dart';
import '../widgets/host_picker.dart';
import '../widgets/provider_settings_host.dart';
import '../widgets/sidebar_agent_list_skeleton.dart';
import '../widgets/sidebar_callout_slot.dart';
import '../widgets/sidebar_resize_handle.dart';
import '../widgets/workspace_explorer.dart';
import '../widgets/worktree_tabbed_pane.dart';
import '../workspace/workspace_deck_retention.dart';
import '../workspace/workspace_file_open.dart';

/// Desktop-style shell: agent sidebar on the left, persistent across every
/// route, with [child] (the currently routed page) filling the rest.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.child, this.routeLocation});

  final Widget child;
  final String? routeLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sidebarVisible = ref.watch(appSidebarVisibilityProvider);
    final focusMode = ref.watch(workspaceFocusModeProvider);
    final selectedWorkspace = ref.watch(selectedWorktreeProvider);
    final location = routeLocation ?? GoRouterState.of(context).matchedLocation;
    final workspaceFocusMode =
        focusMode &&
        (parseHostWorkspaceRouteFromPathname(location) != null ||
            (location == '/' && selectedWorkspace != null));
    final compact = MediaQuery.sizeOf(context).width <= compactFormFactorWidth;
    final recordedCompact = ref.watch(appCompactLayoutProvider);
    if (recordedCompact != compact) {
      scheduleMicrotask(
        () => ref.read(appCompactLayoutProvider.notifier).setCompact(compact),
      );
    }
    final content = _HomeContentDeck(
      routeChild: child,
      routeLocation: routeLocation,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: FluentTheme.of(context).scaffoldBackgroundColor,
          child: compact
              ? _CompactHomeLayout(content: content)
              : sidebarVisible && !workspaceFocusMode
              ? _ResizableHomeLayout(content: content)
              : content,
        ),
        const AddProjectFlowHost(),
        const ProviderSettingsHost(),
      ],
    );
  }
}

class _CompactHomeLayout extends ConsumerStatefulWidget {
  const _CompactHomeLayout({required this.content});

  final Widget content;

  @override
  ConsumerState<_CompactHomeLayout> createState() => _CompactHomeLayoutState();
}

class _CompactHomeLayoutState extends ConsumerState<_CompactHomeLayout>
    with SingleTickerProviderStateMixin {
  static const _animationDuration = Duration(milliseconds: 220);
  static const _animationCurve = Cubic(0.25, 0.1, 0.25, 1);

  late final AnimationController _position;
  late MobilePanelMotionState _motionState;
  double _horizontalDrag = 0;
  var _startedRevision = -1;
  var _leftPresented = false;
  var _rightPresented = false;
  CompactExplorerSidebarHostModel? _retainedExplorerModel;
  CompactExplorerSidebarHostModel? _activeExplorerModel;

  @override
  void initState() {
    super.initState();
    final selection = ref.read(mobilePanelProvider);
    _motionState = MobilePanelMotionState.fromSelection(selection);
    _position = AnimationController.unbounded(
      vsync: this,
      value: getMobilePanelAnchor(selection.target),
    );
    _leftPresented = selection.target == MobilePanelView.agentList;
    _rightPresented = selection.target == MobilePanelView.fileExplorer;
    ref.listenManual<MobilePanelSelection>(
      mobilePanelProvider,
      (_, next) => _applySelection(next),
    );
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _applySelection(MobilePanelSelection selection) {
    final transition = transitionMobilePanel(
      _motionState,
      MobilePanelCommand(selection),
    );
    if (identical(transition.state, _motionState)) return;
    _motionState = transition.state;
    final target = transition.animationTarget;
    if (target == null) return;
    if (target == MobilePanelView.agentList && !_leftPresented) {
      setState(() => _leftPresented = true);
    } else if (target == MobilePanelView.fileExplorer && !_rightPresented) {
      setState(() => _rightPresented = true);
    }
    _animateTo(target, selection.revision);
  }

  void _animateTo(MobilePanelView target, int revision) {
    unawaited(
      _position
          .animateTo(
            getMobilePanelAnchor(target),
            duration: _animationDuration,
            curve: _animationCurve,
          )
          .then((_) {
            if (!mounted) return;
            final transition = transitionMobilePanel(
              _motionState,
              MobilePanelAnimationFinished(revision: revision, target: target),
            );
            _motionState = transition.state;
            final selection = ref.read(mobilePanelProvider);
            if (selection.revision != revision || selection.target != target) {
              return;
            }
            setState(() {
              _leftPresented = target == MobilePanelView.agentList;
              _rightPresented = target == MobilePanelView.fileExplorer;
            });
          }),
    );
  }

  void _beginDrag(DragStartDetails _) {
    final selection = ref.read(mobilePanelProvider);
    final transition = transitionMobilePanel(
      _motionState,
      MobilePanelGestureBegin(selection.target),
    );
    if (identical(transition.state, _motionState)) {
      _startedRevision = -1;
      return;
    }
    _motionState = transition.state;
    _startedRevision = transition.state.gesture?.startedRevision ?? -1;
    _horizontalDrag = 0;
    _position.stop();
    setState(() {
      if (selection.target == MobilePanelView.agent) {
        _leftPresented = true;
        _rightPresented =
            _activeExplorerModel?.workspaceRoot.isNotEmpty == true;
      }
    });
  }

  void _updateDrag(DragUpdateDetails details) {
    if (!isMobilePanelGestureCurrent(_motionState, _startedRevision)) {
      return;
    }
    _horizontalDrag += details.primaryDelta ?? 0;
    if (_motionState.target == MobilePanelView.agent &&
        _horizontalDrag < 0 &&
        _activeExplorerModel?.workspaceRoot.isNotEmpty != true) {
      _position.value = 0;
      return;
    }
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final nextPosition = switch (_motionState.target) {
      MobilePanelView.agent => -_horizontalDrag / width,
      MobilePanelView.agentList => -1 - _horizontalDrag / width,
      MobilePanelView.fileExplorer => 1 - _horizontalDrag / width,
    };
    _position.value = nextPosition.clamp(-1.0, 1.0);
  }

  void _finishDrag(DragEndDetails details) {
    if (!isMobilePanelGestureCurrent(_motionState, _startedRevision)) {
      return;
    }
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final velocity = details.primaryVelocity ?? 0;
    final origin = _motionState.target;
    final hasExplorer = _activeExplorerModel?.workspaceRoot.isNotEmpty == true;
    final target = switch (origin) {
      MobilePanelView.agent
          when _horizontalDrag > width / 3 || velocity > 500 =>
        MobilePanelView.agentList,
      MobilePanelView.agent
          when hasExplorer &&
              (_horizontalDrag < -width / 3 || velocity < -500) =>
        MobilePanelView.fileExplorer,
      MobilePanelView.agent => MobilePanelView.agent,
      MobilePanelView.agentList
          when _horizontalDrag < -width / 3 || velocity < -500 =>
        MobilePanelView.agent,
      MobilePanelView.agentList => MobilePanelView.agentList,
      MobilePanelView.fileExplorer
          when _horizontalDrag > width / 3 || velocity > 500 =>
        MobilePanelView.agent,
      MobilePanelView.fileExplorer => MobilePanelView.fileExplorer,
    };
    final transition = transitionMobilePanel(
      _motionState,
      MobilePanelGestureFinish(
        startedRevision: _startedRevision,
        success: true,
        target: target,
      ),
    );
    _motionState = transition.state;
    final commit = transition.commit;
    if (commit != null &&
        ref.read(mobilePanelProvider).revision == commit.startedRevision) {
      final notifier = ref.read(mobilePanelProvider.notifier);
      switch (commit.target) {
        case MobilePanelView.agent:
          notifier.showAgent();
        case MobilePanelView.agentList:
          notifier.showAgentList();
        case MobilePanelView.fileExplorer:
          notifier.showFileExplorer();
      }
    } else {
      _animateTo(target, _motionState.revision);
    }
    _horizontalDrag = 0;
    _startedRevision = -1;
  }

  void _cancelDrag() {
    if (!isMobilePanelGestureCurrent(_motionState, _startedRevision)) {
      return;
    }
    final target = _motionState.target;
    final transition = transitionMobilePanel(
      _motionState,
      MobilePanelGestureFinish(
        startedRevision: _startedRevision,
        success: false,
        target: target,
      ),
    );
    _motionState = transition.state;
    _animateTo(target, _motionState.revision);
    _horizontalDrag = 0;
    _startedRevision = -1;
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(mobilePanelProvider);
    final selectedWorktree = ref.watch(selectedWorktreeProvider);
    final notifier = ref.read(mobilePanelProvider.notifier);
    final activeHost = ref.watch(activeHostProvider);
    final client = ref.watch(daemonClientProvider);
    final activeServerId = activeHost?.serverId.trim();
    final connectedServerId = client.serverInfo?.serverId.trim();
    final serverId = activeServerId?.isNotEmpty == true
        ? activeServerId!
        : connectedServerId?.isNotEmpty == true
        ? connectedServerId!
        : '';
    final catalogByServer = ref.watch(workspaceCatalogCacheProvider);
    final catalog = catalogByServer[serverId] ?? const <WorkspaceDescriptor>[];
    final agentContext = selectedWorktree == null
        ? null
        : ref.watch(worktreeAgentContextProvider(selectedWorktree));
    final contextWorkspaceId = agentContext?.workspaceId?.trim();
    WorkspaceDescriptor? workspace;
    if (selectedWorktree != null) {
      for (final candidate in catalog) {
        if (candidate.workspaceDirectory == selectedWorktree) {
          workspace = candidate;
          break;
        }
      }
      if (workspace == null &&
          contextWorkspaceId != null &&
          contextWorkspaceId.isNotEmpty) {
        for (final candidate in catalog) {
          if (candidate.id == contextWorkspaceId) {
            workspace = candidate;
            break;
          }
        }
      }
    }
    final explorerOpen = selection.target == MobilePanelView.fileExplorer;
    final retainedSelection =
        explorerOpen &&
            selectedWorktree != null &&
            _retainedExplorerModel?.serverId == serverId &&
            _retainedExplorerModel?.workspaceRoot == selectedWorktree
        ? _retainedExplorerModel
        : null;
    final workspaceId =
        workspace?.id ??
        (contextWorkspaceId?.isNotEmpty == true ? contextWorkspaceId : null) ??
        retainedSelection?.workspaceId ??
        '';
    final explorerSelection = serverId.isEmpty || workspaceId.isEmpty
        ? null
        : CompactExplorerSelection(
            serverId: serverId,
            workspaceId: workspaceId,
          );
    final checkoutStatusKey = workspace == null || serverId.isEmpty
        ? null
        : (serverId: serverId, cwd: workspace.workspaceDirectory);
    final checkoutStatus = checkoutStatusKey == null
        ? null
        : ref.watch(workspaceCheckoutStatusProvider(checkoutStatusKey)).value;
    final resolvedExplorerModel = resolveCompactExplorerSidebarHostModel(
      previous: explorerOpen ? _retainedExplorerModel : null,
      selection: explorerSelection,
      workspace: workspace == null
          ? null
          : CompactExplorerWorkspaceSnapshot(
              workspaceDirectory: workspace.workspaceDirectory,
            ),
      isGit: checkoutStatus?.isGit ?? false,
    );
    if (explorerSelection == null) {
      _retainedExplorerModel = null;
    } else if (!explorerOpen) {
      _retainedExplorerModel = null;
    } else if (resolvedExplorerModel != null) {
      _retainedExplorerModel = resolvedExplorerModel;
    }
    _activeExplorerModel =
        resolvedExplorerModel ?? (explorerOpen ? _retainedExplorerModel : null);

    if (explorerOpen && explorerSelection == null) {
      scheduleMicrotask(notifier.showAgent);
    }

    void openWorkspaceFile(WorkspaceFileOpenRequest request) {
      final path = _activeExplorerModel?.workspaceRoot;
      if (path == null || path.isEmpty) return;
      final tabs = ref.read(worktreeTabsProvider(path).notifier);
      if (request.disposition == OpenFileDisposition.side) {
        tabs.openFileInSidePane(request.location);
      } else {
        tabs.openFile(request.location);
      }
      notifier.showAgent();
    }

    return AnimatedBuilder(
      animation: _position,
      builder: (context, _) {
        final frame = getMobilePanelFrame(
          _position.value,
          MediaQuery.sizeOf(context).width,
        );
        final overlayOpacity =
            frame.leftBackdropOpacity + frame.rightBackdropOpacity;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('mobile-agent-surface'),
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _beginDrag,
              onHorizontalDragUpdate: _updateDrag,
              onHorizontalDragEnd: _finishDrag,
              onHorizontalDragCancel: _cancelDrag,
              child: widget.content,
            ),
            if (selection.target == MobilePanelView.agent &&
                _position.value.abs() <= 0.002)
              Positioned(
                top: 8,
                left: 8,
                child: Tooltip(
                  message: 'Open menu',
                  child: IconButton(
                    key: const ValueKey('menu-button'),
                    icon: const Icon(FluentIcons.global_nav_button, size: 16),
                    onPressed: notifier.showAgentList,
                  ),
                ),
              ),
            if (_leftPresented || _rightPresented)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: selection.target == MobilePanelView.agent,
                  child: GestureDetector(
                    key: ValueKey(
                      selection.target == MobilePanelView.fileExplorer
                          ? 'file-explorer-backdrop'
                          : 'agent-list-backdrop',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: notifier.showAgent,
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: 0.5 * overlayOpacity.clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                ),
              ),
            if (_leftPresented)
              Positioned.fill(
                key: const ValueKey('mobile-left-sidebar'),
                child: IgnorePointer(
                  ignoring: selection.target != MobilePanelView.agentList,
                  child: Transform.translate(
                    offset: Offset(frame.leftTranslateX, 0),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: _beginDrag,
                      onHorizontalDragUpdate: _updateDrag,
                      onHorizontalDragEnd: _finishDrag,
                      onHorizontalDragCancel: _cancelDrag,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.paseoPalette.surfaceSidebar,
                        ),
                        child: _Sidebar(
                          compact: true,
                          onClose: notifier.showAgent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_rightPresented && _activeExplorerModel != null)
              Positioned.fill(
                key: const ValueKey('mobile-file-explorer'),
                child: IgnorePointer(
                  ignoring: selection.target != MobilePanelView.fileExplorer,
                  child: Transform.translate(
                    offset: Offset(frame.rightTranslateX, 0),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: _beginDrag,
                      onHorizontalDragUpdate: _updateDrag,
                      onHorizontalDragEnd: _finishDrag,
                      onHorizontalDragCancel: _cancelDrag,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.paseoPalette.surfaceSidebar,
                        ),
                        child: WorkspaceExplorer(
                          serverId: _activeExplorerModel!.serverId,
                          workspaceId: _activeExplorerModel!.workspaceId,
                          cwd: _activeExplorerModel!.workspaceRoot,
                          isGit: _activeExplorerModel!.isGit,
                          onClose: notifier.showAgent,
                          onOpenFile: openWorkspaceFile,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ResizableHomeLayout extends ConsumerStatefulWidget {
  const _ResizableHomeLayout({required this.content});

  final Widget content;

  @override
  ConsumerState<_ResizableHomeLayout> createState() =>
      _ResizableHomeLayoutState();
}

class _ResizableHomeLayoutState extends ConsumerState<_ResizableHomeLayout> {
  double? _dragWidth;
  double _dragStartWidth = defaultSidebarWidth;
  double _dragStartGlobalX = 0;

  @override
  Widget build(BuildContext context) {
    final requestedWidth = ref.watch(sidebarWidthProvider);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final persistedVisibleWidth = resolveDesktopSidebarWidth(
      requestedWidth: requestedWidth,
      viewportWidth: viewportWidth,
    );
    final visibleWidth = resolveDesktopSidebarWidth(
      requestedWidth: _dragWidth ?? persistedVisibleWidth,
      viewportWidth: viewportWidth,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          children: [
            SizedBox(width: visibleWidth),
            Expanded(child: widget.content),
          ],
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: visibleWidth + 5,
          child: Stack(
            children: [
              Positioned(
                key: const ValueKey('left-sidebar'),
                top: 0,
                bottom: 0,
                left: 0,
                width: visibleWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: context.paseoPalette.border),
                    ),
                  ),
                  child: const _Sidebar(),
                ),
              ),
              SidebarResizeHandle(
                edge: SidebarResizeEdge.right,
                testId: 'left-sidebar-resize-handle',
                onDragStart: (details) {
                  _dragStartWidth = visibleWidth;
                  _dragStartGlobalX = details.globalPosition.dx;
                  setState(() => _dragWidth = visibleWidth);
                },
                onDragUpdate: (details) {
                  final translated =
                      _dragStartWidth +
                      details.globalPosition.dx -
                      _dragStartGlobalX;
                  setState(
                    () => _dragWidth = resolveDesktopSidebarWidth(
                      requestedWidth: translated,
                      viewportWidth: viewportWidth,
                    ),
                  );
                },
                onDragEnd: (_) {
                  final committed = _dragWidth ?? visibleWidth;
                  ref.read(sidebarWidthProvider.notifier).setWidth(committed);
                  setState(() => _dragWidth = null);
                },
                onDragCancel: () => setState(() => _dragWidth = null),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _WorkspaceInventory {
  const _WorkspaceInventory({
    required this.hydrated,
    required this.worktreePaths,
  });

  final bool hydrated;
  final Set<String> worktreePaths;
}

final _workspaceInventoryProvider = Provider<_WorkspaceInventory>((ref) {
  final worktreePaths = <String>{
    for (final agent in ref.watch(agentsProvider).values)
      resolveWorktreeKey(agent),
  };
  final projects = ref.watch(projectsProvider);
  var hydrated = projects is AsyncData<List<ProjectInfo>>;
  for (final project in projects.value ?? const <ProjectInfo>[]) {
    if (!project.isGitRepo) {
      worktreePaths.add(project.path);
      continue;
    }
    final worktrees = ref.watch(worktreesProvider(project.path));
    hydrated = hydrated && worktrees is AsyncData<List<WorktreeInfo>>;
    worktreePaths.addAll(
      (worktrees.value ?? const <WorktreeInfo>[]).map(
        (worktree) => worktree.path,
      ),
    );
  }
  return _WorkspaceInventory(hydrated: hydrated, worktreePaths: worktreePaths);
});

final workspaceDeckControllerProvider =
    Provider<WorkspaceDeckRetentionController>(
      (ref) => WorkspaceDeckRetentionController(),
    );

class _HomeContentDeck extends ConsumerWidget {
  const _HomeContentDeck({
    required this.routeChild,
    required this.routeLocation,
  });

  final Widget routeChild;
  final String? routeLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWorkspaceRoute =
        (routeLocation ?? GoRouterState.of(context).matchedLocation) == '/';
    final selected = ref.watch(selectedWorktreeProvider);
    if (!isWorkspaceRoute || selected == null) {
      return routeChild;
    }
    return WorkspaceDeckPane(worktreePath: selected);
  }
}

/// Retained workspace root shared by the legacy `/` selection surface and the
/// canonical `/h/:serverId/workspace/:workspaceId` route.
class WorkspaceDeckPane extends ConsumerWidget {
  const WorkspaceDeckPane({super.key, required this.worktreePath});

  final String worktreePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(daemonClientProvider);
    final agentContext = ref.watch(worktreeAgentContextProvider(worktreePath));
    final controller = ref.watch(workspaceDeckControllerProvider);
    final activeSelection = controller.selectionFor(
      serverId: client.serverInfo?.serverId ?? client.uri.toString(),
      workspaceId: agentContext.workspaceId ?? worktreePath,
      worktreePath: worktreePath,
    );
    final inventory = ref.watch(_workspaceInventoryProvider);
    final nextSelections = controller.reconcile(
      activeSelection: activeSelection,
      hasHydratedWorkspaces: inventory.hydrated,
      existingWorktreePaths: inventory.worktreePaths,
    );
    final renderedSelections = orderWorkspaceSelectionsForStableRender(
      nextSelections,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        for (final selection in renderedSelections)
          _WorkspaceDeckEntry(
            key: ValueKey('workspace-deck-entry-${selection.key}'),
            selection: selection,
            active: selection == activeSelection,
          ),
      ],
    );
  }
}

class _WorkspaceDeckEntry extends ConsumerWidget {
  const _WorkspaceDeckEntry({
    super.key,
    required this.selection,
    required this.active,
  });

  final WorkspaceDeckSelection selection;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentContext = ref.watch(
      worktreeAgentContextProvider(selection.worktreePath),
    );
    return Offstage(
      offstage: !active,
      child: TickerMode(
        enabled: active,
        child: IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: WorktreeTabbedPane(
              worktreePath: selection.worktreePath,
              projectPath: agentContext.projectPath,
              branch: agentContext.branch,
              isWorktree: agentContext.isWorktree,
              workspaceId: agentContext.workspaceId,
            ),
          ),
        ),
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
      workspaceId: agentContext.workspaceId,
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
    this.active = false,
    this.testId,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final String? testId;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        key: testId == null ? null : ValueKey(testId!),
        onPressed: onTap,
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: hovering || active
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _SidebarGroupMode { project, status }

enum _SidebarWorkspaceTitleSource { title, branch }

class _WorkspacesSectionHeader extends StatefulWidget {
  const _WorkspacesSectionHeader({
    required this.onSearch,
    required this.groupMode,
    required this.titleSource,
    required this.onGroupModeChanged,
    required this.onTitleSourceChanged,
  });

  final VoidCallback onSearch;
  final _SidebarGroupMode groupMode;
  final _SidebarWorkspaceTitleSource titleSource;
  final ValueChanged<_SidebarGroupMode> onGroupModeChanged;
  final ValueChanged<_SidebarWorkspaceTitleSource> onTitleSourceChanged;

  @override
  State<_WorkspacesSectionHeader> createState() =>
      _WorkspacesSectionHeaderState();
}

class _WorkspacesSectionHeaderState extends State<_WorkspacesSectionHeader> {
  final _preferencesController = FlyoutController();

  @override
  void dispose() {
    _preferencesController.dispose();
    super.dispose();
  }

  Widget _selectedIcon(bool selected) => SizedBox.square(
    dimension: 16,
    child: selected
        ? const Icon(FluentIcons.check_mark, size: 12)
        : const SizedBox.shrink(),
  );

  Future<void> _showPreferences() async {
    if (!_preferencesController.isAttached || _preferencesController.isOpen) {
      return;
    }
    await _preferencesController.showFlyout<void>(
      placementMode: FlyoutPlacementMode.bottomRight,
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints.tightFor(width: 220),
        items: [
          MenuFlyoutItem(text: const Text('Group by'), onPressed: null),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-grouping-project'),
            leading: _selectedIcon(
              widget.groupMode == _SidebarGroupMode.project,
            ),
            text: const Text('Project'),
            onPressed: () =>
                widget.onGroupModeChanged(_SidebarGroupMode.project),
          ),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-grouping-status'),
            leading: _selectedIcon(
              widget.groupMode == _SidebarGroupMode.status,
            ),
            text: const Text('Status'),
            onPressed: () =>
                widget.onGroupModeChanged(_SidebarGroupMode.status),
          ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(text: const Text('Workspace title'), onPressed: null),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-workspace-title-source-title'),
            leading: _selectedIcon(
              widget.titleSource == _SidebarWorkspaceTitleSource.title,
            ),
            text: const Text('Title'),
            onPressed: () =>
                widget.onTitleSourceChanged(_SidebarWorkspaceTitleSource.title),
          ),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-workspace-title-source-branch'),
            leading: _selectedIcon(
              widget.titleSource == _SidebarWorkspaceTitleSource.branch,
            ),
            text: const Text('Branch name'),
            onPressed: () => widget.onTitleSourceChanged(
              _SidebarWorkspaceTitleSource.branch,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Workspaces',
              style: context.textStyles.bodySmall?.copyWith(
                color: context.paseoPalette.foregroundMuted,
              ),
            ),
          ),
          Tooltip(
            message: 'Search',
            child: IconButton(
              key: const ValueKey('sidebar-command-center-search'),
              icon: const Icon(FluentIcons.search, size: 14),
              onPressed: widget.onSearch,
            ),
          ),
          FlyoutTarget(
            controller: _preferencesController,
            child: Tooltip(
              message: 'Display preferences',
              child: IconButton(
                key: const ValueKey('sidebar-display-preferences-menu'),
                icon: const Icon(FluentIcons.settings, size: 14),
                onPressed: () => unawaited(_showPreferences()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A collapsible project section header: icon + name + project action + a
/// chevron that flips to indicate expanded/collapsed. The parent supplies the
/// frozen whole-row drag activator; the project-level kebab menu is tracked
/// separately.
class _ProjectHeaderRow extends StatelessWidget {
  const _ProjectHeaderRow({
    required this.name,
    required this.isGitRepo,
    required this.model,
    required this.onTap,
    required this.onNewWorkspace,
    required this.projectKey,
  });

  final String name;
  final bool isGitRepo;
  final SidebarProjectRowModel model;
  final VoidCallback onTap;
  final VoidCallback? onNewWorkspace;
  final String projectKey;

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
                  isGitRepo
                      ? FluentIcons.folder_horizontal
                      : FluentIcons.folder,
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
                if (model.trailingAction is SidebarProjectNewWorkspaceAction)
                  Tooltip(
                    message: 'New workspace in $name',
                    child: IconButton(
                      key: ValueKey('project-new-workspace-$projectKey'),
                      icon: const Icon(FluentIcons.add, size: 12),
                      onPressed: onNewWorkspace,
                    ),
                  ),
                Icon(
                  model.chevron == SidebarProjectChevron.expand
                      ? FluentIcons.chevron_right
                      : FluentIcons.chevron_down,
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
        style: context.textStyles.bodySmall?.copyWith(
          color: context.tokens.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar({this.compact = false, this.onClose});

  final bool compact;
  final VoidCallback? onClose;

  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  final _collapsedProjectPaths = <String>{};
  _SidebarGroupMode _groupMode = _SidebarGroupMode.project;
  _SidebarWorkspaceTitleSource _titleSource =
      _SidebarWorkspaceTitleSource.title;

  String _newWorkspaceRoute({
    required String? selected,
    required SidebarGroups groups,
    required String? serverId,
    required bool supportsMultiplicity,
  }) {
    if (serverId == null) return buildNewWorkspaceRoute();
    if (selected != null) {
      for (final section in groups.projectSections) {
        if (section.rows.any((row) => row.key == selected) &&
            (supportsMultiplicity || section.project.isGitRepo)) {
          final displayName = section.project.name.isEmpty
              ? section.project.path
              : section.project.name;
          return buildNewWorkspaceRoute(
            NewWorkspaceRouteOptions(
              serverId: serverId,
              sourceDirectory: section.project.path,
              displayName: displayName,
              projectId: section.project.path,
            ),
          );
        }
      }
    }
    return buildNewWorkspaceRoute(NewWorkspaceRouteOptions(serverId: serverId));
  }

  void _toggleProject(String projectPath) {
    setState(() {
      if (!_collapsedProjectPaths.remove(projectPath)) {
        _collapsedProjectPaths.add(projectPath);
      }
    });
  }

  void _reorderProjects(
    List<SidebarProjectSection> sections,
    int oldIndex,
    int newIndex,
  ) {
    final reordered = reorderAt(sections, oldIndex, newIndex);
    final visibleKeys = reordered
        .map((section) => section.orderKey)
        .toList(growable: false);
    final current = ref.read(sidebarOrderProvider).projectOrder;
    if (!hasVisibleOrderChanged(
      currentOrder: current,
      reorderedVisibleKeys: visibleKeys,
    )) {
      return;
    }
    unawaited(
      ref
          .read(sidebarOrderProvider.notifier)
          .setProjectOrder(
            mergeWithRemainder(
              currentOrder: current,
              reorderedVisibleKeys: visibleKeys,
            ),
          ),
    );
  }

  void _reorderWorkspaces(
    SidebarProjectSection section,
    int oldIndex,
    int newIndex,
  ) {
    final reordered = reorderAt(section.rows, oldIndex, newIndex);
    final visibleKeys = reordered
        .map((row) => row.orderKey)
        .toList(growable: false);
    final current = ref
        .read(sidebarOrderProvider)
        .workspaceOrder(section.orderKey);
    if (!hasVisibleOrderChanged(
      currentOrder: current,
      reorderedVisibleKeys: visibleKeys,
    )) {
      return;
    }
    unawaited(
      ref
          .read(sidebarOrderProvider.notifier)
          .setWorkspaceOrder(
            section.orderKey,
            mergeWithRemainder(
              currentOrder: current,
              reorderedVisibleKeys: visibleKeys,
            ),
          ),
    );
  }

  Widget _dragListener({
    required Key key,
    required int index,
    required Widget child,
  }) {
    return SidebarReorderDragStartListener(
      key: key,
      index: index,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedWorktreeProvider);
    final groups = ref.watch(sidebarGroupsProvider);
    final projects = ref.watch(projectsProvider);
    final client = ref.watch(daemonClientProvider);
    final serverId =
        ref.watch(activeHostProvider)?.serverId ?? client.serverInfo?.serverId;
    final supportsMultiplicity =
        client.serverInfo?.features['workspaceMultiplicity'] == true;
    final isInitialLoad =
        projects.isLoading &&
        (projects.value?.isEmpty ?? true) &&
        groups.isEmpty;
    final location = GoRouterState.of(context).matchedLocation;
    final statusRows = <SidebarWorktreeRow>[
      for (final section in groups.projectSections) ...section.rows,
      ...groups.other,
    ];
    final statusRowsByBucket =
        <WorkspaceStateBucket, List<SidebarWorktreeRow>>{};
    for (final row in statusRows) {
      final bucket =
          _aggregateStateBucket(row.agents) ?? WorkspaceStateBucket.done;
      statusRowsByBucket.putIfAbsent(bucket, () => []).add(row);
    }
    const statusOrder = [
      WorkspaceStateBucket.needsInput,
      WorkspaceStateBucket.failed,
      WorkspaceStateBucket.attention,
      WorkspaceStateBucket.running,
      WorkspaceStateBucket.done,
    ];
    const statusLabels = {
      WorkspaceStateBucket.needsInput: 'Needs input',
      WorkspaceStateBucket.failed: 'Failed',
      WorkspaceStateBucket.attention: 'Ready to review',
      WorkspaceStateBucket.running: 'Working',
      WorkspaceStateBucket.done: 'Done',
    };

    void selectRow(SidebarWorktreeRow row) {
      widget.onClose?.call();
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

    void pushRoute(String route) {
      widget.onClose?.call();
      context.push(route);
    }

    final sidebar = Column(
      children: [
        const SizedBox(height: 4),
        _SidebarHeaderRow(
          icon: FluentIcons.add,
          label: 'New workspace',
          testId: 'sidebar-global-new-workspace',
          onTap: () => pushRoute(
            _newWorkspaceRoute(
              selected: selected,
              groups: groups,
              serverId: serverId,
              supportsMultiplicity: supportsMultiplicity,
            ),
          ),
        ),
        _SidebarHeaderRow(
          icon: FluentIcons.history,
          label: 'Sessions',
          testId: 'sidebar-sessions',
          active: location == buildSessionsRoute(),
          onTap: () => pushRoute(buildSessionsRoute()),
        ),
        _SidebarHeaderRow(
          icon: FluentIcons.calendar_week,
          label: 'Schedules',
          testId: 'sidebar-schedules',
          active: location == buildSchedulesRoute(),
          onTap: () => pushRoute(buildSchedulesRoute()),
        ),
        const Divider(),
        _WorkspacesSectionHeader(
          onSearch: () => ref
              .read(commandCenterOverlayRequestProvider.notifier)
              .openCommandCenter(),
          groupMode: _groupMode,
          titleSource: _titleSource,
          onGroupModeChanged: (mode) => setState(() => _groupMode = mode),
          onTitleSourceChanged: (source) =>
              setState(() => _titleSource = source),
        ),
        Expanded(
          child: isInitialLoad
              ? const SidebarAgentListSkeleton()
              : groups.isEmpty
              ? Center(
                  child: Text(
                    'No agents yet',
                    style: TextStyle(color: context.tokens.outline),
                  ),
                )
              : _groupMode == _SidebarGroupMode.status
              ? ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (groups.pinned.isNotEmpty) ...[
                      const _SectionLabel('Pinned'),
                      for (final row in groups.pinned)
                        _SidebarWorktreeRow(
                          row: row,
                          selected: row.key == selected,
                          titleSource: _titleSource,
                          onTap: () => selectRow(row),
                        ),
                    ],
                    for (final bucket in statusOrder)
                      if (statusRowsByBucket[bucket] case final rows?
                          when rows.isNotEmpty) ...[
                        _SectionLabel(statusLabels[bucket]!),
                        for (final row in rows)
                          _SidebarWorktreeRow(
                            row: row,
                            selected: row.key == selected,
                            titleSource: _titleSource,
                            onTap: () => selectRow(row),
                          ),
                      ],
                  ],
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: EdgeInsets.zero,
                  header: groups.pinned.isEmpty
                      ? null
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _SectionLabel('Pinned'),
                            for (final row in groups.pinned)
                              _SidebarWorktreeRow(
                                row: row,
                                selected: row.key == selected,
                                titleSource: _titleSource,
                                onTap: () => selectRow(row),
                              ),
                          ],
                        ),
                  footer: groups.other.isEmpty
                      ? null
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final row in groups.other)
                              _SidebarWorktreeRow(
                                row: row,
                                selected: row.key == selected,
                                titleSource: _titleSource,
                                onTap: () => selectRow(row),
                              ),
                          ],
                        ),
                  itemCount: groups.projectSections.length,
                  onReorderItem: (oldIndex, newIndex) => _reorderProjects(
                    groups.projectSections,
                    oldIndex,
                    newIndex > oldIndex ? newIndex + 1 : newIndex,
                  ),
                  itemBuilder: (context, projectIndex) {
                    final section = groups.projectSections[projectIndex];
                    final project = section.project;
                    final collapsed = _collapsedProjectPaths.contains(
                      project.path,
                    );
                    final entry = SidebarProjectEntry(
                      projectKey: project.path,
                      projectName: project.name,
                      hosts: [
                        if (serverId != null)
                          SidebarProjectHost(
                            serverId: serverId,
                            iconWorkingDir: project.path,
                            canCreateWorktree: project.isGitRepo,
                          ),
                      ],
                    );
                    final model = buildSidebarProjectRowModel(
                      project: entry,
                      collapsed: collapsed,
                      supportsMultiplicityByServerId: {
                        ?serverId: supportsMultiplicity,
                      },
                    );
                    final action = model.trailingAction;
                    final displayName = project.name.isEmpty
                        ? project.path
                        : project.name;
                    return Column(
                      key: ValueKey(
                        'sidebar-project-section-${section.orderKey}',
                      ),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _dragListener(
                          key: ValueKey(
                            'sidebar-project-drag-${section.orderKey}',
                          ),
                          index: projectIndex,
                          child: _ProjectHeaderRow(
                            name: displayName,
                            isGitRepo: project.isGitRepo,
                            model: model,
                            projectKey: project.path,
                            onTap: () => _toggleProject(project.path),
                            onNewWorkspace:
                                action is SidebarProjectNewWorkspaceAction
                                ? () => pushRoute(
                                    buildNewWorkspaceRoute(
                                      NewWorkspaceRouteOptions(
                                        serverId: action.target.serverId,
                                        sourceDirectory:
                                            action.target.iconWorkingDir,
                                        displayName: displayName,
                                        projectId: project.path,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        if (!collapsed)
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            primary: false,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            padding: EdgeInsets.zero,
                            itemCount: section.rows.length,
                            onReorderItem: (oldIndex, newIndex) =>
                                _reorderWorkspaces(
                                  section,
                                  oldIndex,
                                  newIndex > oldIndex ? newIndex + 1 : newIndex,
                                ),
                            itemBuilder: (context, workspaceIndex) {
                              final row = section.rows[workspaceIndex];
                              return _dragListener(
                                key: ValueKey(
                                  'sidebar-workspace-drag-${row.orderKey}',
                                ),
                                index: workspaceIndex,
                                child: _SidebarWorktreeRow(
                                  row: row,
                                  selected: row.key == selected,
                                  titleSource: _titleSource,
                                  onTap: () => selectRow(row),
                                ),
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
        ),
        const SidebarCalloutSlot(),
        _SidebarFooter(onBeforeNavigate: widget.onClose),
      ],
    );
    if (!widget.compact) return sidebar;
    return Stack(
      fit: StackFit.expand,
      children: [
        sidebar,
        Positioned(
          top: 8,
          right: 8,
          child: Tooltip(
            message: 'Close sidebar',
            child: IconButton(
              key: const ValueKey('sidebar-close'),
              icon: const Icon(FluentIcons.chrome_close, size: 14),
              onPressed: widget.onClose,
            ),
          ),
        ),
      ],
    );
  }
}

/// The most urgent state bucket among a worktree row's agents (or `null` when
/// it has none), used to roll up the leading status dot for the whole row.
WorkspaceStateBucket? _aggregateStateBucket(List<AgentSummary> agents) {
  WorkspaceStateBucket? worst;
  for (final agent in agents) {
    final bucket = deriveAgentStateBucket(
      status: agent.runState,
      requiresAttention: agent.requiresAttention,
      attentionReason: agent.attentionReason,
    );
    if (worst == null ||
        getWorkspaceStateBucketPriority(bucket) <
            getWorkspaceStateBucketPriority(worst)) {
      worst = bucket;
    }
  }
  return worst;
}

/// One sidebar row per worktree/session-group (Paseo parity: exactly one
/// row regardless of how many agent sessions share it). Always
/// tappable/selectable — even with zero agents, selecting it opens
/// [WorktreeTabbedPane], which seeds a draft composer tab.
class _SidebarWorktreeRow extends ConsumerStatefulWidget {
  const _SidebarWorktreeRow({
    required this.row,
    required this.selected,
    required this.titleSource,
    required this.onTap,
  });

  final SidebarWorktreeRow row;
  final bool selected;
  final _SidebarWorkspaceTitleSource titleSource;
  final VoidCallback onTap;

  @override
  ConsumerState<_SidebarWorktreeRow> createState() =>
      _SidebarWorktreeRowState();
}

class _SidebarWorktreeRowState extends ConsumerState<_SidebarWorktreeRow> {
  final _menuController = FlyoutController();
  final _menuButtonKey = GlobalKey();

  String get _fallbackName {
    if (widget.titleSource == _SidebarWorkspaceTitleSource.branch) {
      final branch =
          widget.row.worktree?.branch ?? widget.row.agents.firstOrNull?.branch;
      if (branch != null && branch.isNotEmpty) return branch;
    }
    // A single session's own title is more informative than the branch name
    // (preserves the pre-unification per-agent row's look); branch/path is
    // only a fallback for empty or multi-session rows.
    if (widget.row.agents.length == 1) {
      final agent = widget.row.agents.single;
      return agent.title.isEmpty ? agent.agentId : agent.title;
    }
    final worktree = widget.row.worktree;
    if (worktree != null) {
      return worktree.branch.isEmpty ? '(detached)' : worktree.branch;
    }
    return widget.row.key;
  }

  Future<void> _rename() async {
    final current = ref.read(worktreeTitlesProvider)[widget.row.key] ?? '';
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
    await ref
        .read(worktreeTitlesProvider.notifier)
        .setTitle(widget.row.key, title);
  }

  List<MenuFlyoutItemBase> _menuItems({
    required bool pinned,
    required String? branch,
    required bool canArchiveWorktree,
  }) {
    final row = widget.row;
    final worktree = row.worktree;
    return [
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
        onPressed: _rename,
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
          onPressed: () => archiveAgentWithWorktreeConfirm(context, ref, agent),
        ),
      if (canArchiveWorktree && worktree != null)
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
    ];
  }

  Future<void> _showMenu(Offset? position) async {
    if (!_menuController.isAttached || _menuController.isOpen) return;
    await _menuController.showFlyout<void>(
      position: position,
      placementMode: FlyoutPlacementMode.bottomRight,
      additionalOffset: position == null ? 2 : 0,
      builder: (context) {
        final row = widget.row;
        final pinned = ref.read(sidebarPinsProvider).contains(row.key);
        final worktree = row.worktree;
        final branch =
            worktree?.branch ??
            (row.agents.length == 1 ? row.agents.single.branch : null);
        final canArchiveWorktree =
            worktree != null && !worktree.isMain && row.agents.isEmpty;
        return MenuFlyout(
          constraints: const BoxConstraints.tightFor(width: 200),
          items: _menuItems(
            pinned: pinned,
            branch: branch,
            canArchiveWorktree: canArchiveWorktree,
          ),
        );
      },
    );
  }

  void _showMenuFromButton() {
    final box = _menuButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final position = box?.localToGlobal(
      Offset(box.size.width, box.size.height),
    );
    unawaited(_showMenu(position));
  }

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final override = ref.watch(worktreeTitlesProvider)[row.key];
    final title = override ?? _fallbackName;
    final subtitle = switch (row.agents.length) {
      0 => row.key,
      1 => '${row.agents.single.provider} · ${row.agents.single.model}',
      final n => '$n sessions',
    };
    final activity = latestWorkspaceActivityForAgents(
      row.agents,
      ref.watch(workspaceAgentActivityIndexProvider),
    );
    final hasWorkspaceIdentity = row.agents.any(
      (agent) => agent.workspaceId?.trim().isNotEmpty == true,
    );
    final stateBucket =
        activity?.status ??
        (hasWorkspaceIdentity ? null : _aggregateStateBucket(row.agents));
    final worktree = row.worktree;

    return FlyoutTarget(
      controller: _menuController,
      child: SidebarContextMenuRegion(
        onOpen: (position) => unawaited(_showMenu(position)),
        child: ListTile.selectable(
          selected: widget.selected,
          leading: stateBucket == null
              ? Icon(
                  worktree == null || worktree.isMain
                      ? FluentIcons.home
                      : FluentIcons.branch_fork2,
                  size: 16,
                )
              : _RunStateIndicator(stateBucket: stateBucket),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            key: _menuButtonKey,
            icon: const Icon(FluentIcons.more_vertical, size: 14),
            onPressed: _showMenuFromButton,
          ),
          onPressed: widget.onTap,
        ),
      ),
    );
  }
}

class _RunStateIndicator extends StatelessWidget {
  const _RunStateIndicator({required this.stateBucket});

  final WorkspaceStateBucket stateBucket;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: switch (stateBucket) {
          WorkspaceStateBucket.running => SizedBox(
            width: 14,
            height: 14,
            child: ProgressRing(strokeWidth: 2, activeColor: Colors.yellow),
          ),
          WorkspaceStateBucket.needsInput => Icon(
            FluentIcons.ringer,
            size: 16,
            color: Colors.red,
          ),
          WorkspaceStateBucket.failed => Icon(
            FluentIcons.circle_fill,
            size: 10,
            color: Colors.red,
          ),
          WorkspaceStateBucket.attention => Icon(
            FluentIcons.ringer,
            size: 16,
            color: Colors.yellow,
          ),
          WorkspaceStateBucket.done => Icon(
            FluentIcons.circle_fill,
            size: 10,
            color: Colors.grey[100],
          ),
        },
      ),
    );
  }
}

class _SidebarFooter extends ConsumerStatefulWidget {
  const _SidebarFooter({this.onBeforeNavigate});

  final VoidCallback? onBeforeNavigate;

  @override
  ConsumerState<_SidebarFooter> createState() => _SidebarFooterState();
}

class _SidebarFooterState extends ConsumerState<_SidebarFooter> {
  final _helpController = FlyoutController();

  @override
  void dispose() {
    _helpController.dispose();
    super.dispose();
  }

  Future<void> _showHelp() async {
    if (!_helpController.isAttached || _helpController.isOpen) return;
    await _helpController.showFlyout<void>(
      placementMode: FlyoutPlacementMode.topRight,
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints.tightFor(width: 280),
        items: [
          MenuFlyoutItem(text: const Text('Help'), onPressed: null),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-help-shortcuts'),
            leading: const Icon(FluentIcons.keyboard_classic, size: 16),
            text: const Text('Keyboard shortcuts'),
            onPressed: () => ref
                .read(commandCenterOverlayRequestProvider.notifier)
                .openShortcuts(),
          ),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-help-diagnostics'),
            leading: const Icon(FluentIcons.diagnostic, size: 16),
            text: const Text('Diagnostics'),
            onPressed: () {
              widget.onBeforeNavigate?.call();
              context.push(
                buildSettingsSectionRoute(SettingsSectionSlug.diagnostics),
              );
            },
          ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(text: const Text('Report an issue'), onPressed: null),
          MenuFlyoutItem(
            key: const ValueKey('sidebar-help-version'),
            text: const Text('Tinyrack v0.1.0'),
            onPressed: null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    final activeHost = ref.watch(activeHostProvider);
    final hosts = <HostProfile>[
      ...registry.hosts,
      if (activeHost != null &&
          !registry.hosts.any(
            (candidate) => candidate.serverId == activeHost.serverId,
          ))
        activeHost,
    ];
    void openHostSettings(String serverId) {
      widget.onBeforeNavigate?.call();
      context.push(
        buildSettingsHostSectionRoute(serverId, HostSectionSlug.connections),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.paseoPalette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: HoverButton(
              key: const ValueKey('sidebar-add-project'),
              onPressed: () {
                widget.onBeforeNavigate?.call();
                unawaited(
                  ref
                      .read(addProjectFlowProvider.notifier)
                      .open(preferredHostId: activeHost?.serverId),
                );
              },
              builder: (context, states) => Container(
                constraints: const BoxConstraints(minHeight: 32),
                decoration: BoxDecoration(
                  color: states.contains(WidgetState.hovered)
                      ? context.paseoPalette.surfaceSidebarHover
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      FluentIcons.new_folder,
                      size: 16,
                      color: context.paseoPalette.foregroundMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Add project',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textStyles.bodyMedium?.copyWith(
                          color: context.paseoPalette.foregroundMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          HostPicker(
            hosts: hosts,
            value: '',
            onSelect: openHostSettings,
            includeAddHost: true,
            onAddHost: () {
              widget.onBeforeNavigate?.call();
              context.push(
                buildSettingsAddHostRoute(
                  DateTime.now().millisecondsSinceEpoch,
                ),
              );
            },
            showActiveConnection: true,
            onOpenHostSettings: openHostSettings,
            searchable: true,
            desktopPlacement: FlyoutPlacementMode.topLeft,
            desktopMinWidth: 240,
            hostOptionKey: (id) => ValueKey('sidebar-host-row-$id'),
            addHostKey: const ValueKey('sidebar-host-add'),
            triggerBuilder: (context, onOpen, open) => _FooterIconButton(
              key: const ValueKey('sidebar-hosts-trigger'),
              label: 'Hosts',
              icon: FluentIcons.server,
              onPressed: onOpen,
            ),
          ),
          const SizedBox(width: 8),
          _FooterIconButton(
            key: const ValueKey('sidebar-home'),
            label: 'Home',
            icon: FluentIcons.home,
            onPressed: () {
              widget.onBeforeNavigate?.call();
              context.push(buildOpenProjectRoute());
            },
          ),
          const SizedBox(width: 8),
          FlyoutTarget(
            controller: _helpController,
            child: _FooterIconButton(
              key: const ValueKey('sidebar-help'),
              label: 'Help',
              icon: FluentIcons.help,
              onPressed: () => unawaited(_showHelp()),
            ),
          ),
          const SizedBox(width: 8),
          _FooterIconButton(
            key: const ValueKey('sidebar-settings'),
            label: 'Settings',
            icon: FluentIcons.settings,
            onPressed: () {
              widget.onBeforeNavigate?.call();
              context.push(buildSettingsRoute());
            },
          ),
        ],
      ),
    );
  }
}

class _FooterIconButton extends StatelessWidget {
  const _FooterIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: SizedBox.square(
      dimension: 28,
      child: IconButton(icon: Icon(icon, size: 16), onPressed: onPressed),
    ),
  );
}
