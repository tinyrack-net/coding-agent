/// Ports of five frozen Paseo 0.2.0 zustand stores — the *pure* half of each
/// one (state shape, transitions, persist/migration), lifted out of React and
/// zustand so the decisions can be exercised without a widget tree:
///
/// - `stores/browser-store/state.ts` (+ the actions/persist in its `index.ts`)
/// - `stores/sidebar-collapsed-sections-store/state.ts` (+ `index.ts`)
/// - `stores/sidebar-view-store.ts`
/// - `stores/navigation-active-workspace-store/navigation.ts`
/// - `stores/draft-store/migration.ts`
///
/// ## Why plain classes rather than Riverpod providers
///
/// Upstream these are zustand stores: a mutable state object plus actions,
/// with a persist middleware wrapped around them. The Riverpod providers in
/// this package own *app wiring* (`SharedPreferences`, `ref` lifecycles); the
/// rules below own *behaviour*. Keeping them apart is what lets the behaviour
/// be tested against the upstream suites without a `ProviderContainer`, and
/// what lets a future provider adopt them without re-deriving the semantics.
/// Every store here therefore takes its storage and its clock as constructor
/// arguments — nothing in this library reads `DateTime.now()`.
///
/// ## Reuse
///
/// This library deliberately does not re-declare anything the repo already
/// ports. It reuses [SidebarGroupMode], [MutableKeyValueStorage],
/// [AttachmentMetadata], [ComposerWorkspaceFileSelection],
/// [ComposerDraftLifecycle], [ForgeSearchItem], [UploadedFileAttachment],
/// [HostWorkspaceRoute] and the host-route builders, [prepareWorkspaceTab],
/// the [WorkspaceTabTarget] hierarchy, and [pickAttentionAgent].
///
/// ## JS semantics reproduced deliberately
///
/// Several upstream branches lean on JavaScript idioms with no Dart analogue.
/// Each one is reproduced and flagged at its use site:
///
/// - **Truthiness** (`!persisted?.collapsedProjectKeys`) is *not* null checks —
///   `0`, `""` and `false` are falsy while `[]` and `{}` are truthy. See
///   [jsTruthy].
/// - **`??` is nullish, not falsy** — `patch.url ?? existing.url` keeps an
///   empty-string patch. Modelled with explicit "absent" sentinels rather than
///   nullability where the distinction is observable.
/// - **Object/Map/Set iteration order** is insertion order in both languages
///   for string keys, so `Object.entries`/`Array.from(set)` map onto Dart's
///   `LinkedHashMap`/`LinkedHashSet` directly. The one divergence — V8 hoists
///   integer-like string keys ahead of the rest — is noted where it could
///   matter.
/// - **`Array.sort` is stable in V8 but `List.sort` is not in Dart**, so every
///   comparator here carries an original-index tiebreak.
library;

import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart'
    show AgentSummary, ForgeSearchItem, ForgeSearchKind, WorkspaceDescriptor;

import '../attachments/attachment_store.dart'
    show AttachmentMetadata, AttachmentStorageType;
import '../composer/composer_draft_store.dart'
    show
        ComposerDraftLifecycle,
        ComposerWorkspaceFileSelection,
        newWorkspaceComposerDraftKey;
import '../core/host_routes.dart'
    show
        HostWorkspaceRoute,
        buildHostWorkspaceOpenRoute,
        buildHostWorkspaceRoute,
        decodeWorkspaceIdFromPathSegment,
        parseHostWorkspaceRouteFromPathname;
import '../core/paseo_app_misc.dart' show MutableKeyValueStorage;
import '../core/paseo_session_projection.dart' show SidebarGroupMode;
import '../workspace/prepare_workspace_tab.dart'
    show
        PrepareWorkspaceTabDependencies,
        PrepareWorkspaceTabInput,
        prepareWorkspaceTab;
import '../workspace/workspace_tab_model.dart'
    show WorkspaceAgentTabTarget, WorkspaceTabTarget;
import 'agent_attention.dart' show pickAttentionAgent;

// Re-exported because they appear in this library's public signatures, so a
// consumer should not have to know which module each one was originally ported
// into.
export '../attachments/attachment_store.dart'
    show AttachmentMetadata, AttachmentStorageType;
export '../composer/composer_draft_store.dart'
    show ComposerDraftLifecycle, ComposerWorkspaceFileSelection;
export '../core/paseo_session_projection.dart' show SidebarGroupMode;

// ---------------------------------------------------------------------------
// Shared JavaScript-semantics helpers
// ---------------------------------------------------------------------------

/// JavaScript truthiness for a decoded-JSON value.
///
/// Upstream guards such as `if (!persisted?.collapsedProjectKeys)` and
/// `...(value.mimeType ? { mimeType } : {})` are falsy tests, not null tests.
/// The difference is observable: an empty array or empty object is *truthy* in
/// JS (so an empty persisted list still counts as "present"), while `0`, `-0`,
/// `NaN`, `""` and `false` are falsy (so an empty string mime type is dropped).
bool jsTruthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is String) return value.isNotEmpty;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

/// Upstream's ubiquitous `trimNonEmpty`: a trimmed copy, or null when the value
/// is not a string or trims away to nothing.
///
/// Exported because `browser-store/state.ts` exports it and its `index.ts`
/// consumes it for id normalisation.
String? trimNonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Upstream's `isRecord`: a JSON object, excluding `null` and arrays.
///
/// `jsonDecode` never produces a Dart `List` for a JS object, so the
/// array-exclusion arm only matters when a caller hands in a hand-built value.
Map<String, Object?>? asJsonObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return null;
}

// ===========================================================================
// 1. browser-store/state.ts
// ===========================================================================

/// The default a browser tab opens on when it is given nothing usable.
const String defaultBrowserUrl = 'https://example.com';

/// Hosts that mean "something running on this machine" and therefore default
/// to `http` rather than `https`: `localhost`, a dotted-quad IPv4 literal, or a
/// bracketed IPv6 literal — each optionally with a port, and terminated by the
/// end of the string or a path/query/fragment delimiter.
final RegExp _localHostishPattern = RegExp(
  r'^(localhost|\d{1,3}(?:\.\d{1,3}){3}|\[[\da-fA-F:.]+\])(?::\d+)?(?:[/?#]|$)',
);

/// An explicit scheme, e.g. `https:`, `file:` or `chrome-extension:`.
final RegExp _explicitSchemePattern = RegExp(r'^[a-zA-Z][a-zA-Z\d+.-]*:');

/// Turns whatever the user typed into an absolute URL.
///
/// The ordering matters and is upstream's: local hosts win over the generic
/// `https` default so `localhost:8081` is not silently upgraded to a scheme no
/// dev server is listening on; an explicit scheme is always preserved; a
/// protocol-relative `//host` inherits `https`.
String normalizeBrowserUrl(String? value) {
  final trimmed = trimNonEmpty(value);
  if (trimmed == null) return defaultBrowserUrl;
  if (_localHostishPattern.hasMatch(trimmed)) return 'http://$trimmed';
  if (_explicitSchemePattern.hasMatch(trimmed)) return trimmed;
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  return 'https://$trimmed';
}

/// One browser tab the workspace owns.
///
/// [isLoading] and [lastError] are transient: they describe an in-flight
/// navigation and are cleared before the record is written to storage (see
/// [sanitizeBrowsersForPersist]), so a restored session never starts wedged on
/// a spinner or an error banner from a previous run.
final class BrowserRecord {
  const BrowserRecord({
    required this.browserId,
    required this.url,
    required this.title,
    required this.isLoading,
    required this.canGoBack,
    required this.canGoForward,
    required this.faviconUrl,
    required this.lastError,
    required this.createdAt,
  });

  /// Restores a persisted record.
  ///
  /// DEVIATION: upstream performs no validation on rehydrate at all — zustand's
  /// default shallow merge drops the raw JSON straight into `browsersById`, so
  /// a corrupt blob yields a half-typed record that only fails when something
  /// reads it. Dart has to decode, so missing or wrongly-typed fields fall back
  /// to the same values [createBrowserRecord] would have used. The failure mode
  /// is strictly gentler, never stricter: no input that upstream keeps is
  /// dropped here.
  factory BrowserRecord.fromJson(String browserId, Map<String, Object?> json) {
    final createdAt = json['createdAt'];
    return BrowserRecord(
      browserId: browserId,
      url: normalizeBrowserUrl(
        json['url'] is String ? json['url'] as String : null,
      ),
      title: json['title'] is String ? json['title'] as String : '',
      isLoading: json['isLoading'] == true,
      canGoBack: json['canGoBack'] == true,
      canGoForward: json['canGoForward'] == true,
      faviconUrl: json['faviconUrl'] is String
          ? json['faviconUrl'] as String
          : null,
      lastError: json['lastError'] is String
          ? json['lastError'] as String
          : null,
      createdAt: createdAt is num ? createdAt.toInt() : 0,
    );
  }

  final String browserId;
  final String url;
  final String title;
  final bool isLoading;
  final bool canGoBack;
  final bool canGoForward;
  final String? faviconUrl;
  final String? lastError;

  /// Epoch milliseconds, supplied by the caller's clock.
  final int createdAt;

  Map<String, Object?> toJson() => {
    'browserId': browserId,
    'url': url,
    'title': title,
    'isLoading': isLoading,
    'canGoBack': canGoBack,
    'canGoForward': canGoForward,
    'faviconUrl': faviconUrl,
    'lastError': lastError,
    'createdAt': createdAt,
  };
}

/// Wraps a patch field so "absent" and "explicitly null" stay distinguishable.
///
/// Upstream's patch type is `Partial<Omit<BrowserRecord, …>>` and is applied
/// with object spread, where a key that is present with value `null` clears the
/// field and a key that is missing leaves it alone. Dart's `null` cannot carry
/// both meanings, so nullable patch fields are boxed.
final class PatchField<T> {
  const PatchField(this.value);

  final T value;
}

/// A partial update to a [BrowserRecord]. `browserId` and `createdAt` are
/// omitted upstream and here — identity and birth time are never patched.
///
/// The non-nullable upstream fields ([url], [title], [isLoading], [canGoBack],
/// [canGoForward]) use plain nullability for "absent" because they can never
/// legitimately be null. The two nullable fields are boxed in [PatchField].
final class BrowserRecordPatch {
  const BrowserRecordPatch({
    this.url,
    this.title,
    this.isLoading,
    this.canGoBack,
    this.canGoForward,
    this.faviconUrl,
    this.lastError,
  });

  final String? url;
  final String? title;
  final bool? isLoading;
  final bool? canGoBack;
  final bool? canGoForward;
  final PatchField<String?>? faviconUrl;
  final PatchField<String?>? lastError;
}

/// The persisted half of the browser store: every known tab, keyed by id.
///
/// DEVIATION: upstream's helpers are generic over `S extends BrowserIndexState`
/// so a caller can thread extra store fields through them. Dart has no object
/// spread to preserve those extra fields, and the only upstream caller is the
/// store itself, so the helpers are monomorphic. The reference-identity
/// contract the upstream tests assert (an unchanged update returns the *same*
/// object) is preserved.
final class BrowserIndexState {
  const BrowserIndexState({required this.browsersById});

  const BrowserIndexState.empty() : browsersById = const {};

  /// Insertion-ordered, matching JS object key order.
  ///
  /// DEVIATION: V8 enumerates integer-like string keys ("0", "12") ahead of all
  /// other keys regardless of insertion order; Dart's `LinkedHashMap` does not.
  /// Browser ids are UUIDs upstream, so no real key is integer-like and the
  /// orders coincide.
  final Map<String, BrowserRecord> browsersById;

  Map<String, Object?> toJson() => {
    'browsersById': {
      for (final entry in browsersById.entries) entry.key: entry.value.toJson(),
    },
  };
}

/// Builds the record a freshly opened tab starts from: URL normalised, every
/// navigation flag idle, no error.
BrowserRecord createBrowserRecord({
  required String browserId,
  required String? initialUrl,
  required int now,
}) => BrowserRecord(
  browserId: browserId,
  url: normalizeBrowserUrl(initialUrl),
  title: '',
  isLoading: false,
  canGoBack: false,
  canGoForward: false,
  faviconUrl: null,
  lastError: null,
  createdAt: now,
);

/// Applies [patch] to the record named by [browserId].
///
/// Returns the *same* [state] instance — checked with `identical` by callers
/// and by the upstream suite — when the id is blank, when the id is unknown, or
/// when the patch is a no-op. That identity is what stops a React re-render
/// upstream and is preserved here so a Riverpod adopter gets the same free
/// bail-out.
BrowserIndexState applyBrowserPatch(
  BrowserIndexState state,
  String browserId,
  BrowserRecordPatch patch,
) {
  final normalizedBrowserId = trimNonEmpty(browserId);
  if (normalizedBrowserId == null) return state;
  final existing = state.browsersById[normalizedBrowserId];
  if (existing == null) return state;

  // `patch.url ?? existing.url` is nullish coalescing upstream, so a patch that
  // carries an empty string uses the empty string (and normalises to the
  // default URL) rather than falling back to the existing one.
  final nextRecord = BrowserRecord(
    browserId: existing.browserId,
    url: normalizeBrowserUrl(patch.url ?? existing.url),
    title: patch.title ?? existing.title,
    isLoading: patch.isLoading ?? existing.isLoading,
    canGoBack: patch.canGoBack ?? existing.canGoBack,
    canGoForward: patch.canGoForward ?? existing.canGoForward,
    faviconUrl: patch.faviconUrl == null
        ? existing.faviconUrl
        : patch.faviconUrl!.value,
    lastError: patch.lastError == null
        ? existing.lastError
        : patch.lastError!.value,
    createdAt: existing.createdAt,
  );

  if (nextRecord.url == existing.url &&
      nextRecord.title == existing.title &&
      nextRecord.isLoading == existing.isLoading &&
      nextRecord.canGoBack == existing.canGoBack &&
      nextRecord.canGoForward == existing.canGoForward &&
      nextRecord.faviconUrl == existing.faviconUrl &&
      nextRecord.lastError == existing.lastError) {
    return state;
  }

  return BrowserIndexState(
    browsersById: {...state.browsersById, normalizedBrowserId: nextRecord},
  );
}

/// Forgets a browser tab. Same identity contract as [applyBrowserPatch].
BrowserIndexState removeBrowserFromIndex(
  BrowserIndexState state,
  String browserId,
) {
  final normalizedBrowserId = trimNonEmpty(browserId);
  if (normalizedBrowserId == null) return state;
  if (!state.browsersById.containsKey(normalizedBrowserId)) return state;
  final next = {...state.browsersById}..remove(normalizedBrowserId);
  return BrowserIndexState(browsersById: next);
}

/// The store's `partialize`: clears the two transient fields on every record so
/// a restored session never resumes mid-navigation or mid-error.
BrowserIndexState sanitizeBrowsersForPersist(BrowserIndexState state) =>
    BrowserIndexState(
      browsersById: {
        for (final entry in state.browsersById.entries)
          entry.key: BrowserRecord(
            browserId: entry.value.browserId,
            url: entry.value.url,
            title: entry.value.title,
            isLoading: false,
            canGoBack: entry.value.canGoBack,
            canGoForward: entry.value.canGoForward,
            faviconUrl: entry.value.faviconUrl,
            lastError: null,
            createdAt: entry.value.createdAt,
          ),
      },
    );

/// The zustand persist key. Frozen: changing it forgets every open tab.
const String browserStoreStorageName = 'workspace-browser-store';

/// The workspace browser index, with its actions and persistence.
///
/// Port of `stores/browser-store/index.ts`. Both non-determinism sources are
/// injected: `crypto.randomUUID()` becomes [generateBrowserId] and `Date.now()`
/// becomes [nowMs], so a test can pin both.
///
/// DEVIATIONS forced by Dart having no ambient background write queue:
/// * the mutating actions return futures; upstream's are synchronous and the
///   persist middleware writes afterwards. The in-memory state is updated
///   before the write starts, so a synchronous read still sees what upstream
///   would see.
/// * [rehydrate] must be called explicitly; upstream hydrates on construction.
final class BrowserIndexStore {
  BrowserIndexStore({
    required this.storage,
    required this.generateBrowserId,
    required this.nowMs,
  });

  final MutableKeyValueStorage storage;

  /// Upstream validates the generated id with a protocol schema and throws on
  /// a bad one; that validation belongs to the id generator, not the store.
  final String Function() generateBrowserId;

  /// Epoch-millisecond clock. Never `DateTime.now()` inside this library.
  final int Function() nowMs;

  BrowserIndexState _state = const BrowserIndexState.empty();

  BrowserIndexState get state => _state;

  /// Opens a tab and returns its id.
  Future<String> createBrowser({String? initialUrl}) async {
    final browserId = generateBrowserId();
    final record = createBrowserRecord(
      browserId: browserId,
      initialUrl: initialUrl,
      now: nowMs(),
    );
    _state = BrowserIndexState(
      browsersById: {..._state.browsersById, browserId: record},
    );
    await _persist();
    return browserId;
  }

  Future<void> updateBrowser(String browserId, BrowserRecordPatch patch) async {
    final next = applyBrowserPatch(_state, browserId, patch);
    if (identical(next, _state)) return;
    _state = next;
    await _persist();
  }

  Future<void> removeBrowser(String browserId) async {
    final next = removeBrowserFromIndex(_state, browserId);
    if (identical(next, _state)) return;
    _state = next;
    await _persist();
  }

  /// Upstream's `getBrowserRecord`: null for a blank or unknown id.
  BrowserRecord? getBrowserRecord(String browserId) {
    final normalized = trimNonEmpty(browserId);
    if (normalized == null) return null;
    return _state.browsersById[normalized];
  }

  /// Reads the persisted blob back into memory.
  ///
  /// A missing key, a non-object blob, or a version this build has no migration
  /// for all collapse to "no persisted state", exactly as zustand's hydrate
  /// path does.
  Future<void> rehydrate() async {
    final raw = await storage.getItem(browserStoreStorageName);
    if (raw == null) return;
    final decoded = asJsonObject(jsonDecode(raw));
    if (decoded == null) return;
    final version = decoded['version'];
    if (version is num && version != 0) return;
    final persisted = asJsonObject(decoded['state']);
    if (persisted == null) return;
    final browsersById = asJsonObject(persisted['browsersById']);
    if (browsersById == null) return;
    _state = BrowserIndexState(
      browsersById: {
        for (final entry in browsersById.entries)
          if (asJsonObject(entry.value) case final record?)
            entry.key: BrowserRecord.fromJson(entry.key, record),
      },
    );
  }

  Future<void> _persist() => storage.setItem(
    browserStoreStorageName,
    // zustand stamps `version: 0` when a store declares no version.
    jsonEncode({
      'state': sanitizeBrowsersForPersist(_state).toJson(),
      'version': 0,
    }),
  );
}

// ===========================================================================
// 2. sidebar-collapsed-sections-store/state.ts
// ===========================================================================

/// Which sidebar sections the user has collapsed.
///
/// Three independent axes, all persisted: individual project sections, the
/// status-group headers of the status-grouped sidebar, and the single Pinned
/// section. Modelled with sets rather than lists because membership is the only
/// question ever asked, and because upstream uses `Set` for exactly that.
final class CollapsedProjectsState {
  const CollapsedProjectsState({
    required this.collapsedProjectKeys,
    required this.collapsedStatusGroupKeys,
    required this.collapsedPinned,
  });

  const CollapsedProjectsState.empty()
    : collapsedProjectKeys = const {},
      collapsedStatusGroupKeys = const {},
      collapsedPinned = false;

  /// Insertion-ordered, matching `Array.from(new Set(...))` upstream.
  final Set<String> collapsedProjectKeys;
  final Set<String> collapsedStatusGroupKeys;
  final bool collapsedPinned;
}

/// Flips the Pinned section open/closed.
CollapsedProjectsState togglePinnedCollapsed(CollapsedProjectsState state) =>
    CollapsedProjectsState(
      collapsedProjectKeys: state.collapsedProjectKeys,
      collapsedStatusGroupKeys: state.collapsedStatusGroupKeys,
      collapsedPinned: !state.collapsedPinned,
    );

/// Flips one project section.
///
/// Re-adding a previously removed key moves it to the end of the iteration
/// order in both `Set` implementations, so the persisted order matches.
CollapsedProjectsState toggleProjectCollapsed(
  CollapsedProjectsState state,
  String projectKey,
) {
  final next = {...state.collapsedProjectKeys};
  if (!next.remove(projectKey)) next.add(projectKey);
  return CollapsedProjectsState(
    collapsedProjectKeys: next,
    collapsedStatusGroupKeys: state.collapsedStatusGroupKeys,
    collapsedPinned: state.collapsedPinned,
  );
}

/// Flips one status-group header.
CollapsedProjectsState toggleStatusGroupCollapsed(
  CollapsedProjectsState state,
  String statusGroupKey,
) {
  final next = {...state.collapsedStatusGroupKeys};
  if (!next.remove(statusGroupKey)) next.add(statusGroupKey);
  return CollapsedProjectsState(
    collapsedProjectKeys: state.collapsedProjectKeys,
    collapsedStatusGroupKeys: next,
    collapsedPinned: state.collapsedPinned,
  );
}

/// Sets one project section's collapse state explicitly, for callers that know
/// the target state rather than wanting a toggle.
///
/// DEVIATION (harmless): upstream always allocates a fresh `Set` and a fresh
/// state object even when nothing changed, so it never returns the same
/// reference the way [applyBrowserPatch] does. That is reproduced — the caller
/// of this function upstream is a zustand `set`, which re-renders regardless.
CollapsedProjectsState setProjectCollapsed(
  CollapsedProjectsState state,
  String projectKey,
  bool collapsed,
) {
  final next = {...state.collapsedProjectKeys};
  if (collapsed) {
    next.add(projectKey);
  } else {
    next.remove(projectKey);
  }
  return CollapsedProjectsState(
    collapsedProjectKeys: next,
    collapsedStatusGroupKeys: state.collapsedStatusGroupKeys,
    collapsedPinned: state.collapsedPinned,
  );
}

/// The store's `partialize`: sets flattened to arrays for JSON.
Map<String, Object?> serializeCollapsedProjects(
  CollapsedProjectsState state,
) => {
  'collapsedProjectKeys': state.collapsedProjectKeys.toList(growable: false),
  'collapsedStatusGroupKeys': state.collapsedStatusGroupKeys.toList(
    growable: false,
  ),
  'collapsedPinned': state.collapsedPinned,
};

Set<String> _deserializeCollapsedKeys(Object? value) {
  if (value is! List) return <String>{};
  return {
    for (final key in value)
      if (key is String) key,
  };
}

bool _areSetsEqual(Set<String> left, Set<String> right) {
  if (left.length != right.length) return false;
  for (final key in left) {
    if (!right.contains(key)) return false;
  }
  return true;
}

/// The store's `merge`: folds a persisted blob onto the live state.
///
/// Returns [current] *by identity* when the blob carries nothing (so a first
/// run does not churn) and when it decodes to exactly what is already there.
///
/// The "carries nothing" test is JS truthiness, not a null check — see
/// [jsTruthy]. That matters: a persisted `collapsedProjectKeys: []` is truthy,
/// so it does *not* short-circuit; it decodes to an empty set, compares equal,
/// and returns [current] through the second gate instead. A persisted `0` or
/// `""` in that slot is falsy and does short-circuit. Both paths land on
/// [current], but only because the second gate exists — the distinction is kept
/// so the two guards stay individually faithful.
CollapsedProjectsState mergePersistedCollapsedProjects(
  Map<String, Object?>? persisted,
  CollapsedProjectsState current,
) {
  final rawProjectKeys = persisted?['collapsedProjectKeys'];
  final rawStatusGroupKeys = persisted?['collapsedStatusGroupKeys'];
  final rawPinned = persisted?['collapsedPinned'];
  // `persisted?.collapsedPinned === undefined` is a strict absence test, so a
  // stored JSON `null` counts as present-but-not-a-boolean and falls through to
  // the `typeof === "boolean"` check below, which keeps the current value.
  final pinnedIsAbsent =
      persisted == null || !persisted.containsKey('collapsedPinned');
  if (!jsTruthy(rawProjectKeys) &&
      !jsTruthy(rawStatusGroupKeys) &&
      pinnedIsAbsent) {
    return current;
  }

  final restoredProjects = _deserializeCollapsedKeys(rawProjectKeys);
  final restoredStatusGroups = _deserializeCollapsedKeys(rawStatusGroupKeys);
  final restoredPinned = rawPinned is bool
      ? rawPinned
      : current.collapsedPinned;

  if (_areSetsEqual(current.collapsedProjectKeys, restoredProjects) &&
      _areSetsEqual(current.collapsedStatusGroupKeys, restoredStatusGroups) &&
      current.collapsedPinned == restoredPinned) {
    return current;
  }

  return CollapsedProjectsState(
    collapsedProjectKeys: restoredProjects,
    collapsedStatusGroupKeys: restoredStatusGroups,
    collapsedPinned: restoredPinned,
  );
}

/// The zustand persist key. Frozen.
const String sidebarCollapsedSectionsStorageName = 'sidebar-collapsed-sections';

// The store below keeps upstream's action names, which then shadow the
// same-named top-level transitions inside the class body. Dart offers no
// library-self prefix, so the transitions are torn off once here and the
// actions call the tear-offs.
const _toggleProjectCollapsedFn = toggleProjectCollapsed;
const _setProjectCollapsedFn = setProjectCollapsed;
const _toggleStatusGroupCollapsedFn = toggleStatusGroupCollapsed;
const _togglePinnedCollapsedFn = togglePinnedCollapsed;

/// The collapsed-sections store, with its actions and persistence.
///
/// Same two deviations as [BrowserIndexStore]: async actions, explicit
/// [rehydrate].
final class SidebarCollapsedSectionsStore {
  SidebarCollapsedSectionsStore({required this.storage});

  final MutableKeyValueStorage storage;

  CollapsedProjectsState _state = const CollapsedProjectsState.empty();

  CollapsedProjectsState get state => _state;

  Future<void> toggleProjectCollapsed(String projectKey) =>
      _apply(_toggleProjectCollapsedFn(_state, projectKey));

  Future<void> setProjectCollapsed(String projectKey, bool collapsed) =>
      _apply(_setProjectCollapsedFn(_state, projectKey, collapsed));

  Future<void> toggleStatusGroupCollapsed(String statusGroupKey) =>
      _apply(_toggleStatusGroupCollapsedFn(_state, statusGroupKey));

  Future<void> togglePinnedCollapsed() =>
      _apply(_togglePinnedCollapsedFn(_state));

  Future<void> _apply(CollapsedProjectsState next) async {
    if (identical(next, _state)) return;
    _state = next;
    await _persist();
  }

  /// Reads the persisted blob and folds it in with
  /// [mergePersistedCollapsedProjects] — the same `merge` upstream registers.
  Future<void> rehydrate() async {
    final raw = await storage.getItem(sidebarCollapsedSectionsStorageName);
    Map<String, Object?>? persisted;
    if (raw != null) {
      final decoded = asJsonObject(jsonDecode(raw));
      if (decoded != null) {
        final version = decoded['version'];
        if (version is! num || version == 0) {
          persisted = asJsonObject(decoded['state']);
        }
      }
    }
    _state = mergePersistedCollapsedProjects(persisted, _state);
  }

  Future<void> _persist() => storage.setItem(
    sidebarCollapsedSectionsStorageName,
    jsonEncode({'state': serializeCollapsedProjects(_state), 'version': 0}),
  );
}

// ===========================================================================
// 3. sidebar-view-store.ts
// ===========================================================================

/// The current persist key for the sidebar's view preferences.
const String sidebarViewStorageName = 'sidebar-view';

/// The pre-rename key. Read once, on a miss against [sidebarViewStorageName],
/// so an upgrading user keeps their grouping choice.
const String legacySidebarGroupModeStorageName = 'sidebar-group-mode';

/// Bumped to 2 when the single `hostFilter` became the `hostFilters` list.
const int sidebarViewStoreVersion = 2;

/// The persisted shape of the sidebar view preferences.
///
/// [hostFilters] empty means "all hosts"; a non-empty list pins the sidebar to
/// exactly those hosts.
final class SidebarViewPersistedState {
  const SidebarViewPersistedState({
    required this.groupMode,
    required this.hostFilters,
  });

  final SidebarGroupMode groupMode;
  final List<String> hostFilters;

  Map<String, Object?> toJson() => {
    'groupMode': groupMode.name,
    'hostFilters': hostFilters,
  };
}

/// Upstream's `isSidebarGroupMode` type guard, returning the parsed value.
SidebarGroupMode? sidebarGroupModeFromWire(Object? value) => switch (value) {
  'project' => SidebarGroupMode.project,
  'status' => SidebarGroupMode.status,
  _ => null,
};

/// Reads the pre-rename `groupModeByServerId` map, which stored a mode per
/// host.
///
/// Collapsing many modes into one is deliberately biased toward `status`: if
/// the user had *any* host on status grouping, that is the layout they were
/// working in, so it survives the merge.
SidebarGroupMode? _readLegacyGroupMode(Map<String, Object?> persistedState) {
  final groupModeByServerId = asJsonObject(
    persistedState['groupModeByServerId'],
  );
  if (groupModeByServerId == null) return null;
  final modes = <SidebarGroupMode>[
    for (final value in groupModeByServerId.values)
      ?sidebarGroupModeFromWire(value),
  ];
  if (modes.isEmpty) return null;
  return modes.contains(SidebarGroupMode.status)
      ? SidebarGroupMode.status
      : SidebarGroupMode.project;
}

/// Reads the host filter from any persisted shape: the current `hostFilters`
/// array, or the pre-v2 single `hostFilter` string (absent meant "all hosts").
///
/// COMPAT(sidebarHostFilters): added upstream in v0.1.102, removable after
/// 2026-12-30 once pre-v2 persisted state has aged out.
List<String> _readHostFilters(Map<String, Object?> persistedState) {
  final hostFilters = persistedState['hostFilters'];
  if (hostFilters is List) {
    return [
      for (final value in hostFilters)
        if (value is String) value,
    ];
  }
  final legacyHostFilter = persistedState['hostFilter'];
  return legacyHostFilter is String ? [legacyHostFilter] : const [];
}

/// The store's `migrate`: normalises any persisted shape — v0's per-host group
/// modes, v1's single host filter, or current v2 — into [SidebarViewPersistedState].
///
/// A legacy group mode short-circuits the host filters to empty on purpose:
/// blobs old enough to carry `groupModeByServerId` predate host filtering, so
/// there is nothing to carry across.
SidebarViewPersistedState migrateSidebarViewState(Object? persistedState) {
  final record = asJsonObject(persistedState);
  if (record == null) {
    return const SidebarViewPersistedState(
      groupMode: SidebarGroupMode.project,
      hostFilters: [],
    );
  }

  final legacyGroupMode = _readLegacyGroupMode(record);
  if (legacyGroupMode != null) {
    return SidebarViewPersistedState(
      groupMode: legacyGroupMode,
      hostFilters: const [],
    );
  }

  return SidebarViewPersistedState(
    groupMode:
        sidebarGroupModeFromWire(record['groupMode']) ??
        SidebarGroupMode.project,
    hostFilters: _readHostFilters(record),
  );
}

/// A read-through storage that falls back to [legacySidebarGroupModeStorageName]
/// the first time the sidebar's current key comes back empty.
///
/// The fallback is read-only and scoped to that one key: writes always go to
/// the new key, so the legacy entry is never rewritten and simply stops being
/// consulted once the new key exists.
MutableKeyValueStorage createSidebarViewStorage(
  MutableKeyValueStorage backingStorage,
) => _SidebarViewStorage(backingStorage);

final class _SidebarViewStorage implements MutableKeyValueStorage {
  const _SidebarViewStorage(this._backing);

  final MutableKeyValueStorage _backing;

  @override
  Future<String?> getItem(String key) async {
    final value = await _backing.getItem(key);
    if (value != null || key != sidebarViewStorageName) return value;
    return _backing.getItem(legacySidebarGroupModeStorageName);
  }

  @override
  Future<void> setItem(String key, String value) =>
      _backing.setItem(key, value);

  @override
  Future<void> removeItem(String key) => _backing.removeItem(key);
}

/// Which hosts the sidebar shows and how it groups them.
///
/// Same two deviations as [BrowserIndexStore]: async actions, explicit
/// [rehydrate]. [rehydrate] runs [migrateSidebarViewState] over whatever the
/// (legacy-aware) storage returns, matching the store's registered `migrate`.
final class SidebarViewStore {
  SidebarViewStore({required MutableKeyValueStorage storage})
    : storage = createSidebarViewStorage(storage);

  /// Already wrapped by [createSidebarViewStorage].
  final MutableKeyValueStorage storage;

  SidebarGroupMode _groupMode = SidebarGroupMode.project;
  List<String> _hostFilters = const [];

  SidebarGroupMode get groupMode => _groupMode;

  /// Empty means "all hosts".
  List<String> get hostFilters => List.unmodifiable(_hostFilters);

  Future<void> setGroupMode(SidebarGroupMode mode) async {
    _groupMode = mode;
    await _persist();
  }

  /// Adds or removes one host, appending at the end so the filter chips keep a
  /// stable, user-observable order.
  Future<void> toggleHostFilter(String serverId) async {
    _hostFilters = _hostFilters.contains(serverId)
        ? [
            for (final id in _hostFilters)
              if (id != serverId) id,
          ]
        : [..._hostFilters, serverId];
    await _persist();
  }

  Future<void> clearHostFilters() async {
    _hostFilters = const [];
    await _persist();
  }

  /// Drops filters that point at hosts which no longer exist.
  ///
  /// Bails out without writing when there is nothing to reconcile, so
  /// re-running it on every host-list change is free. An empty filter list is
  /// left alone rather than being "reconciled" to empty: empty already means
  /// "all hosts", and reconciling it would write on every host change.
  Future<void> reconcileHostFilters(List<String> serverIds) async {
    if (_hostFilters.isEmpty) return;
    final allowed = serverIds.toSet();
    final next = [
      for (final id in _hostFilters)
        if (allowed.contains(id)) id,
    ];
    if (next.length == _hostFilters.length) return;
    _hostFilters = next;
    await _persist();
  }

  Future<void> rehydrate() async {
    final raw = await storage.getItem(sidebarViewStorageName);
    Object? persisted;
    if (raw != null) {
      final decoded = asJsonObject(jsonDecode(raw));
      if (decoded != null) persisted = decoded['state'];
    }
    // Upstream runs `migrate` for any stored version below the declared one and
    // hands the current state straight through otherwise; `migrateSidebarViewState`
    // is idempotent on a v2 blob, so running it unconditionally is equivalent.
    final migrated = migrateSidebarViewState(persisted);
    _groupMode = migrated.groupMode;
    _hostFilters = migrated.hostFilters;
  }

  Future<void> _persist() => storage.setItem(
    sidebarViewStorageName,
    jsonEncode({
      'state': SidebarViewPersistedState(
        groupMode: _groupMode,
        hostFilters: _hostFilters,
      ).toJson(),
      'version': sidebarViewStoreVersion,
    }),
  );
}

// ===========================================================================
// 4. navigation-active-workspace-store/navigation.ts
// ===========================================================================

/// The router params the active-workspace parser reads.
///
/// DEVIATION: upstream's type is `string | string[] | undefined` because
/// expo-router hands repeated query params through as arrays. The fields stay
/// `Object?` here rather than becoming a sealed union — they are a foreign
/// router's shape, not a domain concept, and [_getParamValue] is the only
/// reader.
final class WorkspaceRouteParams {
  const WorkspaceRouteParams({this.serverId, this.workspaceId});

  /// A `String`, a `List<String>`, or null.
  final Object? serverId;

  /// A `String`, a `List<String>`, or null.
  final Object? workspaceId;
}

/// A pathname plus the router params observed alongside it.
final class RouteSelectionInput {
  const RouteSelectionInput({
    required this.pathname,
    this.params = const WorkspaceRouteParams(),
  });

  final String pathname;
  final WorkspaceRouteParams params;
}

String _getParamValue(Object? value) {
  if (value is String) return value.trim();
  if (value is List) {
    final first = value.isEmpty ? null : value.first;
    return first is String ? first.trim() : '';
  }
  return '';
}

HostWorkspaceRoute? _parseWorkspaceSelectionFromRouteParams(
  WorkspaceRouteParams params,
) {
  final serverId = _getParamValue(params.serverId);
  final workspaceValue = _getParamValue(params.workspaceId);
  final workspaceId = workspaceValue.isEmpty
      ? null
      : decodeWorkspaceIdFromPathSegment(workspaceValue);
  if (serverId.isEmpty || workspaceId == null || workspaceId.isEmpty) {
    return null;
  }
  return HostWorkspaceRoute(serverId: serverId, workspaceId: workspaceId);
}

/// Which workspace the current route is showing, if any.
///
/// The pathname is authoritative. Params are only consulted at the root path
/// (`/` or `""`) — the cold-mount window where the router has resolved the
/// params but not yet committed the deep-linked pathname. Consulting them on
/// any other route would resurrect a stale workspace while the user is on, say,
/// a settings screen; the upstream suite pins exactly that.
HostWorkspaceRoute? parseActiveWorkspaceSelection(RouteSelectionInput input) {
  final routeSelection = parseHostWorkspaceRouteFromPathname(input.pathname);
  if (routeSelection != null) return routeSelection;

  if (input.pathname != '/' && input.pathname.isNotEmpty) return null;

  return _parseWorkspaceSelectionFromRouteParams(input.params);
}

/// Upstream `normalizeWorkspaceOpaqueId`: workspace ids are opaque, so the only
/// normalisation is trimming.
///
/// Re-declared here rather than imported because the repo's existing copies
/// (`core/paseo_session_projection.dart`, `navigation/paseo_route_rules.dart`,
/// `state/subagents_provider.dart`) are all file-private.
String? normalizeWorkspaceOpaqueId(String? value) => trimNonEmpty(value);

/// Finds the key under which [workspaceId] is filed in [workspaces].
///
/// Two passes because a session map may be keyed by something other than the
/// descriptor's own id (an older daemon keyed by directory). The direct hit is
/// tried first so the common case costs one lookup.
String? resolveWorkspaceMapKeyByIdentity({
  required Map<String, WorkspaceDescriptor>? workspaces,
  required String? workspaceId,
}) {
  final normalizedWorkspaceId = normalizeWorkspaceOpaqueId(workspaceId);
  if (normalizedWorkspaceId == null) return null;
  if (workspaces == null) return null;

  if (workspaces.containsKey(normalizedWorkspaceId)) {
    return normalizedWorkspaceId;
  }

  for (final entry in workspaces.entries) {
    if (normalizeWorkspaceOpaqueId(entry.value.id) == normalizedWorkspaceId) {
      return entry.key;
    }
  }

  return null;
}

/// What [navigateToWorkspace] is being asked to open.
final class NavigateToWorkspaceInput {
  const NavigateToWorkspaceInput({
    required this.serverId,
    required this.workspaceId,
    this.target,
    this.pin = false,
  });

  final String serverId;
  final String workspaceId;

  /// Null means "let the workspace decide" — see [navigateToWorkspace].
  final WorkspaceTabTarget? target;
  final bool pin;
}

/// Everything [navigateToWorkspace] needs from the outside world.
///
/// Every field is a callback so the rule stays store-free: upstream reads
/// `useSessionStore.getState()` and `useWorkspaceLayoutStore.getState()` *at
/// call time* precisely so navigation always hits the live store, and passing
/// getters preserves that late binding.
final class NavigateToWorkspaceDeps {
  const NavigateToWorkspaceDeps({
    required this.getSessionWorkspaces,
    required this.getSessionAgents,
    required this.openTabFocused,
    required this.pinAgent,
    required this.rememberLastWorkspace,
    required this.navigateToRoute,
  });

  final Map<String, WorkspaceDescriptor>? Function(String serverId)
  getSessionWorkspaces;
  final Iterable<AgentSummary> Function(String serverId) getSessionAgents;
  final String? Function(String workspaceKey, WorkspaceTabTarget target)
  openTabFocused;
  final void Function(String workspaceKey, String agentId) pinAgent;
  final void Function(HostWorkspaceRoute selection) rememberLastWorkspace;
  final void Function(String route) navigateToRoute;
}

/// [NavigateToWorkspaceDeps] plus the last-selection reader.
final class NavigateToLastWorkspaceDeps {
  const NavigateToLastWorkspaceDeps({
    required this.base,
    required this.getLastWorkspaceSelection,
  });

  final NavigateToWorkspaceDeps base;
  final HostWorkspaceRoute? Function() getLastWorkspaceSelection;
}

/// Routes to a workspace, opening the right tab on the way, and returns the
/// route that was pushed.
///
/// Three behaviours worth spelling out, all pinned by the upstream suite:
///
/// * **An explicit [NavigateToWorkspaceInput.target] wins** over the workspace's
///   attention agent. The user asked for a specific tab; auto-focusing a
///   different one would steal the navigation.
/// * **An agent tab for a workspace this client has not seen yet is deferred**,
///   not dropped: opening it would create a tab against an unknown workspace
///   key, so the intent is encoded into the route as `?open=agent:<id>` and
///   replayed once the workspace shows up.
/// * **With no target, the attention agent is focused** — the whole point of
///   clicking a workspace that is asking for input.
String navigateToWorkspace(
  NavigateToWorkspaceInput input,
  NavigateToWorkspaceDeps deps,
) {
  final workspaces = deps.getSessionWorkspaces(input.serverId);
  final resolvedWorkspaceId = resolveWorkspaceMapKeyByIdentity(
    workspaces: workspaces,
    workspaceId: input.workspaceId,
  );

  final target = input.target;
  if (target != null) {
    if (resolvedWorkspaceId != null || target is! WorkspaceAgentTabTarget) {
      prepareWorkspaceTab(
        PrepareWorkspaceTabInput(
          serverId: input.serverId,
          // Deliberately the *raw* workspace id, not the resolved map key:
          // upstream spreads `...input`, so the tab persistence key is built
          // from what the caller asked for.
          workspaceId: input.workspaceId,
          target: target,
          pin: input.pin,
        ),
        PrepareWorkspaceTabDependencies(
          openTabFocused: deps.openTabFocused,
          pinAgent: deps.pinAgent,
        ),
      );
    }
  } else {
    final workspaceAgents = resolvedWorkspaceId == null
        ? const <AgentSummary>[]
        : [
            for (final agent in deps.getSessionAgents(input.serverId))
              if (normalizeWorkspaceOpaqueId(agent.workspaceId) ==
                  resolvedWorkspaceId)
                agent,
          ];
    final attentionAgentId = pickAttentionAgent(workspaceAgents);
    if (attentionAgentId != null && resolvedWorkspaceId != null) {
      // Upstream builds this key inline rather than via
      // `buildWorkspaceTabPersistenceKey`, and does so from the *resolved* id.
      deps.openTabFocused(
        '${input.serverId}:$resolvedWorkspaceId',
        WorkspaceAgentTabTarget(agentId: attentionAgentId),
      );
    }
  }

  final route = target is WorkspaceAgentTabTarget && resolvedWorkspaceId == null
      ? buildHostWorkspaceOpenRoute(
          input.serverId,
          input.workspaceId,
          'agent:${target.agentId}',
        )
      : buildHostWorkspaceRoute(input.serverId, input.workspaceId);
  deps.rememberLastWorkspace(
    HostWorkspaceRoute(
      serverId: input.serverId,
      workspaceId: input.workspaceId,
    ),
  );
  deps.navigateToRoute(route);
  return route;
}

/// Routes back to whatever workspace was last active.
///
/// Returns false — without navigating — when nothing has been remembered yet,
/// so a caller can fall back to a landing screen rather than pushing `/`.
bool navigateToLastWorkspace(NavigateToLastWorkspaceDeps deps) {
  final selection = deps.getLastWorkspaceSelection();
  if (selection == null) return false;
  navigateToWorkspace(
    NavigateToWorkspaceInput(
      serverId: selection.serverId,
      workspaceId: selection.workspaceId,
    ),
    deps.base,
  );
  return true;
}

// ===========================================================================
// 5. draft-store/migration.ts
// ===========================================================================

/// The owner tag the "new workspace" branch/PR picker stamps on the PR
/// attachment it creates.
///
/// It exists so the composer can tell a PR the *user* attached from one the
/// picker attached as checkout context; only the latter is safe to drop when a
/// draft is promoted to a surface with no checkout.
const String newWorkspacePickerAttachmentOwner = 'new-workspace-picker';

/// Whether [draftKey] is a pre-singleton, project-scoped New Workspace key.
///
/// Fork drafts (`new-workspace:draft:<id>`) are *not* legacy: they still name a
/// distinct composer. Only the `new-workspace:<server>:<path>` shape is.
bool isLegacyNewWorkspaceDraftKey(String draftKey) =>
    draftKey.startsWith('$newWorkspaceComposerDraftKey:') &&
    !draftKey.startsWith('$newWorkspaceComposerDraftKey:draft:');

// --- attachments -----------------------------------------------------------

/// One attachment a *user* put on a draft.
///
/// Upstream this is the `UserComposerAttachment` union — deliberately narrower
/// than `ComposerAttachment`, which also covers attachments the *workspace*
/// synthesises (browser elements, review bundles, chat history). Only the user
/// half is ever persisted in a draft, which is why a review attachment found in
/// a persisted blob is rejected rather than migrated.
sealed class UserComposerAttachment {
  const UserComposerAttachment();

  String get kind;

  Map<String, Object?> toJson();
}

/// A pasted or picked image, referenced by id so the draft-store GC can keep
/// its bytes alive.
final class ImageComposerAttachment extends UserComposerAttachment {
  const ImageComposerAttachment(this.metadata);

  final AttachmentMetadata metadata;

  @override
  String get kind => 'image';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'metadata': encodeAttachmentMetadata(metadata),
  };
}

/// A file already uploaded to the daemon.
final class FileComposerAttachment extends UserComposerAttachment {
  const FileComposerAttachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.path,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final int size;
  final String path;

  @override
  String get kind => 'file';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'attachment': {
      'type': 'uploaded_file',
      'id': id,
      'fileName': fileName,
      'mimeType': mimeType,
      'size': size,
      'path': path,
    },
  };
}

/// A file (or a line range within one) from the workspace checkout.
///
/// DEVIATION: the repo's [ComposerWorkspaceFileAttachment] equivalent in
/// `composer/composer_draft_store.dart` also rewrites `\` to `/` during
/// normalisation, which upstream does not do. Reusing it would silently change
/// a Windows-shaped path, so only the *selection* type is reused and the path
/// normalisation matches upstream exactly: trim, then strip one leading `./`.
final class WorkspaceFileComposerAttachment extends UserComposerAttachment {
  const WorkspaceFileComposerAttachment({
    required this.path,
    required this.selection,
  });

  final String path;
  final ComposerWorkspaceFileSelection selection;

  @override
  String get kind => 'workspace_file';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    'selection': selection.toJson(),
  };
}

/// How a forge item was attached. The four spellings are kept apart because
/// they serialise differently and because only [githubPr] may carry an owner.
enum ForgeComposerAttachmentKind {
  forgeIssue('forge_issue'),
  forgeChangeRequest('forge_change_request'),
  // COMPAT(githubAttachmentKinds): added upstream in v0.1.106, removable after
  // 2026-12-28 once the daemon floor reaches v0.1.106.
  githubIssue('github_issue'),
  githubPr('github_pr');

  const ForgeComposerAttachmentKind(this.wireName);

  final String wireName;

  static ForgeComposerAttachmentKind? tryFromWire(Object? value) =>
      switch (value) {
        'forge_issue' => forgeIssue,
        'forge_change_request' => forgeChangeRequest,
        'github_issue' => githubIssue,
        'github_pr' => githubPr,
        _ => null,
      };
}

/// An issue or change request attached from the forge picker.
final class ForgeComposerAttachment extends UserComposerAttachment {
  const ForgeComposerAttachment({
    required this.attachmentKind,
    required this.item,
    this.owner,
  });

  final ForgeComposerAttachmentKind attachmentKind;
  final ForgeSearchItem item;

  /// Only ever [newWorkspacePickerAttachmentOwner], and only on
  /// [ForgeComposerAttachmentKind.githubPr]. Marks checkout context the picker
  /// added rather than something the user chose.
  final String? owner;

  @override
  String get kind => attachmentKind.wireName;

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'item': item.toJson(),
    if (owner != null) 'owner': owner,
  };
}

/// Serialises attachment metadata for a persisted draft.
///
/// DEVIATION: upstream's `normalizeAttachmentMetadata` omits `fileName` and
/// `byteSize` when they are `undefined` but *keeps* them when they are `null`.
/// [AttachmentMetadata] has one nullable field for both states, so this encoder
/// omits them whenever they are null. Nothing reads the difference — both mean
/// "unknown" — and the encoding stays stable across repeated migrations, which
/// is what the upstream round-trip case actually pins.
Map<String, Object?> encodeAttachmentMetadata(AttachmentMetadata metadata) => {
  'id': metadata.id,
  'mimeType': metadata.mimeType,
  'storageType': metadata.storageType.wireName,
  'storageKey': metadata.storageKey,
  'createdAt': metadata.createdAt,
  if (metadata.fileName != null) 'fileName': metadata.fileName,
  if (metadata.byteSize != null) 'byteSize': metadata.byteSize,
};

/// Upstream's `isAttachmentMetadata` guard, returning the parsed value.
///
/// DEVIATION: upstream accepts *any* string as `storageType`; the reused
/// [AttachmentStorageType] enum is closed, so an unrecognised storage type is
/// rejected here. That is the safer direction — a storage type this build
/// cannot read is one whose bytes it could never resolve — and no upstream
/// producer emits one.
AttachmentMetadata? parseAttachmentMetadata(Object? value) {
  final record = asJsonObject(value);
  if (record == null) return null;
  final id = record['id'];
  final mimeType = record['mimeType'];
  final storageType = record['storageType'];
  final storageKey = record['storageKey'];
  final createdAt = record['createdAt'];
  if (id is! String ||
      mimeType is! String ||
      storageType is! String ||
      storageKey is! String ||
      createdAt is! num) {
    return null;
  }
  AttachmentStorageType? parsedStorageType;
  for (final candidate in AttachmentStorageType.values) {
    if (candidate.wireName == storageType) parsedStorageType = candidate;
  }
  if (parsedStorageType == null) return null;

  final fileName = record['fileName'];
  final byteSize = record['byteSize'];
  return AttachmentMetadata(
    id: id,
    mimeType: mimeType,
    storageType: parsedStorageType,
    storageKey: storageKey,
    createdAt: createdAt.toInt(),
    fileName: fileName is String ? fileName : null,
    byteSize: byteSize is num ? byteSize.toInt() : null,
  );
}

/// An image reference as it may appear in a persisted draft: either full
/// attachment metadata, or the pre-attachment-store `{ uri, mimeType? }` shape.
sealed class PersistedDraftImage {
  const PersistedDraftImage();
}

/// The modern shape — already an attachment-store record.
final class PersistedAttachmentDraftImage extends PersistedDraftImage {
  const PersistedAttachmentDraftImage(this.metadata);

  final AttachmentMetadata metadata;
}

/// The pre-attachment-store shape: a platform URI with no stable id.
///
/// DEVIATION: upstream keeps `mimeType` only when it is *truthy*, so an empty
/// string is dropped; [mimeType] is null in exactly that case.
final class LegacyDraftImage extends PersistedDraftImage {
  const LegacyDraftImage({required this.uri, this.mimeType});

  final String uri;
  final String? mimeType;
}

/// Copies legacy image references into the attachment store, returning metadata
/// for the ones that made it.
///
/// Async and injected because the real implementation reads bytes off disk or
/// out of IndexedDB; dropping an image that cannot be copied is intentional, as
/// a draft with a dangling reference is worse than one with fewer images.
typedef MigrateLegacyImages =
    Future<List<AttachmentMetadata>> Function(List<PersistedDraftImage> images);

/// Lifecycle of a persisted draft. Reuses the repo's existing enum rather than
/// declaring a second three-value copy.
typedef DraftLifecycleState = ComposerDraftLifecycle;

/// The canonical draft body: prompt text plus user attachments.
final class DraftInput {
  const DraftInput({required this.text, required this.attachments});

  final String text;
  final List<UserComposerAttachment> attachments;

  Map<String, Object?> toJson() => {
    'text': text,
    'attachments': [for (final attachment in attachments) attachment.toJson()],
  };
}

/// One persisted draft.
final class DraftRecord {
  const DraftRecord({
    required this.input,
    required this.lifecycle,
    required this.updatedAt,
    required this.version,
  });

  final DraftInput input;
  final DraftLifecycleState lifecycle;

  /// Epoch milliseconds. Supplied by the migration's injected clock when the
  /// persisted record has none.
  final int updatedAt;
  final int version;

  DraftRecord withInput(DraftInput nextInput) => DraftRecord(
    input: nextInput,
    lifecycle: lifecycle,
    updatedAt: updatedAt,
    version: version,
  );

  Map<String, Object?> toJson() => {
    'input': input.toJson(),
    'lifecycle': lifecycle.name,
    'updatedAt': updatedAt,
    'version': version,
  };
}

/// The whole persisted draft store: every keyed draft, plus the singleton
/// "create workspace" modal draft.
final class DraftStoreState {
  const DraftStoreState({required this.drafts, required this.createModalDraft});

  final Map<String, DraftRecord> drafts;
  final DraftRecord? createModalDraft;

  Map<String, Object?> toJson() => {
    'drafts': {
      for (final entry in drafts.entries) entry.key: entry.value.toJson(),
    },
    'createModalDraft': createModalDraft?.toJson(),
  };
}

/// The side inputs [migratePersistedState] needs: the legacy-image copier and
/// the clock reading used for records with no `updatedAt`.
final class DraftMigrationPorts {
  const DraftMigrationPorts({
    required this.migrateLegacyImages,
    required this.nowMs,
  });

  final MigrateLegacyImages migrateLegacyImages;

  /// Epoch milliseconds, captured once by the caller. Injected rather than read
  /// here so a migration is reproducible.
  final int nowMs;
}

/// Validates a `forge_issue` / `github_pr` / … item against the union of
/// upstream's `ForgeSearchItemSchema` and `GitHubSearchItemSchema`.
///
/// Written out rather than delegating to [ForgeSearchItem]'s own `fromJson`
/// because that constructor has drifted from the schema: it also accepts the
/// `github-issue`/`github-pr` wire spellings (which Zod rejects here), requires
/// `number` to be positive, and tolerates a missing `body` (which Zod requires,
/// nullable). Delegating would change which persisted attachments survive.
///
/// DEVIATIONS from the Zod union, both unobservable for real producers:
/// * `number` is `z.number()` upstream — any JS number. [ForgeSearchItem.number]
///   is an `int`, so a fractional value is truncated rather than preserved. The
///   attachment is *kept* either way, which is the observable that matters.
/// * `kind: "pr"` collapses to [ForgeSearchKind.changeRequest] at parse time
///   because the reused enum has no separate `pr`. Upstream only performs that
///   rewrite inside `normalizeComposerAttachment` for `github_pr`, so a
///   `github_issue` whose item claimed `kind: "pr"` would keep `"pr"` upstream
///   and becomes `"change_request"` here. No producer emits that combination.
ForgeSearchItem? parseForgeOrGitHubSearchItem(Object? value) {
  final record = asJsonObject(value);
  if (record == null) return null;

  final kind = switch (record['kind']) {
    'issue' => ForgeSearchKind.issue,
    'change_request' || 'pr' => ForgeSearchKind.changeRequest,
    _ => null,
  };
  if (kind == null) return null;

  final number = record['number'];
  final title = record['title'];
  final url = record['url'];
  final state = record['state'];
  if (number is! num ||
      title is! String ||
      url is! String ||
      state is! String) {
    return null;
  }

  // `body: z.string().nullable()` — required, but may be null.
  if (!record.containsKey('body')) return null;
  final body = record['body'];
  if (body != null && body is! String) return null;

  final labels = record['labels'];
  if (labels is! List || labels.any((label) => label is! String)) return null;

  // `z.string().optional()` accepts absent or a string but rejects an explicit
  // null; `z.string().nullable().optional()` additionally accepts null.
  for (final field in const ['forge', 'projectPath', 'updatedAt']) {
    if (record.containsKey(field) && record[field] is! String) return null;
  }
  for (final field in const ['baseRefName', 'headRefName']) {
    final raw = record[field];
    if (record.containsKey(field) && raw != null && raw is! String) return null;
  }

  String? optionalString(String field) {
    final raw = record[field];
    return raw is String ? raw : null;
  }

  return ForgeSearchItem(
    kind: kind,
    forge: optionalString('forge'),
    number: number.toInt(),
    title: title,
    url: url,
    state: state,
    body: body as String?,
    labels: [for (final label in labels) label as String],
    projectPath: optionalString('projectPath'),
    baseRefName: optionalString('baseRefName'),
    headRefName: optionalString('headRefName'),
    updatedAt: optionalString('updatedAt'),
  );
}

/// Upstream's `isWorkspaceFileComposerAttachment` guard plus the normalisation
/// `normalizeComposerAttachment` applies, fused into one parse.
WorkspaceFileComposerAttachment? _parseWorkspaceFileAttachment(
  Map<String, Object?> record,
) {
  final path = record['path'];
  if (path is! String || path.trim().isEmpty) return null;

  final selection = asJsonObject(record['selection']);
  if (selection == null) return null;

  final ComposerWorkspaceFileSelection parsedSelection;
  switch (selection['kind']) {
    case 'whole_file':
      parsedSelection = ComposerWorkspaceFileSelection.wholeFileSelection;
    case 'line_range':
      final startLine = selection['startLine'];
      final endLine = selection['endLine'];
      if (startLine is! int ||
          endLine is! int ||
          startLine <= 0 ||
          endLine < startLine) {
        return null;
      }
      parsedSelection = ComposerWorkspaceFileSelection.lineRange(
        startLine: startLine,
        endLine: endLine,
      );
    default:
      return null;
  }

  return WorkspaceFileComposerAttachment(
    // Upstream: `path.trim().replace(/^\.\//, "")` — one leading `./`, nothing
    // else. Notably no separator rewriting.
    path: path.trim().replaceFirst(RegExp(r'^\./'), ''),
    selection: parsedSelection,
  );
}

/// Upstream's `isUserComposerAttachment` + `normalizeComposerAttachment`,
/// fused: a persisted entry either parses into a canonical attachment or is
/// dropped.
///
/// Fusing them is safe because upstream never calls the guard without following
/// it with the normaliser on the same value, and it removes the un-typed
/// intermediate state that only exists because TypeScript guards narrow in
/// place.
UserComposerAttachment? parseUserComposerAttachment(Object? value) {
  final record = asJsonObject(value);
  if (record == null) return null;
  final kind = record['kind'];

  if (kind == 'image') {
    final metadata = parseAttachmentMetadata(record['metadata']);
    return metadata == null ? null : ImageComposerAttachment(metadata);
  }

  if (kind == 'workspace_file') return _parseWorkspaceFileAttachment(record);

  if (kind == 'file') {
    final attachment = asJsonObject(record['attachment']);
    if (attachment == null) return null;
    final id = attachment['id'];
    final fileName = attachment['fileName'];
    final mimeType = attachment['mimeType'];
    final size = attachment['size'];
    final path = attachment['path'];
    if (attachment['type'] != 'uploaded_file' ||
        id is! String ||
        fileName is! String ||
        mimeType is! String ||
        path is! String ||
        size is! int ||
        size < 0) {
      return null;
    }
    return FileComposerAttachment(
      id: id,
      fileName: fileName,
      mimeType: mimeType,
      size: size,
      path: path,
    );
  }

  final forgeKind = ForgeComposerAttachmentKind.tryFromWire(kind);
  if (forgeKind == null) return null;

  // A `github_pr` may only carry the picker's owner tag. Any other owner means
  // the blob was written by something this build does not understand, so the
  // attachment is dropped rather than silently stripped of its provenance.
  final owner = record['owner'];
  if (forgeKind == ForgeComposerAttachmentKind.githubPr &&
      record.containsKey('owner') &&
      owner != null &&
      owner != newWorkspacePickerAttachmentOwner) {
    return null;
  }

  final item = parseForgeOrGitHubSearchItem(record['item']);
  if (item == null) return null;

  return ForgeComposerAttachment(
    attachmentKind: forgeKind,
    item: item,
    owner:
        forgeKind == ForgeComposerAttachmentKind.githubPr &&
            owner == newWorkspacePickerAttachmentOwner
        ? newWorkspacePickerAttachmentOwner
        : null,
  );
}

PersistedDraftImage? _normalizePersistedImage(Object? value) {
  final metadata = parseAttachmentMetadata(value);
  if (metadata != null) return PersistedAttachmentDraftImage(metadata);
  final record = asJsonObject(value);
  if (record == null) return null;
  final uri = record['uri'];
  if (uri is! String) return null;
  final mimeType = record['mimeType'];
  return LegacyDraftImage(
    uri: uri,
    // `...(value.mimeType ? { mimeType } : {})` — falsy drops the key.
    mimeType: jsTruthy(mimeType) ? mimeType as String : null,
  );
}

/// Normalises one draft's persisted body.
///
/// Legacy `images` are appended *after* the already-canonical `attachments`
/// rather than interleaved, because the original ordering between the two lists
/// was never recorded and appending is the only choice that is stable across
/// repeated migrations.
Future<DraftInput> migrateDraftInput(
  Object? rawInput,
  DraftMigrationPorts ports,
) async {
  final record = asJsonObject(rawInput) ?? const <String, Object?>{};

  final rawAttachments = record['attachments'];
  final attachments = <UserComposerAttachment>[
    if (rawAttachments is List)
      for (final entry in rawAttachments) ?parseUserComposerAttachment(entry),
  ];

  final rawImages = record['images'];
  final legacyImages = <PersistedDraftImage>[
    if (rawImages is List)
      for (final entry in rawImages) ?_normalizePersistedImage(entry),
  ];
  final migratedImages = await ports.migrateLegacyImages(legacyImages);

  final text = record['text'];
  return DraftInput(
    text: text is String ? text : '',
    attachments: [
      ...attachments,
      for (final metadata in migratedImages) ImageComposerAttachment(metadata),
    ],
  );
}

DraftLifecycleState _resolvePersistedLifecycle(Object? lifecycle) =>
    switch (lifecycle) {
      'sent' => ComposerDraftLifecycle.sent,
      'abandoned' => ComposerDraftLifecycle.abandoned,
      _ => ComposerDraftLifecycle.active,
    };

/// Older records stored the body's fields at the top level; newer ones nest
/// them under `input`. A record whose `input` is present and object-shaped uses
/// it; anything else is treated as the flat legacy shape.
Object? _extractRawInput(Map<String, Object?> record) {
  final input = record['input'];
  // `record.input && typeof record.input === "object"` — a JSON array is also
  // an object in JS, so it is handed on (and then reads as an empty body)
  // rather than falling back to the flat shape.
  if (input is Map || input is List) return input;
  return record;
}

Future<DraftRecord> _buildMigratedDraftRecord(
  Map<String, Object?> parsed,
  DraftMigrationPorts ports,
) async {
  final updatedAt = parsed['updatedAt'];
  final version = parsed['version'];
  return DraftRecord(
    input: await migrateDraftInput(_extractRawInput(parsed), ports),
    lifecycle: _resolvePersistedLifecycle(parsed['lifecycle']),
    updatedAt: updatedAt is num ? updatedAt.toInt() : ports.nowMs,
    version: version is num ? version.toInt() : 1,
  );
}

/// Folds every pre-singleton, project-scoped New Workspace draft into the one
/// global `new-workspace` key.
///
/// The newest still-active scoped draft wins; the rest are dropped. An already
/// existing singleton draft is never overwritten — it was written by a build
/// that already had the singleton, so it is strictly newer intent.
///
/// DEVIATION: the "newest" pick relies on `Array.prototype.sort` being stable
/// in V8 when two drafts share an `updatedAt`. Dart's [List.sort] is *not*
/// stable, so the comparator carries an explicit original-index tiebreak that
/// reproduces the V8 result.
///
/// COMPAT(newWorkspaceDraftSingleton): migrated upstream in v0.1.108; removable
/// after 2027-01-13.
Map<String, DraftRecord> migrateNewWorkspaceDraftKeys(
  Map<String, DraftRecord> drafts,
) {
  final legacyEntries = [
    for (final entry in drafts.entries)
      if (isLegacyNewWorkspaceDraftKey(entry.key)) entry,
  ];
  if (legacyEntries.isEmpty) return drafts;

  final nextDrafts = {...drafts};
  for (final entry in legacyEntries) {
    nextDrafts.remove(entry.key);
  }

  if (nextDrafts.containsKey(newWorkspaceComposerDraftKey)) return nextDrafts;

  final activeDrafts = <({int index, DraftRecord draft})>[];
  for (final entry in legacyEntries) {
    if (entry.value.lifecycle != ComposerDraftLifecycle.active) continue;
    activeDrafts.add((index: activeDrafts.length, draft: entry.value));
  }
  activeDrafts.sort((left, right) {
    final byUpdatedAt = right.draft.updatedAt.compareTo(left.draft.updatedAt);
    return byUpdatedAt != 0 ? byUpdatedAt : left.index.compareTo(right.index);
  });

  if (activeDrafts.isEmpty) return nextDrafts;
  final newestActiveDraft = activeDrafts.first.draft;

  // Legacy scoped drafts did not record whether a PR came from the Base picker.
  // That checkout context is unsafe to carry onto a global surface, so every PR
  // attachment is dropped rather than guessed at.
  nextDrafts[newWorkspaceComposerDraftKey] = newestActiveDraft.withInput(
    DraftInput(
      text: newestActiveDraft.input.text,
      attachments: [
        for (final attachment in newestActiveDraft.input.attachments)
          if (!(attachment is ForgeComposerAttachment &&
              attachment.attachmentKind ==
                  ForgeComposerAttachmentKind.githubPr))
            attachment,
      ],
    ),
  );

  return nextDrafts;
}

/// Migrates a whole persisted draft-store blob into the canonical shape.
///
/// Idempotent by construction: running it on its own output is a no-op, which
/// is what makes it safe to run on every launch regardless of which build wrote
/// the blob.
Future<DraftStoreState> migratePersistedState(
  Object? state,
  DraftMigrationPorts ports,
) async {
  final input = asJsonObject(state) ?? const <String, Object?>{};

  final nextDrafts = <String, DraftRecord>{};
  final rawDrafts = asJsonObject(input['drafts']) ?? const <String, Object?>{};
  for (final entry in rawDrafts.entries) {
    final rawRecord = asJsonObject(entry.value);
    if (rawRecord == null) continue;
    nextDrafts[entry.key] = await _buildMigratedDraftRecord(rawRecord, ports);
  }

  DraftRecord? createModalDraft;
  final rawModalDraft = asJsonObject(input['createModalDraft']);
  if (rawModalDraft != null) {
    createModalDraft = await _buildMigratedDraftRecord(rawModalDraft, ports);
  }

  return DraftStoreState(
    drafts: migrateNewWorkspaceDraftKeys(nextDrafts),
    createModalDraft: createModalDraft,
  );
}
