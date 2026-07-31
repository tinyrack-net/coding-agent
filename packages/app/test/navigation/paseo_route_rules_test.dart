// Ports of the upstream test suites for Paseo's route-adjacent decision
// rules: agent-route-resolution, workspace-route-navigation, focus-scope and
// use-rewind-capabilities, plus the edge cases the upstream suites leave
// unpinned (blank ids, nested host stacks, malformed open intents, candidate
// precedence, label overrides).
import 'package:coding_agent_app/core/paseo_session_rules.dart';
import 'package:coding_agent_app/navigation/paseo_route_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every action a navigator was asked to dispatch.
final class _FakeNavigator implements WorkspaceRouteNavigator {
  _FakeNavigator({this.rootState, this.ready = true});

  final NavigationStackState? rootState;
  final bool ready;
  final List<Map<String, Object?>> dispatched = [];
  int rootStateReads = 0;

  @override
  bool get isReady => ready;

  @override
  NavigationStackState? getRootState() {
    rootStateReads += 1;
    return rootState;
  }

  @override
  void dispatch(Map<String, Object?> action) => dispatched.add(action);
}

Map<String, Object?> _popToAction({
  required String target,
  required String serverId,
  required String workspaceId,
  String? open,
}) => {
  'type': 'POP_TO',
  'target': target,
  'payload': {
    'name': rootHostRouteName,
    'params': {
      'serverId': serverId,
      'screen': hostWorkspaceRouteName,
      'params': {
        'serverId': serverId,
        'workspaceId': workspaceId,
        'open': ?open,
      },
      'pop': true,
    },
  },
};

void main() {
  group('resolveAgentRoute', () {
    AgentRouteResolution resolve({
      String serverId = 'server-1',
      String agentId = 'agent-1',
      String? cachedWorkspaceId,
      required DaemonConnectionStatus connectionStatus,
      AgentRouteLookup lookup = const IdleAgentRouteLookup(),
    }) => resolveAgentRoute(
      serverId: serverId,
      agentId: agentId,
      cachedWorkspaceId: cachedWorkspaceId,
      connectionStatus: connectionStatus,
      lookup: lookup,
    );

    test('opens a cached workspace without waiting for its host', () {
      expect(
        resolve(
          cachedWorkspaceId: 'workspace-1',
          connectionStatus: DaemonConnectionStatus.offline,
        ),
        const ResolvedAgentRoute('workspace-1'),
      );
    });

    for (final status in const [
      DaemonConnectionStatus.idle,
      DaemonConnectionStatus.connecting,
      DaemonConnectionStatus.offline,
      DaemonConnectionStatus.error,
    ]) {
      test(
        'waits for a ${status.name} target host instead of abandoning the agent',
        () {
          expect(
            resolve(connectionStatus: status),
            WaitingForHostAgentRoute(status),
          );
        },
      );
    }

    test('fetches the agent after its target host connects', () {
      expect(
        resolve(connectionStatus: DaemonConnectionStatus.online),
        const FetchingAgentRoute(),
      );
    });

    test('keeps showing the fetch state while the lookup is in flight', () {
      expect(
        resolve(
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FetchingAgentRouteLookup(),
        ),
        const FetchingAgentRoute(),
      );
    });

    test('opens the workspace returned by the target host', () {
      expect(
        resolve(
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FoundAgentRouteLookup('workspace-2'),
        ),
        const ResolvedAgentRoute('workspace-2'),
      );
    });

    test(
      'abandons the agent only after the target host says it is missing',
      () {
        expect(
          resolve(
            connectionStatus: DaemonConnectionStatus.online,
            lookup: const FoundAgentRouteLookup(null),
          ),
          const AgentRouteNotFound(),
        );
      },
    );

    test('treats a blank fetched workspace id as missing', () {
      expect(
        resolve(
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FoundAgentRouteLookup('   '),
        ),
        const AgentRouteNotFound(),
      );
    });

    test('trims the workspace id the host returns', () {
      expect(
        resolve(
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FoundAgentRouteLookup('  workspace-2  '),
        ),
        const ResolvedAgentRoute('workspace-2'),
      );
    });

    test('keeps lookup failures retryable', () {
      expect(
        resolve(
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FailedAgentRouteLookup('connection closed'),
        ),
        const AgentRouteLookupError('connection closed'),
      );
    });

    test('rejects incomplete route parameters', () {
      expect(
        resolve(agentId: '', connectionStatus: DaemonConnectionStatus.online),
        const InvalidAgentRoute(),
      );
      expect(
        resolve(serverId: '', connectionStatus: DaemonConnectionStatus.online),
        const InvalidAgentRoute(),
      );
    });

    test('rejects an invalid route before consulting the cache', () {
      expect(
        resolve(
          serverId: '',
          cachedWorkspaceId: 'workspace-1',
          connectionStatus: DaemonConnectionStatus.online,
        ),
        const InvalidAgentRoute(),
      );
    });

    test('accepts whitespace ids, matching upstream falsy checks', () {
      // Upstream guards with `!input.serverId`, which only rejects "".
      expect(
        resolve(serverId: ' ', connectionStatus: DaemonConnectionStatus.online),
        const FetchingAgentRoute(),
      );
    });

    test('ignores a blank cached workspace id', () {
      expect(
        resolve(
          cachedWorkspaceId: '  ',
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FoundAgentRouteLookup('workspace-2'),
        ),
        const ResolvedAgentRoute('workspace-2'),
      );
    });

    test('prefers the cached workspace over a fetched one', () {
      expect(
        resolve(
          cachedWorkspaceId: '  workspace-1 ',
          connectionStatus: DaemonConnectionStatus.online,
          lookup: const FoundAgentRouteLookup('workspace-2'),
        ),
        const ResolvedAgentRoute('workspace-1'),
      );
    });
  });

  group('findStackKeyWithMountedRouteName', () {
    test('returns null for an absent state', () {
      expect(findStackKeyWithMountedRouteName(null, rootHostRouteName), isNull);
    });

    test('returns null when no route matches', () {
      expect(
        findStackKeyWithMountedRouteName(
          const NavigationStackState(
            key: 'root-stack',
            routes: [NavigationStackRoute(name: 'settings/[section]')],
          ),
          rootHostRouteName,
        ),
        isNull,
      );
    });

    test('finds the key of the navigator holding the route', () {
      expect(
        findStackKeyWithMountedRouteName(
          const NavigationStackState(
            key: 'root-stack',
            routes: [
              NavigationStackRoute(name: 'index'),
              NavigationStackRoute(name: rootHostRouteName),
            ],
          ),
          rootHostRouteName,
        ),
        'root-stack',
      );
    });

    test('descends into nested navigator state', () {
      expect(
        findStackKeyWithMountedRouteName(
          const NavigationStackState(
            key: 'root-stack',
            routes: [
              NavigationStackRoute(
                name: 'modal',
                state: NavigationStackState(
                  key: 'inner-stack',
                  routes: [NavigationStackRoute(name: rootHostRouteName)],
                ),
              ),
            ],
          ),
          rootHostRouteName,
        ),
        'inner-stack',
      );
    });

    test('skips a keyless navigator but still searches its children', () {
      expect(
        findStackKeyWithMountedRouteName(
          const NavigationStackState(
            routes: [
              NavigationStackRoute(name: rootHostRouteName),
              NavigationStackRoute(
                name: 'modal',
                state: NavigationStackState(
                  key: 'inner-stack',
                  routes: [NavigationStackRoute(name: rootHostRouteName)],
                ),
              ),
            ],
          ),
          rootHostRouteName,
        ),
        'inner-stack',
      );
    });

    test('prefers the shallowest navigator that has the route mounted', () {
      expect(
        findStackKeyWithMountedRouteName(
          const NavigationStackState(
            key: 'root-stack',
            routes: [
              NavigationStackRoute(
                name: rootHostRouteName,
                state: NavigationStackState(
                  key: 'inner-stack',
                  routes: [NavigationStackRoute(name: rootHostRouteName)],
                ),
              ),
            ],
          ),
          rootHostRouteName,
        ),
        'root-stack',
      );
    });
  });

  group('getHostWorkspaceOpenParamFromPathname', () {
    test('returns null without a query string', () {
      expect(
        getHostWorkspaceOpenParamFromPathname('/h/server-1/workspace/ws-a'),
        isNull,
      );
    });

    test('returns a decoded, recognised open intent', () {
      expect(
        getHostWorkspaceOpenParamFromPathname(
          '/h/server-1/workspace/ws-a?open=agent%3Aagent-1',
        ),
        'agent:agent-1',
      );
    });

    test('stops at the fragment', () {
      expect(
        getHostWorkspaceOpenParamFromPathname(
          '/h/server-1/workspace/ws-a?open=terminal%3At-1#section',
        ),
        'terminal:t-1',
      );
    });

    test('ignores an open param with an unknown intent kind', () {
      expect(
        getHostWorkspaceOpenParamFromPathname(
          '/h/server-1/workspace/ws-a?open=bogus%3Ax',
        ),
        isNull,
      );
    });

    test('ignores an open param with no payload', () {
      expect(
        getHostWorkspaceOpenParamFromPathname(
          '/h/server-1/workspace/ws-a?open=agent%3A',
        ),
        isNull,
      );
    });

    test('reads the first open param and keeps other params out of it', () {
      expect(
        getHostWorkspaceOpenParamFromPathname(
          '/h/server-1/workspace/ws-a?pop=true&open=agent%3Aa&open=agent%3Ab',
        ),
        'agent:a',
      );
    });
  });

  group('resolveHostWorkspaceNavigation', () {
    const mountedHostStack = NavigationStackState(
      key: 'root-stack',
      routes: [
        NavigationStackRoute(key: 'host-server-1', name: rootHostRouteName),
        NavigationStackRoute(
          key: 'settings-general',
          name: 'settings/[section]',
        ),
      ],
    );

    test('falls back when the host stack is not mounted', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/h/server-1/workspace/workspace-a',
          rootState: const NavigationStackState(
            key: 'root-stack',
            routes: [
              NavigationStackRoute(
                key: 'settings-general',
                name: 'settings/[section]',
              ),
            ],
          ),
          isReady: true,
        ),
        const DismissToHostWorkspaceNavigation(
          '/h/server-1/workspace/workspace-a',
        ),
      );
    });

    test('falls back while the navigator is not ready', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/h/server-1/workspace/workspace-a',
          rootState: mountedHostStack,
          isReady: false,
        ),
        const DismissToHostWorkspaceNavigation(
          '/h/server-1/workspace/workspace-a',
        ),
      );
    });

    test('falls back for a route that is not a host workspace route', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/settings/general',
          rootState: mountedHostStack,
          isReady: true,
        ),
        const DismissToHostWorkspaceNavigation('/settings/general'),
      );
    });

    test('pops to the mounted host route and targets the workspace', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/h/server-1/workspace/workspace-a',
          rootState: mountedHostStack,
          isReady: true,
        ),
        const PopToHostWorkspaceNavigation(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceIdSegment: 'workspace-a',
        ),
      );
    });

    test('re-encodes a workspace id that is not path safe', () {
      final decision =
          resolveHostWorkspaceNavigation(
                route: '/h/server-1/workspace/b64_L3RtcC9kZW1v',
                rootState: mountedHostStack,
                isReady: true,
              )
              as PopToHostWorkspaceNavigation;

      expect(decision.workspaceIdSegment, 'b64_L3RtcC9kZW1v');
    });

    test('preserves a workspace open intent', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/h/server-1/workspace/workspace-a?open=agent%3Aagent-1',
          rootState: mountedHostStack,
          isReady: true,
        ),
        const PopToHostWorkspaceNavigation(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceIdSegment: 'workspace-a',
          open: 'agent:agent-1',
        ),
      );
    });

    test('drops an unrecognised open intent', () {
      expect(
        resolveHostWorkspaceNavigation(
          route: '/h/server-1/workspace/workspace-a?open=nonsense',
          rootState: mountedHostStack,
          isReady: true,
        ),
        const PopToHostWorkspaceNavigation(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceIdSegment: 'workspace-a',
        ),
      );
    });

    test('emits the upstream POP_TO action shape', () {
      final decision =
          resolveHostWorkspaceNavigation(
                route: '/h/server-1/workspace/workspace-a',
                rootState: mountedHostStack,
                isReady: true,
              )
              as PopToHostWorkspaceNavigation;

      expect(
        decision.toNavigationAction(),
        _popToAction(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
      );
    });

    test('omits the open key entirely when there is no intent', () {
      final decision =
          resolveHostWorkspaceNavigation(
                route: '/h/server-1/workspace/workspace-a',
                rootState: mountedHostStack,
                isReady: true,
              )
              as PopToHostWorkspaceNavigation;
      final payload =
          decision.toNavigationAction()['payload']! as Map<String, Object?>;
      final params = payload['params']! as Map<String, Object?>;
      final screenParams = params['params']! as Map<String, Object?>;

      expect(screenParams.containsKey('open'), isFalse);
    });
  });

  group('navigateToHostWorkspaceRoute', () {
    setUp(() {
      registerWorkspaceRouteNavigationRef(null);
    });

    tearDown(() {
      registerWorkspaceRouteNavigationRef(null);
    });

    test('falls back to route navigation with no navigator registered', () {
      final dismissed = <String>[];

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: dismissed.add,
      );

      expect(dismissed, ['/h/server-1/workspace/workspace-a']);
    });

    test('falls back when no host route is mounted yet', () {
      final navigator = _FakeNavigator(
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [
            NavigationStackRoute(
              key: 'settings-general',
              name: 'settings/[section]',
            ),
          ],
        ),
      );
      registerWorkspaceRouteNavigationRef(navigator);
      final dismissed = <String>[];

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: dismissed.add,
      );

      expect(navigator.dispatched, isEmpty);
      expect(dismissed, ['/h/server-1/workspace/workspace-a']);
    });

    test('pops to the mounted host route and targets the workspace', () {
      final navigator = _FakeNavigator(
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [
            NavigationStackRoute(key: 'host-server-1', name: rootHostRouteName),
            NavigationStackRoute(
              key: 'settings-general',
              name: 'settings/[section]',
            ),
          ],
        ),
      );
      registerWorkspaceRouteNavigationRef(navigator);
      final dismissed = <String>[];

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: dismissed.add,
      );

      expect(dismissed, isEmpty);
      expect(navigator.dispatched, [
        _popToAction(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
      ]);
    });

    test('preserves a workspace open intent in the POP_TO target', () {
      final navigator = _FakeNavigator(
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [
            NavigationStackRoute(key: 'host-server-1', name: rootHostRouteName),
          ],
        ),
      );
      registerWorkspaceRouteNavigationRef(navigator);

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a?open=agent%3Aagent-1',
        dismissTo: (_) {},
      );

      expect(navigator.dispatched, [
        _popToAction(
          target: 'root-stack',
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          open: 'agent:agent-1',
        ),
      ]);
    });

    test('never reads the root state of an unready navigator', () {
      final navigator = _FakeNavigator(
        ready: false,
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [NavigationStackRoute(name: rootHostRouteName)],
        ),
      );
      registerWorkspaceRouteNavigationRef(navigator);
      final dismissed = <String>[];

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: dismissed.add,
      );

      expect(navigator.rootStateReads, 0);
      expect(navigator.dispatched, isEmpty);
      expect(dismissed, ['/h/server-1/workspace/workspace-a']);
    });

    test('unregistering releases the navigator', () {
      final navigator = _FakeNavigator(
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [NavigationStackRoute(name: rootHostRouteName)],
        ),
      );
      final unregister = registerWorkspaceRouteNavigationRef(navigator);
      unregister();
      final dismissed = <String>[];

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: dismissed.add,
      );

      expect(navigator.dispatched, isEmpty);
      expect(dismissed, ['/h/server-1/workspace/workspace-a']);
    });

    test('a stale unregister does not clear a replacement navigator', () {
      final stale = _FakeNavigator();
      final current = _FakeNavigator(
        rootState: const NavigationStackState(
          key: 'root-stack',
          routes: [NavigationStackRoute(name: rootHostRouteName)],
        ),
      );
      final unregisterStale = registerWorkspaceRouteNavigationRef(stale);
      registerWorkspaceRouteNavigationRef(current);
      unregisterStale();

      navigateToHostWorkspaceRoute(
        '/h/server-1/workspace/workspace-a',
        dismissTo: (_) => fail('should have popped to the mounted host stack'),
      );

      expect(current.dispatched, hasLength(1));
    });
  });

  group('resolveKeyboardFocusScope', () {
    test('resolves terminal scope from the direct keyboard event target', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(selectors: const {xtermSelector}),
          commandCenterOpen: false,
        ),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('resolves terminal scope from the terminal surface wrapper', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(
            selectors: const {terminalSurfaceSelector},
          ),
          commandCenterOpen: true,
        ),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('resolves terminal scope through an ancestor', () {
      final terminal = FocusTargetElement(
        selectors: const {terminalSurfaceSelector},
      );
      final target = FocusTargetElement(
        tagName: 'textarea',
        parentElement: terminal,
      );

      expect(
        resolveKeyboardFocusScope(target: target, commandCenterOpen: false),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('falls back to activeElement when target is not an Element', () {
      expect(
        resolveKeyboardFocusScope(
          target: null,
          commandCenterOpen: false,
          activeElement: FocusTargetElement(selectors: const {xtermSelector}),
        ),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('detects editable scope from activeElement fallback', () {
      expect(
        resolveKeyboardFocusScope(
          target: null,
          commandCenterOpen: false,
          activeElement: FocusTargetElement(tagName: 'input'),
        ),
        PaseoKeyboardFocusScope.editable,
      );
    });

    test('classifies a non-element target by its parent element', () {
      final target = FocusTargetNode(
        parentElement: FocusTargetElement(selectors: const {xtermSelector}),
      );

      expect(
        resolveKeyboardFocusScope(target: target, commandCenterOpen: false),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('returns other with no candidates at all', () {
      expect(
        resolveKeyboardFocusScope(target: null, commandCenterOpen: false),
        PaseoKeyboardFocusScope.other,
      );
    });

    test('attributes an empty candidate set to an open command center', () {
      expect(
        resolveKeyboardFocusScope(target: null, commandCenterOpen: true),
        PaseoKeyboardFocusScope.commandCenter,
      );
    });

    test('claims the command center panel only while it is open', () {
      final panel = FocusTargetElement(
        selectors: const {commandCenterPanelSelector},
      );

      expect(
        resolveKeyboardFocusScope(target: panel, commandCenterOpen: true),
        PaseoKeyboardFocusScope.commandCenter,
      );
      expect(
        resolveKeyboardFocusScope(target: panel, commandCenterOpen: false),
        PaseoKeyboardFocusScope.other,
      );
    });

    test('claims a portalled command center input', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(
            tagName: 'input',
            selectors: const {commandCenterInputSelector},
          ),
          commandCenterOpen: true,
        ),
        PaseoKeyboardFocusScope.commandCenter,
      );
    });

    test('resolves the message composer to message-input scope', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(
            tagName: 'textarea',
            selectors: const {messageInputRootSelector},
          ),
          commandCenterOpen: false,
        ),
        PaseoKeyboardFocusScope.messageInput,
      );
    });

    test(
      'keeps the message composer even while the command center is open',
      () {
        expect(
          resolveKeyboardFocusScope(
            target: FocusTargetElement(
              selectors: const {messageInputRootSelector},
            ),
            commandCenterOpen: true,
          ),
          PaseoKeyboardFocusScope.messageInput,
        );
      },
    );

    test('lets the terminal win over the message composer', () {
      final composer = FocusTargetElement(
        selectors: const {messageInputRootSelector, xtermSelector},
      );

      expect(
        resolveKeyboardFocusScope(target: composer, commandCenterOpen: false),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('treats contenteditable as editable', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(isContentEditable: true),
          commandCenterOpen: false,
        ),
        PaseoKeyboardFocusScope.editable,
      );
    });

    for (final tag in const ['input', 'textarea', 'select', 'INPUT']) {
      test('treats <$tag> as editable', () {
        expect(
          resolveKeyboardFocusScope(
            target: FocusTargetElement(tagName: tag),
            commandCenterOpen: false,
          ),
          PaseoKeyboardFocusScope.editable,
        );
      });
    }

    test('reattributes a stray editable to an open command center', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(tagName: 'input'),
          commandCenterOpen: true,
        ),
        PaseoKeyboardFocusScope.commandCenter,
      );
    });

    test('returns other for a plain element', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(tagName: 'button'),
          commandCenterOpen: false,
        ),
        PaseoKeyboardFocusScope.other,
      );
    });

    test('considers the activeElement alongside the event target', () {
      expect(
        resolveKeyboardFocusScope(
          target: FocusTargetElement(tagName: 'button'),
          commandCenterOpen: false,
          activeElement: FocusTargetElement(selectors: const {xtermSelector}),
        ),
        PaseoKeyboardFocusScope.terminal,
      );
    });

    test('does not double-count a target that is also the activeElement', () {
      final element = FocusTargetElement(tagName: 'input');

      expect(
        resolveKeyboardFocusScope(
          target: element,
          commandCenterOpen: false,
          activeElement: element,
        ),
        PaseoKeyboardFocusScope.editable,
      );
    });
  });

  group('resolveRewindMenuItems', () {
    test('returns no items when the provider declares no capabilities', () {
      expect(resolveRewindMenuItems(null), isEmpty);
    });

    test(
      'returns no items when the provider declares no rewind capability',
      () {
        expect(
          resolveRewindMenuItems(
            const RewindCapabilities(
              supportsRewindConversation: false,
              supportsRewindFiles: false,
              supportsRewindBoth: false,
            ),
          ),
          isEmpty,
        );
      },
    );

    test('returns only the capabilities declared by the provider', () {
      expect(
        resolveRewindMenuItems(
          const RewindCapabilities(
            supportsRewindConversation: true,
            supportsRewindFiles: false,
            supportsRewindBoth: true,
          ),
        ),
        const [
          RewindMenuItem(
            mode: RewindMode.conversation,
            label: 'Rewind conversation',
            testId: 'rewind-menu-conversation',
          ),
          RewindMenuItem(
            mode: RewindMode.both,
            label: 'Rewind conversation and files',
            testId: 'rewind-menu-both',
          ),
        ],
      );
    });

    test('keeps conversation, files, both menu order', () {
      expect(
        resolveRewindMenuItems(
          const RewindCapabilities(
            supportsRewindConversation: true,
            supportsRewindFiles: true,
            supportsRewindBoth: true,
          ),
        ).map((item) => item.mode),
        const [RewindMode.conversation, RewindMode.files, RewindMode.both],
      );
    });

    test('uses caller-provided labels for available capabilities', () {
      expect(
        resolveRewindMenuItems(
          const RewindCapabilities(
            supportsRewindConversation: true,
            supportsRewindFiles: true,
            supportsRewindBoth: false,
          ),
          const RewindMenuLabelOverrides(
            conversation: 'Conversation label',
            files: 'Files label',
            both: 'Both label',
          ),
        ).map((item) => item.label),
        const ['Conversation label', 'Files label'],
      );
    });

    test('falls back to the default label for each omitted override', () {
      expect(
        resolveRewindMenuItems(
          const RewindCapabilities(
            supportsRewindConversation: true,
            supportsRewindFiles: true,
            supportsRewindBoth: true,
          ),
          const RewindMenuLabelOverrides(files: 'Files label'),
        ).map((item) => item.label),
        const [
          'Rewind conversation',
          'Files label',
          'Rewind conversation and files',
        ],
      );
    });

    test('keeps the test ids upstream selectors rely on', () {
      expect(
        resolveRewindMenuItems(
          const RewindCapabilities(
            supportsRewindConversation: true,
            supportsRewindFiles: true,
            supportsRewindBoth: true,
          ),
        ).map((item) => item.testId),
        const [
          'rewind-menu-conversation',
          'rewind-menu-files',
          'rewind-menu-both',
        ],
      );
    });
  });
}
