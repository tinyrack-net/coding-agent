import 'package:coding_agent_app/keyboard/keyboard_action_dispatcher.dart';
import 'package:coding_agent_app/keyboard/shortcut_engine.dart';
import 'package:coding_agent_app/keyboard/shortcut_routing.dart';
import 'package:flutter_test/flutter_test.dart';

const _targets = [
  ShortcutWorkspaceTarget(serverId: 'host', workspaceId: 'one'),
  ShortcutWorkspaceTarget(serverId: 'host', workspaceId: 'two'),
  ShortcutWorkspaceTarget(serverId: 'host', workspaceId: 'three'),
];

ShortcutRoutingContext _context({
  String pathname = '/',
  bool isMobile = false,
  List<ShortcutWorkspaceTarget> targets = _targets,
  ShortcutWorkspaceTarget? active = const ShortcutWorkspaceTarget(
    serverId: 'host',
    workspaceId: 'one',
  ),
  bool commandCenterOpen = false,
  bool shortcutsDialogOpen = false,
}) => ShortcutRoutingContext(
  pathname: pathname,
  isMobile: isMobile,
  sidebarShortcutTargets: targets,
  navigationActiveWorkspace: active,
  commandCenterOpen: commandCenterOpen,
  shortcutsDialogOpen: shortcutsDialogOpen,
);

KeyboardShortcutMatch _match(
  String action, [
  KeyboardShortcutPayload? payload,
]) => KeyboardShortcutMatch(
  action: action,
  payload: payload,
  preventDefault: true,
  stopPropagation: true,
);

void main() {
  test('routes tab index and relative payloads to workspace dispatch', () {
    final index =
        routeKeyboardShortcut(
              _match(
                'workspace.tab.navigate.index',
                const ShortcutIndexPayload(3),
              ),
              _context(),
            )
            as DispatchRoutedShortcutAction;
    expect(index.action.id, 'workspace.tab.navigate-index');
    expect(index.action.scope, KeyboardActionScope.workspace);
    expect(index.action.index, 3);

    final relative =
        routeKeyboardShortcut(
              _match(
                'workspace.tab.navigate.relative',
                const ShortcutDeltaPayload(-1),
              ),
              _context(),
            )
            as DispatchRoutedShortcutAction;
    expect(relative.action.id, 'workspace.tab.navigate-relative');
    expect(relative.action.delta, -1);
  });

  test('rejects missing or mismatched typed payloads', () {
    expect(
      routeKeyboardShortcut(_match('workspace.tab.navigate.index'), _context()),
      isA<NoRoutedShortcutAction>(),
    );
    expect(
      routeKeyboardShortcut(
        _match('workspace.navigate.relative', const ShortcutIndexPayload(1)),
        _context(),
      ),
      isA<NoRoutedShortcutAction>(),
    );
    expect(
      routeKeyboardShortcut(_match('message-input.action'), _context()),
      isA<NoRoutedShortcutAction>(),
    );
  });

  test('routes absolute workspace index and ignores out of range', () {
    final action =
        routeKeyboardShortcut(
              _match('workspace.navigate.index', const ShortcutIndexPayload(2)),
              _context(),
            )
            as NavigateWorkspaceRoutedShortcutAction;
    expect(action.target, _targets[1]);
    expect(
      routeKeyboardShortcut(
        _match('workspace.navigate.index', const ShortcutIndexPayload(9)),
        _context(),
      ),
      isA<NoRoutedShortcutAction>(),
    );
  });

  test('relative workspace navigation wraps and handles no active target', () {
    expect(_targets.first.hashCode, isNot(0));
    final previous =
        routeKeyboardShortcut(
              _match(
                'workspace.navigate.relative',
                const ShortcutDeltaPayload(-1),
              ),
              _context(),
            )
            as NavigateWorkspaceRoutedShortcutAction;
    expect(previous.target, _targets.last);

    final first =
        routeKeyboardShortcut(
              _match(
                'workspace.navigate.relative',
                const ShortcutDeltaPayload(1),
              ),
              _context(active: null),
            )
            as NavigateWorkspaceRoutedShortcutAction;
    expect(first.target, _targets.first);

    expect(
      routeKeyboardShortcut(
        _match('workspace.navigate.relative', const ShortcutDeltaPayload(1)),
        _context(targets: const [], active: null),
      ),
      isA<NoRoutedShortcutAction>(),
    );
  });

  test('maps message input kinds and passthrough actions', () {
    final message =
        routeKeyboardShortcut(
              _match(
                'message-input.action',
                const ShortcutMessageInputPayload('mode-cycle'),
              ),
              _context(),
            )
            as DispatchRoutedShortcutAction;
    expect(message.action.id, 'message-input.mode-cycle');
    expect(message.action.scope, KeyboardActionScope.messageInput);

    final terminal =
        routeKeyboardShortcut(_match('workspace.terminal.new'), _context())
            as DispatchRoutedShortcutAction;
    expect(terminal.action.id, 'workspace.terminal.new');
  });

  test('settings toggles with desktop and mobile route semantics', () {
    expect(
      routeKeyboardShortcut(_match('settings.toggle'), _context()),
      isA<RouterPushRoutedShortcutAction>(),
    );
    expect(
      routeKeyboardShortcut(
        _match('settings.toggle'),
        _context(pathname: '/settings/general'),
      ),
      isA<NavigateLastWorkspaceRoutedShortcutAction>(),
    );
    expect(
      routeKeyboardShortcut(
        _match('settings.toggle'),
        _context(pathname: '/settings/general', isMobile: true),
      ),
      isA<RouterBackRoutedShortcutAction>(),
    );
  });

  test('routes callbacks, project picker, overlays, and unknown actions', () {
    final callback =
        routeKeyboardShortcut(_match('sidebar.toggle.left'), _context())
            as CallbackRoutedShortcutAction;
    expect(callback.name, ShortcutCallbackName.toggleAgentList);
    expect(
      routeKeyboardShortcut(_match('agent.new'), _context()),
      isA<OpenProjectPickerRoutedShortcutAction>(),
    );
    final center =
        routeKeyboardShortcut(
              _match('command-center.toggle'),
              _context(commandCenterOpen: true),
            )
            as CommandCenterRoutedShortcutAction;
    expect(center.nextOpen, isFalse);
    final help =
        routeKeyboardShortcut(
              _match('shortcuts.dialog.toggle'),
              _context(shortcutsDialogOpen: false),
            )
            as ShortcutsDialogRoutedShortcutAction;
    expect(help.nextOpen, isTrue);
    expect(
      routeKeyboardShortcut(_match('unknown'), _context()),
      isA<NoRoutedShortcutAction>(),
    );
  });
}
