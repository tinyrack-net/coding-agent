/// Frozen Paseo 0.2.0 server environment cluster, ported to Dart.
///
/// Upstream modules covered by this library
/// (`paseo/packages/server/src/server/`):
///
/// | Upstream                | Section here                              |
/// | ----------------------- | ----------------------------------------- |
/// | `client-message-id.ts`  | [normalizeClientMessageId] and friends    |
/// | `daemon-version.ts`     | [resolveDaemonVersion] and friends        |
/// | `paseo-home.ts`         | [resolveTinyrackServerHome]               |
/// | `paseo-env.ts`          | [createExternalProcessEnv] and friends    |
/// | `messages.ts`           | [serializeAgentStreamEvent] and friends   |
/// | `exports.ts`            | [findServerEntrySurfaceViolations]        |
///
/// ## Branding
///
/// Paseo's on-disk paths and environment variable names are *not* copied
/// literally: this project ships as **Tinyrack** with its own Hub, so only the
/// *behavior* (resolution order, overrides, fallbacks, scrubbing rules) is
/// ported. The name mapping is:
///
/// | Paseo                    | Tinyrack                    |
/// | ------------------------ | --------------------------- |
/// | `PASEO_HOME`             | `TINYRACK_HOME`             |
/// | `~/.paseo` (default)     | `~/.tinyrack-agent`         |
/// | `PASEO_NODE_ENV`         | `TINYRACK_NODE_ENV`         |
/// | `PASEO_DESKTOP_MANAGED`  | `TINYRACK_DESKTOP_MANAGED`  |
/// | `PASEO_SUPERVISED`       | `TINYRACK_SUPERVISED`       |
/// | `@getpaseo/server`       | `agent_daemon`              |
///
/// `ELECTRON_RUN_AS_NODE` and `ELECTRON_NO_ATTACH_CONSOLE` keep their literal
/// names: they are Electron's, not Paseo's, and this repo already scrubs them
/// in `cli/desktop_launch.dart`, so renaming them would break that contract.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'server/daemon_config.dart' show resolveTinyrackHome;

// ---------------------------------------------------------------------------
// client-message-id.ts
// ---------------------------------------------------------------------------

/// Trims a client-supplied message id, collapsing "absent" and "blank" into a
/// single `null`.
///
/// Clients optimistically render a user message before the daemon echoes it
/// back, and correlate the two by this id. A whitespace-only id would silently
/// never match, so it is treated exactly like an omitted one and the caller
/// falls back to a generated id.
///
/// Deviation: TypeScript guards `typeof clientMessageId !== "string"` because
/// untyped callers can pass anything. Dart's type system makes that
/// unrepresentable, so only the `null`/blank branch survives.
String? normalizeClientMessageId(String? clientMessageId) {
  if (clientMessageId == null) return null;
  final trimmed = clientMessageId.trim();
  return trimmed.isNotEmpty ? trimmed : null;
}

/// Returns the normalized [clientMessageId], or a freshly generated id.
///
/// [generateId] is injectable so tests can pin the fallback; production callers
/// get a UUID v4 from the `uuid` package this repo already depends on.
String resolveClientMessageId(
  String? clientMessageId, [
  String Function()? generateId,
]) =>
    normalizeClientMessageId(clientMessageId) ??
    (generateId ?? _defaultClientMessageIdGenerator)();

String _defaultClientMessageIdGenerator() => const Uuid().v4();

// ---------------------------------------------------------------------------
// daemon-version.ts
// ---------------------------------------------------------------------------

/// Pubspec name of the daemon package, the Dart counterpart of Paseo's
/// `@getpaseo/server` npm package name.
const String daemonPackageName = 'agent_daemon';

/// Raised when package metadata for a package cannot be located or is unusable.
///
/// Mirrors upstream `PackageVersionResolutionError`. It is an [Exception]
/// rather than an [Error] because a missing/garbled pubspec is an environment
/// problem the caller may want to recover from, not a programming mistake.
class PackageVersionResolutionError implements Exception {
  PackageVersionResolutionError({
    required this.startDirectory,
    required this.packageName,
  });

  /// Directory the upward search started from.
  final String startDirectory;

  /// Pubspec `name:` that was being looked for.
  final String packageName;

  /// Human-readable explanation, kept close to the upstream message.
  String get message =>
      'Unable to resolve $packageName version from directory $startDirectory.';

  @override
  String toString() => '$runtimeType: $message';
}

/// Raised when the *daemon's* own version cannot be resolved.
///
/// Subclassing keeps upstream's ability to catch either the general or the
/// daemon-specific failure.
class DaemonVersionResolutionError extends PackageVersionResolutionError {
  DaemonVersionResolutionError({
    required super.startDirectory,
    required super.packageName,
  });
}

/// Walks up from [startDirectory] looking for a `pubspec.yaml` whose `name:`
/// equals [packageName], and returns its trimmed `version:`.
///
/// Directories whose pubspec belongs to a *different* package are skipped (a
/// workspace member sits below the workspace root), unreadable pubspecs are
/// skipped, and a matching pubspec with a missing/blank version is a hard
/// failure — all exactly as upstream treats `package.json`.
///
/// Deviations from `package-version.ts`:
/// * `package.json` -> `pubspec.yaml`; JSON parsing -> a minimal top-level
///   scalar reader (see [_readTopLevelPubspecScalar]) so this stays
///   dependency-free.
/// * Node seeds the walk from `import.meta.url` (the compiled module's own
///   location). Dart libraries have no runtime self-location, so the walk is
///   seeded from [startDirectory], defaulting to the current directory.
String resolvePackageVersion({
  required String packageName,
  String? startDirectory,
}) {
  final origin = p.normalize(
    p.absolute(startDirectory ?? Directory.current.path),
  );
  var currentDir = origin;
  while (true) {
    final version = _readMatchingPackageVersion(
      p.join(currentDir, 'pubspec.yaml'),
      packageName,
      origin,
    );
    if (version != null) return version;

    final parentDir = p.dirname(currentDir);
    if (parentDir == currentDir) break;
    currentDir = parentDir;
  }

  throw PackageVersionResolutionError(
    startDirectory: origin,
    packageName: packageName,
  );
}

/// Resolves the daemon version from on-disk package metadata.
///
/// Rewraps [PackageVersionResolutionError] as [DaemonVersionResolutionError] so
/// callers can distinguish "the daemon's own metadata is broken" from a generic
/// lookup failure, matching upstream `resolveDaemonVersion`.
String resolveDaemonVersion([String? startDirectory]) {
  try {
    return resolvePackageVersion(
      packageName: daemonPackageName,
      startDirectory: startDirectory,
    );
  } on PackageVersionResolutionError catch (error) {
    throw DaemonVersionResolutionError(
      startDirectory: error.startDirectory,
      packageName: daemonPackageName,
    );
  }
}

/// Best-effort daemon version: on-disk metadata first, compile-time constant
/// second.
///
/// A released daemon is a single AOT executable with no `pubspec.yaml` beside
/// it, so the filesystem walk that works from a source checkout necessarily
/// fails in production. `daemonVersion` from `daemon_lifecycle` is this repo's
/// existing source of truth for the shipped version (`ws_server.dart` and
/// `daemon_server.dart` already report it), so it is reused as the fallback
/// rather than duplicated.
String resolveDaemonVersionWithFallback([String? startDirectory]) {
  try {
    return resolveDaemonVersion(startDirectory);
  } on PackageVersionResolutionError {
    return daemonVersion;
  }
}

/// Returns the version from [pubspecPath] when it declares [packageName], or
/// `null` when the caller should keep walking upward.
String? _readMatchingPackageVersion(
  String pubspecPath,
  String packageName,
  String startDirectory,
) {
  final String source;
  try {
    final file = File(pubspecPath);
    if (!file.existsSync()) return null;
    source = file.readAsStringSync();
  } on Object {
    // Unreadable metadata is indistinguishable from absent metadata upstream
    // (`JSON.parse` failures return null and the walk continues).
    return null;
  }

  if (_readTopLevelPubspecScalar(source, 'name') != packageName) return null;

  final version = _readTopLevelPubspecScalar(source, 'version');
  if (version != null && version.trim().isNotEmpty) return version.trim();

  throw PackageVersionResolutionError(
    startDirectory: startDirectory,
    packageName: packageName,
  );
}

/// Reads a top-level `key: value` scalar out of a pubspec without pulling in a
/// YAML parser.
///
/// Only unindented, non-comment lines count, so nested keys (`dependencies:` ->
/// `  name:`) can never be mistaken for the package's own fields. Inline
/// comments and surrounding quotes are stripped.
String? _readTopLevelPubspecScalar(String source, String key) {
  for (final line in const LineSplitter().convert(source)) {
    if (line.isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t') || line.startsWith('#')) {
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    if (line.substring(0, colon).trim() != key) continue;

    var value = line.substring(colon + 1).trim();
    final comment = value.indexOf(' #');
    if (comment >= 0) value = value.substring(0, comment).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
  return null;
}

// ---------------------------------------------------------------------------
// paseo-home.ts
// ---------------------------------------------------------------------------

/// POSIX mode for the Tinyrack home directory (`0o700`).
///
/// The home directory holds the daemon keypair, bearer password hash and
/// persisted credentials, so it must not be group/world readable.
const int privateDirectoryMode = 0x1C0;

/// Expands a leading `~` against the user's home directory.
///
/// Deviations from upstream `expandHomeDir`:
/// * `~\` is accepted alongside `~/`, because a Windows user typing
///   `TINYRACK_HOME=~\agent` means the same thing.
/// * Node's `os.homedir()` is replaced by `USERPROFILE`/`HOME`, matching the
///   lookup order already used by `resolveTinyrackHome`; when neither is set
///   the current directory is used so the result can never be a literal `~`
///   directory.
String expandHomeDirectory(String input, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
  if (input == '~') return home;
  if (input.startsWith('~/') || input.startsWith(r'~\')) {
    return p.join(home, input.substring(2));
  }
  return input;
}

/// Creates [directoryPath] (and parents) with owner-only permissions.
///
/// Dart has no `mkdir(mode:)`, so the mode is applied afterwards via `chmod`,
/// and only on POSIX — the same best-effort, never-fatal shape as
/// `private-files.ts`, and consistent with this repo's existing
/// `ensurePrivateFile`.
void ensurePrivateDirectory(String directoryPath) {
  Directory(directoryPath).createSync(recursive: true);
  if (Platform.isWindows) return;
  try {
    Process.runSync('chmod', ['700', directoryPath]);
  } on Object {
    // Keep startup resilient if the filesystem does not support POSIX modes.
  }
}

/// Resolves the Tinyrack home directory and guarantees it exists privately.
///
/// Port of `resolvePaseoHome`. The raw value comes from the repo's existing
/// [resolveTinyrackHome] (`TINYRACK_HOME`, else `~/.tinyrack-agent` under
/// `USERPROFILE`/`HOME`); this function adds the three things upstream does on
/// top of the raw lookup and that [resolveTinyrackHome] does not do: `~`
/// expansion, absolutization/normalization, and private-directory creation.
String resolveTinyrackServerHome([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final raw = resolveTinyrackHome(env);
  final resolved = p.normalize(
    p.absolute(expandHomeDirectory(raw, environment: env)),
  );
  ensurePrivateDirectory(resolved);
  return resolved;
}

// ---------------------------------------------------------------------------
// paseo-env.ts
// ---------------------------------------------------------------------------

/// Selects the daemon's runtime mode, deliberately *not* reusing `NODE_ENV`.
const String tinyrackNodeEnvKey = 'TINYRACK_NODE_ENV';

/// Set when the daemon re-spawns itself through an Electron-style host.
const String electronRunAsNodeEnvKey = 'ELECTRON_RUN_AS_NODE';

/// Variables that describe *how this process was launched* and must never leak
/// into a child the user's agent spawns.
///
/// A shell tool inheriting `TINYRACK_SUPERVISED` would make nested tooling
/// believe it is desktop-managed and change its own behavior, so the whole set
/// is scrubbed from every external environment.
const List<String> runtimeControlEnvKeys = <String>[
  tinyrackNodeEnvKey,
  'TINYRACK_DESKTOP_MANAGED',
  'TINYRACK_SUPERVISED',
  electronRunAsNodeEnvKey,
  'ELECTRON_NO_ATTACH_CONSOLE',
];

/// Runtime modes accepted in [tinyrackNodeEnvKey].
///
/// Repo style maps the upstream `"development" | "production" | "test"` union
/// onto an enum; anything else resolves to `null` rather than a fourth case.
enum TinyrackNodeEnv { development, production, test }

/// Builds the environment for an *internal* daemon child process.
///
/// Internal children are the daemon's own workers, so they intentionally keep
/// the runtime control variables — that is the whole difference from
/// [createExternalProcessEnv].
///
/// Deviation: Dart has no `undefined`. Upstream models "present but unset" with
/// `string | undefined` values; here that is `Map<String, String?>` and `null`
/// carries the same meaning. The internal copy preserves nulls verbatim, just
/// as the upstream spread does.
Map<String, String?> createTinyrackInternalEnv(Map<String, String?> baseEnv) =>
    Map<String, String?>.from(baseEnv);

/// Builds the environment for a process the *user's* agent will run.
///
/// Overlays are applied left to right on top of [baseEnv], then the runtime
/// control keys are removed. The order matters: scrubbing happens *after* the
/// overlays, so an overlay cannot smuggle a control variable back in.
Map<String, String> createExternalProcessEnv(
  Map<String, String?> baseEnv, [
  List<Map<String, String?>> overlays = const [],
]) => _buildExternalProcessEnv(baseEnv, overlays);

/// Identical to [createExternalProcessEnv]; [command] is ignored.
///
/// Upstream kept this deprecated shim while callers migrated off a version that
/// special-cased `process.execPath`. It is ported so the "no per-command
/// special-casing" guarantee stays pinned by tests.
Map<String, String> createExternalCommandProcessEnv(
  String command,
  Map<String, String?> baseEnv, [
  List<Map<String, String?>> overlays = const [],
]) => _buildExternalProcessEnv(baseEnv, overlays);

Map<String, String> _buildExternalProcessEnv(
  Map<String, String?> baseEnv,
  List<Map<String, String?>> overlays,
) {
  final sanitized = <String, String?>{...baseEnv};
  for (final overlay in overlays) {
    sanitized.addAll(overlay);
  }
  for (final key in runtimeControlEnvKeys) {
    sanitized.remove(key);
  }
  return _dropNullValues(sanitized);
}

Map<String, String> _dropNullValues(Map<String, String?> env) {
  final result = <String, String>{};
  env.forEach((key, value) {
    if (value != null) result[key] = value;
  });
  return result;
}

/// A command that re-launches the current executable.
///
/// Repo style: an interface-shaped TS return type becomes a `final class` with
/// named parameters.
final class SelfExecutableCommand {
  const SelfExecutableCommand({
    required this.command,
    required this.args,
    required this.env,
  });

  /// Absolute path of the executable to run.
  final String command;

  /// Arguments passed through unchanged.
  final List<String> args;

  /// Fully resolved child environment.
  final Map<String, String> env;
}

/// Builds a command that re-executes *this* binary.
///
/// Port of `buildSelfNodeCommand`. The overlay is applied **after** scrubbing —
/// upstream `Object.assign(env, { ELECTRON_RUN_AS_NODE: "1" }, envOverlay)` —
/// so a self-spawn may legitimately re-set a control variable that an external
/// spawn is not allowed to keep. A `null` overlay value deletes the key.
///
/// Deviations:
/// * `process.execPath` -> [Platform.resolvedExecutable], overridable via
///   [executable] for tests.
/// * [electronRunAsNodeEnvKey] is still set to `"1"`: this repo remains
///   interoperable with Paseo-launched desktop hosts and already recognises the
///   key, so dropping it would change observable behavior.
SelfExecutableCommand buildSelfExecutableCommand(
  List<String> args, {
  Map<String, String?>? envOverlay,
  Map<String, String?>? baseEnv,
  String? executable,
}) {
  final scrubbed = _buildExternalProcessEnv(
    baseEnv ?? Platform.environment,
    const [],
  );
  final merged = <String, String?>{
    ...scrubbed,
    electronRunAsNodeEnvKey: '1',
    ...?envOverlay,
  };
  return SelfExecutableCommand(
    command: executable ?? Platform.resolvedExecutable,
    args: List<String>.unmodifiable(args),
    env: Map<String, String>.unmodifiable(_dropNullValues(merged)),
  );
}

/// Reads the daemon runtime mode from [tinyrackNodeEnvKey].
///
/// A user's `NODE_ENV` (or any other ambient mode variable) is deliberately
/// ignored: the daemon runs inside the user's shell environment, and letting an
/// unrelated variable flip it into development mode would be a footgun.
/// Unrecognized values resolve to `null`, not a default.
TinyrackNodeEnv? resolveTinyrackNodeEnv(Map<String, String?> env) =>
    switch (env[tinyrackNodeEnvKey]) {
      'development' => TinyrackNodeEnv.development,
      'production' => TinyrackNodeEnv.production,
      'test' => TinyrackNodeEnv.test,
      _ => null,
    };

// ---------------------------------------------------------------------------
// messages.ts
// ---------------------------------------------------------------------------

/// Sentinel distinguishing "no title override" from "override with null".
const Object absentSnapshotTitle = Object();

/// Projects an agent into the wire `AgentSnapshotPayload`.
///
/// Reuses the protocol package's [PaseoAgentSnapshotCodec] (this repo's port of
/// upstream `toAgentPayload`); the only thing this wrapper adds is upstream's
/// `options.title` override.
///
/// Deviation: upstream's `ManagedAgent` has no title at all, so
/// `title: options?.title ?? null` discards nothing. This repo's [AgentSummary]
/// *does* carry a title, so an omitted [title] keeps the agent's own value and
/// only an explicit override (including an explicit `null`) replaces it.
/// Blank overrides normalize to `null`, matching the codec's own rule.
Map<String, Object?> serializeAgentSnapshot(
  AgentSummary agent, {
  Object? title = absentSnapshotTitle,
  Iterable<PermissionItem> pendingPermissions = const [],
}) {
  final payload = PaseoAgentSnapshotCodec.encode(
    agent,
    pendingPermissions: pendingPermissions,
  );
  if (identical(title, absentSnapshotTitle)) return payload;
  final override = title as String?;
  return <String, Object?>{
    ...payload,
    'title': override == null || override.trim().isEmpty ? null : override,
  };
}

/// Validates and normalizes a provider stream event for the websocket wire.
///
/// Returns `null` for anything that does not satisfy the shared schema, which
/// is how upstream keeps a misbehaving provider from poisoning connected
/// clients: the event is dropped, not thrown.
///
/// Two behaviors are load-bearing:
/// * `attention_required` is rewritten with `shouldNotify: false`. Providers
///   emit attention without per-client notification context; the websocket
///   server recomputes `shouldNotify` per client, so the provider's event is
///   normalized to the schema-satisfying default first.
/// * Internal session-config drift events (`mode_changed`, `model_changed`,
///   `thinking_option_changed`) are dropped, because they are not part of the
///   client-facing stream vocabulary.
///
/// Deviation: upstream validates with a zod schema. This repo has no runtime
/// schema; validation instead round-trips the event through the protocol
/// package's [PaseoAgentStreamCodec], which throws [FormatException] on exactly
/// the same rejects (unknown event type, unknown timeline item type, unknown
/// tool-call status such as the legacy `"inProgress"`, `error`/status
/// disagreement). Valid events are returned **unchanged** rather than
/// re-encoded, preserving upstream's pass-through guarantee.
Map<String, Object?>? serializeAgentStreamEvent(Map<String, Object?> event) {
  final type = event['type'];
  if (type is! String || type.isEmpty) return null;

  if (type == 'attention_required') {
    return _normalizeAttentionRequired(event);
  }
  return _validateStreamEventPayload(event);
}

Map<String, Object?>? _normalizeAttentionRequired(Map<String, Object?> event) {
  final provider = event['provider'];
  if (provider is! String || provider.isEmpty) return null;

  final reason = event['reason'];
  if (reason is! String ||
      !AgentAttentionReason.values.any((value) => value.name == reason)) {
    return null;
  }

  final timestamp = event['timestamp'];
  if (timestamp != null && timestamp is! String) return null;

  return <String, Object?>{
    'type': 'attention_required',
    'provider': provider,
    'reason': reason,
    'timestamp': timestamp,
    'shouldNotify': false,
  };
}

Map<String, Object?>? _validateStreamEventPayload(Map<String, Object?> event) {
  try {
    PaseoAgentStreamCodec.decode(<String, Object?>{
      'type': 'agent_stream',
      'payload': <String, Object?>{
        'agentId': _streamValidationAgentId,
        'event': event,
        'timestamp': _streamValidationTimestamp,
        'seq': 0,
        'epoch': '0',
      },
    });
  } on Object {
    return null;
  }
  return event;
}

/// Placeholder envelope fields used only to satisfy the codec while validating
/// a bare event; they never reach the wire.
const String _streamValidationAgentId = 'stream-validation';
const String _streamValidationTimestamp = '1970-01-01T00:00:00.000Z';

// ---------------------------------------------------------------------------
// exports.ts
// ---------------------------------------------------------------------------

/// Symbols the daemon's public entry (`package:agent_daemon/agent_daemon.dart`)
/// must expose.
///
/// Mirrors upstream's positive assertions on `createPaseoDaemon` /
/// `resolvePaseoHome`: `startDaemonServer` is this repo's daemon factory and
/// `resolveTinyrackHome` its home resolver.
const Set<String> serverPublicEntryRequiredSymbols = <String>{
  'startDaemonServer',
  'DaemonServerHandle',
  'resolveTinyrackHome',
};

/// Symbols that belong to the *client* and must never be reachable from the
/// daemon's public entry.
///
/// Keeping them out is what stops the daemon from accidentally depending on
/// client transport code (and the app from importing the daemon to get a
/// client). In this repo they live in `packages/app/lib/core/daemon_client.dart`
/// and equivalents.
const Set<String> daemonClientOnlySymbols = <String>{
  'DaemonClient',
  'DaemonClientConfig',
  'ConnectionState',
  'DaemonEvent',
  'WebSocketFactory',
  'WebSocketLike',
};

final RegExp _exportDirectivePattern = RegExp(
  '''^\\s*export\\s+(?:'([^']+)'|"([^"]+)")''',
  multiLine: true,
);

/// Extracts the targets of every `export '...';` directive in [librarySource].
///
/// Deviation: upstream simply `await import()`s the entry and inspects the
/// resulting namespace object. `dart:mirrors` cannot see re-exported names, so
/// the export surface is recovered from the source of the entry library
/// instead.
List<String> parseDartExportTargets(String librarySource) => [
  for (final match in _exportDirectivePattern.allMatches(librarySource))
    (match.group(1) ?? match.group(2))!,
];

/// Whether [source] declares [symbol] at the top level.
///
/// Covers the three declaration shapes this repo actually uses: type
/// declarations (optionally prefixed by `final`/`sealed`/`abstract`/...),
/// top-level functions, and top-level variables. Anchoring at column zero is
/// what keeps a member named `close` inside a class from counting as a
/// top-level export.
bool declaresTopLevelSymbol(String source, String symbol) {
  final escaped = RegExp.escape(symbol);
  final patterns = <RegExp>[
    RegExp(
      '^(?:(?:abstract|base|final|sealed|interface|mixin|external|const)\\s+)*'
      '(?:class|enum|mixin|extension|typedef)\\s+$escaped\\b',
      multiLine: true,
    ),
    RegExp(
      '^[A-Za-z_\$][\\w<>,?\\[\\]. \$]*\\s$escaped\\s*[(<]',
      multiLine: true,
    ),
    RegExp(
      '^(?:final|const|var|late)\\s[^=;]*\\b$escaped\\s*[=;]',
      multiLine: true,
    ),
  ];
  return patterns.any((pattern) => pattern.hasMatch(source));
}

/// Returns a human-readable violation for every broken public-entry rule.
///
/// An empty list means the surface is correct. Returning descriptions instead
/// of throwing lets a single test report *all* problems at once.
List<String> findServerEntrySurfaceViolations({
  required Set<String> exportedSymbols,
}) => [
  for (final symbol in serverPublicEntryRequiredSymbols)
    if (!exportedSymbols.contains(symbol))
      'missing required server entry export: $symbol',
  for (final symbol in daemonClientOnlySymbols)
    if (exportedSymbols.contains(symbol))
      'daemon-client symbol leaked into the server entry: $symbol',
];
