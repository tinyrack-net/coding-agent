import 'keyboard_action_dispatcher.dart';
import 'shortcut_engine.dart';

final class ShortcutWorkspaceTarget {
  const ShortcutWorkspaceTarget({
    required this.serverId,
    required this.workspaceId,
  });

  final String serverId;
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is ShortcutWorkspaceTarget &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId);
}

final class ShortcutRoutingContext {
  const ShortcutRoutingContext({
    required this.pathname,
    required this.isMobile,
    required this.sidebarShortcutTargets,
    required this.navigationActiveWorkspace,
    required this.commandCenterOpen,
    required this.shortcutsDialogOpen,
  });

  final String pathname;
  final bool isMobile;
  final List<ShortcutWorkspaceTarget> sidebarShortcutTargets;
  final ShortcutWorkspaceTarget? navigationActiveWorkspace;
  final bool commandCenterOpen;
  final bool shortcutsDialogOpen;
}

enum ShortcutCallbackName { toggleAgentList, toggleBothSidebars, cycleTheme }

sealed class RoutedShortcutAction {
  const RoutedShortcutAction();
}

final class NoRoutedShortcutAction extends RoutedShortcutAction {
  const NoRoutedShortcutAction();
}

final class DispatchRoutedShortcutAction extends RoutedShortcutAction {
  const DispatchRoutedShortcutAction(this.action);
  final KeyboardActionDefinition action;
}

final class NavigateWorkspaceRoutedShortcutAction extends RoutedShortcutAction {
  const NavigateWorkspaceRoutedShortcutAction(this.target);
  final ShortcutWorkspaceTarget target;
}

final class NavigateLastWorkspaceRoutedShortcutAction
    extends RoutedShortcutAction {
  const NavigateLastWorkspaceRoutedShortcutAction();
}

final class RouterReplaceRoutedShortcutAction extends RoutedShortcutAction {
  const RouterReplaceRoutedShortcutAction(this.route);
  final String route;
}

final class RouterBackRoutedShortcutAction extends RoutedShortcutAction {
  const RouterBackRoutedShortcutAction();
}

final class RouterPushRoutedShortcutAction extends RoutedShortcutAction {
  const RouterPushRoutedShortcutAction(this.route);
  final String route;
}

final class OpenProjectPickerRoutedShortcutAction extends RoutedShortcutAction {
  const OpenProjectPickerRoutedShortcutAction();
}

final class CallbackRoutedShortcutAction extends RoutedShortcutAction {
  const CallbackRoutedShortcutAction(this.name);
  final ShortcutCallbackName name;
}

final class CommandCenterRoutedShortcutAction extends RoutedShortcutAction {
  const CommandCenterRoutedShortcutAction(this.nextOpen);
  final bool nextOpen;
}

final class ShortcutsDialogRoutedShortcutAction extends RoutedShortcutAction {
  const ShortcutsDialogRoutedShortcutAction(this.nextOpen);
  final bool nextOpen;
}

const _none = NoRoutedShortcutAction();

const _passthroughDispatch = <String, KeyboardActionDefinition>{
  'agent.interrupt': KeyboardActionDefinition(
    id: 'agent.interrupt',
    scope: KeyboardActionScope.global,
  ),
  'workspace.tab.new': KeyboardActionDefinition(
    id: 'workspace.tab.new',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.new': KeyboardActionDefinition(
    id: 'workspace.new',
    scope: KeyboardActionScope.sidebar,
  ),
  'workspace.archive': KeyboardActionDefinition(
    id: 'workspace.archive',
    scope: KeyboardActionScope.sidebar,
  ),
  'workspace.pin': KeyboardActionDefinition(
    id: 'workspace.pin',
    scope: KeyboardActionScope.sidebar,
  ),
  'workspace.terminal.new': KeyboardActionDefinition(
    id: 'workspace.terminal.new',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.tab.close.current': KeyboardActionDefinition(
    id: 'workspace.tab.close.current',
    scope: KeyboardActionScope.workspace,
  ),
  'sidebar.toggle.right': KeyboardActionDefinition(
    id: 'sidebar.toggle.right',
    scope: KeyboardActionScope.sidebar,
  ),
  'workspace.pane.split.right': KeyboardActionDefinition(
    id: 'workspace.pane.split.right',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.split.down': KeyboardActionDefinition(
    id: 'workspace.pane.split.down',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.focus.left': KeyboardActionDefinition(
    id: 'workspace.pane.focus.left',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.focus.right': KeyboardActionDefinition(
    id: 'workspace.pane.focus.right',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.focus.up': KeyboardActionDefinition(
    id: 'workspace.pane.focus.up',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.focus.down': KeyboardActionDefinition(
    id: 'workspace.pane.focus.down',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.move-tab.left': KeyboardActionDefinition(
    id: 'workspace.pane.move-tab.left',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.move-tab.right': KeyboardActionDefinition(
    id: 'workspace.pane.move-tab.right',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.move-tab.up': KeyboardActionDefinition(
    id: 'workspace.pane.move-tab.up',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.move-tab.down': KeyboardActionDefinition(
    id: 'workspace.pane.move-tab.down',
    scope: KeyboardActionScope.workspace,
  ),
  'workspace.pane.close': KeyboardActionDefinition(
    id: 'workspace.pane.close',
    scope: KeyboardActionScope.workspace,
  ),
  'view.toggle.focus': KeyboardActionDefinition(
    id: 'workspace.focus.toggle',
    scope: KeyboardActionScope.workspace,
  ),
};

RoutedShortcutAction _routeWorkspaceIndex(
  KeyboardShortcutPayload? payload,
  ShortcutRoutingContext context,
) {
  if (payload is! ShortcutIndexPayload) return _none;
  final offset = payload.index - 1;
  if (offset < 0 || offset >= context.sidebarShortcutTargets.length) {
    return _none;
  }
  return NavigateWorkspaceRoutedShortcutAction(
    context.sidebarShortcutTargets[offset],
  );
}

RoutedShortcutAction _routeWorkspaceRelative(
  KeyboardShortcutPayload? payload,
  ShortcutRoutingContext context,
) {
  if (payload is! ShortcutDeltaPayload ||
      context.sidebarShortcutTargets.isEmpty) {
    return _none;
  }
  final targets = context.sidebarShortcutTargets;
  final current = context.navigationActiveWorkspace;
  final currentIndex = current == null ? -1 : targets.indexOf(current);
  if (currentIndex < 0) {
    return NavigateWorkspaceRoutedShortcutAction(
      payload.delta > 0 ? targets.first : targets.last,
    );
  }
  final index =
      (currentIndex + payload.delta + targets.length) % targets.length;
  return NavigateWorkspaceRoutedShortcutAction(targets[index]);
}

RoutedShortcutAction routeKeyboardShortcut(
  KeyboardShortcutMatch input,
  ShortcutRoutingContext context,
) {
  final passthrough = _passthroughDispatch[input.action];
  if (passthrough != null) return DispatchRoutedShortcutAction(passthrough);

  switch (input.action) {
    case 'workspace.tab.navigate.index':
      final payload = input.payload;
      return payload is ShortcutIndexPayload
          ? DispatchRoutedShortcutAction(
              KeyboardActionDefinition(
                id: 'workspace.tab.navigate-index',
                scope: KeyboardActionScope.workspace,
                index: payload.index,
              ),
            )
          : _none;
    case 'workspace.tab.navigate.relative':
      final payload = input.payload;
      return payload is ShortcutDeltaPayload
          ? DispatchRoutedShortcutAction(
              KeyboardActionDefinition(
                id: 'workspace.tab.navigate-relative',
                scope: KeyboardActionScope.workspace,
                delta: payload.delta,
              ),
            )
          : _none;
    case 'workspace.navigate.index':
      return _routeWorkspaceIndex(input.payload, context);
    case 'workspace.navigate.relative':
      return _routeWorkspaceRelative(input.payload, context);
    case 'message-input.action':
      final payload = input.payload;
      if (payload is! ShortcutMessageInputPayload) return _none;
      return DispatchRoutedShortcutAction(
        KeyboardActionDefinition(
          id: 'message-input.${payload.kind}',
          scope: KeyboardActionScope.messageInput,
        ),
      );
    case 'agent.new':
      return const OpenProjectPickerRoutedShortcutAction();
    case 'settings.toggle':
      if (!context.pathname.startsWith('/settings')) {
        return const RouterPushRoutedShortcutAction('/settings/general');
      }
      return context.isMobile
          ? const RouterBackRoutedShortcutAction()
          : const NavigateLastWorkspaceRoutedShortcutAction();
    case 'sidebar.toggle.left':
      return const CallbackRoutedShortcutAction(
        ShortcutCallbackName.toggleAgentList,
      );
    case 'sidebar.toggle.both':
      return const CallbackRoutedShortcutAction(
        ShortcutCallbackName.toggleBothSidebars,
      );
    case 'theme.cycle':
      return const CallbackRoutedShortcutAction(
        ShortcutCallbackName.cycleTheme,
      );
    case 'command-center.toggle':
      return CommandCenterRoutedShortcutAction(!context.commandCenterOpen);
    case 'shortcuts.dialog.toggle':
      return ShortcutsDialogRoutedShortcutAction(!context.shortcutsDialogOpen);
    default:
      return _none;
  }
}
