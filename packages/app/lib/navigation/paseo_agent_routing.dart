/// Ports of Paseo 0.2.0's *agent-addressing* rules — the frozen logic that
/// answers "which agent does this gesture, link, notification or payload refer
/// to, and how do we get there?":
///
/// - `utils/navigate-to-agent/resolve.ts` — turning "open agent X" into either
///   a workspace tab or a bare host agent deep link.
/// - `utils/new-agent-routing.ts` — which agent the "new agent" affordance
///   should inherit from, and which directory it should start in.
/// - `utils/notification-routing.ts` — which route an OS notification opens.
/// - `utils/agent-snapshots.ts` — projecting a wire agent snapshot into the
///   store shape, and keying pending permission prompts.
/// - `utils/client-id.ts` — the stable per-install client identity every
///   connection presents.
///
/// The five live together because each one resolves an *agent identity* from
/// something that is not an agent object: a nav intent, a URL, a notification
/// payload, a wire snapshot, or persistent storage. All are pure (or
/// dependency-injected) so they can be exercised without a router, a store, a
/// notification plugin or a real device.
///
/// Nothing about route syntax is re-derived here. Route building and parsing
/// come from `core/host_routes.dart` (`buildHostAgentDetailRoute`,
/// `buildHostWorkspaceOpenRoute`, `buildHostRootRoute`,
/// `parseHostWorkspaceRouteFromPathname`,
/// `parseHostWorkspaceOpenIntentFromPathname`,
/// `parseHostAgentRouteFromPathname`, and the `HostAgentRoute` /
/// `WorkspaceOpenIntent` types); tab targets come from
/// `workspace/workspace_tab_model.dart`; and the agent snapshot projection
/// reuses `AgentSummary` plus `parentAgentIdFromLabels` from
/// `package:agent_protocol`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';

import '../core/host_routes.dart';
import '../workspace/workspace_tab_model.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Inlined `normalizeWorkspaceOpaqueId` from upstream
/// `utils/workspace-identity.ts`.
///
/// workspace-identity is outside this cluster and the only behaviour these
/// rules need from it is "trim, and treat blank as absent". Kept private so
/// the eventual full port of workspace-identity owns the public name — the
/// same choice `navigation/paseo_route_rules.dart` already made.
String? _normalizeWorkspaceOpaqueId(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// JS string truthiness: `null` and `''` are falsy, everything else is truthy.
///
/// Used wherever upstream chains values with `||`, which — unlike Dart's `??` —
/// also falls through the empty string.
String? _truthyOrNull(String? value) =>
    value == null || value.isEmpty ? null : value;

// ---------------------------------------------------------------------------
// navigate-to-agent/resolve.ts
// ---------------------------------------------------------------------------

/// A request to open a particular agent.
final class NavigateToAgentInput {
  const NavigateToAgentInput({
    required this.serverId,
    required this.agentId,
    this.workspaceId,
    this.pin,
  });

  final String serverId;
  final String agentId;

  /// The workspace to treat as the agent's home when the agent is not yet in
  /// the session store — that is, cold deep links. When absent the workspace
  /// is read from the store instead, via
  /// [NavigateToAgentDependencies.readAgentNavTarget].
  final String? workspaceId;

  /// Whether the opened tab should be pinned.
  ///
  /// Nullable rather than defaulted to false because upstream forwards
  /// `pin: undefined` verbatim to `navigateToWorkspace`, which distinguishes
  /// "caller said nothing" from "caller said no".
  final bool? pin;
}

/// What the session store knows about an agent's whereabouts.
///
/// A one-field class rather than a bare `String?` so the "store answered with
/// nothing" case stays distinguishable from "the store was never asked", which
/// is what the laziness contract below turns on.
final class AgentNavTarget {
  const AgentNavTarget({required this.agentWorkspaceId});

  final String? agentWorkspaceId;
}

/// The store and router seams [resolveNavigateToAgent] drives.
///
/// Injected rather than imported so the decision stays observable in tests:
/// upstream's own suite asserts that [readAgentNavTarget] is *not* called when
/// the caller already supplied a workspace id.
final class NavigateToAgentDependencies {
  const NavigateToAgentDependencies({
    required this.readAgentNavTarget,
    required this.navigateToHostAgent,
    required this.navigateToWorkspace,
  });

  /// Reads the agent's workspace from the session store.
  final AgentNavTarget Function({
    required String serverId,
    required String agentId,
  })
  readAgentNavTarget;

  /// Navigates to a bare `/h/:serverId/agent/:agentId` deep link.
  final void Function(String route) navigateToHostAgent;

  /// Opens the agent inside its workspace, returning the resulting route.
  ///
  /// Deviation: upstream passes a `NavigateToWorkspaceInput` object. Declaring
  /// a Dart mirror of it would duplicate a store type this cluster does not
  /// own, so the fields arrive as named parameters and [WorkspaceTabTarget]
  /// (from `workspace/workspace_tab_model.dart`) carries the target as-is.
  final String Function({
    required String serverId,
    required String workspaceId,
    required WorkspaceTabTarget target,
    bool? pin,
  })
  navigateToWorkspace;
}

/// Opens an agent, returning the route that was navigated to.
///
/// The rule exists because an agent can be addressed two ways and only one of
/// them survives a cold start: a workspace tab is richer (it keeps the deck,
/// the diff pane and the terminal alongside the conversation) but requires
/// knowing which workspace owns the agent. When that is unknown — an
/// unhydrated store, a deleted workspace, a link from another device — the
/// bare host agent route still resolves, and the agent route screen takes over
/// the lookup from there. So the workspace path is preferred and the host
/// route is the always-available fallback, never an error.
///
/// [NavigateToAgentInput.workspaceId] short-circuits the store read entirely
/// (Dart's `??` short-circuits exactly like JS's), which is what makes cold
/// deep links work before the session store has hydrated.
String resolveNavigateToAgent(
  NavigateToAgentInput input,
  NavigateToAgentDependencies dependencies,
) {
  final agentWorkspaceId =
      input.workspaceId ??
      dependencies
          .readAgentNavTarget(serverId: input.serverId, agentId: input.agentId)
          .agentWorkspaceId;
  final workspaceId = _normalizeWorkspaceOpaqueId(agentWorkspaceId);

  if (workspaceId == null) {
    final route = buildHostAgentDetailRoute(input.serverId, input.agentId);
    dependencies.navigateToHostAgent(route);
    return route;
  }

  return dependencies.navigateToWorkspace(
    serverId: input.serverId,
    workspaceId: workspaceId,
    target: WorkspaceAgentTabTarget(agentId: input.agentId),
    pin: input.pin,
  );
}

// ---------------------------------------------------------------------------
// new-agent-routing.ts
// ---------------------------------------------------------------------------

/// Splits a `"<serverId>:<agentId>"` selection key.
///
/// The *last* colon separates, not the first, because host ids are routinely
/// `host:port` (`"localhost:6767:agent-9"` must yield server `localhost:6767`).
///
/// Returns [HostAgentRoute] — the existing `core/host_routes.dart` pair type —
/// rather than a new server+agent record, since the two are structurally and
/// semantically identical and a second type would only invite conversions.
///
/// Deviation: upstream's `if (!key)` is a JS falsy check that rejects `null`,
/// `undefined` and `''`; whitespace-only keys pass it and are rejected later by
/// the trimmed emptiness checks. Reproduced exactly — [key] is tested with
/// `isEmpty`, deliberately not trimmed, before the separator scan.
HostAgentRoute? parseAgentKey(String? key) {
  if (key == null || key.isEmpty) return null;

  final separator = key.lastIndexOf(':');
  // A leading separator has no server id; a trailing one has no agent id.
  if (separator <= 0 || separator >= key.length - 1) return null;

  final serverId = key.substring(0, separator).trim();
  final agentId = key.substring(separator + 1).trim();
  if (serverId.isEmpty || agentId.isEmpty) return null;

  return HostAgentRoute(serverId: serverId, agentId: agentId);
}

/// Which agent the "new agent" affordance should inherit context from.
///
/// The current route wins over the sidebar selection because the route is what
/// the user is actually looking at: a workspace URL carrying `?open=agent:…`
/// names the visible conversation, and a bare agent deep link names it
/// directly. Only when the route names no agent at all does the remembered
/// [selectedAgentId] apply, so switching tabs never leaves the new-agent flow
/// pointing at a conversation that scrolled off screen.
///
/// Both parsers come from `core/host_routes.dart`; this rule contributes only
/// the precedence.
HostAgentRoute? resolveSelectedAgentForNewAgent({
  required String pathname,
  String? selectedAgentId,
}) {
  final workspaceRoute = parseHostWorkspaceRouteFromPathname(pathname);
  final openIntent = parseHostWorkspaceOpenIntentFromPathname(pathname);
  if (workspaceRoute != null && openIntent is AgentWorkspaceOpenIntent) {
    // Upstream re-trims here. `parseWorkspaceOpenIntent` already trims the
    // payload and rejects a blank one, so the guard can never fail; it is kept
    // so the rule does not silently depend on that invariant.
    final agentId = openIntent.agentId.trim();
    if (agentId.isNotEmpty) {
      return HostAgentRoute(
        serverId: workspaceRoute.serverId,
        agentId: agentId,
      );
    }
  }
  return parseHostAgentRouteFromPathname(pathname) ??
      parseAgentKey(selectedAgentId);
}

/// The Paseo-owned worktree marker, as it appears once separators are
/// normalised to forward slashes.
const String _paseoWorktreeMarker = '/.paseo/worktrees';

/// Recovers the repository a Paseo-owned worktree was cut from, by path shape
/// alone.
///
/// This is the no-metadata fallback: when the daemon has not (yet) reported
/// checkout status, the path itself still says where the main checkout is,
/// because Paseo always nests worktrees at `<repo>/.paseo/worktrees/<name>`.
///
/// The marker must be preceded by something (`markerIndex <= 0` rejects a cwd
/// that *is* `/.paseo/worktrees`, which has no parent repo) and followed by
/// either nothing or a separator, so an unrelated directory such as
/// `/repo/.paseo/worktrees-backup` is not mistaken for one.
///
/// Deviation: upstream indexes past the end of the string and relies on
/// `undefined` being falsy; Dart would throw, so the bounds check is explicit.
/// `cwd.slice(0, markerIndex)` is applied to the *original* cwd, which is safe
/// because separator normalisation is length-preserving — that is what lets a
/// Windows path come back with its backslashes intact.
String? _inferMainRepoRootFromPaseoWorktreePath(String cwd) {
  final normalizedPath = cwd.replaceAll(r'\', '/');
  final markerIndex = normalizedPath.indexOf(_paseoWorktreeMarker);
  if (markerIndex <= 0) return null;

  final markerEnd = markerIndex + _paseoWorktreeMarker.length;
  final nextChar = markerEnd < normalizedPath.length
      ? normalizedPath[markerEnd]
      : null;
  if (nextChar != null && nextChar != '/') return null;

  // Non-global `/[\\/]+$/`: strips the whole trailing separator run, once.
  final inferred = cwd
      .substring(0, markerIndex)
      .replaceFirst(RegExp(r'[\\/]+$'), '');
  return inferred.trim().isEmpty ? null : inferred;
}

/// Where a newly created agent should start.
///
/// A new agent launched from inside a Paseo-owned worktree belongs in the
/// *main* checkout, not the worktree: the worktree is scoped to some other
/// agent's task and inheriting it would silently entangle two unrelated runs.
/// Authoritative checkout metadata is preferred, path inference is the
/// fallback when the daemon has not reported yet, and an ordinary directory is
/// simply used as-is.
///
/// [checkout] is the protocol's [CheckoutStatusPayload]; only
/// `isPaseoOwnedWorktree` and `mainRepoRoot` are read, and a blank
/// `mainRepoRoot` is treated as absent (upstream's `?.trim() || null`).
String resolveNewAgentWorkingDir(String cwd, CheckoutStatusPayload? checkout) {
  final explicitMainRepoRoot = checkout != null && checkout.isPaseoOwnedWorktree
      ? _truthyOrNull(checkout.mainRepoRoot?.trim())
      : null;
  if (explicitMainRepoRoot != null) {
    return explicitMainRepoRoot;
  }

  return _inferMainRepoRootFromPaseoWorktreePath(cwd) ?? cwd;
}

// ---------------------------------------------------------------------------
// notification-routing.ts
// ---------------------------------------------------------------------------

/// The identifiers an OS notification payload can carry.
///
/// Every field is independently nullable because notifications are produced by
/// several daemon versions and surfaces; the route rule below is what decides
/// which *combinations* are actionable.
final class NotificationTarget {
  const NotificationTarget({
    required this.serverId,
    required this.agentId,
    required this.workspaceId,
    required this.terminalId,
  });

  final String? serverId;
  final String? agentId;
  final String? workspaceId;
  final String? terminalId;

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.serverId == serverId &&
      other.agentId == agentId &&
      other.workspaceId == workspaceId &&
      other.terminalId == terminalId;

  @override
  int get hashCode => Object.hash(serverId, agentId, workspaceId, terminalId);

  @override
  String toString() =>
      'NotificationTarget($serverId, $agentId, $workspaceId, $terminalId)';
}

/// Reads [key] from a notification payload, keeping only non-blank strings.
///
/// Deviation: upstream's payload is `Record<string, unknown>`; Dart's analogue
/// is `Map<String, Object?>`, and the `typeof value !== "string"` guard becomes
/// an `is String` test. Both reject a numeric or object-valued field.
String? _readNonEmptyString(Map<String, Object?>? data, String key) {
  final value = data?[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Extracts the addressable ids from a notification payload.
///
/// Only these four keys are read. In particular `cwd` is deliberately *not*
/// accepted as a workspace id: a path and a workspace id are different
/// identities, and conflating them would open the wrong workspace whenever two
/// workspaces share a checkout.
NotificationTarget resolveNotificationTarget(Map<String, Object?>? data) =>
    NotificationTarget(
      serverId: _readNonEmptyString(data, 'serverId'),
      agentId: _readNonEmptyString(data, 'agentId'),
      workspaceId: _readNonEmptyString(data, 'workspaceId'),
      terminalId: _readNonEmptyString(data, 'terminalId'),
    );

/// The route a notification click should open.
///
/// The ladder degrades rather than failing: a fully addressed agent or
/// terminal opens its workspace tab, an incomplete payload still lands the
/// user on the right host, and a payload with no host at all lands on the app
/// root. A notification click therefore always goes *somewhere* useful — which
/// matters because the payload was serialised by whichever daemon version was
/// running when the notification was posted.
///
/// Note that an agent id without a workspace id does **not** become an agent
/// deep link: the notification cannot prove the agent still exists on that
/// host, so it stops at the host root instead of risking a dead end.
///
/// Route construction is entirely `core/host_routes.dart`'s
/// [buildHostWorkspaceOpenRoute] / [buildHostRootRoute].
String buildNotificationRoute(Map<String, Object?>? data) {
  final target = resolveNotificationTarget(data);
  final serverId = target.serverId;
  final workspaceId = target.workspaceId;

  if (serverId != null && workspaceId != null && target.agentId != null) {
    return buildHostWorkspaceOpenRoute(
      serverId,
      workspaceId,
      'agent:${target.agentId}',
    );
  }
  if (serverId != null && workspaceId != null && target.terminalId != null) {
    return buildHostWorkspaceOpenRoute(
      serverId,
      workspaceId,
      'terminal:${target.terminalId}',
    );
  }
  if (serverId != null) {
    return buildHostRootRoute(serverId);
  }
  return '/';
}

// ---------------------------------------------------------------------------
// agent-snapshots.ts
// ---------------------------------------------------------------------------

/// A permission prompt awaiting the user, as carried on an agent snapshot.
///
/// Deviation: `package:agent_protocol` has no `AgentPermissionRequest` port
/// yet — its `PermissionItem` is a *timeline* item with an entirely different
/// shape (`permissionId`/`toolName`/`status`/`detail`). The fields
/// [derivePendingPermissionKey] actually reads are therefore declared here, the
/// same way `navigation/paseo_route_rules.dart` declares `RewindCapabilities`.
/// When the protocol gains the full type this becomes a projection of it.
final class AgentPermissionRequest {
  const AgentPermissionRequest({
    this.id = '',
    this.name = '',
    this.kind = '',
    this.title,
    this.input,
    this.metadata,
  });

  /// The provider-assigned request id. Upstream types this as required but
  /// falls through it with `||`, so an empty id is a real, handled case.
  final String id;

  final String name;

  /// `"tool" | "plan" | "question" | "mode" | "other"` upstream. Kept as a
  /// raw string because it is only ever concatenated into the fallback key —
  /// narrowing it to an enum here would reject provider values this rule is
  /// meant to tolerate.
  final String kind;

  final String? title;

  final Map<String, Object?>? input;

  final Map<String, Object?>? metadata;
}

/// `JSON.stringify` for the permission-key fallback.
///
/// Dart maps preserve insertion order and `jsonEncode` walks them in that
/// order, matching `JSON.stringify`'s own key ordering for string keys.
///
/// Deviation: `JSON.stringify` silently drops keys whose value is `undefined`
/// or a function, and throws only on cycles; `jsonEncode` throws on anything it
/// cannot encode. Unencodable values are routed through `toString()` so a key
/// is always produced — an exception here would break the permission list
/// rather than merely key it oddly.
String _stringifyForPermissionKey(Map<String, Object?> value) =>
    jsonEncode(value, toEncodable: (object) => object.toString());

/// A stable key for a pending permission prompt, scoped to its agent.
///
/// Permission prompts have to be de-duplicated and reconciled across snapshot
/// pushes, but not every provider supplies a durable request id. The waterfall
/// therefore walks from most to least stable — request id, a metadata id, the
/// tool name, the human title — and only if all of those are blank does it
/// synthesise a content key from the request's own payload, which is stable for
/// as long as the request is.
///
/// Deviation: upstream chains with `||`, so an *empty string* falls through
/// just like a missing value. Dart's `??` would not, so [_truthyOrNull]
/// reproduces JS truthiness explicitly at each rung.
String derivePendingPermissionKey(
  String agentId,
  AgentPermissionRequest request,
) {
  final metadataId = request.metadata?['id'];
  final fallbackId =
      _truthyOrNull(request.id) ??
      _truthyOrNull(metadataId is String ? metadataId : null) ??
      _truthyOrNull(request.name) ??
      _truthyOrNull(request.title) ??
      '${request.kind}:'
          '${_stringifyForPermissionKey(request.input ?? request.metadata ?? const {})}';

  return '$agentId:$fallbackId';
}

/// A wire agent snapshot projected into the shape the client stores.
///
/// Deviation: upstream returns an anonymous object that flattens the whole
/// snapshot alongside its derived fields. Here [agent] carries the snapshot's
/// own fields — it is `package:agent_protocol`'s [AgentSummary], which
/// `PaseoAgentSnapshotCodec.decode` already produces from the raw
/// `AgentSnapshotPayload` JSON — and this class adds only what the upstream
/// function actually *derives*. Re-declaring an `AgentSnapshotPayload` mirror
/// would duplicate a protocol type that is already ported.
final class NormalizedAgentSnapshot {
  const NormalizedAgentSnapshot({
    required this.serverId,
    required this.agent,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUserMessageAt,
    required this.lastActivityAt,
    required this.attentionTimestamp,
    required this.archivedAt,
    required this.parentAgentId,
  });

  /// The host this snapshot arrived from. Snapshots are host-scoped but the
  /// wire payload does not repeat the host, so the caller supplies it.
  final String serverId;

  /// The decoded snapshot itself.
  final AgentSummary agent;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUserMessageAt;

  /// Aliases [updatedAt]. Upstream keeps the second name because sort order and
  /// "last active" copy read from it, and the two are expected to diverge once
  /// activity stops being inferred from the snapshot's own mtime.
  final DateTime lastActivityAt;

  final DateTime? attentionTimestamp;
  final DateTime? archivedAt;

  /// The delegating parent, derived from the agent's *labels*.
  ///
  /// Takes precedence over [AgentSummary.parentAgentId], which
  /// `PaseoAgentSnapshotCodec.decode` fills from the payload's `parentAgentId`
  /// / `managedBy` fields. The label is the authoritative signal for
  /// daemon-managed delegation; the other two are legacy shapes.
  final String? parentAgentId;
}

/// Coerces an ISO timestamp field, honouring JS truthiness on the source.
///
/// Deviation: upstream writes `value ? new Date(value) : null`, so `''` yields
/// null but an unparsable non-empty string yields an *Invalid Date* object
/// rather than null. Dart has no Invalid Date, so unparsable input collapses to
/// null. Observably this only differs for corrupt timestamps, where upstream's
/// value formats as `"Invalid Date"` and every comparison against it is false —
/// i.e. both spellings mean "no usable time".
DateTime? _parseSnapshotTimestamp(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

/// Projects a decoded agent snapshot into the client's store shape.
///
/// Timestamps arrive as ISO strings on the wire but every consumer wants
/// comparable values, so they are parsed exactly once, here, rather than at
/// each sort and each relative-time label.
///
/// [snapshot] is expected to have come from
/// `PaseoAgentSnapshotCodec.decode`, which is the repo's existing port of the
/// `AgentSnapshotPayload` wire shape; this function deliberately does not
/// re-parse JSON.
///
/// Deviation: upstream's schema requires `updatedAt`, while [AgentSummary]
/// makes it optional. A missing or unparsable `updatedAt` falls back to
/// [createdAt] — the same convention `PaseoAgentSnapshotCodec.encode` uses when
/// it writes the field back out.
NormalizedAgentSnapshot normalizeAgentSnapshot({
  required AgentSummary snapshot,
  required String serverId,
}) {
  final createdAt = DateTime.fromMillisecondsSinceEpoch(
    snapshot.createdAtMs,
    isUtc: true,
  );
  final updatedAt = _parseSnapshotTimestamp(snapshot.updatedAt) ?? createdAt;

  return NormalizedAgentSnapshot(
    serverId: serverId,
    agent: snapshot,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastUserMessageAt: _parseSnapshotTimestamp(snapshot.lastUserMessageAt),
    lastActivityAt: updatedAt,
    attentionTimestamp: _parseSnapshotTimestamp(snapshot.attentionTimestamp),
    archivedAt: _parseSnapshotTimestamp(snapshot.archivedAt),
    // `parentAgentIdFromLabels` is `package:agent_protocol`'s port of upstream
    // `getParentAgentIdFromLabels`, trimming included.
    parentAgentId: parentAgentIdFromLabels(snapshot.labels),
  );
}

// ---------------------------------------------------------------------------
// client-id.ts
// ---------------------------------------------------------------------------

/// The storage key the client id has lived under since v1.
///
/// Exposed so callers can migrate or inspect it; changing it would hand every
/// existing install a brand-new identity.
const String defaultClientIdStorageKey = '@paseo:client-id-v1';

/// The key/value persistence the client id needs.
///
/// Deviated from upstream's direct `AsyncStorage` import on purpose: an
/// interface keeps the resolver testable and lets the app supply whichever
/// backing store the platform has, since this repo has no AsyncStorage.
abstract interface class ClientIdStorage {
  Future<String?> getItem(String key);

  Future<void> setItem(String key, String value);
}

/// Blank stored values are treated as absent, so a truncated or partially
/// written record self-heals into a fresh id instead of being presented to the
/// daemon as an identity.
///
/// Deviation: upstream also guards `typeof value !== "string"` because
/// AsyncStorage is untyped; [ClientIdStorage.getItem] is already `String?`, so
/// only the blank check survives.
String? _normalizeStoredClientId(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Resolves — and on first run creates — this install's stable client id.
///
/// The id has to be *stable* (the daemon uses it to reconcile sessions across
/// reconnects) and *created exactly once*, which is why this is a stateful
/// resolver rather than a function: it memoises the resolved id and collapses
/// concurrent first-run callers onto a single storage write, so two screens
/// racing at startup cannot mint two identities.
final class ClientIdResolver {
  ClientIdResolver({
    required this.storage,
    required this.generateUuid,
    this.storageKey = defaultClientIdStorageKey,
  });

  /// Where the id is persisted.
  final ClientIdStorage storage;

  /// Injected rather than called directly so the identity is deterministic in
  /// tests; see [createRandomClientIdGenerator] for the production generator.
  ///
  /// Deviation: upstream closes over these three dependencies inside a factory
  /// function and exposes only `getOrCreate`. Dart's `prefer_initializing_formals`
  /// style makes them plain fields instead; they stay read-only, so the
  /// observable surface is unchanged.
  final String Function() generateUuid;

  /// Defaults to [defaultClientIdStorageKey].
  final String storageKey;

  String? _cached;
  Future<String>? _inFlight;

  /// Returns the stored client id, creating and persisting one if needed.
  ///
  /// A failed read or write leaves both the cache and the in-flight slot clear,
  /// so the next caller retries rather than inheriting a poisoned future.
  Future<String> getOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    final pending = _inFlight;
    if (pending != null) return pending;

    // Synchronous up to the first suspension inside `_resolve`, which is what
    // lets a caller arriving in the same microtask observe `_inFlight` and
    // join it instead of starting a second write — matching upstream's
    // synchronously-invoked async IIFE.
    final future = _resolve();
    _inFlight = future;
    try {
      return await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<String> _resolve() async {
    final stored = await storage.getItem(storageKey);
    final existing = _normalizeStoredClientId(stored);
    if (existing != null) {
      _cached = existing;
      return existing;
    }

    final next = 'cid_${generateUuid()}';
    await storage.setItem(storageKey, next);
    _cached = next;
    return next;
  }
}

/// A `generateUuid` implementation matching upstream's
/// `crypto.randomUUID().replace(/-/g, "")`: 32 lowercase hex characters of a
/// version-4 UUID with its dashes removed.
///
/// [random] is a parameter rather than an internal `Random.secure()` so the
/// generated identity stays reproducible under test. Production callers should
/// pass `Random.secure()`.
///
/// Deviation: upstream also carries a
/// `Date.now().toString(36) + Math.random().toString(36).slice(2)` fallback for
/// JS runtimes with no `crypto.randomUUID`. Dart's `Random` is always
/// available, so there is no branch to fall back *from* and the fallback is not
/// ported; the format it produced was never part of any contract.
String Function() createRandomClientIdGenerator(Random random) {
  return () {
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // RFC 4122 version 4 / variant bits, as `crypto.randomUUID` sets them.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  };
}
