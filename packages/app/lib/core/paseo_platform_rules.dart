/// Port of Paseo 0.2.0's platform-boundary rules — the small pieces of logic
/// that sit directly against a host API (Electron IPC, a native dialog, a
/// JavaScript global object) but whose *decisions* are pure and worth pinning.
///
/// Every host API upstream reaches for is injected here as a narrow function
/// type or a small bridge class, so the rules stay exercisable without a
/// desktop host, a browser global, or `dart:io`.
///
/// - `panels/panel-instance-attributes.ts` — the per-panel "is this tab dirty?"
///   side channel. A panel publishes its modified flag, and the sidebar/tab
///   strip subscribes so it can draw a dot without the two ever knowing about
///   each other.
/// - `polyfills/install-crypto-polyfills.ts` — only the portable half: how a
///   v4 UUID is derived from 16 random bytes, and which entropy source wins
///   when the host already provides one. See [installCryptoPolyfills] for what
///   deliberately did *not* come across.
/// - `desktop/pick-directory.ts` — the exact options handed to the native
///   directory picker, and which responses count as a cancel versus a bug.
/// - `desktop/electron/idle.ts` — validating the system idle time an untyped
///   IPC channel hands back, so a bad value degrades to "unknown" instead of
///   poisoning idle-based scheduling.
/// - `diagnostics/desktop-diagnostic-report.ts` — assembling the desktop half
///   of a support bundle, where a partial report beats no report.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/core/app_diagnostic_report.dart'
    show formatDiagnosticSection;

// ---------------------------------------------------------------------------
// panels/panel-instance-attributes.ts
// ---------------------------------------------------------------------------

/// Which panel instance a set of attributes belongs to.
///
/// A panel is only unique across all three axes: the same tab id can exist in
/// two workspaces, and the same workspace id can exist on two servers, so a
/// dirty marker keyed on any one of them alone would bleed across.
final class PanelInstanceIdentity {
  /// Creates an identity for the panel instance rendered for [tabId] inside
  /// [workspaceId] on [serverId].
  const PanelInstanceIdentity({
    required this.serverId,
    required this.workspaceId,
    required this.tabId,
  });

  /// The host whose workspace this panel belongs to.
  final String serverId;

  /// The workspace the panel is rendered inside.
  final String workspaceId;

  /// The tab the panel is rendered for.
  final String tabId;

  @override
  bool operator ==(Object other) =>
      other is PanelInstanceIdentity &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId &&
      other.tabId == tabId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId, tabId);

  @override
  String toString() => 'PanelInstanceIdentity(${buildPanelInstanceKey(this)})';
}

/// A callback that suspends whatever autosave a panel has pending, returning
/// the function that resumes it.
///
/// Upstream types this as `() => () => void`; the outer call suspends and the
/// returned call resumes, so callers can bracket a risky operation.
typedef SuspendPendingSave = void Function() Function();

/// The runtime state a panel instance publishes about itself.
///
/// Only [modified] drives UI today; [suspendPendingSave] is carried alongside
/// it so a component that wants to interrupt the panel's autosave can reach it
/// through the same channel.
final class PanelInstanceAttributes {
  /// Creates an attribute set. [modified] defaults to `false` so
  /// [PanelInstanceAttributes.unmodified] and a bare constructor agree.
  const PanelInstanceAttributes({
    this.modified = false,
    this.suspendPendingSave,
  });

  /// The value read back for a panel that has never published, matching
  /// upstream's shared `DEFAULT_ATTRIBUTES` constant.
  static const PanelInstanceAttributes unmodified = PanelInstanceAttributes();

  /// Whether the panel holds unsaved edits.
  final bool modified;

  /// See [SuspendPendingSave]. `null` when the panel has no autosave to pause.
  final SuspendPendingSave? suspendPendingSave;

  /// Upstream compares the two fields with `===`, so a *different* closure with
  /// identical behaviour still counts as a change. Dart's `==` on closures is
  /// identity for the same reason, with one documented divergence: Dart makes
  /// two tear-offs of the same instance method equal, where JavaScript's
  /// `fn.bind(obj)` produces a fresh unequal function each time. The only
  /// consequence is that Dart may skip a redundant notification JavaScript
  /// would have emitted.
  @override
  bool operator ==(Object other) =>
      other is PanelInstanceAttributes &&
      other.modified == modified &&
      other.suspendPendingSave == suspendPendingSave;

  @override
  int get hashCode => Object.hash(modified, suspendPendingSave);

  @override
  String toString() =>
      'PanelInstanceAttributes(modified: $modified, '
      'suspendPendingSave: ${suspendPendingSave == null ? 'none' : 'set'})';
}

/// The map key for a panel instance.
///
/// Exposed because upstream exports it: callers that already hold a flat key
/// (log lines, debug overlays) can build one without constructing a store.
String buildPanelInstanceKey(PanelInstanceIdentity identity) =>
    '${identity.serverId}:${identity.workspaceId}:${identity.tabId}';

/// The registry panels publish their [PanelInstanceAttributes] into and that
/// chrome (tab strips, sidebars) subscribes to.
///
/// Deviation: upstream keeps the maps, the listener sets and the revision
/// counter in module scope, because a React module is already a per-app
/// singleton. Modelling that as Dart top-level mutable state would leak between
/// tests and between two app instances in one isolate, so it is an object here.
/// Wire one instance in wherever the app needs the singleton behaviour.
final class PanelInstanceAttributeStore {
  /// Creates an empty store.
  PanelInstanceAttributeStore();

  final Map<String, PanelInstanceAttributes> _attributesByPanel = {};
  final Map<String, Set<void Function()>> _listenersByPanel = {};
  final Set<void Function()> _allListeners = {};
  int _revision = 0;

  /// A counter bumped on every accepted write.
  ///
  /// Upstream feeds this to `useSyncExternalStore` as the snapshot for the
  /// "which tabs are dirty" hook: the derived set is not identity-stable, so a
  /// monotonic scalar is what the store actually publishes.
  int get revision => _revision;

  /// The attributes published for [identity], or
  /// [PanelInstanceAttributes.unmodified] when the panel never published.
  PanelInstanceAttributes read(PanelInstanceIdentity identity) =>
      _attributesByPanel[buildPanelInstanceKey(identity)] ??
      PanelInstanceAttributes.unmodified;

  /// Publishes [attributes] for [identity], notifying subscribers only when
  /// something actually changed.
  ///
  /// Two upstream subtleties are preserved:
  ///
  /// * Unmodified panels are *deleted* rather than stored, so the map only ever
  ///   holds dirty panels and [read] falls through to the shared default.
  /// * The no-op check compares against the **stored** value, not the value the
  ///   caller last passed. Publishing `modified: false` with a fresh
  ///   [SuspendPendingSave] therefore still counts as a change and still
  ///   notifies, even though nothing is written — the stored entry was absent,
  ///   so its `suspendPendingSave` reads as `null`.
  void write(
    PanelInstanceIdentity identity,
    PanelInstanceAttributes attributes,
  ) {
    final key = buildPanelInstanceKey(identity);
    final previous =
        _attributesByPanel[key] ?? PanelInstanceAttributes.unmodified;
    if (previous == attributes) return;
    if (attributes.modified) {
      _attributesByPanel[key] = attributes;
    } else {
      _attributesByPanel.remove(key);
    }
    _revision += 1;
    _notify(_listenersByPanel[key]);
    _notify(_allListeners);
  }

  /// Deviation: upstream iterates the live `Set`, which JavaScript permits a
  /// listener to mutate mid-iteration; Dart throws `ConcurrentModificationError`
  /// for that. Iterating a snapshot and re-checking membership reproduces
  /// JavaScript's `Set` iteration order semantics for the case that actually
  /// happens — a listener unsubscribing during a notification, where JavaScript
  /// skips a not-yet-visited listener that was just removed. The remaining gap
  /// is that a listener *added* mid-notification is visited by JavaScript but
  /// not here; nothing upstream subscribes from inside a notification.
  static void _notify(Set<void Function()>? listeners) {
    if (listeners == null) return;
    for (final listener in [...listeners]) {
      if (!listeners.contains(listener)) continue;
      listener();
    }
  }

  /// Subscribes [listener] to changes for [identity]. Returns the unsubscribe.
  ///
  /// The per-key listener set is dropped once empty so a long-lived store does
  /// not accumulate an entry per tab the user ever opened.
  void Function() subscribe(
    PanelInstanceIdentity identity,
    void Function() listener,
  ) {
    final key = buildPanelInstanceKey(identity);
    final listeners = _listenersByPanel.putIfAbsent(key, () => {});
    listeners.add(listener);
    return () {
      listeners.remove(listener);
      if (listeners.isEmpty) _listenersByPanel.remove(key);
    };
  }

  /// Subscribes [listener] to *any* change in the store. Returns the
  /// unsubscribe.
  ///
  /// This is what [modifiedTabIds] consumers watch, since a tab strip cares
  /// about every tab it renders rather than one identity.
  void Function() subscribeAll(void Function() listener) {
    _allListeners.add(listener);
    return () => _allListeners.remove(listener);
  }

  /// The subset of [tabIds] that are currently modified, in the order given.
  ///
  /// This is the pure core of upstream's `useModifiedPanelTabIds`; the React
  /// `useSyncExternalStore`/`useMemo` wrapper around it is the widget layer's
  /// job and is not ported. Pair it with [subscribeAll] and [revision] to get
  /// the same recompute-on-change behaviour.
  Set<String> modifiedTabIds({
    required String serverId,
    required String workspaceId,
    required List<String> tabIds,
  }) => {
    for (final tabId in tabIds)
      if (read(
        PanelInstanceIdentity(
          serverId: serverId,
          workspaceId: workspaceId,
          tabId: tabId,
        ),
      ).modified)
        tabId,
  };

  /// Publishes [attributes] for [identity] and returns the cleanup that resets
  /// it to [PanelInstanceAttributes.unmodified].
  ///
  /// This is upstream's `usePublishPanelInstanceAttributes` effect body without
  /// React: mount publishes, unmount clears. Clearing on teardown is what stops
  /// a closed tab from leaving a permanent dirty dot behind.
  void Function() publish(
    PanelInstanceIdentity identity,
    PanelInstanceAttributes attributes,
  ) {
    write(identity, attributes);
    return () => write(identity, PanelInstanceAttributes.unmodified);
  }
}

// ---------------------------------------------------------------------------
// polyfills/install-crypto-polyfills.ts
// ---------------------------------------------------------------------------

/// Fills [array] with random bytes and returns it (or returns `null` for a
/// `null` input).
///
/// Mirrors the shape of both `crypto.getRandomValues` and Expo's
/// `getRandomValues`: the buffer is filled in place *and* handed back, so
/// callers may use either the argument or the result.
typedef FillRandomBytes = Uint8List? Function(Uint8List? array);

/// The entropy the host cannot supply itself.
///
/// Upstream names the single field after Expo's `expo-crypto` shim because that
/// is the one source guaranteed to exist on React Native.
final class CryptoPolyfillSources {
  /// Creates the fallback source set.
  const CryptoPolyfillSources({required this.expoGetRandomValues});

  /// The always-available filler used when the host offers nothing better.
  final FillRandomBytes expoGetRandomValues;
}

/// What the host runtime already provides, if anything.
///
/// Deviation: upstream takes the JavaScript global object and mutates it,
/// feature-detecting each member with `typeof x !== "function"`. Dart has no
/// mutable global namespace, so the same information arrives as nullable fields
/// — `null` means "the host does not have this", which is exactly what the
/// `typeof` check was answering.
final class CryptoPolyfillTarget {
  /// Creates a description of the host's existing crypto surface. Omit a field
  /// to say the host lacks it.
  const CryptoPolyfillTarget({this.getRandomValues, this.randomUuid});

  /// The host's native `crypto.getRandomValues`, or `null`.
  final FillRandomBytes? getRandomValues;

  /// The host's native `crypto.randomUUID`, or `null`.
  final String Function()? randomUuid;
}

/// The crypto surface after resolution: host implementations where they exist,
/// derived ones where they do not.
final class InstalledCryptoPolyfills {
  /// Creates a resolved surface. Produced by [installCryptoPolyfills].
  const InstalledCryptoPolyfills({
    required this.randomUuid,
    required this.getRandomValues,
  });

  /// Returns a v4 UUID string.
  final String Function() randomUuid;

  /// Fills a buffer with random bytes. See [FillRandomBytes].
  final FillRandomBytes getRandomValues;
}

/// Formats 16 bytes as a v4 UUID, forcing the version and variant bits.
///
/// Byte 6's high nibble is pinned to `4` (version) and byte 8's top two bits to
/// `10` (RFC 4122 variant); the remaining 122 bits are the caller's entropy
/// verbatim. Exposed separately from [installCryptoPolyfills] because the
/// derivation is the genuinely portable part — given the same bytes it must
/// produce the same string on any runtime.
///
/// Throws [ArgumentError] when [bytes] is not exactly 16 long; upstream cannot
/// hit that case because it allocates the buffer itself.
String formatUuidV4FromBytes(Uint8List bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(
      bytes.length,
      'bytes',
      'A v4 UUID needs exactly 16 bytes',
    );
  }
  final patched = Uint8List.fromList(bytes)
    ..[6] = (bytes[6] & 0x0f) | 0x40
    ..[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [
    for (final byte in patched) byte.toRadixString(16).padLeft(2, '0'),
  ];
  return [
    hex.sublist(0, 4).join(),
    hex.sublist(4, 6).join(),
    hex.sublist(6, 8).join(),
    hex.sublist(8, 10).join(),
    hex.sublist(10, 16).join(),
  ].join('-');
}

/// Resolves the crypto surface: keeps whatever [target] already provides and
/// derives the rest from [sources].
///
/// The precedence rule is the load-bearing part. A host's own
/// `getRandomValues` is preferred over the injected fallback even when the host
/// has no `randomUUID`, so a runtime with a real CSPRNG is never downgraded to
/// the shim just because one member was missing.
///
/// **Not ported, deliberately.** Upstream's other job is installing
/// `TextEncoder`/`TextDecoder` and a `crypto` object onto the JavaScript global
/// when Hermes omits them. Dart has no missing global to patch —
/// `dart:convert`'s UTF-8 codecs and `Random.secure` are always present — so
/// there is no Dart analogue to reproduce and none is invented here. The
/// encoding *semantics* upstream installs are still pinned, by
/// [polyfillTextEncode] and [polyfillTextDecode], because shared E2EE code
/// depends on them byte for byte.
InstalledCryptoPolyfills installCryptoPolyfills(
  CryptoPolyfillTarget target,
  CryptoPolyfillSources sources,
) {
  final native = target.getRandomValues;
  Uint8List? fillRandomValues(Uint8List? array) {
    if (array == null) return array;
    if (native != null) return native(array);
    return sources.expoGetRandomValues(array);
  }

  return InstalledCryptoPolyfills(
    randomUuid: target.randomUuid ?? () => _createUuidV4(fillRandomValues),
    getRandomValues: native ?? fillRandomValues,
  );
}

String _createUuidV4(FillRandomBytes fillRandomValues) {
  final bytes = fillRandomValues(Uint8List(16));
  if (bytes == null) {
    // Upstream would throw a TypeError indexing `null` here. Dart's null safety
    // turns that into an explicit failure with a message that names the cause.
    throw StateError('Random byte source returned no bytes for randomUUID.');
  }
  return formatUuidV4FromBytes(bytes);
}

/// UTF-8 encodes [input], matching the `Buffer`-backed `TextEncoder` upstream
/// installs. An omitted argument encodes the empty string, as upstream's
/// `encode(input = "")` default does.
Uint8List polyfillTextEncode([String input = '']) =>
    Uint8List.fromList(utf8.encode(input));

/// UTF-8 decodes [input], matching the `Buffer`-backed `TextDecoder` upstream
/// installs. A `null` buffer decodes to the empty string rather than throwing,
/// because upstream's `decode()` is routinely called with no argument.
///
/// Deviation: `allowMalformed` is on. `Buffer.toString("utf8")` substitutes
/// U+FFFD for invalid sequences where Dart's [utf8] decoder throws by default,
/// and E2EE payload handling upstream relies on the lenient behaviour.
String polyfillTextDecode([Uint8List? input]) =>
    input == null ? '' : utf8.decode(input, allowMalformed: true);

// ---------------------------------------------------------------------------
// desktop/pick-directory.ts
// ---------------------------------------------------------------------------

/// The options a native open-dialog accepts.
///
/// Only the fields [pickDirectory] sets are modelled with defaults; the rest of
/// upstream's `DesktopDialogOpenOptions` is carried so a caller can hand the
/// same class to other dialog call sites. Value equality is implemented so
/// tests can assert on exactly what reached the host.
final class DesktopDialogOpenOptions {
  /// Creates an option set. Every field is optional, matching upstream where
  /// each key may simply be absent.
  const DesktopDialogOpenOptions({
    this.title,
    this.defaultPath,
    this.directory,
    this.createDirectory,
    this.multiple,
  });

  /// Dialog window title.
  final String? title;

  /// Directory the dialog opens at.
  final String? defaultPath;

  /// Whether directories rather than files are being selected.
  final bool? directory;

  /// Whether the dialog offers a "new folder" affordance.
  final bool? createDirectory;

  /// Whether more than one entry may be selected.
  final bool? multiple;

  @override
  bool operator ==(Object other) =>
      other is DesktopDialogOpenOptions &&
      other.title == title &&
      other.defaultPath == defaultPath &&
      other.directory == directory &&
      other.createDirectory == createDirectory &&
      other.multiple == multiple;

  @override
  int get hashCode =>
      Object.hash(title, defaultPath, directory, createDirectory, multiple);

  @override
  String toString() =>
      'DesktopDialogOpenOptions(title: $title, defaultPath: $defaultPath, '
      'directory: $directory, createDirectory: $createDirectory, '
      'multiple: $multiple)';
}

/// Opens a native picker and resolves to the selection.
///
/// The return type is deliberately loose — upstream's bridge resolves to
/// `string | string[] | null`, and [pickDirectory] exists precisely to narrow
/// that. `null` means the user cancelled.
typedef DesktopDialogOpen =
    Future<Object?> Function(DesktopDialogOpenOptions options);

/// The slice of the desktop host's dialog module this module needs.
///
/// [open] is nullable because upstream's bridge is an optional member on an
/// optional object: on web, or before the preload script lands, it simply is
/// not there.
final class DesktopDialogBridge {
  /// Creates a bridge. Pass no [open] to model a host that cannot show dialogs.
  const DesktopDialogBridge({this.open});

  /// The host's open-dialog entry point, or `null` when unavailable.
  final DesktopDialogOpen? open;
}

/// Asks the host for a single directory, returning `null` if the user
/// cancelled.
///
/// Deviation: upstream defaults the [dialog] argument to
/// `getDesktopHost()?.dialog ?? null`, reaching for an ambient Electron global.
/// There is no ambient host here, so the bridge is always injected; a `null`
/// [dialog] models the same "no host" case the default resolved to.
///
/// A missing bridge throws rather than returning `null`, because "the picker
/// cannot run" and "the user declined" must not be confused — the caller
/// usually shows an error for the first and does nothing for the second. A
/// list response also throws: it means `multiple: false` was ignored by the
/// host, which is a bug worth surfacing rather than silently taking `[0]`.
Future<String?> pickDirectory([DesktopDialogBridge? dialog]) async {
  final open = dialog?.open;
  if (open == null) {
    throw StateError(
      'Desktop dialog open() is unavailable in this environment.',
    );
  }

  final selection = await open(
    const DesktopDialogOpenOptions(
      directory: true,
      multiple: false,
      createDirectory: true,
    ),
  );
  if (selection == null) {
    return null;
  }
  if (selection is String) {
    return selection;
  }

  throw StateError('Unexpected directory picker response.');
}

// ---------------------------------------------------------------------------
// desktop/electron/idle.ts
// ---------------------------------------------------------------------------

const String _desktopSystemIdleCommand = 'desktop_get_system_idle_time';

/// Invokes a desktop IPC [command] and resolves to whatever the host sent back.
///
/// Deviation: upstream is generic (`<T>(command: string) => Promise<T>`), but
/// the caller immediately widens to `unknown` and validates, so the Dart type
/// is `Object?` — the unchecked cast the generic performed would be a lie here.
typedef DesktopIpcInvoker = Future<Object?> Function(String command);

/// Receives the diagnostics upstream sends to `console.warn`.
///
/// Injected rather than hard-wired to `print` so the rule stays side-effect
/// free and tests can assert that a bad value was actually reported.
typedef DesktopIdleWarning = void Function(String message, Object? detail);

/// How long the machine has been idle, in milliseconds, or `null` when the host
/// could not say.
///
/// Every failure — a rejected IPC call, a non-numeric payload, a negative or
/// non-finite duration — collapses to `null`, because callers use this to
/// decide whether to defer background work and must not treat garbage as a real
/// duration. Zero is a legitimate answer (the user is active right now) and is
/// returned as-is.
///
/// [onWarn] receives upstream's two `console.warn` calls verbatim.
Future<num?> readDesktopSystemIdleTimeMs(
  DesktopIpcInvoker invoke, {
  DesktopIdleWarning? onWarn,
}) async {
  try {
    final idleTimeMs = await invoke(_desktopSystemIdleCommand);
    if (!_isValidIdleTimeMs(idleTimeMs)) {
      onWarn?.call('[DesktopIdle] Invalid system idle time', idleTimeMs);
      return null;
    }
    return idleTimeMs as num;
  } catch (error) {
    onWarn?.call('[DesktopIdle] Failed to read system idle time', error);
    return null;
  }
}

/// Upstream's `typeof value === "number" && Number.isFinite(value) && value >= 0`.
///
/// Dart's [num] covers both `int` and `double`, which together are JavaScript's
/// single number type; `bool` and `String` are not [num] here just as they fail
/// the `typeof` check there. `NaN` fails both [num.isFinite] and `>= 0`, and
/// infinities fail [num.isFinite].
bool _isValidIdleTimeMs(Object? value) =>
    value is num && value.isFinite && value >= 0;

// ---------------------------------------------------------------------------
// diagnostics/desktop-diagnostic-report.ts
// ---------------------------------------------------------------------------

/// The daemon lifecycle states the desktop host reports.
///
/// Upstream's `DesktopDaemonState` string union. The report prints the raw wire
/// name, so [wireName] is the single place that mapping lives.
enum DesktopDaemonState {
  /// The daemon process is launching.
  starting,

  /// The daemon is up and accepting connections.
  running,

  /// The daemon is not running and that is expected.
  stopped,

  /// The daemon failed; see [DesktopDaemonStatus.error].
  errored;

  /// The exact string upstream puts in the report.
  String get wireName => name;
}

/// A snapshot of the daemon the desktop app manages.
///
/// Declared locally because `desktop/daemon/desktop-daemon.ts` is not ported;
/// only the fields the report reads are guaranteed to matter, but the whole
/// upstream shape is carried so a future port can drop straight in.
final class DesktopDaemonStatus {
  /// Creates a status snapshot. Nullable fields mirror upstream's `| null`.
  const DesktopDaemonStatus({
    required this.serverId,
    required this.status,
    required this.home,
    required this.desktopManaged,
    this.listen,
    this.hostname,
    this.pid,
    this.version,
    this.error,
  });

  /// The daemon's server identity.
  final String serverId;

  /// The lifecycle state.
  final DesktopDaemonState status;

  /// The daemon home directory. May be empty when unknown.
  final String home;

  /// Whether this app launched and owns the daemon process.
  final bool desktopManaged;

  /// The address the daemon listens on, or `null`.
  final String? listen;

  /// The daemon's host name, or `null`.
  final String? hostname;

  /// The daemon process id, or `null` when not running.
  final int? pid;

  /// The daemon version, or `null` when it has not reported one.
  final String? version;

  /// The last daemon error, or `null`.
  final String? error;
}

/// A log file's path and its captured tail.
///
/// Upstream declares `DesktopDaemonLogs` and `DesktopAppLogs` as two structurally
/// identical interfaces; they are one class here with aliases below, so the
/// call sites keep their upstream names without duplicating the shape.
final class DesktopLogTail {
  /// Creates a log tail. An empty [contents] means "nothing captured", which
  /// the report renders as a placeholder rather than blank space.
  const DesktopLogTail({required this.logPath, required this.contents});

  /// Absolute path to the log file. May be empty when unknown.
  final String logPath;

  /// The captured tail, newline separated. May be empty.
  final String contents;
}

/// Upstream's `DesktopDaemonLogs`. See [DesktopLogTail].
typedef DesktopDaemonLogs = DesktopLogTail;

/// Upstream's `DesktopAppLogs`. See [DesktopLogTail].
typedef DesktopAppLogs = DesktopLogTail;

/// Whether a diagnostic collection completed intact.
enum DesktopDiagnosticStatus {
  /// Every source answered.
  done,

  /// At least one source failed; the report contains an error section in its
  /// place and the rest of the sections are still usable.
  failed,
}

/// The outcome of [collectDesktopDiagnosticSections].
final class DesktopDiagnosticCollectionResult {
  /// Creates a result.
  const DesktopDiagnosticCollectionResult({
    required this.sections,
    required this.status,
  });

  /// The report sections, in the order they should be joined.
  final List<String> sections;

  /// Whether any source failed. See [DesktopDiagnosticStatus].
  final DesktopDiagnosticStatus status;
}

/// The three host calls the desktop report is assembled from.
///
/// Injected as a bundle so the whole report can be exercised without a desktop
/// host, and so a caller can substitute cached values.
final class DesktopDiagnosticSources {
  /// Creates a source bundle.
  const DesktopDiagnosticSources({
    required this.getStatus,
    required this.getDaemonLogs,
    required this.getAppLogs,
  });

  /// Reads the managed daemon's status.
  final Future<DesktopDaemonStatus> Function() getStatus;

  /// Reads the daemon's log tail.
  final Future<DesktopDaemonLogs> Function() getDaemonLogs;

  /// Reads the desktop shell's own log tail.
  final Future<DesktopAppLogs> Function() getAppLogs;
}

/// Builds the desktop portion of a support bundle.
///
/// All three sources are started before anything is awaited, so a slow log read
/// does not serialise behind the status call — the report is something a user
/// waits on with a spinner.
///
/// Failures are contained rather than propagated: each half of the report
/// degrades to an error section on its own, so a broken app-log reader still
/// yields the daemon status and vice versa. That is the whole point — the
/// report is most needed exactly when something is broken. The status is
/// [DesktopDiagnosticStatus.failed] whenever any section degraded, which is how
/// the caller knows to tell the user the bundle is partial.
///
/// Deviation: upstream's status/daemon-log pair is a `Promise.all`, which
/// settles as soon as either rejects. [Future.wait] with `eagerError: true` is
/// the exact analogue; the default (`false`) would hang if the surviving future
/// never completed.
Future<DesktopDiagnosticCollectionResult> collectDesktopDiagnosticSections(
  DesktopDiagnosticSources sources,
) async {
  final sections = <String>[];
  var failed = false;

  // Order matters and is pinned by the upstream suite: status, then daemon
  // logs, then app logs, all started before the first await.
  final daemonFuture = _settle(
    Future.wait<Object>([
      sources.getStatus(),
      sources.getDaemonLogs(),
    ], eagerError: true),
  );
  final appLogsFuture = _settle(sources.getAppLogs());

  final daemonResult = await daemonFuture;
  final appLogsResult = await appLogsFuture;

  if (daemonResult.isFulfilled) {
    final status = daemonResult.value![0] as DesktopDaemonStatus;
    final daemonLogs = daemonResult.value![1] as DesktopDaemonLogs;
    sections.insertAll(
      0,
      _formatDesktopDaemonSections(
        status: status,
        daemonLogs: daemonLogs,
        appLogs: appLogsResult.isFulfilled ? appLogsResult.value : null,
      ),
    );
  } else {
    failed = true;
    sections.insertAll(0, [
      formatDiagnosticSection('Desktop', [
        ('Error', describeDiagnosticError(daemonResult.error)),
      ]),
    ]);
  }

  if (appLogsResult.isFulfilled) {
    sections.add(
      _formatLogTailSection(
        'Desktop app log tail',
        appLogsResult.value!.contents,
      ),
    );
  } else {
    failed = true;
    sections.add(
      formatDiagnosticSection('Desktop app log tail', [
        ('Error', describeDiagnosticError(appLogsResult.error)),
      ]),
    );
  }

  return DesktopDiagnosticCollectionResult(
    sections: sections,
    status: failed
        ? DesktopDiagnosticStatus.failed
        : DesktopDiagnosticStatus.done,
  );
}

List<String> _formatDesktopDaemonSections({
  required DesktopDaemonStatus status,
  required DesktopDaemonLogs daemonLogs,
  required DesktopAppLogs? appLogs,
}) => [
  formatDiagnosticSection('Desktop', [
    ('Daemon status', status.status.wireName),
    // Upstream's `String(boolean)`.
    ('Desktop managed', '${status.desktopManaged}'),
    ('Daemon PID', status.pid == null ? 'none' : '${status.pid}'),
    // `??`: a present-but-empty version would be printed as-is upstream.
    ('Daemon version', status.version ?? 'unknown'),
    // `||`: an empty string is as useless as a missing one, so it falls back.
    ('Daemon home', status.home.isEmpty ? 'unknown' : status.home),
    ('Log path', daemonLogs.logPath.isEmpty ? 'unknown' : daemonLogs.logPath),
    (
      'App log path',
      (appLogs == null || appLogs.logPath.isEmpty)
          ? 'unavailable'
          : appLogs.logPath,
    ),
    ('Error', status.error ?? 'none'),
  ]),
  _formatLogTailSection('Desktop daemon log tail', daemonLogs.contents),
];

String _formatLogTailSection(String title, String contents) => [
  title,
  contents.isEmpty ? '  No log lines found' : _indentBlock(contents),
].join('\n');

/// Indents every non-empty line by two spaces so a log tail nests visually
/// under its heading. Blank lines are dropped, matching upstream's
/// `.filter(Boolean)`.
String _indentBlock(String value) => value
    .split('\n')
    .where((line) => line.isNotEmpty)
    .map((line) => '  $line')
    .join('\n');

/// The human-readable message for a thrown [error].
///
/// Deviation: upstream is `error instanceof Error ? error.message : String(error)`.
/// Dart has no universal `message` member — [Error] does not declare one — so
/// the equivalent is assembled from the throwables a Dart port actually
/// produces, unwrapping each to the bare message and falling back to
/// `toString()`. Without this, every diagnostic line would carry a `Bad state:`
/// or `Exception:` prefix that upstream's reports never contain.
String describeDiagnosticError(Object? error) {
  if (error is StateError) return error.message;
  if (error is FormatException) return error.message;
  if (error is ArgumentError) return '${error.message}';
  final text = '$error';
  const exceptionPrefix = 'Exception: ';
  if (error is Exception && text.startsWith(exceptionPrefix)) {
    return text.substring(exceptionPrefix.length);
  }
  return text;
}

/// A completed future's outcome, standing in for one entry of
/// `Promise.allSettled`.
final class _Settled<T> {
  const _Settled.fulfilled(this.value) : error = null, isFulfilled = true;
  const _Settled.rejected(this.error) : value = null, isFulfilled = false;

  final T? value;
  final Object? error;
  final bool isFulfilled;
}

Future<_Settled<T>> _settle<T>(Future<T> future) => future.then(
  (value) => _Settled<T>.fulfilled(value),
  onError: (Object error) => _Settled<T>.rejected(error),
);
