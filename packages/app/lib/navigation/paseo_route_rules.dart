/// Ports of Paseo 0.2.0's route-adjacent decision rules — the frozen logic
/// that sits between a URL (or a keyboard event) and the screen that ends up
/// mounted:
///
/// - `navigation/agent-route-resolution.ts` — what an `/h/:serverId/agent/:id`
///   deep link should render while its host is still connecting.
/// - `navigation/workspace-route-navigation.ts` — whether a workspace link can
///   pop the already-mounted host stack instead of pushing a fresh route.
/// - `keyboard/focus-scope.ts` — which keyboard scope owns a key event, based
///   on what is focused.
/// - `components/rewind/use-rewind-capabilities.ts` — which rewind menu items
///   a provider's capability flags permit.
///
/// The four live together because each is a pure function that decides *what
/// the router or key dispatcher should do next*, with no store or widget
/// dependency, so they can be tested without mounting anything.
///
/// Route parsing itself is not re-ported here: this library reuses
/// `core/host_routes.dart` (`parseHostWorkspaceRouteFromPathname`,
/// `encodeWorkspaceIdForPathSegment`, `parseWorkspaceOpenIntent`) and the
/// `DaemonConnectionStatus` enum from `core/paseo_session_rules.dart`.
library;

import '../core/host_routes.dart';
import '../core/paseo_session_rules.dart';

// ---------------------------------------------------------------------------
// agent-route-resolution.ts
// ---------------------------------------------------------------------------

/// Inlined `normalizeWorkspaceOpaqueId` from upstream `utils/workspace-identity.ts`.
///
/// That module is outside this cluster, and the only behaviour these rules
/// need from it is "trim, and treat blank as absent". Kept private so the
/// eventual full port of workspace-identity owns the public name.
String? _normalizeWorkspaceOpaqueId(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The state of the "which workspace does this agent live in?" query that the
/// agent route screen runs against its host.
///
/// [IdleAgentRouteLookup] and [FetchingAgentRouteLookup] are distinct upstream
/// but resolve identically; both are kept so callers can model the query's
/// real lifecycle rather than collapsing it at the call site.
sealed class AgentRouteLookup {
  const AgentRouteLookup();
}

/// No lookup has been started (usually because the host is not online yet).
final class IdleAgentRouteLookup extends AgentRouteLookup {
  const IdleAgentRouteLookup();
}

/// A lookup is in flight.
final class FetchingAgentRouteLookup extends AgentRouteLookup {
  const FetchingAgentRouteLookup();
}

/// The host answered. A null [workspaceId] is a *negative* answer — the host
/// knows of no workspace for this agent — which is the only signal strong
/// enough to show "not found".
final class FoundAgentRouteLookup extends AgentRouteLookup {
  const FoundAgentRouteLookup(this.workspaceId);

  final String? workspaceId;
}

/// The lookup itself failed (transport error, closed connection). Distinct
/// from a negative answer because it is retryable.
final class FailedAgentRouteLookup extends AgentRouteLookup {
  const FailedAgentRouteLookup(this.error);

  final String error;
}

/// What an agent deep link should render right now.
sealed class AgentRouteResolution {
  const AgentRouteResolution();
}

/// The route is missing a server or agent id and can never resolve.
final class InvalidAgentRoute extends AgentRouteResolution {
  const InvalidAgentRoute();

  @override
  bool operator ==(Object other) => other is InvalidAgentRoute;

  @override
  int get hashCode => (InvalidAgentRoute).hashCode;

  @override
  String toString() => 'InvalidAgentRoute()';
}

/// The agent's workspace is known; open it.
final class ResolvedAgentRoute extends AgentRouteResolution {
  const ResolvedAgentRoute(this.workspaceId);

  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is ResolvedAgentRoute && other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(ResolvedAgentRoute, workspaceId);

  @override
  String toString() => 'ResolvedAgentRoute($workspaceId)';
}

/// The target host is not online, so the link is held rather than failed.
///
/// [connectionStatus] is upstream's `Exclude<HostRuntimeConnectionStatus,
/// "online">`. Dart has no negated union type, so the field keeps the full
/// [DaemonConnectionStatus] enum; [DaemonConnectionStatus.online] is
/// unreachable here by construction because an online host takes the lookup
/// branch instead.
final class WaitingForHostAgentRoute extends AgentRouteResolution {
  const WaitingForHostAgentRoute(this.connectionStatus);

  final DaemonConnectionStatus connectionStatus;

  @override
  bool operator ==(Object other) =>
      other is WaitingForHostAgentRoute &&
      other.connectionStatus == connectionStatus;

  @override
  int get hashCode => Object.hash(WaitingForHostAgentRoute, connectionStatus);

  @override
  String toString() => 'WaitingForHostAgentRoute($connectionStatus)';
}

/// The host is online and the workspace lookup is (or should be) running.
final class FetchingAgentRoute extends AgentRouteResolution {
  const FetchingAgentRoute();

  @override
  bool operator ==(Object other) => other is FetchingAgentRoute;

  @override
  int get hashCode => (FetchingAgentRoute).hashCode;

  @override
  String toString() => 'FetchingAgentRoute()';
}

/// The host answered that this agent has no workspace.
final class AgentRouteNotFound extends AgentRouteResolution {
  const AgentRouteNotFound();

  @override
  bool operator ==(Object other) => other is AgentRouteNotFound;

  @override
  int get hashCode => (AgentRouteNotFound).hashCode;

  @override
  String toString() => 'AgentRouteNotFound()';
}

/// The lookup failed; the screen should offer a retry rather than a dead end.
final class AgentRouteLookupError extends AgentRouteResolution {
  const AgentRouteLookupError(this.error);

  final String error;

  @override
  bool operator ==(Object other) =>
      other is AgentRouteLookupError && other.error == error;

  @override
  int get hashCode => Object.hash(AgentRouteLookupError, error);

  @override
  String toString() => 'AgentRouteLookupError($error)';
}

/// Decides what an agent deep link renders, given what is already cached and
/// how far its host has got.
///
/// The ordering encodes the product rule that an agent link must never 404
/// just because its host is slow: a cached workspace wins outright (so a
/// previously visited agent opens offline), an unreachable host parks the
/// route in [WaitingForHostAgentRoute] instead of failing it, and only a host
/// that is online *and* has explicitly answered "no workspace" produces
/// [AgentRouteNotFound].
///
/// Deviation: upstream's `!input.serverId || !input.agentId` is a JS falsy
/// check, which rejects only the empty string — a whitespace-only id is
/// truthy and passes. [serverId] and [agentId] are therefore tested with
/// `isEmpty`, deliberately *not* trimmed, so `" "` stays valid as upstream.
/// [cachedWorkspaceId] by contrast is trimmed, because upstream runs it
/// through `normalizeWorkspaceOpaqueId`.
AgentRouteResolution resolveAgentRoute({
  required String serverId,
  required String agentId,
  required String? cachedWorkspaceId,
  required DaemonConnectionStatus connectionStatus,
  required AgentRouteLookup lookup,
}) {
  if (serverId.isEmpty || agentId.isEmpty) {
    return const InvalidAgentRoute();
  }

  final cached = _normalizeWorkspaceOpaqueId(cachedWorkspaceId);
  if (cached != null) {
    return ResolvedAgentRoute(cached);
  }

  if (connectionStatus != DaemonConnectionStatus.online) {
    return WaitingForHostAgentRoute(connectionStatus);
  }

  switch (lookup) {
    case FoundAgentRouteLookup(:final workspaceId):
      final fetched = _normalizeWorkspaceOpaqueId(workspaceId);
      return fetched != null
          ? ResolvedAgentRoute(fetched)
          : const AgentRouteNotFound();
    case FailedAgentRouteLookup(:final error):
      return AgentRouteLookupError(error);
    case IdleAgentRouteLookup():
    case FetchingAgentRouteLookup():
      return const FetchingAgentRoute();
  }
}

// ---------------------------------------------------------------------------
// workspace-route-navigation.ts
// ---------------------------------------------------------------------------

/// The Expo Router route name of the per-host stack, as registered upstream.
const String rootHostRouteName = 'h/[serverId]';

/// The route name of the workspace screen nested inside the host stack.
const String hostWorkspaceRouteName = 'workspace/[workspaceId]/index';

/// One entry in a navigator's route list.
///
/// Upstream probes an opaque `unknown` React Navigation state; this is the
/// subset it actually reads. [state] is the route's own nested navigator
/// state, which is how a host stack mounted several levels deep is found.
final class NavigationStackRoute {
  const NavigationStackRoute({required this.name, this.key, this.state});

  final String name;
  final String? key;
  final NavigationStackState? state;
}

/// A navigator's state: its own [key] plus the routes it currently holds.
///
/// Deviation: upstream bails out when `routes` is not an array, and skips a
/// level (while still recursing) when `key` is not a string. With [routes]
/// typed as a non-null list, "not an array" collapses onto the empty list,
/// which produces the same `null` result; [key] stays nullable so the
/// skip-but-recurse path is preserved exactly.
final class NavigationStackState {
  const NavigationStackState({this.key, required this.routes});

  final String? key;
  final List<NavigationStackRoute> routes;
}

/// Finds the key of the *shallowest* navigator that currently has
/// [routeName] mounted, or null if no navigator does.
///
/// This is what distinguishes "the host stack is already on screen, so pop
/// back to it" from "the host stack was never pushed, so navigate normally".
/// The search is breadth-first at each level in upstream's sense — a level is
/// fully checked for a matching route before any of its children are
/// descended into — so a nested navigator that happens to reuse the route
/// name cannot shadow the real host stack above it.
String? findStackKeyWithMountedRouteName(
  NavigationStackState? state,
  String routeName,
) {
  if (state == null) return null;

  if (state.key != null &&
      state.routes.any((route) => route.name == routeName)) {
    return state.key;
  }

  for (final route in state.routes) {
    final childKey = findStackKeyWithMountedRouteName(route.state, routeName);
    if (childKey != null) return childKey;
  }

  return null;
}

/// What [navigateToHostWorkspaceRoute] should do with a workspace link.
sealed class HostWorkspaceNavigation {
  const HostWorkspaceNavigation();
}

/// Pop the mounted host stack back to the requested workspace.
///
/// Preferred over a plain navigation because repeated `/new` -> workspace hops
/// would otherwise append hidden entries to the deck.
final class PopToHostWorkspaceNavigation extends HostWorkspaceNavigation {
  const PopToHostWorkspaceNavigation({
    required this.target,
    required this.serverId,
    required this.workspaceIdSegment,
    this.open,
  });

  /// The navigator key returned by [findStackKeyWithMountedRouteName].
  final String target;

  final String serverId;

  /// The workspace id re-encoded for a path segment, since React Navigation
  /// params carry the URL form rather than the decoded id.
  final String workspaceIdSegment;

  /// The validated `open=` intent carried by the link, if any.
  final String? open;

  /// The literal action object upstream dispatches.
  ///
  /// Emitted as a map rather than a typed action because React Navigation's
  /// `POP_TO` payload is structurally typed and the nested `params.params`
  /// shape — including the `pop: true` hint that the browser-route
  /// canonicalizer later strips from the URL — is the actual contract.
  Map<String, Object?> toNavigationAction() => {
    'type': 'POP_TO',
    'target': target,
    'payload': {
      'name': rootHostRouteName,
      'params': {
        'serverId': serverId,
        'screen': hostWorkspaceRouteName,
        'params': {
          'serverId': serverId,
          'workspaceId': workspaceIdSegment,
          if (open != null) 'open': open,
        },
        // React Navigation consumes this nested hint when resolving the host
        // child screen; without it repeated hops append hidden deck entries.
        'pop': true,
      },
    },
  };

  @override
  bool operator ==(Object other) =>
      other is PopToHostWorkspaceNavigation &&
      other.target == target &&
      other.serverId == serverId &&
      other.workspaceIdSegment == workspaceIdSegment &&
      other.open == open;

  @override
  int get hashCode => Object.hash(target, serverId, workspaceIdSegment, open);

  @override
  String toString() =>
      'PopToHostWorkspaceNavigation($target, $serverId, '
      '$workspaceIdSegment, $open)';
}

/// Fall back to ordinary route navigation with the original link.
final class DismissToHostWorkspaceNavigation extends HostWorkspaceNavigation {
  const DismissToHostWorkspaceNavigation(this.route);

  final String route;

  @override
  bool operator ==(Object other) =>
      other is DismissToHostWorkspaceNavigation && other.route == route;

  @override
  int get hashCode => Object.hash(DismissToHostWorkspaceNavigation, route);

  @override
  String toString() => 'DismissToHostWorkspaceNavigation($route)';
}

/// Upstream `extractSearch` from `utils/host-routes.ts`.
///
/// Deliberately hand-rolled instead of going through [Uri]: the pathname may
/// be a relative, partially-encoded route string that [Uri] would reject or
/// re-normalise, and upstream only ever slices between `?` and `#`.
String _extractSearch(String pathname) {
  final queryIndex = pathname.indexOf('?');
  if (queryIndex < 0) return '';
  final hashIndex = pathname.indexOf('#', queryIndex);
  return hashIndex >= 0
      ? pathname.substring(queryIndex + 1, hashIndex)
      : pathname.substring(queryIndex + 1);
}

/// `URLSearchParams` component decoding.
///
/// Deviation: `Uri.decodeQueryComponent` throws on a malformed escape while
/// `URLSearchParams` leaves the raw text in place, so failures fall back to
/// the undecoded value to keep the observable result identical.
String _decodeSearchComponent(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on ArgumentError {
    return value;
  } on FormatException {
    return value;
  }
}

/// First value for [name], matching `new URLSearchParams(search).get(name)`.
String? _searchParam(String search, String name) {
  if (search.isEmpty) return null;
  for (final pair in search.split('&')) {
    if (pair.isEmpty) continue;
    final separator = pair.indexOf('=');
    final rawKey = separator < 0 ? pair : pair.substring(0, separator);
    if (_decodeSearchComponent(rawKey) != name) continue;
    // A key with no `=` yields the empty string upstream, not null.
    return separator < 0
        ? ''
        : _decodeSearchComponent(pair.substring(separator + 1));
  }
  return null;
}

/// The raw `open=` parameter of a workspace link, but only when it names an
/// intent the app actually understands.
///
/// The *raw* string is returned rather than the parsed intent because it is
/// forwarded verbatim as a navigation param; parsing is used purely as a
/// validity gate, which is why this delegates to `parseWorkspaceOpenIntent`
/// from `core/host_routes.dart` instead of re-implementing intent syntax.
String? getHostWorkspaceOpenParamFromPathname(String pathname) {
  final open = _searchParam(_extractSearch(pathname), 'open');
  return parseWorkspaceOpenIntent(open) != null ? open : null;
}

/// Decides how to honour a workspace link.
///
/// Popping is only safe when every precondition holds at once: the link really
/// is a host workspace route, the navigator has mounted, and the host stack is
/// on screen. Any missing piece falls back to [DismissToHostWorkspaceNavigation]
/// rather than guessing, because a `POP_TO` aimed at an unmounted stack is a
/// runtime error rather than a no-op.
HostWorkspaceNavigation resolveHostWorkspaceNavigation({
  required String route,
  required NavigationStackState? rootState,
  required bool isReady,
}) {
  final selection = parseHostWorkspaceRouteFromPathname(route);
  if (selection == null || !isReady) {
    return DismissToHostWorkspaceNavigation(route);
  }

  final target = findStackKeyWithMountedRouteName(rootState, rootHostRouteName);
  if (target == null) {
    return DismissToHostWorkspaceNavigation(route);
  }

  return PopToHostWorkspaceNavigation(
    target: target,
    serverId: selection.serverId,
    workspaceIdSegment: encodeWorkspaceIdForPathSegment(selection.workspaceId),
    open: getHostWorkspaceOpenParamFromPathname(route),
  );
}

/// The root navigator, as seen by [navigateToHostWorkspaceRoute].
///
/// Upstream holds a React `NavigationContainerRef`; the three members it
/// actually touches are modelled here so navigation decisions stay testable
/// without a live navigator.
abstract interface class WorkspaceRouteNavigator {
  /// Whether the navigator has mounted and can accept actions.
  bool get isReady;

  /// The current root navigation state, read only after [isReady].
  NavigationStackState? getRootState();

  /// Dispatches the raw action produced by
  /// [PopToHostWorkspaceNavigation.toNavigationAction].
  void dispatch(Map<String, Object?> action);
}

WorkspaceRouteNavigator? _rootNavigator;

/// Registers the app's root navigator and returns its unregister callback.
///
/// Library-level mutable state mirrors upstream, where the navigator is a
/// module singleton so any call site can reach it without prop drilling. The
/// unregister callback clears the slot only if it is *still* holding the same
/// navigator, so a late unmount cannot wipe a navigator that has already
/// replaced it.
///
/// Deviation: upstream's ref object (`{ current }`) collapses to a nullable
/// navigator, since Dart has no equivalent indirection. Passing null is the
/// upstream idiom of registering a ref whose `current` is null — it clears the
/// slot.
void Function() registerWorkspaceRouteNavigationRef(
  WorkspaceRouteNavigator? navigator,
) {
  _rootNavigator = navigator;
  return () {
    if (identical(_rootNavigator, navigator)) {
      _rootNavigator = null;
    }
  };
}

/// Navigates to a workspace link, popping the mounted host stack when possible.
///
/// [dismissTo] is the caller's ordinary route navigation, injected rather than
/// imported so the fallback path stays observable in tests (upstream defaults
/// it to `router.dismissTo`).
void navigateToHostWorkspaceRoute(
  String route, {
  required void Function(String route) dismissTo,
}) {
  final navigator = _rootNavigator;
  // Upstream never reads the root state of an unready navigator; the guard is
  // preserved because `getRootState` can throw before mount.
  final isReady = navigator?.isReady ?? false;
  final decision = resolveHostWorkspaceNavigation(
    route: route,
    rootState: isReady ? navigator!.getRootState() : null,
    isReady: isReady,
  );

  switch (decision) {
    case final PopToHostWorkspaceNavigation popTo:
      navigator!.dispatch(popTo.toNavigationAction());
    case DismissToHostWorkspaceNavigation(route: final fallbackRoute):
      dismissTo(fallbackRoute);
  }
}

// ---------------------------------------------------------------------------
// focus-scope.ts
// ---------------------------------------------------------------------------

/// Upstream `KeyboardFocusScope` from `keyboard/actions.ts`, in full.
///
/// Deviation: the repo already has a `KeyboardFocusScope` in
/// `keyboard/shortcut_engine.dart`, but it carries only the four values that
/// port needed (`messageInput`, `editable`, `terminal`, `other`). Dart enums
/// are closed, so this rule — which can also answer `commandCenter` — declares
/// the complete upstream union under its own name rather than modifying the
/// existing enum. `browser` is part of the upstream union but is never
/// produced by [resolveKeyboardFocusScope]; it is assigned elsewhere.
enum PaseoKeyboardFocusScope {
  terminal,
  messageInput,
  commandCenter,
  editable,
  browser,
  other,
}

/// Marks the terminal surface wrapper.
const String terminalSurfaceSelector = "[data-testid='terminal-surface']";

/// Marks xterm's own root, which the terminal surface does not always wrap.
const String xtermSelector = '.xterm';

/// Marks the command center panel.
const String commandCenterPanelSelector =
    "[data-testid='command-center-panel']";

/// Marks the command center's text field, which can be portalled outside the
/// panel and so is matched separately.
const String commandCenterInputSelector =
    "[data-testid='command-center-input']";

/// Marks the message composer root.
const String messageInputRootSelector = "[data-testid='message-input-root']";

/// A node in the focus tree that is *not* an element.
///
/// Upstream distinguishes DOM `Node` from `Element` because a key event can be
/// targeted at a text node, in which case only its parent element is
/// classifiable. Modelled explicitly so that case stays testable — Dart has no
/// ambient DOM, so callers project their own tree onto these two types.
base class FocusTargetNode {
  FocusTargetNode({this.parentElement});

  FocusTargetElement? parentElement;
}

/// An element in the focus tree.
///
/// [selectors] is the set of CSS selectors this element itself matches, which
/// is how [closest] is answered without a real DOM: the walk asks each
/// ancestor in turn, exactly as `Element.closest` does.
final class FocusTargetElement extends FocusTargetNode {
  FocusTargetElement({
    String tagName = 'div',
    Set<String> selectors = const {},
    this.isContentEditable = false,
    super.parentElement,
  }) : tagName = tagName.toUpperCase(),
       selectors = {...selectors};

  /// Upper-cased to match `Element.tagName`, which the rule then lower-cases
  /// before comparing.
  final String tagName;

  final Set<String> selectors;

  final bool isContentEditable;

  /// Nearest self-or-ancestor matching [selector], or null.
  FocusTargetElement? closest(String selector) {
    if (selectors.contains(selector)) return this;
    return parentElement?.closest(selector);
  }
}

/// Tag names that count as editable regardless of `contenteditable`.
const Set<String> _editableTagNames = {'input', 'textarea', 'select'};

List<FocusTargetElement> _focusCandidateElements(
  FocusTargetNode? target,
  FocusTargetElement? activeElement,
) {
  final candidates = <FocusTargetElement>[];
  void pushUnique(FocusTargetElement? element) {
    // Reference identity, matching upstream's `candidates.includes`.
    if (element == null || candidates.contains(element)) return;
    candidates.add(element);
  }

  if (target is FocusTargetElement) pushUnique(target);
  if (target != null) pushUnique(target.parentElement);
  pushUnique(activeElement);

  return candidates;
}

/// Decides which keyboard scope owns an event.
///
/// Candidates are considered in a fixed priority order rather than by
/// specificity, because the scopes overlap: a command center input is also an
/// `<input>`, and a terminal can host one too. Terminal wins outright so raw
/// keys always reach the pty; the command center only claims its own subtree
/// while it is open; and once the command center *is* open, any otherwise
/// unclassified or merely editable focus is attributed to it, since it is the
/// modal surface the user is actually driving.
///
/// Deviation: upstream reads `document.activeElement` from the ambient DOM and
/// degrades to no candidates when `Element`/`Node`/`document` are undefined.
/// Dart has no ambient DOM, so [activeElement] is an explicit parameter, and
/// the "no DOM" case is expressed by passing null for both it and [target].
PaseoKeyboardFocusScope resolveKeyboardFocusScope({
  required FocusTargetNode? target,
  required bool commandCenterOpen,
  FocusTargetElement? activeElement,
}) {
  final candidates = _focusCandidateElements(target, activeElement);
  if (candidates.isEmpty) {
    return commandCenterOpen
        ? PaseoKeyboardFocusScope.commandCenter
        : PaseoKeyboardFocusScope.other;
  }

  bool anyClosest(List<String> selectors) => candidates.any(
    (element) => selectors.any((selector) => element.closest(selector) != null),
  );

  if (anyClosest(const [terminalSurfaceSelector, xtermSelector])) {
    return PaseoKeyboardFocusScope.terminal;
  }

  if (commandCenterOpen &&
      anyClosest(const [
        commandCenterPanelSelector,
        commandCenterInputSelector,
      ])) {
    return PaseoKeyboardFocusScope.commandCenter;
  }

  if (anyClosest(const [messageInputRootSelector])) {
    return PaseoKeyboardFocusScope.messageInput;
  }

  final editable = candidates.any(
    (element) =>
        element.isContentEditable ||
        _editableTagNames.contains(element.tagName.toLowerCase()),
  );
  if (editable) {
    return commandCenterOpen
        ? PaseoKeyboardFocusScope.commandCenter
        : PaseoKeyboardFocusScope.editable;
  }

  return commandCenterOpen
      ? PaseoKeyboardFocusScope.commandCenter
      : PaseoKeyboardFocusScope.other;
}

// ---------------------------------------------------------------------------
// use-rewind-capabilities.ts
// ---------------------------------------------------------------------------

/// What a rewind undoes.
enum RewindMode { conversation, files, both }

/// The three rewind capability flags a provider declares.
///
/// Deviation: upstream takes `Pick<AgentCapabilityFlags, ...>`; the protocol
/// package has no `AgentCapabilityFlags` port yet, so the three fields the
/// rule reads are declared here. When the flags land in the protocol, this
/// becomes a projection of them rather than a new type.
final class RewindCapabilities {
  const RewindCapabilities({
    required this.supportsRewindConversation,
    required this.supportsRewindFiles,
    required this.supportsRewindBoth,
  });

  final bool supportsRewindConversation;
  final bool supportsRewindFiles;
  final bool supportsRewindBoth;
}

/// The labels the rewind menu shows.
final class RewindMenuLabels {
  const RewindMenuLabels({
    required this.conversation,
    required this.files,
    required this.both,
  });

  final String conversation;
  final String files;
  final String both;
}

/// Upstream's `Partial<RewindMenuLabels>`: a null field keeps the default.
///
/// A separate type rather than nullable fields on [RewindMenuLabels] so the
/// merged result stays non-nullable and call sites cannot accidentally render
/// a null label.
final class RewindMenuLabelOverrides {
  const RewindMenuLabelOverrides({this.conversation, this.files, this.both});

  final String? conversation;
  final String? files;
  final String? both;
}

/// English defaults, matching upstream's `DEFAULT_REWIND_MENU_LABELS`.
///
/// Kept here (rather than in the i18n layer) because upstream treats them as
/// the rule's own fallback: a caller that supplies no override gets these.
const RewindMenuLabels defaultRewindMenuLabels = RewindMenuLabels(
  conversation: 'Rewind conversation',
  files: 'Rewind files',
  both: 'Rewind conversation and files',
);

/// One entry in the rewind menu.
final class RewindMenuItem {
  const RewindMenuItem({
    required this.mode,
    required this.label,
    required this.testId,
  });

  final RewindMode mode;
  final String label;

  /// Upstream's `testID`, preserved verbatim so the ported widget tests and
  /// upstream's e2e selectors keep matching.
  final String testId;

  @override
  bool operator ==(Object other) =>
      other is RewindMenuItem &&
      other.mode == mode &&
      other.label == label &&
      other.testId == testId;

  @override
  int get hashCode => Object.hash(mode, label, testId);

  @override
  String toString() => 'RewindMenuItem($mode, $label, $testId)';
}

/// The rewind menu entries a provider's capabilities permit, in menu order.
///
/// Capabilities are checked independently rather than as a hierarchy: a
/// provider may support rewinding files without supporting conversation
/// rewind, so the menu is assembled from whatever it declares. Absent
/// capabilities (null) mean the menu is not showable at all — distinct from a
/// provider that declares all three flags false, though both yield an empty
/// list.
List<RewindMenuItem> resolveRewindMenuItems(
  RewindCapabilities? capabilities, [
  RewindMenuLabelOverrides? labelOverrides,
]) {
  if (capabilities == null) return const [];

  final labels = RewindMenuLabels(
    conversation:
        labelOverrides?.conversation ?? defaultRewindMenuLabels.conversation,
    files: labelOverrides?.files ?? defaultRewindMenuLabels.files,
    both: labelOverrides?.both ?? defaultRewindMenuLabels.both,
  );

  return [
    if (capabilities.supportsRewindConversation)
      RewindMenuItem(
        mode: RewindMode.conversation,
        label: labels.conversation,
        testId: 'rewind-menu-conversation',
      ),
    if (capabilities.supportsRewindFiles)
      RewindMenuItem(
        mode: RewindMode.files,
        label: labels.files,
        testId: 'rewind-menu-files',
      ),
    if (capabilities.supportsRewindBoth)
      RewindMenuItem(
        mode: RewindMode.both,
        label: labels.both,
        testId: 'rewind-menu-both',
      ),
  ];
}
