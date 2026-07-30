import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../command_center/command_center.dart';
import '../composer/provider_model_selection.dart';
import '../core/host_routes.dart';
import '../keyboard/keyboard_action_dispatcher.dart';
import '../keyboard/keyboard_ime.dart';
import '../keyboard/shortcut_engine.dart';
import '../keyboard/shortcut_focus_scope.dart';
import '../keyboard/shortcut_flutter_adapter.dart';
import '../keyboard/shortcut_routing.dart';
import '../state/agents_provider.dart';
import '../state/add_project_flow_provider.dart';
import '../state/appearance_provider.dart';
import '../state/app_sidebar_visibility_provider.dart';
import '../state/command_center_provider.dart';
import '../state/daemon_providers.dart';
import '../state/keyboard_shortcut_overrides_provider.dart';
import '../state/sidebar_grouping_provider.dart';
import '../state/sidebar_pins_provider.dart';
import '../state/worktree_tabs_provider.dart';
import '../state/worktree_titles_provider.dart';
import 'command_center_dialog.dart';
import 'keyboard_shortcuts_dialog.dart';
import 'workspace_explorer.dart';

class AppCommandCenterHost extends ConsumerStatefulWidget {
  const AppCommandCenterHost({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<AppCommandCenterHost> createState() =>
      _AppCommandCenterHostState();
}

class _AppCommandCenterHostState extends ConsumerState<AppCommandCenterHost> {
  var _commandCenterOpen = false;
  var _shortcutsOpen = false;
  var _chordState = ShortcutChordState.empty;
  late final void Function() _disposeKeyboardHandler;
  late final CommandCenterRegistryNotifier _commandCenterRegistry;
  late final CommandCenterRegistrationOwner _rootContributionOwner;
  CommandCenterRegistrationOwner? _activeModelOwner;
  var _rootContributionsScheduled = false;
  String? _activeModelSignature;

  bool get _isMac =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isMobile =>
      ref.read(appCompactLayoutProvider) ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _commandCenterRegistry = ref.read(commandCenterRegistryProvider.notifier);
    _rootContributionOwner = CommandCenterRegistrationOwner(
      sourceId: 'root',
      token: Object(),
    );
    _disposeKeyboardHandler = keyboardActionDispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'app-command-center-host',
        actions: const {
          'agent.interrupt',
          'workspace.tab.new',
          'workspace.new',
          'workspace.pin',
          'workspace.terminal.new',
          'workspace.tab.navigate-index',
          'workspace.tab.navigate-relative',
          'sidebar.toggle.right',
        },
        enabled: true,
        priority: 0,
        isActive: () => mounted,
        handle: _handleDispatchedAction,
      ),
    );
  }

  KeyboardFocusScope _focusScope() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyboardFocusScope.other;
    final marked = ShortcutFocusScope.maybeOf(context);
    if (marked != null) return marked;
    final editable =
        context.widget is EditableText ||
        context.widget is TextBox ||
        context.findAncestorWidgetOfExactType<EditableText>() != null ||
        context.findAncestorWidgetOfExactType<TextBox>() != null;
    return editable ? KeyboardFocusScope.editable : KeyboardFocusScope.other;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editable = focusContext?.findAncestorStateOfType<EditableTextState>();
    if (editable != null &&
        isImeComposingTextEditingValue(editable.currentTextEditingValue)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_commandCenterOpen || _shortcutsOpen)) {
      setState(() {
        _commandCenterOpen = false;
        _shortcutsOpen = false;
      });
      return KeyEventResult.handled;
    }
    final input = shortcutInputFromKeyEvent(event);
    if (input == null) return KeyEventResult.ignored;
    final resolution = resolveKeyboardShortcut(
      event: input,
      context: KeyboardShortcutContext(
        isMac: _isMac,
        isDesktop: !kIsWeb,
        focusScope: _focusScope(),
        commandCenterOpen: _commandCenterOpen,
      ),
      chordState: _chordState,
      onChordReset: () => _chordState = ShortcutChordState.empty,
      bindings: ref.read(effectiveKeyboardShortcutBindingsProvider),
    );
    _chordState = resolution.nextChordState;
    final match = resolution.match;
    if (match == null) {
      return resolution.preventDefault
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final handled = _routeShortcut(match);
    return handled && match.stopPropagation
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    final activeModelOwner = _activeModelOwner;
    Future<void>.microtask(() {
      _commandCenterRegistry.remove(_rootContributionOwner);
      if (activeModelOwner != null) {
        _commandCenterRegistry.remove(activeModelOwner);
      }
    });
    _disposeKeyboardHandler();
    _chordState.timeout?.cancel();
    super.dispose();
  }

  bool _routeShortcut(KeyboardShortcutMatch match) {
    final groups = ref.read(sidebarGroupsProvider);
    final seen = <String>{};
    final rows = [
      ...groups.pinned,
      for (final section in groups.projectSections) ...section.rows,
      ...groups.other,
    ].where((row) => seen.add(row.key)).take(9).toList();
    final serverId =
        ref.read(daemonClientProvider).serverInfo?.serverId ?? 'local';
    final selected = ref.read(selectedWorktreeProvider);
    final action = routeKeyboardShortcut(
      match,
      ShortcutRoutingContext(
        pathname: widget.router.routeInformationProvider.value.uri.path,
        isMobile: _isMobile,
        sidebarShortcutTargets: [
          for (final row in rows)
            ShortcutWorkspaceTarget(serverId: serverId, workspaceId: row.key),
        ],
        navigationActiveWorkspace: selected == null
            ? null
            : ShortcutWorkspaceTarget(
                serverId: serverId,
                workspaceId: selected,
              ),
        commandCenterOpen: _commandCenterOpen,
        shortcutsDialogOpen: _shortcutsOpen,
      ),
    );
    return _executeRoutedAction(action);
  }

  bool _executeRoutedAction(RoutedShortcutAction action) {
    switch (action) {
      case NoRoutedShortcutAction():
        return false;
      case DispatchRoutedShortcutAction():
        return keyboardActionDispatcher.dispatch(action.action);
      case NavigateWorkspaceRoutedShortcutAction():
        ref
            .read(selectedWorktreeProvider.notifier)
            .select(action.target.workspaceId);
        widget.router.go('/');
        return true;
      case NavigateLastWorkspaceRoutedShortcutAction():
        widget.router.go('/');
        return true;
      case RouterReplaceRoutedShortcutAction():
        widget.router.replace(action.route);
        return true;
      case RouterBackRoutedShortcutAction():
        if (widget.router.canPop()) {
          widget.router.pop();
        } else {
          widget.router.go('/');
        }
        return true;
      case RouterPushRoutedShortcutAction():
        widget.router.push(action.route);
        return true;
      case OpenProjectPickerRoutedShortcutAction():
        unawaited(ref.read(addProjectFlowProvider.notifier).open());
        return true;
      case CallbackRoutedShortcutAction():
        return _runShortcutCallback(action.name);
      case CommandCenterRoutedShortcutAction():
        setState(() {
          _commandCenterOpen = action.nextOpen;
          if (_commandCenterOpen) _shortcutsOpen = false;
        });
        return true;
      case ShortcutsDialogRoutedShortcutAction():
        setState(() {
          _shortcutsOpen = action.nextOpen;
          if (_shortcutsOpen) _commandCenterOpen = false;
        });
        return true;
    }
  }

  bool _runShortcutCallback(ShortcutCallbackName name) {
    switch (name) {
      case ShortcutCallbackName.toggleAgentList:
        if (ref.read(appCompactLayoutProvider)) {
          ref.read(mobileSidebarVisibilityProvider.notifier).toggle();
        } else {
          ref.read(appSidebarVisibilityProvider.notifier).toggle();
        }
        return true;
      case ShortcutCallbackName.toggleBothSidebars:
        if (ref.read(appCompactLayoutProvider)) {
          ref.read(mobileSidebarVisibilityProvider.notifier).toggle();
          return true;
        }
        final leftVisible = ref.read(appSidebarVisibilityProvider);
        final path = ref.read(selectedWorktreeProvider);
        final rightVisible =
            path != null && ref.read(workspaceExplorerVisibilityProvider(path));
        if (leftVisible || rightVisible) {
          ref.read(appSidebarVisibilityProvider.notifier).hide();
          if (path != null) {
            ref.read(workspaceExplorerVisibilityProvider(path).notifier).hide();
          }
        } else {
          ref.read(appSidebarVisibilityProvider.notifier).show();
          if (path != null) {
            ref.read(workspaceExplorerVisibilityProvider(path).notifier).show();
          }
        }
        return true;
      case ShortcutCallbackName.cycleTheme:
        ref.read(appearanceProvider.notifier).cycle();
        return true;
    }
  }

  bool _handleDispatchedAction(KeyboardActionDefinition action) {
    final path = ref.read(selectedWorktreeProvider);
    switch (action.id) {
      case 'workspace.new':
        widget.router.push(buildNewWorkspaceRoute());
        return true;
      case 'workspace.pin':
        if (path == null) return false;
        unawaited(ref.read(sidebarPinsProvider.notifier).togglePin(path));
        return true;
      case 'workspace.tab.new':
        if (path == null) return false;
        ref
            .read(worktreeTabsProvider(path).notifier)
            .addTab(WorktreeTabKind.draft);
        return true;
      case 'workspace.terminal.new':
        if (path == null) return false;
        ref
            .read(worktreeTabsProvider(path).notifier)
            .addTab(WorktreeTabKind.terminal);
        return true;
      case 'workspace.tab.navigate-index':
        if (path == null || action.index == null) return false;
        final tabs = ref.read(worktreeTabsProvider(path)).layout.tabs;
        final index = action.index! - 1;
        if (index < 0 || index >= tabs.length) return true;
        ref
            .read(worktreeTabsProvider(path).notifier)
            .setActiveTab(tabs[index].tabId);
        return true;
      case 'workspace.tab.navigate-relative':
        if (path == null || action.delta == null) return false;
        final layout = ref.read(worktreeTabsProvider(path)).layout;
        if (layout.tabs.isEmpty) return true;
        final current = layout.tabs.indexWhere(
          (tab) => tab.tabId == layout.activeTabId,
        );
        final from = current < 0 ? 0 : current;
        final index =
            (from + action.delta! + layout.tabs.length) % layout.tabs.length;
        ref
            .read(worktreeTabsProvider(path).notifier)
            .setActiveTab(layout.tabs[index].tabId);
        return true;
      case 'sidebar.toggle.right':
        if (path == null) return false;
        final provider = workspaceExplorerVisibilityProvider(path);
        final notifier = ref.read(provider.notifier);
        if (ref.read(provider)) {
          notifier.hide();
        } else {
          notifier.show();
        }
        return true;
      case 'agent.interrupt':
        if (path == null) return false;
        final layout = ref.read(worktreeTabsProvider(path)).layout;
        final active = layout.tabs
            .where((tab) => tab.tabId == layout.activeTabId)
            .firstOrNull;
        if (active?.agentId case final agentId?) {
          unawaited(
            ref
                .read(agentActionsProvider)
                .interrupt(agentId)
                .catchError((_) {}),
          );
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  List<CommandCenterResultSection> _buildSections(String query) {
    final normalized = query.trim().toLowerCase();
    bool matches(String value) =>
        normalized.isEmpty || value.toLowerCase().contains(normalized);

    final titles = ref.read(worktreeTitlesProvider);
    final groups = ref.read(sidebarGroupsProvider);
    final rows = [
      ...groups.pinned,
      for (final section in groups.projectSections) ...section.rows,
      ...groups.other,
    ];
    final seenWorktrees = <String>{};
    final workspaces = <CommandCenterResult>[];
    for (final row in rows) {
      if (!seenWorktrees.add(row.key)) continue;
      final title =
          titles[row.key] ??
          row.worktree?.branch ??
          row.key.replaceAll(r'\', '/').split('/').last;
      final subtitle = row.worktree?.branch ?? row.key;
      final searchText = '$title $subtitle'.toLowerCase();
      if (!matches(searchText)) continue;
      workspaces.add(
        CommandCenterWorkspaceResult(
          id: 'workspace:${row.key}',
          title: title,
          subtitle: subtitle,
          searchText: searchText,
          run: () {
            ref.read(selectedWorktreeProvider.notifier).select(row.key);
            widget.router.go('/');
          },
        ),
      );
    }
    workspaces.sort((left, right) => left.title.compareTo(right.title));

    final agents = ref.read(sortedAgentsProvider);
    final agentResults = <CommandCenterResult>[
      for (final agent in agents)
        if (matches(
          '${agent.title} ${agent.cwd} ${agent.provider} ${agent.model}',
        ))
          CommandCenterAgentResult(
            id: 'agent:${agent.agentId}',
            title: agent.title.isEmpty ? 'New agent' : agent.title,
            subtitle: '${agent.provider} · ${agent.model} · ${agent.cwd}',
            searchText:
                '${agent.title} ${agent.cwd} ${agent.provider} ${agent.model}'
                    .toLowerCase(),
            agent: agent,
            run: () {
              final path = resolveWorktreeKey(agent);
              ref.read(selectedWorktreeProvider.notifier).select(path);
              ref
                  .read(worktreeTabsProvider(path).notifier)
                  .focusAgent(agent.agentId);
              widget.router.go('/');
            },
          ),
    ];

    final contributedSections = buildContributionSections(
      ref.read(commandCenterRegistryProvider).contributions,
      query,
    );
    return [
      ...contributedSections,
      if (workspaces.isNotEmpty)
        CommandCenterResultSection(
          id: 'workspaces',
          rank: 2,
          title: 'Workspaces',
          results: workspaces,
        ),
      if (agentResults.isNotEmpty)
        CommandCenterResultSection(
          id: 'agents',
          rank: 3,
          title: 'Agents',
          results: agentResults,
        ),
    ]..sort((left, right) => left.rank.compareTo(right.rank));
  }

  void _syncRootContributions() {
    if (_rootContributionsScheduled) return;
    _rootContributionsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _commandCenterRegistry.replace(
        CommandCenterRegistration(
          owner: _rootContributionOwner,
          contributions: [
            CommandCenterContribution(
              id: 'new-agent',
              group: 'actions',
              groupRank: 0,
              rank: 0,
              keywords: const [
                'open',
                'project',
                'folder',
                'workspace',
                'repo',
              ],
              presentation: const CommandCenterActionPresentation(
                title: 'Add project',
                sectionTitle: 'Actions',
                shortcutKeys: [
                  ['mod', 'O'],
                ],
              ),
              run: () =>
                  unawaited(ref.read(addProjectFlowProvider.notifier).open()),
            ),
            CommandCenterContribution(
              id: 'home',
              group: 'actions',
              groupRank: 0,
              rank: 1,
              keywords: const [
                'home',
                'start',
                'import',
                'session',
                'pair',
                'device',
                'providers',
              ],
              presentation: const CommandCenterActionPresentation(
                title: 'Home',
                sectionTitle: 'Actions',
              ),
              run: () => widget.router.go('/'),
            ),
            CommandCenterContribution(
              id: 'settings',
              group: 'actions',
              groupRank: 0,
              rank: 2,
              keywords: const [
                'settings',
                'preferences',
                'config',
                'configuration',
              ],
              presentation: const CommandCenterActionPresentation(
                title: 'Settings',
                sectionTitle: 'Actions',
                shortcutKeys: [
                  ['mod', ','],
                ],
              ),
              run: () => widget.router.push('/settings/general'),
            ),
          ],
        ),
      );
    });
  }

  void _syncActiveModelContributions({
    required AgentSummary? agent,
    required List<ProviderInfo> providers,
    required String serverId,
  }) {
    final provider = agent == null
        ? null
        : providers
              .where((candidate) => candidate.id.name == agent.provider)
              .firstOrNull;
    final signature = provider == null
        ? 'none'
        : [
            serverId,
            agent!.agentId,
            agent.provider,
            agent.model,
            for (final model in provider.models)
              '${model.id}:${model.displayName}',
          ].join('|');
    if (_activeModelSignature == signature) return;
    _activeModelSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeModelSignature != signature) return;
      final previousOwner = _activeModelOwner;
      if (provider == null || agent == null) {
        if (previousOwner != null) {
          _commandCenterRegistry.remove(previousOwner);
          _activeModelOwner = null;
        }
        return;
      }
      final sourceId = 'agent:$serverId:${agent.agentId}';
      var owner = previousOwner;
      if (owner == null || owner.sourceId != sourceId) {
        if (owner != null) _commandCenterRegistry.remove(owner);
        owner = CommandCenterRegistrationOwner(
          sourceId: sourceId,
          token: Object(),
        );
        _activeModelOwner = owner;
      }
      _commandCenterRegistry.replace(
        CommandCenterRegistration(
          owner: owner,
          contributions: buildModelChoiceContributions(
            serverId: serverId,
            providers: [
              ProviderSelectorProvider(
                id: provider.id.name,
                label: provider.displayName,
                modelSelection: ProviderModelRows([
                  for (final model in provider.models)
                    ProviderSelectionModelRow(
                      favoriteKey: '${provider.id.name}:${model.id}',
                      provider: provider.id.name,
                      providerLabel: provider.displayName,
                      modelId: model.id,
                      modelLabel: model.displayName,
                    ),
                ]),
              ),
            ],
            selectedProvider: agent.provider,
            selectedModelId: agent.model,
            groupLabel: 'Model',
            searchKeywords: 'model switch',
            select: (_, modelId) => _setAgentModel(agent, modelId),
          ),
        ),
      );
    });
  }

  AgentSummary? _activeAgent(String? path, Map<String, AgentSummary> agents) {
    if (path == null) return null;
    final layout = ref.watch(worktreeTabsProvider(path)).layout;
    final activeTab = layout.tabs
        .where((tab) => tab.tabId == layout.activeTabId)
        .firstOrNull;
    final agentId = activeTab?.agentId;
    return agentId == null ? null : agents[agentId];
  }

  Future<void> _setAgentModel(AgentSummary agent, String modelId) async {
    await ref.read(daemonClientProvider).setAgentModel(agent.agentId, modelId);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(effectiveKeyboardShortcutBindingsProvider);
    ref.watch(commandCenterRegistryProvider);
    ref.listen(commandCenterOverlayRequestProvider, (previous, next) {
      if (next == null || next.serial == previous?.serial) return;
      setState(() {
        _commandCenterOpen = next.overlay == CommandCenterOverlay.commandCenter;
        _shortcutsOpen = next.overlay == CommandCenterOverlay.shortcuts;
      });
    });
    final selectedPath = ref.watch(selectedWorktreeProvider);
    final agents = ref.watch(agentsProvider);
    final providers = ref.watch(providerListProvider).value ?? const [];
    final serverId =
        ref.watch(daemonClientProvider).serverInfo?.serverId ?? 'local';
    _syncRootContributions();
    _syncActiveModelContributions(
      agent: _activeAgent(selectedPath, agents),
      providers: providers,
      serverId: serverId,
    );
    final shortcutOverrides = ref.watch(keyboardShortcutOverridesProvider);
    final commandCenterBindingId = _isMac
        ? 'command-center-toggle-cmd-k-mac'
        : 'command-center-toggle-ctrl-k-non-mac';
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_commandCenterOpen || _shortcutsOpen) ...[
            ModalBarrier(
              dismissible: true,
              onDismiss: () => setState(() {
                _commandCenterOpen = false;
                _shortcutsOpen = false;
              }),
              color: Colors.black.withValues(alpha: 0.42),
            ),
            Center(
              child: _commandCenterOpen
                  ? CommandCenterDialog(
                      sectionsBuilder: _buildSections,
                      isMac: _isMac,
                      toggleShortcutOverride:
                          shortcutOverrides[commandCenterBindingId],
                      onClose: () => setState(() => _commandCenterOpen = false),
                    )
                  : KeyboardShortcutsDialog(
                      isMac: _isMac,
                      overrides: shortcutOverrides,
                      onClose: () => setState(() => _shortcutsOpen = false),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
