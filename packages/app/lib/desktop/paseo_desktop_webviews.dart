/// Ports of six frozen Paseo 0.2.0 desktop-host modules that make up the
/// *runtime* half of the embedded-browser, application-menu, auto-update and
/// external-editor features. Each one lived in the Electron main process and
/// reached straight for an Electron or Node API; here every one of those
/// capabilities arrives as a narrow injected interface, so the rules run with
/// no Electron, no `dart:io` and no plugin.
///
/// - `features/browser-webviews/registry.ts` — the authoritative map from a
///   guest `webContents` id to the browser tab and host window that own it, and
///   the per-host-window "which tab is active" bookkeeping.
/// - `features/browser-webviews/index.ts` — the attach gate that decides whether
///   a `<webview>` the renderer is claiming really is a Paseo browser tab, plus
///   the navigation guards that keep a guest on `http`/`https`/`about:blank`.
/// - `features/browser-keyboard/index.ts` — the runtime that pushes the shell's
///   keyboard policy into each guest, forwards the keystrokes the shell claims
///   back to its host window, and handles the three shortcuts the embedded
///   browser owns outright (reload / force-reload / focus-url).
/// - `features/auto-updater.ts` — the staged-rollout entry point, the per-install
///   staging user id, the "don't self-install on quit under AppImage" rule, and
///   the electron-updater adapter behind [DesktopAppUpdateRuntime].
/// - `features/menu.ts` — the application-menu template, the terminal context
///   menu, the shortcut-capture zoom-accelerator suppression, and the
///   reload-the-active-browser-not-the-window rule.
/// - `features/editor-targets/runtime.ts` — the concrete [EditorTargetRuntime]:
///   PATH resolution, Windows `.cmd`/`.bat` quoting, detached spawn, and the
///   macOS `.app` probe.
///
/// ## Reuse — what this library deliberately does *not* redeclare
///
/// Several of these modules are the runtime halves of rules already ported into
/// this repo, and those ports are taken as-is rather than duplicated:
///
/// - **`browser-keyboard/policy.ts`** lives in `paseo_desktop_browser.dart`.
///   [BrowserKeyboard] below calls its [parseBrowserKeyboardPolicy],
///   [parseBrowserShortcutInput], [matchesBrowserShortcutPolicy],
///   [matchesBrowserShortcutPrefixes] and [classifyBrowserReservedShortcut]
///   directly; nothing about policy matching is re-implemented here.
/// - **`browser-webviews/window-open.ts`** lives in
///   `core/desktop/desktop_browser_window_open.dart` (and is re-exported by
///   `paseo_desktop_browser.dart`). [isPaseoBrowserWebviewAttach] and the
///   navigation guards call its `isAllowedDesktopBrowserUrl`.
/// - **`browser-profile.ts`**'s `PASEO_BROWSER_PROFILE_PARTITION` lives in
///   `paseo_desktop_features.dart` as `paseoBrowserProfilePartition`; the attach
///   gate compares against that constant.
/// - **`app-update-rollout.ts`** lives in `paseo_desktop_features.dart`;
///   [shouldAdmitToRollout] is the thin `intent: "automatic"` wrapper upstream
///   exports and forwards to that port's `shouldAdmitAppUpdate`.
/// - **`app-update-service.ts`** lives in
///   `core/desktop/desktop_app_update_service.dart` as [DesktopAppUpdateService]
///   and its [DesktopAppUpdateRuntime] port. [ElectronStyleAppUpdateRuntime]
///   below is upstream's `ElectronAppUpdateRuntime` written against that
///   existing port instead of a new one.
/// - **`editor-targets/target.ts`** and **`registry.ts`** live in
///   `paseo_desktop_features.dart`. [createEditorTargetRuntime] returns that
///   library's [EditorTargetRuntime] and throws its [EditorTargetError].
/// - **`node:path`** comes from [DesktopBrowserPathOps] in
///   `paseo_desktop_browser.dart`, which already models the POSIX/Win32 split as
///   an injectable value. It has no `extname`/`dirname`, so the two private
///   helpers [_extname] and [_dirname] here are built on top of its `basename`
///   and `fileStem` rather than forking it.
///
/// The one conflict worth naming: `paseo_desktop_features.dart` spells Node's
/// `process.platform` as [EditorTargetPlatform], a name that reads as
/// editor-specific. It is nonetheless the repo's only Node-platform enum and has
/// exactly the members [shouldInstallAppUpdateOnQuit] and
/// [createEditorTargetRuntime] branch on, so both reuse it rather than
/// introducing a second, near-identical enum that callers would have to convert
/// between.
///
/// ## Deviation: module singletons become instances
///
/// `browser-webviews/index.ts` is a module with a private module-level
/// `browserRegistry` and a dozen free functions closing over it, and `menu.ts`
/// keeps module-level `applicationMenuOptions` / `capturingShortcut` globals.
/// Both become instantiable classes ([PaseoBrowserWebviews],
/// [PaseoApplicationMenu]) with the same method names and semantics. The
/// observable behaviour of a single instance is identical; the change exists
/// because a mutable library-level singleton cannot be reset between tests, and
/// upstream's own suite has to hand-unregister every browser it creates to keep
/// cases from leaking into each other.
///
/// ## Deviation: click callbacks become a command enum
///
/// Upstream's menu template carries Electron `click` closures. Here a menu item
/// carries a [DesktopMenuCommand] and the host maps commands to behaviour, so
/// the template is a pure, comparable value. That is what makes it possible to
/// assert on the template at all — a closure has no useful equality.
library;

import 'dart:async';
import 'dart:typed_data';

import '../core/desktop/desktop_app_update_service.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppRuntimeCheckResult,
        DesktopAppUpdateCancellation,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateInfo,
        DesktopAppUpdateRuntime,
        DesktopAppUpdateRuntimeConfiguration;
import '../core/desktop/desktop_browser_window_open.dart'
    show isAllowedDesktopBrowserUrl;
import 'paseo_desktop_browser.dart'
    show
        BrowserKeyboardPolicy,
        BrowserReservedShortcut,
        BrowserReservedShortcutInput,
        BrowserShortcutMatchInput,
        BrowserShortcutPrefix,
        DesktopBrowserPathOps,
        classifyBrowserReservedShortcut,
        matchesBrowserShortcutPolicy,
        matchesBrowserShortcutPrefixes,
        parseBrowserKeyboardPolicy,
        parseBrowserShortcutInput;
import 'paseo_desktop_features.dart'
    show
        EditorTargetError,
        EditorTargetIcon,
        EditorTargetPlatform,
        EditorTargetRuntime,
        paseoBrowserProfilePartition,
        shouldAdmitAppUpdate;

// Re-exported because they appear throughout this library's public signatures.
// A caller wiring up the embedded browser should not have to know which sibling
// port first introduced each type.
export '../core/desktop/desktop_app_update_service.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppRuntimeCheckResult,
        DesktopAppUpdateCancellation,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateInfo,
        DesktopAppUpdateRuntime,
        DesktopAppUpdateRuntimeConfiguration;
export 'paseo_desktop_browser.dart'
    show
        BrowserKeyboardPolicy,
        BrowserReservedShortcut,
        BrowserShortcutInput,
        BrowserShortcutPrefix,
        DesktopBrowserPathOps;
export 'paseo_desktop_features.dart'
    show
        EditorTargetError,
        EditorTargetIcon,
        EditorTargetPlatform,
        EditorTargetRuntime;

// ===========================================================================
// browser-webviews/registry.ts
// ===========================================================================

/// Which browser tab a workspace owns.
final class BrowserWorkspaceRegistration {
  const BrowserWorkspaceRegistration({
    required this.browserId,
    required this.workspaceId,
  });

  final String browserId;
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is BrowserWorkspaceRegistration &&
      other.browserId == browserId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(browserId, workspaceId);

  @override
  String toString() =>
      'BrowserWorkspaceRegistration(browserId: $browserId, '
      'workspaceId: $workspaceId)';
}

/// Which browser tab, in which host window, a guest `webContents` belongs to.
///
/// The host window id is half of the identity on purpose: the same
/// `browserId` can legitimately be attached in two windows at once, and every
/// teardown path has to be able to remove one without touching the other.
final class BrowserWebContentsRegistration {
  const BrowserWebContentsRegistration({
    required this.browserId,
    required this.hostWebContentsId,
  });

  final String browserId;
  final int hostWebContentsId;

  @override
  bool operator ==(Object other) =>
      other is BrowserWebContentsRegistration &&
      other.browserId == browserId &&
      other.hostWebContentsId == hostWebContentsId;

  @override
  int get hashCode => Object.hash(browserId, hostWebContentsId);

  @override
  String toString() =>
      'BrowserWebContentsRegistration(browserId: $browserId, '
      'hostWebContentsId: $hostWebContentsId)';
}

/// The authoritative bookkeeping behind Paseo's embedded browser.
///
/// Three indexes are kept in lockstep:
///
/// - `webContentsId -> (browserId, hostWebContentsId)`, the reverse lookup an
///   incoming IPC message uses to find out which tab it came from;
/// - `(hostWebContentsId, browserId) -> webContentsId`, the forward lookup that
///   guarantees **one** live guest per tab per window — a re-attach evicts the
///   previous guest so a stale `destroyed` event cannot unregister the new one;
/// - `hostWebContentsId -> {workspaceId -> browserId}`, the active tab per
///   workspace per window, kept in *insertion* order so the most recently
///   activated workspace is last.
///
/// Deviation: Dart forbids mutating a map while iterating it, which JS `Map`
/// permits. Every loop that deletes therefore snapshots its keys first; the
/// resulting order of operations is the same as upstream's.
final class PaseoBrowserWebviewRegistry {
  final Map<int, BrowserWebContentsRegistration> _registrationsByWebContentsId =
      <int, BrowserWebContentsRegistration>{};
  final Map<String, int> _webContentsIdsByHostAndBrowserId = <String, int>{};
  final Map<String, String> _workspaceIdsByBrowserId = <String, String>{};
  final Map<int, Map<String, String>> _activeBrowserIdsByHostWindow =
      <int, Map<String, String>>{};

  /// Binds [webContentsId] to [browserId] inside [hostWebContentsId].
  ///
  /// Re-registering the exact same triple is a no-op — that is what keeps a
  /// second `attach` from clearing the window's active-tab selection. Any other
  /// registration evicts whatever previously held either side of the pair, and
  /// the eviction of the *replaced* guest deliberately preserves the active
  /// selection: the tab is not going away, only its backing guest.
  void registerWebContents({
    required int webContentsId,
    required String browserId,
    required int hostWebContentsId,
  }) {
    final hostBrowserKey = _hostBrowserKey(hostWebContentsId, browserId);
    final replacedWebContentsId =
        _webContentsIdsByHostAndBrowserId[hostBrowserKey];
    final existingRegistration = _registrationsByWebContentsId[webContentsId];
    if (replacedWebContentsId == webContentsId &&
        existingRegistration?.browserId == browserId &&
        existingRegistration?.hostWebContentsId == hostWebContentsId) {
      return;
    }
    if (replacedWebContentsId != null &&
        replacedWebContentsId != webContentsId) {
      _removeWebContents(replacedWebContentsId, preserveActiveBrowser: true);
    }
    if (_registrationsByWebContentsId.containsKey(webContentsId)) {
      _removeWebContents(webContentsId);
    }

    _registrationsByWebContentsId[webContentsId] =
        BrowserWebContentsRegistration(
          browserId: browserId,
          hostWebContentsId: hostWebContentsId,
        );
    _webContentsIdsByHostAndBrowserId[hostBrowserKey] = webContentsId;
  }

  /// Drops a guest, if it is still the registered one.
  ///
  /// The `containsKey` guard is what makes a late `destroyed` event from an
  /// already-evicted guest harmless.
  void unregisterWebContents(int webContentsId) {
    if (!_registrationsByWebContentsId.containsKey(webContentsId)) return;
    _removeWebContents(webContentsId);
  }

  /// The browser tab that owns [webContentsId], or null.
  String? getBrowserIdForWebContents(int webContentsId) =>
      _registrationsByWebContentsId[webContentsId]?.browserId;

  /// The full `(browserId, hostWebContentsId)` pair for [webContentsId].
  BrowserWebContentsRegistration? getRegistrationForWebContents(
    int webContentsId,
  ) => _registrationsByWebContentsId[webContentsId];

  /// The live guest backing [browserId] inside [hostWebContentsId], or null.
  int? getWebContentsIdForBrowserInHostWindow(
    int hostWebContentsId,
    String browserId,
  ) =>
      _webContentsIdsByHostAndBrowserId[_hostBrowserKey(
        hostWebContentsId,
        browserId,
      )];

  /// Every distinct attached tab id, sorted.
  ///
  /// Sorted because upstream sorts: the list is surfaced to the renderer and a
  /// Map-iteration order would make it churn for no reason.
  List<String> listBrowserIds() {
    final ids = <String>{
      for (final registration in _registrationsByWebContentsId.values)
        registration.browserId,
    }.toList();
    ids.sort();
    return ids;
  }

  /// Records which workspace a tab belongs to.
  void registerWorkspace(BrowserWorkspaceRegistration input) {
    _workspaceIdsByBrowserId[input.browserId] = input.workspaceId;
  }

  /// Forgets a tab entirely, in every window, including its workspace binding.
  void unregisterBrowser(String browserId) {
    for (final webContentsId in _registrationsByWebContentsId.keys.toList()) {
      final registration = _registrationsByWebContentsId[webContentsId];
      if (registration == null || registration.browserId != browserId) continue;
      _registrationsByWebContentsId.remove(webContentsId);
      _webContentsIdsByHostAndBrowserId.remove(
        _hostBrowserKey(registration.hostWebContentsId, browserId),
      );
    }
    _workspaceIdsByBrowserId.remove(browserId);
    _deleteActiveBrowserReferences(browserId);
  }

  /// Forgets a tab in exactly one window, leaving other windows' copies alone.
  void unregisterBrowserFromHost(int hostWebContentsId, String browserId) {
    final webContentsId = getWebContentsIdForBrowserInHostWindow(
      hostWebContentsId,
      browserId,
    );
    if (webContentsId != null) unregisterWebContents(webContentsId);
  }

  /// The workspace [browserId] belongs to, or null.
  String? getWorkspaceId(String browserId) =>
      _workspaceIdsByBrowserId[browserId];

  /// Whether some *other* window still has [browserId] attached.
  ///
  /// The shell asks this before tearing down a tab's daemon-side state: a tab
  /// closed in one window must survive if a second window is still showing it.
  bool hasBrowserInOtherHostWindow(int hostWebContentsId, String browserId) =>
      _registrationsByWebContentsId.values.any(
        (registration) =>
            registration.browserId == browserId &&
            registration.hostWebContentsId != hostWebContentsId,
      );

  /// Drops every guest belonging to a closing window, and that window's
  /// active-tab selections.
  void unregisterHostWebContents(int hostWebContentsId) {
    for (final webContentsId in _registrationsByWebContentsId.keys.toList()) {
      final registration = _registrationsByWebContentsId[webContentsId];
      if (registration?.hostWebContentsId == hostWebContentsId) {
        unregisterWebContents(webContentsId);
      }
    }
    _activeBrowserIdsByHostWindow.remove(hostWebContentsId);
  }

  /// Every attached tab in [workspaceId], sorted.
  List<String> listBrowserIdsForWorkspace(String workspaceId) =>
      listBrowserIds()
          .where(
            (browserId) => _workspaceIdsByBrowserId[browserId] == workspaceId,
          )
          .toList();

  /// Marks (or, with a null [browserId], clears) the active tab for a workspace
  /// inside one window.
  ///
  /// Both the inner and the outer map entry are removed and re-inserted so that
  /// "most recently activated" is simply "last", which is what
  /// [getActiveBrowserIdForHostWindow] and
  /// [getMostRecentActiveBrowserIdForWorkspace] read. A selection may be made
  /// *before* the guest attaches, which is why the workspace binding is only
  /// updated when the tab is already known.
  void setWorkspaceActiveBrowser({
    required int hostWebContentsId,
    required String workspaceId,
    required String? browserId,
  }) {
    if (browserId == null) {
      final activeBrowserIdsByWorkspace =
          _activeBrowserIdsByHostWindow[hostWebContentsId];
      if (activeBrowserIdsByWorkspace == null) return;
      activeBrowserIdsByWorkspace.remove(workspaceId);
      if (activeBrowserIdsByWorkspace.isEmpty) {
        _activeBrowserIdsByHostWindow.remove(hostWebContentsId);
      }
      return;
    }
    if (_hasBrowser(browserId)) {
      _workspaceIdsByBrowserId[browserId] = workspaceId;
    }
    final activeBrowserIdsByWorkspace =
        _activeBrowserIdsByHostWindow[hostWebContentsId] ?? <String, String>{};
    activeBrowserIdsByWorkspace.remove(workspaceId);
    activeBrowserIdsByWorkspace[workspaceId] = browserId;
    _activeBrowserIdsByHostWindow.remove(hostWebContentsId);
    _activeBrowserIdsByHostWindow[hostWebContentsId] =
        activeBrowserIdsByWorkspace;
  }

  /// The tab the user last activated anywhere in [hostWebContentsId].
  String? getActiveBrowserIdForHostWindow(int hostWebContentsId) {
    final byWorkspace = _activeBrowserIdsByHostWindow[hostWebContentsId];
    if (byWorkspace == null || byWorkspace.isEmpty) return null;
    return byWorkspace.values.last;
  }

  /// The tab active for one workspace in one window.
  String? getActiveBrowserIdForWorkspaceInHostWindow(
    int hostWebContentsId,
    String workspaceId,
  ) => _activeBrowserIdsByHostWindow[hostWebContentsId]?[workspaceId];

  /// The tab active for [workspaceId] in the most recently touched window.
  ///
  /// Scanned newest window first, because "the workspace's browser" with no
  /// window in hand should follow the window the user was last in.
  String? getMostRecentActiveBrowserIdForWorkspace(String workspaceId) {
    final byHostWindow = _activeBrowserIdsByHostWindow.values.toList();
    for (var index = byHostWindow.length - 1; index >= 0; index -= 1) {
      final browserId = byHostWindow[index][workspaceId];
      // JS truthiness: upstream's `if (browserId)` also skips `""`, which a
      // caller could have set. An empty id is not a tab.
      if (browserId != null && browserId.isNotEmpty) return browserId;
    }
    return null;
  }

  void _deleteActiveBrowserReferences(String browserId) {
    for (final hostWebContentsId
        in _activeBrowserIdsByHostWindow.keys.toList()) {
      final activeBrowserIdsByWorkspace =
          _activeBrowserIdsByHostWindow[hostWebContentsId];
      if (activeBrowserIdsByWorkspace == null) continue;
      for (final workspaceId in activeBrowserIdsByWorkspace.keys.toList()) {
        if (activeBrowserIdsByWorkspace[workspaceId] == browserId) {
          activeBrowserIdsByWorkspace.remove(workspaceId);
        }
      }
      if (activeBrowserIdsByWorkspace.isEmpty) {
        _activeBrowserIdsByHostWindow.remove(hostWebContentsId);
      }
    }
  }

  void _deleteActiveBrowserReferencesInHostWindow(
    String browserId,
    int hostWebContentsId,
  ) {
    final activeBrowserIdsByWorkspace =
        _activeBrowserIdsByHostWindow[hostWebContentsId];
    if (activeBrowserIdsByWorkspace == null) return;
    for (final workspaceId in activeBrowserIdsByWorkspace.keys.toList()) {
      if (activeBrowserIdsByWorkspace[workspaceId] == browserId) {
        activeBrowserIdsByWorkspace.remove(workspaceId);
      }
    }
    if (activeBrowserIdsByWorkspace.isEmpty) {
      _activeBrowserIdsByHostWindow.remove(hostWebContentsId);
    }
  }

  void _removeWebContents(
    int webContentsId, {
    bool preserveActiveBrowser = false,
  }) {
    final registration = _registrationsByWebContentsId[webContentsId];
    if (registration == null) return;
    final browserId = registration.browserId;
    final hostWebContentsId = registration.hostWebContentsId;

    _registrationsByWebContentsId.remove(webContentsId);
    _webContentsIdsByHostAndBrowserId.remove(
      _hostBrowserKey(hostWebContentsId, browserId),
    );

    if (!preserveActiveBrowser &&
        !_hasBrowserInHostWindow(browserId, hostWebContentsId)) {
      _deleteActiveBrowserReferencesInHostWindow(browserId, hostWebContentsId);
    }
  }

  bool _hasBrowser(String browserId) => _registrationsByWebContentsId.values
      .any((registration) => registration.browserId == browserId);

  bool _hasBrowserInHostWindow(String browserId, int hostWebContentsId) =>
      _webContentsIdsByHostAndBrowserId.containsKey(
        _hostBrowserKey(hostWebContentsId, browserId),
      );

  String _hostBrowserKey(int hostWebContentsId, String browserId) =>
      '$hostWebContentsId:$browserId';
}

// ===========================================================================
// browser-webviews/index.ts
// ===========================================================================

/// The two things every `webContents`-shaped object must answer.
abstract interface class BrowserWebContentsIdentity {
  int get id;

  bool isDestroyed();
}

/// A guest `webContents` as the attach gate inspects it.
///
/// [hostWebContents] and [session] are compared by **reference identity**, not
/// equality — that is the entire security value of the gate. A renderer can
/// forge any id or string it likes; it cannot forge the object Electron handed
/// the main process for another window's `webContents` or for the shared
/// browser-profile session.
abstract interface class RegisteredBrowserWebContents
    implements BrowserWebContentsIdentity {
  /// The renderer that embeds this guest, or null if it is not embedded.
  BrowserWebContentsIdentity? get hostWebContents;

  /// The Electron `Session` object backing the guest's partition.
  Object get session;

  void setBackgroundThrottling(bool allowed);

  /// Electron `contents.once("destroyed", ...)`.
  void onceDestroyed(void Function() listener);
}

/// What [reloadActiveBrowserOrWindow] needs from a reloadable target.
abstract interface class ReloadableWebContents {
  bool isLoadingMainFrame();

  void stop();

  void reload();

  void reloadIgnoringCache();
}

/// A live Paseo browser guest, resolved from a `webContents` id.
///
/// Deviation: upstream returns Electron's single fat `WebContents` type. This
/// port narrows it to exactly the two capabilities the callers use — identity
/// (so a destroyed guest can be pruned) and reload control (so the View menu
/// can drive it).
abstract interface class PaseoBrowserWebContents
    implements BrowserWebContentsIdentity, ReloadableWebContents {}

/// Electron's `webContents.fromId`, injected.
typedef PaseoBrowserWebContentsLookup =
    PaseoBrowserWebContents? Function(int webContentsId);

/// Electron's per-call `webContents.fromId` used by the attach gate.
typedef RegisteredBrowserWebContentsLookup =
    RegisteredBrowserWebContents? Function(int webContentsId);

/// A navigation about to happen inside a guest.
abstract interface class BrowserWebviewNavigationEvent {
  /// The destination. Null when Electron did not supply one, which the guard
  /// treats as "nothing to check" exactly as upstream's `undefined` does.
  String? get url;

  void preventDefault();
}

/// The three navigation events a guest `webContents` emits.
abstract interface class BrowserWebviewNavigationHost {
  void onWillNavigate(
    void Function(BrowserWebviewNavigationEvent event) listener,
  );

  void onWillFrameNavigate(
    void Function(BrowserWebviewNavigationEvent event) listener,
  );

  void onWillRedirect(
    void Function(BrowserWebviewNavigationEvent event) listener,
  );
}

/// Whether a `<webview>` the renderer is creating is a Paseo browser tab.
///
/// Both halves matter. The URL check keeps a guest off `file:`, `paseo:` and
/// every other privileged scheme; the partition check keeps a page from
/// claiming the shared browser cookie jar for a webview the shell did not
/// create — including the pre-v0.1.108 `persist:paseo-browser-tab-*` partitions,
/// which are legacy storage to be migrated, never a live attach target.
///
/// Deviation: `src` is optional upstream and an absent one is *allowed* (the
/// webview simply has nothing loaded yet). Null and `""` both take that branch
/// here. The URL allowlist itself is the already-ported
/// `isAllowedDesktopBrowserUrl`, which is deliberately stricter than upstream's
/// WHATWG parse — see its own documentation; on an attach gate, stricter is the
/// safe direction.
bool isPaseoBrowserWebviewAttach({String? src, String? partition}) =>
    isAllowedDesktopBrowserUrl(src ?? '') &&
    partition == paseoBrowserProfilePartition;

/// The main-process side of the embedded browser.
///
/// Deviation: upstream is a module holding a private singleton registry; this
/// is the same surface as an instantiable object. See the library doc.
final class PaseoBrowserWebviews {
  factory PaseoBrowserWebviews({
    required PaseoBrowserWebContentsLookup findWebContentsById,
    PaseoBrowserWebviewRegistry? registry,
  }) => PaseoBrowserWebviews._(
    findWebContentsById,
    registry ?? PaseoBrowserWebviewRegistry(),
  );

  PaseoBrowserWebviews._(this._findWebContentsById, this.registry);

  final PaseoBrowserWebContentsLookup _findWebContentsById;

  /// Upstream `getPaseoBrowserWebviewRegistry()`. Exposed because
  /// [BrowserKeyboard] is constructed against the same instance.
  final PaseoBrowserWebviewRegistry registry;

  /// Every attached tab id, sorted.
  List<String> listRegisteredPaseoBrowserIds() => registry.listBrowserIds();

  /// Turns off background throttling and arms the destroy cleanup.
  ///
  /// Throttling is disabled because a background browser tab in Paseo is still
  /// expected to keep running timers and websockets — it is a workspace tab,
  /// not an idle window.
  ///
  /// The `webContents` id is captured *before* the listener is registered:
  /// reading `contents.id` from inside the destroy handler would throw, since
  /// Electron tears the native object down first.
  void preparePaseoBrowserWebContents(RegisteredBrowserWebContents contents) {
    final webContentsId = contents.id;
    contents.setBackgroundThrottling(false);
    contents.onceDestroyed(() {
      registry.unregisterWebContents(webContentsId);
    });
  }

  /// Binds a renderer-claimed `(browserId, workspaceId)` to a real guest.
  ///
  /// Returns false — registering nothing — unless all four hold: the guest
  /// exists, it is alive, its host really is [sender], and it really is on the
  /// shared browser profile session. A renderer that lies about any of them is
  /// trying to adopt another window's tab or a guest outside the browser
  /// profile, so the gate rejects rather than repairs.
  bool registerAttachedPaseoBrowser({
    required String browserId,
    required String workspaceId,
    required int webContentsId,
    required BrowserWebContentsIdentity sender,
    required Object profileSession,
    required RegisteredBrowserWebContentsLookup findWebContents,
  }) {
    final guest = findWebContents(webContentsId);
    if (guest == null ||
        guest.isDestroyed() ||
        !identical(guest.hostWebContents, sender) ||
        !identical(guest.session, profileSession)) {
      return false;
    }

    registry.registerWebContents(
      webContentsId: webContentsId,
      browserId: browserId,
      hostWebContentsId: sender.id,
    );
    registry.registerWorkspace(
      BrowserWorkspaceRegistration(
        browserId: browserId,
        workspaceId: workspaceId,
      ),
    );
    return true;
  }

  /// The tab that owns [contents], or null if it is gone or unknown.
  String? getPaseoBrowserIdForWebContents(
    BrowserWebContentsIdentity? contents,
  ) {
    if (contents == null || contents.isDestroyed()) return null;
    return registry.getBrowserIdForWebContents(contents.id);
  }

  /// Forgets a tab in every window.
  void unregisterPaseoBrowser(String browserId) =>
      registry.unregisterBrowser(browserId);

  /// Forgets a tab in one window only.
  void unregisterPaseoBrowserFromHost(
    int hostWebContentsId,
    String browserId,
  ) => registry.unregisterBrowserFromHost(hostWebContentsId, browserId);

  /// Forgets everything a closing window owned.
  void unregisterPaseoBrowserHost(int hostWebContentsId) =>
      registry.unregisterHostWebContents(hostWebContentsId);

  /// The workspace a tab belongs to.
  String? getPaseoBrowserWorkspaceId(String browserId) =>
      registry.getWorkspaceId(browserId);

  /// Every attached tab in a workspace.
  List<String> listRegisteredPaseoBrowserIdsForWorkspace(String workspaceId) =>
      registry.listBrowserIdsForWorkspace(workspaceId);

  /// Records the active tab for a workspace in one window.
  void setWorkspaceActivePaseoBrowserId({
    required int hostWebContentsId,
    required String workspaceId,
    required String? browserId,
  }) => registry.setWorkspaceActiveBrowser(
    hostWebContentsId: hostWebContentsId,
    workspaceId: workspaceId,
    browserId: browserId,
  );

  /// The workspace's active tab in the most recently touched window.
  String? getWorkspaceActivePaseoBrowserId(String workspaceId) =>
      registry.getMostRecentActiveBrowserIdForWorkspace(workspaceId);

  /// The workspace's active tab in one specific window.
  String? getWorkspaceActivePaseoBrowserIdForHostWindow(
    String workspaceId,
    int hostWebContentsId,
  ) => registry.getActiveBrowserIdForWorkspaceInHostWindow(
    hostWebContentsId,
    workspaceId,
  );

  /// Resolves a tab to its live guest inside one window.
  ///
  /// A registration whose guest has vanished is pruned on the way out, so the
  /// registry self-heals when a `destroyed` event was missed.
  PaseoBrowserWebContents? getPaseoBrowserWebContentsForHostWindow(
    String browserId,
    int hostWebContentsId,
  ) {
    final contentsId = registry.getWebContentsIdForBrowserInHostWindow(
      hostWebContentsId,
      browserId,
    );
    if (contentsId == null) return null;
    return _resolveLiveWebContents(contentsId);
  }

  /// Resolves the window's active tab to its live guest.
  PaseoBrowserWebContents? getActivePaseoBrowserWebContentsForHostWindow(
    int hostWebContentsId,
  ) {
    final browserId = registry.getActiveBrowserIdForHostWindow(
      hostWebContentsId,
    );
    // JS truthiness: upstream's `if (!browserId)` also bails on `""`.
    if (browserId == null || browserId.isEmpty) return null;
    final contentsId = registry.getWebContentsIdForBrowserInHostWindow(
      hostWebContentsId,
      browserId,
    );
    if (contentsId == null) return null;
    return _resolveLiveWebContents(contentsId);
  }

  PaseoBrowserWebContents? _resolveLiveWebContents(int contentsId) {
    final contents = _findWebContentsById(contentsId);
    if (contents != null && !contents.isDestroyed()) return contents;
    registry.unregisterWebContents(contentsId);
    return null;
  }

  /// Blocks any guest navigation that leaves the allowed schemes.
  ///
  /// All three events are guarded, not just `will-navigate`: a subframe
  /// (`will-frame-navigate`) and a server redirect (`will-redirect`) reach a
  /// `file:` or custom-scheme URL without ever firing the top-level event.
  void registerBrowserWebviewNavigationGuards(
    BrowserWebviewNavigationHost contents,
  ) {
    contents.onWillNavigate(_preventUnsafeBrowserWebviewNavigation);
    contents.onWillFrameNavigate(_preventUnsafeBrowserWebviewNavigation);
    contents.onWillRedirect(_preventUnsafeBrowserWebviewNavigation);
  }

  static void _preventUnsafeBrowserWebviewNavigation(
    BrowserWebviewNavigationEvent event,
  ) {
    if (!isAllowedDesktopBrowserUrl(event.url ?? '')) {
      event.preventDefault();
    }
  }
}

// ===========================================================================
// browser-keyboard/index.ts
// ===========================================================================

/// Renderer -> main: "here is the shell's keyboard policy".
const String browserKeyboardPolicyInputChannel =
    'paseo:browser:set-shortcut-policy';

/// Main -> guest: the policy a guest frame should enforce.
const String browserKeyboardPolicyOutputChannel =
    'paseo:browser-keyboard-policy';

/// Guest -> main: "I reloaded, send me the policy again".
const String browserKeyboardPolicyRequestChannel =
    'paseo:browser-keyboard-policy-request';

/// Guest -> main: a keystroke the guest decided the shell owns.
const String browserKeyboardShortcutInputChannel =
    'paseo:browser-shortcut-input';

/// Main -> host renderer: a validated shell keystroke from a guest.
const String browserKeyboardShortcutOutputChannel =
    'paseo:event:browser-shortcut-input';

/// Main -> host renderer: a browser-owned shortcut the main process handled.
const String browserKeyboardReservedShortcutOutputChannel =
    'paseo:event:browser-shortcut';

/// The minimum a `webContents` must expose to take part in keyboard routing.
abstract interface class BrowserKeyboardContentsIdentity {
  int get id;
}

/// A frame inside a guest's subtree.
abstract interface class BrowserKeyboardFrame {
  /// Electron marks a frame detached once it has been removed from the tree;
  /// sending to one throws.
  bool get detached;

  void send(String channel, Object? payload);
}

/// A `before-input-event` that can still be cancelled.
abstract interface class BrowserKeyboardInputEvent {
  void preventDefault();
}

/// One raw Electron `before-input-event` payload.
///
/// Deviation: upstream types this as `Electron.Input`, which carries a dozen
/// fields; only these eight are ever read. [type] stays a raw string because
/// the main process receives whatever Electron sends and only ever compares it
/// against `keyDown`.
final class BrowserKeyboardKeyInput {
  const BrowserKeyboardKeyInput({
    required this.code,
    required this.key,
    this.alt = false,
    this.control = false,
    this.isAutoRepeat = false,
    this.meta = false,
    this.shift = false,
    this.type = 'keyDown',
  });

  final bool alt;
  final String code;
  final bool control;

  /// Electron's `isAutoRepeat`, which the policy layer calls `repeat`.
  final bool isAutoRepeat;

  final String key;
  final bool meta;
  final bool shift;
  final String type;
}

/// A guest `webContents` as the keyboard runtime drives it.
///
/// Deviation: upstream reaches `contents.mainFrame.framesInSubtree`;
/// [framesInSubtree] flattens that one hop so a host adapter is not forced to
/// model an intermediate `mainFrame` object it has no other use for.
abstract interface class BrowserKeyboardGuestContents
    implements BrowserKeyboardContentsIdentity {
  List<BrowserKeyboardFrame> get framesInSubtree;

  bool isDestroyed();

  bool isLoadingMainFrame();

  void onDomReady(void Function() listener);

  void onBeforeInputEvent(
    void Function(
      BrowserKeyboardInputEvent event,
      BrowserKeyboardKeyInput input,
    )
    listener,
  );

  void onceDestroyed(void Function() listener);

  void reload();

  void reloadIgnoringCache();

  /// Electron `setIgnoreMenuShortcuts` — when true, the application menu does
  /// not get first refusal on this keystroke.
  void setIgnoreMenuShortcuts(bool ignore);

  void stop();
}

/// The renderer window that embeds a guest.
abstract interface class BrowserKeyboardHostContents
    implements BrowserKeyboardContentsIdentity {
  bool isDestroyed();

  void send(String channel, Object? payload);
}

/// The policy payload pushed down to a guest frame.
///
/// Deviation: upstream sends the object literal `{...policy, browserId}`. This
/// is that flat shape as a value type; [toJson] reproduces the exact wire form
/// for a host adapter that has to serialise it.
final class BrowserKeyboardPolicyMessage {
  const BrowserKeyboardPolicyMessage({
    required this.policy,
    required this.browserId,
  });

  final BrowserKeyboardPolicy policy;

  /// Which tab the receiving frame belongs to, so a guest can ignore a policy
  /// that raced with a re-attach.
  final String browserId;

  List<BrowserShortcutPrefix> get menuPrefixes => policy.menuPrefixes;

  List<BrowserShortcutPrefix> get prefixes => policy.prefixes;

  Map<String, Object?> toJson() => <String, Object?>{
    'menuPrefixes': menuPrefixes,
    'prefixes': prefixes,
    'browserId': browserId,
  };

  @override
  bool operator ==(Object other) =>
      other is BrowserKeyboardPolicyMessage &&
      other.policy == policy &&
      other.browserId == browserId;

  @override
  int get hashCode => Object.hash(policy, browserId);

  @override
  String toString() =>
      'BrowserKeyboardPolicyMessage(browserId: $browserId, policy: $policy)';
}

/// A browser-owned shortcut the main process handled and is reporting upward.
///
/// Only [BrowserReservedShortcut.focusUrl] is ever sent: reload and
/// force-reload are executed on the guest and need no renderer involvement.
final class BrowserReservedShortcutMessage {
  const BrowserReservedShortcutMessage({
    required this.action,
    required this.browserId,
  });

  final BrowserReservedShortcut action;
  final String browserId;

  /// The exact spelling upstream puts on the wire.
  String get actionWireName => switch (action) {
    BrowserReservedShortcut.focusUrl => 'focus-url',
    BrowserReservedShortcut.reload => 'reload',
    BrowserReservedShortcut.forceReload => 'force-reload',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'action': actionWireName,
    'browserId': browserId,
  };

  @override
  bool operator ==(Object other) =>
      other is BrowserReservedShortcutMessage &&
      other.action == action &&
      other.browserId == browserId;

  @override
  int get hashCode => Object.hash(action, browserId);

  @override
  String toString() =>
      'BrowserReservedShortcutMessage(action: $actionWireName, '
      'browserId: $browserId)';
}

/// An inbound IPC message, as the main process sees it.
abstract interface class BrowserKeyboardIpcEvent {
  BrowserKeyboardContentsIdentity get sender;

  /// Electron `event.reply` — answers on the sender's own channel.
  void reply(String channel, Object? payload);
}

/// Electron's `ipcMain`, injected.
///
/// [handle] is the invoke/handle pair (the renderer awaits a result); [on] is
/// fire-and-forget. The distinction is preserved because the renderer side
/// depends on it.
abstract interface class BrowserKeyboardIpcRegistrar {
  void handle(
    String channel,
    void Function(BrowserKeyboardIpcEvent event, Object? payload) handler,
  );

  void on(
    String channel,
    void Function(BrowserKeyboardIpcEvent event, Object? payload) handler,
  );
}

final class _BrowserKeyboardGuest {
  const _BrowserKeyboardGuest(this.contents, this.hostContents);

  final BrowserKeyboardGuestContents contents;
  final BrowserKeyboardHostContents hostContents;
}

/// Routes keystrokes between the shell, the application menu and browser guests.
///
/// Three jobs, all of which have to agree about *who owns a keystroke*:
///
/// 1. push the shell's policy into every guest frame, so the guest preload can
///    stop a page from swallowing a shortcut the shell claims;
/// 2. decide, per keystroke, whether the application menu is allowed to fire —
///    otherwise Electron's accelerators would steal combos the shell owns;
/// 3. execute the three shortcuts the embedded browser owns outright.
///
/// Every lookup is re-validated against the registry at the moment it is used
/// rather than trusted from attach time, because a guest can be re-attached to
/// a different tab, or its host window can close, between events.
final class BrowserKeyboard {
  factory BrowserKeyboard(
    PaseoBrowserWebviewRegistry browserRegistry, {
    required bool isMac,
  }) => BrowserKeyboard._(browserRegistry, isMac);

  BrowserKeyboard._(this._browserRegistry, this._isMac);

  final PaseoBrowserWebviewRegistry _browserRegistry;

  /// Deviation: upstream reads `process.platform === "darwin"` inline. Injected
  /// here so the reserved-shortcut modifier can be exercised on any host.
  final bool _isMac;

  final Map<int, _BrowserKeyboardGuest> _attachedGuestsByWebContentsId =
      <int, _BrowserKeyboardGuest>{};
  final Map<int, BrowserKeyboardPolicy> _policiesByHostWebContentsId =
      <int, BrowserKeyboardPolicy>{};

  /// Wires the three IPC channels this runtime listens on.
  void registerIpc(BrowserKeyboardIpcRegistrar ipc) {
    ipc.handle(browserKeyboardPolicyInputChannel, (event, rawPolicy) {
      publish(event.sender.id, rawPolicy);
    });
    ipc.on(browserKeyboardShortcutInputChannel, (event, rawInput) {
      forwardShortcutInput(event.sender, rawInput);
    });
    ipc.on(browserKeyboardPolicyRequestChannel, (event, _) {
      final payload = _policyForGuest(event.sender);
      if (payload != null) {
        event.reply(browserKeyboardPolicyOutputChannel, payload);
      }
    });
  }

  /// Starts routing keystrokes for a guest.
  ///
  /// Refuses when the registry does not already agree that this guest belongs
  /// to this host window — the keyboard runtime never establishes identity, it
  /// only consumes what [PaseoBrowserWebviews.registerAttachedPaseoBrowser]
  /// established. Re-attaching the identical pair is a no-op, so a duplicate
  /// `attach` cannot double-register the input listener and handle a reload
  /// twice.
  void attach({
    required BrowserKeyboardGuestContents contents,
    required BrowserKeyboardHostContents hostContents,
  }) {
    final webContentsId = contents.id;
    final registration = _browserRegistry.getRegistrationForWebContents(
      webContentsId,
    );
    if (registration == null ||
        registration.hostWebContentsId != hostContents.id) {
      return;
    }
    final attachedGuest = _attachedGuestsByWebContentsId[webContentsId];
    if (attachedGuest != null &&
        identical(attachedGuest.contents, contents) &&
        identical(attachedGuest.hostContents, hostContents)) {
      return;
    }
    final guest = _BrowserKeyboardGuest(contents, hostContents);
    _attachedGuestsByWebContentsId[webContentsId] = guest;

    // `webContentsId` is captured rather than re-read: Electron's `id` getter
    // throws once the native object is gone, and this listener runs then.
    contents.onceDestroyed(() {
      if (identical(_attachedGuestsByWebContentsId[webContentsId], guest)) {
        _attachedGuestsByWebContentsId.remove(webContentsId);
      }
    });
    contents.onDomReady(() {
      final currentRegistration = _registrationForGuest(webContentsId, guest);
      if (currentRegistration == null) return;
      final policy =
          _policiesByHostWebContentsId[currentRegistration.hostWebContentsId];
      if (policy != null) {
        _sendPolicy(guest, currentRegistration.browserId, policy);
      }
    });
    contents.onBeforeInputEvent((event, keyboardInput) {
      final currentRegistration = _registrationForGuest(webContentsId, guest);
      if (currentRegistration != null) {
        _handleGuestInput(guest, currentRegistration, event, keyboardInput);
      }
    });

    final policy = _policiesByHostWebContentsId[registration.hostWebContentsId];
    if (policy != null) {
      _sendPolicy(guest, registration.browserId, policy);
    }
  }

  /// Accepts a policy from a host window and fans it out to that window's
  /// guests.
  ///
  /// A malformed policy is dropped whole — never half-applied — so the shell
  /// keeps enforcing the last policy it successfully published rather than
  /// silently losing shortcuts.
  void publish(int hostWebContentsId, Object? rawPolicy) {
    final policy = parseBrowserKeyboardPolicy(rawPolicy);
    if (policy == null) return;
    _policiesByHostWebContentsId[hostWebContentsId] = policy;
    for (final entry in _attachedGuestsByWebContentsId.entries.toList()) {
      final registration = _registrationForGuest(entry.key, entry.value);
      if (registration?.hostWebContentsId == hostWebContentsId) {
        _sendPolicy(entry.value, registration!.browserId, policy);
      }
    }
  }

  /// Forwards a guest-reported keystroke to the window that embeds it.
  ///
  /// The `browserId` in the message must match the registry's own answer for
  /// the sending guest. A guest that reports someone else's tab id is dropped,
  /// not corrected: routing it anyway would let a compromised page drive the
  /// shell's shortcut handler on behalf of a different tab.
  void forwardShortcutInput(
    BrowserKeyboardContentsIdentity contents,
    Object? rawInput,
  ) {
    final input = parseBrowserShortcutInput(rawInput);
    if (input == null) return;
    final guest = _attachedGuestsByWebContentsId[contents.id];
    if (guest == null) return;
    final registration = _registrationForGuest(contents.id, guest);
    if (registration == null ||
        registration.browserId != input.browserId ||
        guest.hostContents.isDestroyed()) {
      return;
    }
    guest.hostContents.send(browserKeyboardShortcutOutputChannel, input);
  }

  /// Forgets a closing window's policy.
  ///
  /// Guests are not detached here: they are removed by their own `destroyed`
  /// event, which fires independently of the host window's teardown order.
  void detachHost(int hostWebContentsId) {
    _policiesByHostWebContentsId.remove(hostWebContentsId);
  }

  void _handleGuestInput(
    _BrowserKeyboardGuest guest,
    BrowserWebContentsRegistration registration,
    BrowserKeyboardInputEvent event,
    BrowserKeyboardKeyInput input,
  ) {
    final policy = _policiesByHostWebContentsId[registration.hostWebContentsId];
    final matchInput = BrowserShortcutMatchInput(
      alt: input.alt,
      code: input.code,
      control: input.control,
      key: input.key,
      meta: input.meta,
      repeat: input.isAutoRepeat,
      shift: input.shift,
    );
    final belongsToBrowserPolicy =
        policy != null && matchesBrowserShortcutPolicy(policy, matchInput);
    final belongsToMenuPolicy =
        policy != null &&
        matchesBrowserShortcutPrefixes(policy.menuPrefixes, matchInput);
    // A keystroke with no command modifier can never be a menu accelerator, so
    // the menu is bypassed unconditionally. With a modifier the menu is only
    // bypassed when the shell already claims the combo — otherwise Cmd+Q and
    // friends would stop working inside a browser tab.
    guest.contents.setIgnoreMenuShortcuts(
      (!input.control && !input.meta) ||
          belongsToBrowserPolicy ||
          belongsToMenuPolicy,
    );
    final reservedShortcut = classifyBrowserReservedShortcut(
      BrowserReservedShortcutInput(
        alt: input.alt,
        control: input.control,
        key: input.key,
        meta: input.meta,
        shift: input.shift,
        type: input.type,
      ),
      isMac: _isMac,
    );

    switch (reservedShortcut) {
      case BrowserReservedShortcut.forceReload:
        event.preventDefault();
        guest.contents.reloadIgnoringCache();
      case BrowserReservedShortcut.reload:
        event.preventDefault();
        // Cmd/Ctrl+R on a page that is still loading means "stop", matching
        // every real browser's reload button.
        if (guest.contents.isLoadingMainFrame()) {
          guest.contents.stop();
        } else {
          guest.contents.reload();
        }
      case BrowserReservedShortcut.focusUrl:
        event.preventDefault();
        if (!guest.hostContents.isDestroyed()) {
          guest.hostContents.send(
            browserKeyboardReservedShortcutOutputChannel,
            BrowserReservedShortcutMessage(
              action: BrowserReservedShortcut.focusUrl,
              browserId: registration.browserId,
            ),
          );
        }
      case null:
        return;
    }
  }

  BrowserWebContentsRegistration? _registrationForGuest(
    int webContentsId,
    _BrowserKeyboardGuest guest,
  ) {
    if (!identical(_attachedGuestsByWebContentsId[webContentsId], guest)) {
      return null;
    }
    if (guest.hostContents.isDestroyed()) return null;
    final registration = _browserRegistry.getRegistrationForWebContents(
      webContentsId,
    );
    return registration?.hostWebContentsId == guest.hostContents.id
        ? registration
        : null;
  }

  void _sendPolicy(
    _BrowserKeyboardGuest guest,
    String browserId,
    BrowserKeyboardPolicy policy,
  ) {
    if (guest.contents.isDestroyed()) return;
    final payload = BrowserKeyboardPolicyMessage(
      policy: policy,
      browserId: browserId,
    );
    // Every frame, not just the main one: an iframe runs its own preload and
    // would otherwise enforce nothing.
    for (final frame in guest.contents.framesInSubtree) {
      if (!frame.detached) {
        frame.send(browserKeyboardPolicyOutputChannel, payload);
      }
    }
  }

  BrowserKeyboardPolicyMessage? _policyForGuest(
    BrowserKeyboardContentsIdentity contents,
  ) {
    final guest = _attachedGuestsByWebContentsId[contents.id];
    if (guest == null) return null;
    final registration = _registrationForGuest(contents.id, guest);
    if (registration == null) return null;
    final policy = _policiesByHostWebContentsId[registration.hostWebContentsId];
    return policy == null
        ? null
        : BrowserKeyboardPolicyMessage(
            policy: policy,
            browserId: registration.browserId,
          );
  }
}

// ===========================================================================
// menu.ts
// ===========================================================================

/// Electron menu roles this template uses.
///
/// [wireName] is the exact string Electron expects — note `togglefullscreen`
/// is all lowercase while `toggleDevTools` and `hideOthers` are camelCase; that
/// asymmetry is Electron's, not a typo.
enum DesktopMenuRole {
  about('about'),
  services('services'),
  hide('hide'),
  hideOthers('hideOthers'),
  unhide('unhide'),
  quit('quit'),
  undo('undo'),
  redo('redo'),
  cut('cut'),
  copy('copy'),
  paste('paste'),
  selectAll('selectAll'),
  toggleDevTools('toggleDevTools'),
  toggleFullScreen('togglefullscreen'),
  minimize('minimize'),
  zoom('zoom'),
  front('front'),
  close('close');

  const DesktopMenuRole(this.wireName);

  final String wireName;
}

/// The menu commands Paseo implements itself.
///
/// Deviation: upstream attaches an Electron `click` closure to each of these
/// items. Modelling them as an enum keeps the template a comparable value; the
/// host maps each command to the closure it would have written inline.
enum DesktopMenuCommand {
  newWindow,
  zoomIn,
  zoomOut,
  actualSize,
  reload,
  forceReload,
}

/// One entry in a menu template.
sealed class DesktopMenuItem {
  const DesktopMenuItem();
}

/// A horizontal rule.
final class DesktopMenuSeparator extends DesktopMenuItem {
  const DesktopMenuSeparator();

  @override
  bool operator ==(Object other) => other is DesktopMenuSeparator;

  @override
  int get hashCode => (DesktopMenuSeparator).hashCode;

  @override
  String toString() => 'DesktopMenuSeparator()';
}

/// An item Electron implements for us (copy, quit, toggle dev tools, ...).
final class DesktopMenuRoleItem extends DesktopMenuItem {
  const DesktopMenuRoleItem(this.role, {this.label, this.enabled = true});

  final DesktopMenuRole role;

  /// An override for Electron's built-in label. Null keeps Electron's own,
  /// which is already localised.
  final String? label;

  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is DesktopMenuRoleItem &&
      other.role == role &&
      other.label == label &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(role, label, enabled);

  @override
  String toString() =>
      'DesktopMenuRoleItem(${role.wireName}, label: $label, '
      'enabled: $enabled)';
}

/// An item Paseo handles itself.
final class DesktopMenuCommandItem extends DesktopMenuItem {
  const DesktopMenuCommandItem({
    required this.label,
    required this.command,
    this.accelerator,
    this.enabled = true,
  });

  final String label;
  final DesktopMenuCommand command;

  /// Electron accelerator syntax, e.g. `CmdOrCtrl+Shift+N`.
  final String? accelerator;

  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is DesktopMenuCommandItem &&
      other.label == label &&
      other.command == command &&
      other.accelerator == accelerator &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(label, command, accelerator, enabled);

  @override
  String toString() =>
      'DesktopMenuCommandItem($label, ${command.name}, '
      'accelerator: $accelerator, enabled: $enabled)';
}

/// A top-level menu, or a nested one.
final class DesktopMenuSubmenu extends DesktopMenuItem {
  const DesktopMenuSubmenu({required this.label, required this.items});

  final String label;
  final List<DesktopMenuItem> items;

  @override
  bool operator ==(Object other) =>
      other is DesktopMenuSubmenu &&
      other.label == label &&
      _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(label, Object.hashAll(items));

  @override
  String toString() => 'DesktopMenuSubmenu($label, $items)';
}

/// What the renderer asked for when it requested a context menu.
///
/// Deviation: [kind] stays a raw nullable string rather than an enum because it
/// arrives over IPC from the renderer and is only ever compared against the one
/// literal `"terminal"`. Anything else — including a plausible-looking new kind
/// — must produce no menu at all, and a raw string makes that impossible to get
/// wrong by adding an enum member.
final class ShowContextMenuInput {
  const ShowContextMenuInput({this.kind, this.hasSelection});

  final String? kind;

  /// Upstream tests `hasSelection === true`, so a missing or non-boolean value
  /// disables Copy. Modelled as a nullable bool with the same three-way meaning.
  final bool? hasSelection;
}

/// The only context menu Paseo shows: the terminal one.
const String terminalContextMenuKind = 'terminal';

/// Builds the terminal context menu, or null when [input] is not a terminal
/// request.
///
/// Copy is enabled only for an explicit `hasSelection: true` — a copy with no
/// selection would silently clear the clipboard.
List<DesktopMenuItem>? buildTerminalContextMenuTemplate(
  ShowContextMenuInput? input,
) {
  if (input?.kind != terminalContextMenuKind) return null;
  return <DesktopMenuItem>[
    DesktopMenuRoleItem(
      DesktopMenuRole.copy,
      label: 'Copy',
      enabled: input?.hasSelection == true,
    ),
    const DesktopMenuRoleItem(DesktopMenuRole.paste, label: 'Paste'),
    const DesktopMenuSeparator(),
    const DesktopMenuRoleItem(DesktopMenuRole.selectAll, label: 'Select All'),
  ];
}

/// Builds the application menu.
///
/// [capturingShortcut] disables the three zoom accelerators. While the user is
/// recording a keybinding, `Cmd+-` / `Cmd+=` / `Cmd+0` must reach the renderer
/// as keystrokes to record, not zoom the window.
///
/// The macOS branch adds the standard app menu and swaps the Window menu's
/// trailing `close` for `front`, which is what platform conventions require.
List<DesktopMenuItem> buildPaseoApplicationMenuTemplate({
  required bool isMac,
  required String appName,
  required bool capturingShortcut,
}) {
  final zoomEnabled = !capturingShortcut;
  return <DesktopMenuItem>[
    if (isMac)
      DesktopMenuSubmenu(
        label: appName,
        items: const <DesktopMenuItem>[
          DesktopMenuRoleItem(DesktopMenuRole.about),
          DesktopMenuSeparator(),
          DesktopMenuRoleItem(DesktopMenuRole.services),
          DesktopMenuSeparator(),
          DesktopMenuRoleItem(DesktopMenuRole.hide),
          DesktopMenuRoleItem(DesktopMenuRole.hideOthers),
          DesktopMenuRoleItem(DesktopMenuRole.unhide),
          DesktopMenuSeparator(),
          DesktopMenuRoleItem(DesktopMenuRole.quit),
        ],
      ),
    const DesktopMenuSubmenu(
      label: 'File',
      items: <DesktopMenuItem>[
        DesktopMenuCommandItem(
          label: 'New Window',
          accelerator: 'CmdOrCtrl+Shift+N',
          command: DesktopMenuCommand.newWindow,
        ),
      ],
    ),
    const DesktopMenuSubmenu(
      label: 'Edit',
      items: <DesktopMenuItem>[
        DesktopMenuRoleItem(DesktopMenuRole.undo),
        DesktopMenuRoleItem(DesktopMenuRole.redo),
        DesktopMenuSeparator(),
        DesktopMenuRoleItem(DesktopMenuRole.cut),
        DesktopMenuRoleItem(DesktopMenuRole.copy),
        DesktopMenuRoleItem(DesktopMenuRole.paste),
        DesktopMenuRoleItem(DesktopMenuRole.selectAll),
      ],
    ),
    DesktopMenuSubmenu(
      label: 'View',
      items: <DesktopMenuItem>[
        DesktopMenuCommandItem(
          label: 'Zoom In',
          accelerator: 'CmdOrCtrl+=',
          enabled: zoomEnabled,
          command: DesktopMenuCommand.zoomIn,
        ),
        DesktopMenuCommandItem(
          label: 'Zoom Out',
          accelerator: 'CmdOrCtrl+-',
          enabled: zoomEnabled,
          command: DesktopMenuCommand.zoomOut,
        ),
        DesktopMenuCommandItem(
          label: 'Actual Size',
          accelerator: 'CmdOrCtrl+0',
          enabled: zoomEnabled,
          command: DesktopMenuCommand.actualSize,
        ),
        const DesktopMenuSeparator(),
        const DesktopMenuCommandItem(
          label: 'Reload',
          accelerator: 'CmdOrCtrl+R',
          command: DesktopMenuCommand.reload,
        ),
        const DesktopMenuCommandItem(
          label: 'Force Reload',
          accelerator: 'CmdOrCtrl+Shift+R',
          command: DesktopMenuCommand.forceReload,
        ),
        const DesktopMenuRoleItem(DesktopMenuRole.toggleDevTools),
        const DesktopMenuSeparator(),
        const DesktopMenuRoleItem(DesktopMenuRole.toggleFullScreen),
      ],
    ),
    DesktopMenuSubmenu(
      label: 'Window',
      items: <DesktopMenuItem>[
        const DesktopMenuRoleItem(DesktopMenuRole.minimize),
        const DesktopMenuRoleItem(DesktopMenuRole.zoom),
        if (isMac) ...const <DesktopMenuItem>[
          DesktopMenuSeparator(),
          DesktopMenuRoleItem(DesktopMenuRole.front),
        ] else
          const DesktopMenuRoleItem(DesktopMenuRole.close),
      ],
    ),
  ];
}

/// A window's own `webContents`, which is both reloadable and identifiable.
abstract interface class ReloadableWindowWebContents
    implements ReloadableWebContents {
  int get id;
}

/// The slice of an Electron `BrowserWindow` the reload rule needs.
abstract interface class ReloadableWindow {
  ReloadableWindowWebContents get webContents;
}

/// Resolves the active browser guest for a host window, if any.
typedef ActiveBrowserContentsResolver =
    ReloadableWebContents? Function(int hostWebContentsId);

/// Reload targets the active browser tab, not the Paseo window.
///
/// This is what makes Cmd/Ctrl+R behave the way a user expects while a browser
/// tab is focused: reloading the Paseo window itself would throw away the whole
/// workspace UI. Only when the window has no active browser does the window
/// reload.
///
/// Force-reload skips the "stop a load in progress" branch on purpose:
/// Cmd+Shift+R means "fetch it all again", including when a load is already
/// under way.
void reloadActiveBrowserOrWindow({
  required ReloadableWindow win,
  required ActiveBrowserContentsResolver getActiveBrowserContentsForHostWindow,
  bool ignoreCache = false,
}) {
  final browserContents = getActiveBrowserContentsForHostWindow(
    win.webContents.id,
  );
  if (browserContents != null) {
    if (ignoreCache) {
      browserContents.reloadIgnoringCache();
      return;
    }
    if (browserContents.isLoadingMainFrame()) {
      browserContents.stop();
      return;
    }
    browserContents.reload();
    return;
  }

  if (ignoreCache) {
    win.webContents.reloadIgnoringCache();
    return;
  }
  win.webContents.reload();
}

/// Owns the application menu and rebuilds it when the capture state changes.
///
/// Deviation: upstream keeps `applicationMenuOptions` and `capturingShortcut`
/// as module-level mutable globals and rebuilds via a private function. This is
/// the same state machine as an object. [setup] corresponds to
/// `setupApplicationMenu`; the IPC handlers upstream registers inline become the
/// three public methods below, so the host owns channel naming.
final class PaseoApplicationMenu {
  factory PaseoApplicationMenu({
    required bool isMac,
    required String appName,
    required void Function(List<DesktopMenuItem> template) setApplicationMenu,
    required void Function(List<DesktopMenuItem> template) popupContextMenu,
  }) => PaseoApplicationMenu._(
    isMac,
    appName,
    setApplicationMenu,
    popupContextMenu,
  );

  PaseoApplicationMenu._(
    this._isMac,
    this._appName,
    this._setApplicationMenu,
    this._popupContextMenu,
  );

  final bool _isMac;
  final String _appName;
  final void Function(List<DesktopMenuItem> template) _setApplicationMenu;
  final void Function(List<DesktopMenuItem> template) _popupContextMenu;

  bool _capturingShortcut = false;
  bool _isSetUp = false;

  /// Whether the zoom accelerators are currently suppressed.
  bool get isCapturingShortcut => _capturingShortcut;

  /// Installs the menu for the first time.
  ///
  /// Until this is called, every other method still updates state but installs
  /// nothing — upstream's `rebuildApplicationMenu` bails while
  /// `applicationMenuOptions` is null, and that guard is what keeps a stray IPC
  /// message during startup from building a menu with no handlers behind it.
  void setup() {
    _isSetUp = true;
    _rebuild();
  }

  /// Handles `paseo:menu:set-capturing-shortcut`.
  ///
  /// [capturing] is deliberately [Object] rather than `bool`: the value comes
  /// from the renderer, and upstream's `capturing === true` treats every other
  /// value — missing, null, `"true"`, `1` — as "not capturing". Failing closed
  /// here means an oddly-typed message can never leave zoom permanently broken.
  void setCapturingShortcut(Object? capturing) {
    _capturingShortcut = capturing == true;
    _rebuild();
  }

  /// Handles a main window finishing a load.
  ///
  /// If the renderer reloads mid-capture (Cmd+R while recording), its cleanup
  /// effect never runs and it can never send `false`, so the main process
  /// resets the flag itself. Browser guests are not `BrowserWindow`s, so they
  /// never reach this path and cannot clear a real capture.
  void handleWindowDidFinishLoad() {
    if (!_capturingShortcut) return;
    _capturingShortcut = false;
    _rebuild();
  }

  /// Handles `paseo:menu:showContextMenu`. Returns whether a menu was shown.
  ///
  /// [hasWindow] is upstream's `BrowserWindow.fromWebContents(event.sender)`
  /// lookup: a request from a `webContents` with no window (a browser guest,
  /// say) is dropped before the kind is even examined.
  bool showContextMenu({required bool hasWindow, ShowContextMenuInput? input}) {
    if (!hasWindow) return false;
    final template = buildTerminalContextMenuTemplate(input);
    if (template == null) return false;
    _popupContextMenu(template);
    return true;
  }

  void _rebuild() {
    if (!_isSetUp) return;
    _setApplicationMenu(
      buildPaseoApplicationMenuTemplate(
        isMac: _isMac,
        appName: _appName,
        capturingShortcut: _capturingShortcut,
      ),
    );
  }
}

// ===========================================================================
// auto-updater.ts
// ===========================================================================

/// Whether an *automatic* update check may take this release right now.
///
/// Upstream's `shouldAdmitToRollout` is exactly `shouldAdmitAppUpdate` with
/// `intent: "automatic"` pinned: the wrapper exists so the staged-rollout gate
/// can be handed to electron-updater's `isUserWithinRollout` hook, which has no
/// way to express a user-initiated check. A manual check goes through
/// `shouldAdmitAppUpdate` directly and is always admitted.
bool shouldAdmitToRollout({
  required DesktopAppReleaseChannel channel,
  required double? rolloutHours,
  required String? releaseDate,
  required DateTime now,
  required double bucket,
}) => shouldAdmitAppUpdate(
  channel: channel,
  intent: DesktopAppUpdateCheckIntent.automatic,
  rolloutHours: rolloutHours,
  releaseDate: releaseDate,
  now: now,
  bucket: bucket,
);

/// Whether a downloaded update may be installed during app quit.
///
/// Everything except a Linux AppImage may. AppImage's no-relaunch install path
/// blocks while it launches the replacement binary, and the running file has
/// already been replaced by then, so the quit can hang forever; those builds
/// stay on the explicit, user-visible install path instead.
bool shouldInstallAppUpdateOnQuit({
  required EditorTargetPlatform platform,
  required bool isAppImage,
}) => !(platform == EditorTargetPlatform.linux && isAppImage);

/// The `builder-util-runtime` UUID shape check, as a predicate.
///
/// Deviation: upstream calls `UUID.check(id)`, which returns a *descriptor
/// object* (truthy) or `false`. Only its truthiness is used, so this port
/// returns a bool. Verified against the frozen module: the check lowercases the
/// input and tests `^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$` — nothing
/// about version or variant bits is validated, and the nil UUID passes.
bool isBuilderUtilUuid(String value) =>
    _uuidPattern.hasMatch(value.toLowerCase());

final RegExp _uuidPattern = RegExp(
  r'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
);

/// Everything [resolveStagingUserId] needs from the host.
///
/// Split this finely because each capability fails differently and upstream
/// reacts to each failure differently: a missing file is the normal
/// first-run path, any other read failure is worth a warning, and a write
/// failure is warned about but never fatal.
abstract interface class StagingUserIdHost {
  /// Reads the id file as UTF-8. Throws when it cannot be read.
  Future<String> readTextFile(String path);

  /// Whether [error] is the "file does not exist" failure.
  ///
  /// Upstream compares `error.code !== "ENOENT"`; the host owns that mapping
  /// because the exception type depends on the IO implementation.
  bool isNotFoundError(Object error);

  /// `mkdir(path, { recursive: true })`.
  Future<void> createDirectory(String path);

  Future<void> writeTextFile(String path, String contents);

  /// Cryptographically secure random bytes. Upstream draws 4096 of them.
  Uint8List randomBytes(int byteCount);

  /// SHA-1 of [bytes], for the RFC 4122 v5 derivation.
  ///
  /// Injected because this package carries no crypto dependency and because a
  /// deterministic stub makes the derivation testable.
  Uint8List sha1(Uint8List bytes);

  /// Upstream `console.warn`.
  void warn(String message);
}

/// The RFC 4122 OID namespace, `6ba7b812-9dad-11d1-80b4-00c04fd430c8`.
///
/// The exact namespace `builder-util-runtime`'s `UUID.v5` uses, kept verbatim
/// so an id generated by this port is indistinguishable from one electron-
/// updater would have written.
const List<int> builderUtilOidNamespaceBytes = <int>[
  0x6b, 0xa7, 0xb8, 0x12, //
  0x9d, 0xad, 0x11, 0xd1,
  0x80, 0xb4, 0x00, 0xc0,
  0x4f, 0xd4, 0x30, 0xc8,
];

/// Reads, or creates, the stable per-install rollout identity.
///
/// This id is what makes staged rollouts *stable*: it seeds the client's
/// bucket, so an install admitted at 30% stays admitted on every later check
/// instead of re-rolling the dice and flapping.
///
/// Every failure path still produces an id. A missing file is expected on first
/// run; any other read error, a malformed stored value, or a failed write is
/// warned about and then ignored, because a client that cannot persist its id
/// must still be able to update — it simply re-buckets next launch.
Future<String> resolveStagingUserId({
  required StagingUserIdHost host,
  required String filePath,
  DesktopBrowserPathOps pathOps = DesktopBrowserPathOps.posix,
}) async {
  try {
    final id = (await host.readTextFile(filePath)).trim();
    if (isBuilderUtilUuid(id)) return id;
  } catch (error) {
    if (!host.isNotFoundError(error)) {
      host.warn(
        "[auto-updater] Couldn't read staging user ID, creating a blank one: "
        '$error',
      );
    }
  }

  final id = _uuidV5(
    host.sha1(
      _concatBytes(
        Uint8List.fromList(builderUtilOidNamespaceBytes),
        host.randomBytes(4096),
      ),
    ),
  );

  try {
    await host.createDirectory(_dirname(pathOps, filePath));
    await host.writeTextFile(filePath, id);
  } catch (error) {
    host.warn("[auto-updater] Couldn't write out staging user ID: $error");
  }

  return id;
}

/// Caches the staging user id for the life of the process.
///
/// Deviation: upstream memoises a module-level `Promise<string>`; this is the
/// same single-flight memoisation as an object. The *promise* is cached, not
/// the value, so two concurrent callers share one read/write rather than racing
/// to create two different ids.
final class StagingUserId {
  factory StagingUserId({
    required StagingUserIdHost host,
    required String Function() userDataDirectory,
    DesktopBrowserPathOps pathOps = DesktopBrowserPathOps.posix,
  }) => StagingUserId._(host, userDataDirectory, pathOps);

  StagingUserId._(this._host, this._userDataDirectory, this._pathOps);

  /// The file name electron-updater itself uses, inside the app's userData
  /// directory.
  static const String fileName = '.updaterId';

  final StagingUserIdHost _host;
  final String Function() _userDataDirectory;
  final DesktopBrowserPathOps _pathOps;

  Future<String>? _cached;

  /// Upstream `getStagingUserId()`.
  Future<String> get() => _cached ??= resolveStagingUserId(
    host: _host,
    filePath: _pathOps.join(<String>[_userDataDirectory(), fileName]),
    pathOps: _pathOps,
  );
}

/// The electron-updater surface [ElectronStyleAppUpdateRuntime] drives.
///
/// Every member mirrors one electron-updater property, method or event, so the
/// adapter below reads as a line-for-line port of upstream's
/// `ElectronAppUpdateRuntime`.
abstract interface class ElectronUpdaterPort {
  set autoDownload(bool value);

  set autoRunAppAfterInstall(bool value);

  set autoInstallOnAppQuit(bool value);

  set allowPrerelease(bool value);

  /// electron-updater's channel name: `latest` or `beta`.
  set channel(String value);

  set allowDowngrade(bool value);

  /// electron-updater's staged-rollout hook.
  set isUserWithinRollout(
    Future<bool> Function(DesktopAppUpdateInfo info)? hook,
  );

  void onUpdateAvailable(void Function(DesktopAppUpdateInfo info) listener);

  void onUpdateDownloaded(void Function(DesktopAppUpdateInfo info) listener);

  void onUpdateNotAvailable(void Function() listener);

  void onError(void Function(Object error, StackTrace stackTrace) listener);

  Future<DesktopAppRuntimeCheckResult?> checkForUpdates();

  Future<void> downloadUpdate();

  void quitAndInstall({required bool silent, required bool restart});
}

/// electron-updater behind the repo's [DesktopAppUpdateRuntime] port.
///
/// The four fixed settings are each a deliberate choice:
///
/// - `autoDownload = true` — the download is a cache; nothing installs from it
///   without a fresh manifest check first.
/// - `autoInstallOnAppQuit = false` — Electron's built-in quit handler would
///   install whatever was downloaded, even if a newer release has since
///   superseded it. Paseo revalidates the manifest and installs explicitly.
/// - `allowDowngrade = false` — a channel switch must never roll the user back.
/// - `allowPrerelease` / `channel` follow the selected release channel.
///
/// The rollout hook swallows its own failures and returns `true`: if the
/// staged-rollout gate itself breaks, the user should still get the update
/// rather than be silently pinned to an old build.
final class ElectronStyleAppUpdateRuntime implements DesktopAppUpdateRuntime {
  ElectronStyleAppUpdateRuntime(this._updater);

  final ElectronUpdaterPort _updater;

  bool _configured = false;

  @override
  void configure(DesktopAppUpdateRuntimeConfiguration configuration) {
    _updater.autoDownload = true;
    _updater.autoRunAppAfterInstall = true;
    _updater.autoInstallOnAppQuit = false;
    _updater.allowPrerelease =
        configuration.releaseChannel == DesktopAppReleaseChannel.beta;
    _updater.channel =
        configuration.releaseChannel == DesktopAppReleaseChannel.beta
        ? 'beta'
        : 'latest';
    _updater.allowDowngrade = false;
    _updater.isUserWithinRollout = (info) async {
      try {
        return await configuration.shouldAdmitUpdate(info);
      } catch (_) {
        return true;
      }
    };

    // Settings are refreshed on every configure because the channel can change;
    // the event subscriptions are one-shot because electron-updater's emitter
    // would otherwise accumulate a listener per check.
    if (_configured) return;
    _configured = true;

    _updater.onUpdateAvailable(configuration.onUpdateAvailable);
    _updater.onUpdateDownloaded(configuration.onUpdateDownloaded);
    _updater.onUpdateNotAvailable(configuration.onUpdateNotAvailable);
    _updater.onError(configuration.onError);
  }

  @override
  Future<DesktopAppRuntimeCheckResult?> checkForUpdates() =>
      _updater.checkForUpdates();

  /// Deviation: the repo's port hands a [DesktopAppUpdateCancellation] to every
  /// download so a quit-time deadline can abandon the wait. electron-updater
  /// exposes no cancel handle on `downloadUpdate()`, so the token is accepted
  /// and ignored here — abandoning the *wait* is the service's job, and the
  /// download itself is harmless if it finishes into the cache unobserved.
  @override
  Future<void> downloadUpdate(DesktopAppUpdateCancellation cancellation) =>
      _updater.downloadUpdate();

  @override
  Future<void> quitAndInstall({
    required bool silent,
    required bool restart,
  }) async {
    // Upstream re-assigns `autoRunAppAfterInstall` immediately before quitting
    // because the flag is read by the installer that outlives this process.
    _updater.autoRunAppAfterInstall = restart;
    _updater.quitAndInstall(silent: silent, restart: restart);
  }
}

// ===========================================================================
// editor-targets/runtime.ts
// ===========================================================================

/// Environment variables that describe *this* process's supervision and must
/// never leak into a detached editor.
///
/// An editor that inherited `ELECTRON_RUN_AS_NODE` would start as a bare Node
/// process instead of an app, and one that inherited `PASEO_DESKTOP_MANAGED`
/// would believe it was launched by Paseo's supervisor.
const List<String> editorRuntimeControlEnvKeys = <String>[
  'PASEO_NODE_ENV',
  'PASEO_DESKTOP_MANAGED',
  'PASEO_SUPERVISED',
  'ELECTRON_RUN_AS_NODE',
  'ELECTRON_NO_ATTACH_CONSOLE',
];

/// The `child_process.spawn` options an editor launch uses.
///
/// Always the same four values, but modelled as a value type so a host adapter
/// receives them explicitly and a test can assert on them.
final class EditorProcessSpawnOptions {
  const EditorProcessSpawnOptions({
    required this.detached,
    required this.env,
    required this.shell,
    required this.stdio,
  });

  /// Always true: the editor must outlive Paseo.
  final bool detached;

  final Map<String, String> env;

  /// True only for a Windows `.cmd`/`.bat`, which cannot be executed directly.
  final bool shell;

  /// Always `ignore`: an editor's stdio pipes would keep the child tied to a
  /// dead parent's handles.
  final String stdio;

  @override
  bool operator ==(Object other) =>
      other is EditorProcessSpawnOptions &&
      other.detached == detached &&
      other.shell == shell &&
      other.stdio == stdio &&
      _mapEquals(other.env, env);

  @override
  int get hashCode => Object.hash(
    detached,
    shell,
    stdio,
    Object.hashAll(
      env.entries.map((entry) => Object.hash(entry.key, entry.value)).toList()
        ..sort(),
    ),
  );

  @override
  String toString() =>
      'EditorProcessSpawnOptions(detached: $detached, shell: $shell, '
      'stdio: $stdio, env: $env)';
}

/// The child-process handle the launch rule needs.
abstract interface class SpawnedEditorProcess {
  /// `child.once("error", ...)` — spawn failed asynchronously.
  void onceError(void Function(Object error) handler);

  /// `child.once("spawn", ...)` — the OS accepted the launch.
  void onceSpawn(void Function() handler);

  /// `child.unref()` — stop the parent's event loop from tracking the child.
  void unref();
}

/// `child_process.spawn`, injected. May throw synchronously, as Node's does.
typedef EditorProcessSpawner =
    SpawnedEditorProcess Function(
      String command,
      List<String> args,
      EditorProcessSpawnOptions options,
    );

/// Electron `shell.openPath`, which resolves to an error message — or `""` on
/// success.
typedef EditorShellOpenPath = Future<String> Function(String path);

/// Builds the concrete [EditorTargetRuntime] the editor registry runs against.
///
/// Deviation: every parameter is required. Upstream defaults each one to a Node
/// or Electron global (`process.platform`, `process.env`, `fs.existsSync`,
/// `child_process.spawn`, `shell.openPath`, `os.homedir()`, and an icon loader
/// that reads from the app bundle). This library must not import `dart:io` or a
/// plugin, so there is nothing to default *to* — the host supplies all of them,
/// which is also what makes the rules below testable at all.
EditorTargetRuntime createEditorTargetRuntime({
  required EditorTargetPlatform platform,
  required Map<String, String> env,
  required bool Function(String path) pathExists,
  required EditorProcessSpawner spawn,
  required EditorShellOpenPath openPath,
  required void Function(String path) revealPath,
  required Future<EditorTargetIcon> Function(String fileName) loadIcon,
  required String homeDirectory,
}) => _EditorTargetRuntime(
  platform,
  env,
  pathExists,
  spawn,
  openPath,
  revealPath,
  loadIcon,
  homeDirectory,
);

/// Strips the supervision variables, and any Node `undefined` entries, from an
/// environment about to be handed to a detached child.
///
/// Deviation: Dart's `Map<String, String>` cannot hold Node's `undefined`, so
/// the second upstream loop (deleting undefined values) has nothing to do and
/// is omitted. An empty-string value is *kept*, exactly as upstream keeps it.
Map<String, String> createExternalProcessEnv(Map<String, String> baseEnv) {
  final result = Map<String, String>.from(baseEnv);
  for (final key in editorRuntimeControlEnvKeys) {
    result.remove(key);
  }
  return result;
}

/// Whether [value] is an absolute path under [platform]'s rules.
bool editorRuntimeIsAbsolutePath(String value, EditorTargetPlatform platform) =>
    _pathOpsFor(platform).isAbsolute(value);

/// Finds the first of [commands] that names a real executable.
///
/// Each candidate is tried as an absolute path first, then against every PATH
/// entry. On Windows a command with no extension is additionally probed with
/// `.exe`, `.cmd`, `.bat`, `.com` and finally no extension, in that order —
/// the order matters because a directory can hold both `code` (a shell script
/// Windows cannot execute) and `code.cmd`.
///
/// Deviation: candidates are joined with a forward slash on every platform,
/// including Windows. That is upstream's literal `${directory}/${command}`, and
/// Windows accepts either separator, so the resulting string is passed through
/// unchanged rather than normalised — normalising would change the exact
/// command string handed to the OS.
String? resolveEditorExecutable(
  List<String> commands, {
  required Map<String, String> env,
  required bool Function(String path) pathExists,
  required EditorTargetPlatform platform,
}) {
  final isWindows = platform == EditorTargetPlatform.win32;
  for (final command in commands) {
    if (editorRuntimeIsAbsolutePath(command, platform) && pathExists(command)) {
      return command;
    }

    // JS `??` is null-ish only, so an explicitly empty PATH wins over `Path`.
    final pathValue = env['PATH'] ?? env['Path'] ?? env['path'] ?? '';
    final pathDelimiter = isWindows ? ';' : ':';
    for (final directory in pathValue.split(pathDelimiter)) {
      if (directory.isEmpty) continue;
      final candidate = '$directory/$command';
      if (!isWindows) {
        if (pathExists(candidate)) return candidate;
        continue;
      }

      final hasExtension = _extname(
        DesktopBrowserPathOps.windows,
        command,
      ).isNotEmpty;
      final extensions = hasExtension
          ? const <String>['']
          : const <String>['.exe', '.cmd', '.bat', '.com', ''];
      for (final extension in extensions) {
        final windowsCandidate = '$candidate$extension';
        if (pathExists(windowsCandidate)) return windowsCandidate;
      }
    }
  }
  return null;
}

/// Whether [executable] is a Windows batch script rather than a real binary.
///
/// These must be run through `cmd.exe`, which is exactly why their arguments
/// need [escapeWindowsCmdValue].
bool isWindowsCommandScript(String executable, EditorTargetPlatform platform) {
  if (platform != EditorTargetPlatform.win32) return false;
  final extension = _extname(
    DesktopBrowserPathOps.windows,
    executable,
  ).toLowerCase();
  return extension == '.cmd' || extension == '.bat';
}

/// Quotes a value for `cmd.exe`.
///
/// This is a command-injection boundary: a workspace path is attacker-
/// influenced (it is whatever the user cloned), and running a `.cmd` means the
/// string is re-parsed by `cmd.exe`, where `&`, `|`, `^`, `<`, `>`, `(`, `)`
/// and `!` are all operators. Anything containing one of those, whitespace or a
/// quote is wrapped in quotes; embedded quotes get their preceding backslashes
/// doubled and are themselves escaped, and trailing backslashes are doubled so
/// they cannot escape the closing quote.
///
/// A value that is *already* fully quoted is unwrapped and re-quoted rather
/// than trusted, so a caller cannot smuggle an unescaped payload past the check
/// by pre-quoting it.
String escapeWindowsCmdValue(String value) {
  final isQuoted = value.startsWith('"') && value.endsWith('"');
  // Deviation: JS `'"'.startsWith('"') && '"'.endsWith('"')` is true for a
  // lone quote character, and `slice(1, -1)` then yields `""`. Dart's
  // `substring(1, 0)` would throw, so the degenerate case is spelled out.
  final unquoted = isQuoted
      ? (value.length <= 2 ? '' : value.substring(1, value.length - 1))
      : value;
  if (!isQuoted && !_cmdMetaCharacters.hasMatch(unquoted)) return unquoted;

  final quoted = unquoted
      .replaceAllMapped(
        RegExp(r'(\\*)"'),
        (match) => '${match[1]}${match[1]}\\"',
      )
      .replaceAllMapped(RegExp(r'\\+$'), (match) => '${match[0]}${match[0]}');
  return '"$quoted"';
}

final RegExp _cmdMetaCharacters = RegExp(r'[\s"&|^<>()!]');

final class _EditorTargetRuntime implements EditorTargetRuntime {
  _EditorTargetRuntime(
    this.platform,
    this.env,
    this._pathExists,
    this._spawn,
    this._openPath,
    this._revealPath,
    this._loadIcon,
    this._homeDirectory,
  );

  @override
  final EditorTargetPlatform platform;

  @override
  final Map<String, String> env;

  final bool Function(String path) _pathExists;
  final EditorProcessSpawner _spawn;
  final EditorShellOpenPath _openPath;
  final void Function(String path) _revealPath;
  final Future<EditorTargetIcon> Function(String fileName) _loadIcon;
  final String _homeDirectory;

  @override
  bool pathExists(String path) => _pathExists(path);

  @override
  bool isAbsolutePath(String path) =>
      editorRuntimeIsAbsolutePath(path, platform);

  @override
  String? resolveCommand(List<String> commands) => resolveEditorExecutable(
    commands,
    env: env,
    pathExists: _pathExists,
    platform: platform,
  );

  @override
  Future<void> spawnDetached({
    required String command,
    required List<String> args,
  }) {
    final commandScript = isWindowsCommandScript(command, platform);
    final launchCommand = commandScript
        ? escapeWindowsCmdValue(command)
        : command;
    final launchArgs = commandScript
        ? args.map(escapeWindowsCmdValue).toList()
        : List<String>.from(args);

    final completer = Completer<void>();
    final SpawnedEditorProcess child;
    try {
      child = _spawn(
        launchCommand,
        launchArgs,
        EditorProcessSpawnOptions(
          detached: true,
          env: createExternalProcessEnv(env),
          shell: commandScript,
          stdio: 'ignore',
        ),
      );
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      return completer.future;
    }
    // A JS promise ignores a second settle; a Dart Completer throws, so both
    // handlers guard. `error` and `spawn` are mutually exclusive in practice,
    // but a misbehaving host must not turn a launch failure into a crash.
    child.onceError((error) {
      if (!completer.isCompleted) completer.completeError(error);
    });
    child.onceSpawn(() {
      if (completer.isCompleted) return;
      child.unref();
      completer.complete();
    });
    return completer.future;
  }

  @override
  Future<void> openPath(String path) async {
    final errorMessage = await _openPath(path);
    // JS truthiness: `shell.openPath` resolves to `""` on success.
    if (errorMessage.isNotEmpty) throw EditorTargetError(errorMessage);
  }

  @override
  void revealPath(String path) => _revealPath(path);

  @override
  Future<EditorTargetIcon> loadIcon(String fileName) => _loadIcon(fileName);

  @override
  bool hasMacApplication(String applicationName) {
    if (platform != EditorTargetPlatform.darwin) return false;
    return <String>[
      '/Applications/$applicationName.app',
      '$_homeDirectory/Applications/$applicationName.app',
      '/System/Applications/$applicationName.app',
    ].any(_pathExists);
  }

  @override
  Future<void> openMacApplication({
    required String applicationName,
    required List<String> paths,
  }) => spawnDetached(
    command: '/usr/bin/open',
    args: <String>['-a', applicationName, ...paths],
  );
}

// ===========================================================================
// Shared helpers
// ===========================================================================

DesktopBrowserPathOps _pathOpsFor(EditorTargetPlatform platform) =>
    platform == EditorTargetPlatform.win32
    ? DesktopBrowserPathOps.windows
    : DesktopBrowserPathOps.posix;

/// `path.extname`, built from [DesktopBrowserPathOps.basename] and `fileStem`.
///
/// Node's two carve-outs are already encoded in `fileStem` (a leading dot is
/// part of the name, and `..` never splits), so the extension is simply what
/// the stem left behind.
String _extname(DesktopBrowserPathOps ops, String path) {
  final base = ops.basename(path);
  return base.substring(ops.fileStem(base).length);
}

/// `path.dirname`, for the one call site that needs it.
///
/// Deviation: [DesktopBrowserPathOps] has no `dirname`, and adding one would
/// mean editing a sibling port. This covers what upstream's single use needs —
/// the directory holding a regular file path — by trimming the basename and any
/// separators that preceded it, falling back to `.` when there was no
/// directory component.
String _dirname(DesktopBrowserPathOps ops, String path) {
  var end = path.length;
  while (end > 0 && _isPathSeparator(ops, path[end - 1])) {
    end -= 1;
  }
  if (end == 0) return path.isEmpty ? '.' : path.substring(0, 1);
  var index = end - 1;
  while (index >= 0 && !_isPathSeparator(ops, path[index])) {
    index -= 1;
  }
  if (index < 0) return '.';
  while (index > 0 && _isPathSeparator(ops, path[index - 1])) {
    index -= 1;
  }
  if (index == 0) return path.substring(0, 1);
  return path.substring(0, index);
}

bool _isPathSeparator(DesktopBrowserPathOps ops, String character) =>
    character == '/' || (ops.separator == r'\' && character == r'\');

Uint8List _concatBytes(Uint8List first, Uint8List second) {
  final result = Uint8List(first.length + second.length);
  result.setRange(0, first.length, first);
  result.setRange(first.length, result.length, second);
  return result;
}

/// Formats a SHA-1 digest as an RFC 4122 v5 UUID string.
///
/// Byte 6's high nibble becomes the version (5) and byte 8's top two bits
/// become the RFC 4122 variant, exactly as `builder-util-runtime` writes them.
/// Only the first 16 bytes of the 20-byte digest are used.
String _uuidV5(Uint8List digest) {
  final bytes = Uint8List(16);
  for (var index = 0; index < 16; index += 1) {
    bytes[index] = index < digest.length ? digest[index] : 0;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
