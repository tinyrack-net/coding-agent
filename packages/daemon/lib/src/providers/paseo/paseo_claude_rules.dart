/// Port of four frozen Paseo 0.2.0 provider rules that had no Dart home:
///
/// - `agent/providers/claude/rewind.ts` — the Claude-specific half of a rewind
///   request: forking the provider transcript and restoring checkpointed files.
/// - `agent/providers/claude/project-dir.ts` — the Claude Agent SDK's
///   `~/.claude/projects/<encoded>` directory encoding.
/// - `agent/providers/cursor-acp-agent.ts` — the ACP knobs that make
///   `cursor-agent acp` behave, plus the config-option → feature derivation
///   those knobs feed.
/// - `agent/providers/provider-runner.ts` — collecting one provider turn out of
///   a subscription into a single result value.
///
/// They are grouped into one library the same way
/// `agent/paseo_agent_rules.dart` groups its four: each is a handful of pure
/// rules that would otherwise be a file too small to review on its own. The
/// library is named for Claude because two of the four are Claude's and the
/// rewind rules are the reason the cluster exists; the Cursor and
/// provider-runner sections are called out by their own banners below.
///
/// Reuse note: this library deliberately does **not** re-declare types the
/// daemon already owns. Rewind capability flags come from
/// `agent/paseo_agent_rules.dart`, ACP select-option flattening from
/// `acp_catalog.dart`, and [TimelineItem] / [AgentUsage] / [AgentFeature] /
/// [ProviderSelectOption] from `package:agent_protocol`.
///
/// Architecture note: this daemon runs a native LLM harness instead of driving
/// a vendor CLI, so the *bindings* upstream ships alongside these rules (the
/// real `@anthropic-ai/claude-agent-sdk` handles, the `CursorACPAgentClient`
/// subclass, the `AgentClient.run` wrapper) have no live counterpart. What is
/// ported here is the observable rule in each: path resolution, argument
/// shapes, capability gating and event reduction.
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../agent/paseo_agent_rules.dart' show RewindCapabilities;
import 'acp_catalog.dart' show flattenAcpSelectOptions;

// ---------------------------------------------------------------------------
// claude/rewind.ts
// ---------------------------------------------------------------------------

/// Raised when a Claude rewind cannot proceed.
///
/// Upstream throws bare `new Error(...)`; a named exception keeps the two
/// distinct failures (no session, no checkpoint) matchable in Dart without
/// string-sniffing, while [message] stays byte-for-byte upstream's.
final class ClaudeRewindError implements Exception {
  const ClaudeRewindError(this.message);

  final String message;

  @override
  String toString() => 'ClaudeRewindError: $message';
}

/// The result of forking a Claude session — upstream's
/// `Promise<{ sessionId: string }>`.
final class ClaudeForkedSession {
  const ClaudeForkedSession({required this.sessionId});

  /// The id of the *new* branch. Rewinding never mutates the old session, so
  /// the caller must rebind to this id or its next prompt lands on the
  /// pre-rewind transcript.
  final String sessionId;
}

/// The one Claude Agent SDK entry point conversation rewind needs.
///
/// Upstream declares this so the SDK can be faked in tests and binds the real
/// implementation in `realClaudeRewindSdk`. There is no counterpart binding
/// here: this daemon never loads `@anthropic-ai/claude-agent-sdk`, so the
/// interface is the whole port and an adapter would have nothing to adapt.
abstract interface class ClaudeRewindSdk {
  /// Branches [sessionId] so the new transcript ends just before
  /// [upToMessageId].
  Future<ClaudeForkedSession> forkSession(
    String sessionId, {
    required String upToMessageId,
  });
}

/// Outcome of asking Claude to restore the files a message's turn touched.
///
/// [error] carries the provider's own explanation when [canRewind] is false;
/// it is `null` when the provider declined without one.
final class ClaudeFileRewindResult {
  const ClaudeFileRewindResult({required this.canRewind, this.error});

  final bool canRewind;
  final String? error;
}

/// The one live-query entry point file rewind needs — upstream's `Query`
/// narrowed to `rewindFiles`.
///
/// Unlike [ClaudeRewindSdk] this is inherently session-scoped: file
/// checkpoints live in the running query, not in the SDK module.
abstract interface class ClaudeRewindQuery {
  /// Restores tracked files to their state at [messageId].
  ///
  /// [dryRun] is part of the upstream signature and is always passed `false`
  /// by these rules; it stays on the interface so a caller can probe.
  Future<ClaudeFileRewindResult> rewindFiles(
    String messageId, {
    required bool dryRun,
  });
}

/// Translates a Paseo timeline message id into the id Claude's own JSONL
/// transcript uses.
///
/// Upstream types the return as a non-nullable `string | Promise<string>`, so
/// the `?? input.messageId` fallback fires only when *no* resolver was passed.
/// A resolver that returns the empty string therefore yields the empty string
/// rather than falling back — reproduced here, since `null` is not a value
/// this signature can produce either.
typedef ClaudeMessageIdResolver = FutureOr<String> Function(String messageId);

/// What a Claude-backed session advertises to [invokeRewindCapability].
///
/// Claude implements all three legs — [revertClaudeConversation],
/// [revertClaudeFiles] and [revertClaudeConversationAndFiles] — so every flag
/// is set. Exposed as a constant so a session class does not have to restate
/// (and risk mis-stating) what this library can actually do.
const claudeRewindCapabilities = RewindCapabilities(
  supportsRewindConversation: true,
  supportsRewindFiles: true,
  supportsRewindBoth: true,
);

/// Forks the Claude transcript so it ends just before [messageId], then
/// rebinds the caller's session id to the fork.
///
/// The working tree is left alone; use [revertClaudeConversationAndFiles] when
/// the files must follow.
///
/// DEVIATION: upstream's guard is `if (!input.sessionId)`, which is falsy for
/// both `null` and `""`. Dart has no truthiness, so the emptiness test is
/// explicit — an empty session id is as absent as a missing one, and forking
/// from it would ask the SDK to branch a session that was never established.
Future<void> revertClaudeConversation({
  required ClaudeRewindSdk sdk,
  required String? sessionId,
  required String messageId,
  required void Function(String sessionId) setSessionId,
  ClaudeMessageIdResolver? resolveMessageId,
}) async {
  if (sessionId == null || sessionId.isEmpty) {
    throw const ClaudeRewindError('Claude session is not ready for rewind');
  }
  final resolvedMessageId = await _resolveClaudeMessageId(
    messageId,
    resolveMessageId,
  );
  final fork = await sdk.forkSession(
    sessionId,
    upToMessageId: resolvedMessageId,
  );
  setSessionId(fork.sessionId);
}

/// Restores the files checkpointed at [messageId], leaving the transcript
/// alone.
///
/// A provider that reports it cannot rewind must fail loudly: silently
/// succeeding would leave the working tree ahead of a transcript the user
/// believes was restored. The provider's own [ClaudeFileRewindResult.error]
/// wins when it supplies one, because it is more specific than anything this
/// rule could say.
///
/// Note the fallback message quotes the *resolved* id, matching upstream,
/// which shadows `messageId` with the resolved value before building it.
Future<void> revertClaudeFiles({
  required ClaudeRewindQuery query,
  required String messageId,
  ClaudeMessageIdResolver? resolveMessageId,
}) async {
  final resolvedMessageId = await _resolveClaudeMessageId(
    messageId,
    resolveMessageId,
  );
  final result = await query.rewindFiles(resolvedMessageId, dryRun: false);
  if (!result.canRewind) {
    throw ClaudeRewindError(
      // Upstream's `??` is nullish, not falsy: a provider that reports an
      // empty-string error produces an empty-string message rather than the
      // fallback. Dart's `??` behaves identically.
      result.error ?? 'No file checkpoint found for message $resolvedMessageId',
    );
  }
}

/// Restores files *and* transcript for [messageId].
///
/// Files go first, on purpose: if the file rewind fails the transcript is
/// still intact and the caller can retry, whereas forking first and then
/// failing would leave a branch nobody asked for. The transcript rebind
/// happens before this future completes so a caller that rehydrates its
/// timeline immediately afterwards reads the forked session, not the old one.
///
/// [resolveMessageId] is invoked once per leg — twice in total — exactly as
/// upstream does, because each leg resolves independently.
Future<void> revertClaudeConversationAndFiles({
  required ClaudeRewindSdk sdk,
  required ClaudeRewindQuery query,
  required String? sessionId,
  required String messageId,
  required void Function(String sessionId) setSessionId,
  ClaudeMessageIdResolver? resolveMessageId,
}) async {
  await revertClaudeFiles(
    query: query,
    messageId: messageId,
    resolveMessageId: resolveMessageId,
  );
  await revertClaudeConversation(
    sdk: sdk,
    sessionId: sessionId,
    messageId: messageId,
    setSessionId: setSessionId,
    resolveMessageId: resolveMessageId,
  );
}

Future<String> _resolveClaudeMessageId(
  String messageId,
  ClaudeMessageIdResolver? resolveMessageId,
) async =>
    resolveMessageId == null ? messageId : await resolveMessageId(messageId);

// ---------------------------------------------------------------------------
// claude/project-dir.ts
// ---------------------------------------------------------------------------

/// The Claude Agent SDK truncates an encoded project path at 200 characters
/// and appends a hash of the full path, so two long sibling directories do not
/// collide on the same transcript folder.
const claudeProjectDirLengthCap = 200;

final _claudeProjectDirSeparators = RegExp('[^a-zA-Z0-9]');

/// The environment inputs [resolveClaudeConfigDir] reads.
///
/// Injected rather than read from [Platform] so the rule is testable and so a
/// caller that already holds a provider environment map (as
/// `ClaudeAgentClient` does) can pass it straight through.
final class ClaudeConfigDirEnvironment {
  const ClaudeConfigDirEnvironment({
    required this.variables,
    required this.homeDirectory,
  });

  /// The process environment, or a provider-specific overlay of it.
  final Map<String, String> variables;

  /// Stands in for Node's `os.homedir()`.
  ///
  /// DEVIATION: `os.homedir()` consults `$HOME` on POSIX and `%USERPROFILE%`
  /// on Windows and, when neither is set, falls back to `getpwuid()` /
  /// `SHGetKnownFolderPath` — neither of which Dart exposes.
  /// [ClaudeConfigDirEnvironment.fromPlatform] therefore reproduces the
  /// convention the rest of this daemon already uses (`HOME`, then
  /// `USERPROFILE`, then the current directory), which agrees with Node
  /// whenever either variable is set and differs only in the
  /// no-variables-at-all case.
  final String homeDirectory;

  /// Reads the ambient environment.
  ///
  /// [variables] overlays `Platform.environment` when supplied, matching how
  /// `ClaudeAgentClient` resolves a session's environment before looking for
  /// its transcripts.
  factory ClaudeConfigDirEnvironment.fromPlatform([
    Map<String, String>? variables,
  ]) {
    final env = variables ?? Platform.environment;
    return ClaudeConfigDirEnvironment(
      variables: env,
      homeDirectory:
          env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path,
    );
  }
}

/// Where Claude keeps its per-user state — `$CLAUDE_CONFIG_DIR`, else
/// `<home>/.claude`.
///
/// DEVIATION: upstream's `??` is nullish, so an *empty* `CLAUDE_CONFIG_DIR`
/// wins and yields a relative `projects/...` path instead of falling back to
/// the home directory. Dart's `??` on a `Map` lookup behaves the same, and the
/// quirk is preserved deliberately: a user who exports an empty variable is
/// telling Claude something, and the daemon must look where Claude looks.
String resolveClaudeConfigDir(ClaudeConfigDirEnvironment environment) =>
    environment.variables['CLAUDE_CONFIG_DIR'] ??
    p.join(environment.homeDirectory, '.claude');

/// Resolves a path to its canonical on-disk form, or returns it unchanged.
///
/// Upstream's `canonicalize` swallows every realpath failure, most commonly
/// "the directory does not exist yet" — the encoded name must still be
/// computable for a workspace Claude has not visited.
typedef ClaudeProjectPathCanonicalizer = FutureOr<String> Function(String path);

/// Inputs to [claudeProjectDirectory] and [claudeProjectDirectorySync].
final class ClaudeProjectDirectoryOptions {
  const ClaudeProjectDirectoryOptions({
    this.configDir,
    this.environment,
    this.normalizeUnicode,
    this.canonicalize,
  });

  /// Overrides the whole `$CLAUDE_CONFIG_DIR` / `<home>/.claude` lookup.
  final String? configDir;

  /// Environment consulted when [configDir] is absent.
  final ClaudeConfigDirEnvironment? environment;

  /// Whether to apply Unicode NFC to the canonical path.
  ///
  /// Upstream gates this on `process.platform === "darwin"`, which is the
  /// default here. It is exposed because the answer is a property of the
  /// filesystem, not of the running process — a daemon reading a transcript
  /// folder written on a Mac needs the Mac rule regardless of where it runs.
  final bool? normalizeUnicode;

  /// Overrides realpath resolution; defaults to the real filesystem.
  final ClaudeProjectPathCanonicalizer? canonicalize;
}

/// The `~/.claude/projects/<encoded>` directory the Claude Agent SDK stores
/// [cwd]'s transcripts in.
///
/// Paseo has to compute this itself because the SDK exposes no accessor for
/// it, and getting it wrong means silently reading an empty history for a
/// session that does have one.
///
/// DEVIATION: upstream's async entry point uses Node's `fs/promises.realpath`
/// while its sync one uses `realpathSync.native` — two different resolvers
/// that upstream's own test asserts must agree. Dart's async and sync
/// `resolveSymbolicLinks` are the same call, so they agree by construction.
Future<String> claudeProjectDirectory(
  String cwd, [
  ClaudeProjectDirectoryOptions options = const ClaudeProjectDirectoryOptions(),
]) async {
  final canonicalize = options.canonicalize ?? _canonicalizeClaudeProjectPath;
  final canonical = _normalizeClaudeProjectPath(
    await canonicalize(cwd),
    options,
  );
  return _joinClaudeProjectDir(canonical, options);
}

/// Synchronous [claudeProjectDirectory], for call sites that cannot await.
///
/// A [ClaudeProjectDirectoryOptions.canonicalize] that returns a `Future`
/// cannot be honoured here; passing one throws, rather than silently
/// producing a directory named after a `Future`'s `toString`.
String claudeProjectDirectorySync(
  String cwd, [
  ClaudeProjectDirectoryOptions options = const ClaudeProjectDirectoryOptions(),
]) {
  final canonicalize =
      options.canonicalize ?? _canonicalizeClaudeProjectPathSync;
  final canonical = canonicalize(cwd);
  if (canonical is! String) {
    throw ArgumentError.value(
      options.canonicalize,
      'options.canonicalize',
      'claudeProjectDirectorySync requires a synchronous canonicalizer',
    );
  }
  return _joinClaudeProjectDir(
    _normalizeClaudeProjectPath(canonical, options),
    options,
  );
}

/// Encodes an already-canonical path the way the Claude Agent SDK does.
///
/// Every character outside `[a-zA-Z0-9]` becomes `-`; if the result exceeds
/// [claudeProjectDirLengthCap] it is truncated there and a base-36 hash of the
/// *pre-substitution* path is appended after another `-`.
///
/// Exposed separately because the canonicalize step needs real I/O while this
/// step is pure, and because callers that already hold a canonical path (a
/// directory listing walk, for instance) should not pay for a second realpath.
String encodeClaudeProjectPath(String canonicalPath) {
  final replaced = canonicalPath.replaceAll(_claudeProjectDirSeparators, '-');
  if (replaced.length <= claudeProjectDirLengthCap) return replaced;
  return '${replaced.substring(0, claudeProjectDirLengthCap)}'
      '-${_javaScriptStringHash(canonicalPath)}';
}

String _joinClaudeProjectDir(
  String canonical,
  ClaudeProjectDirectoryOptions options,
) {
  final configDir =
      options.configDir ??
      resolveClaudeConfigDir(
        options.environment ?? ClaudeConfigDirEnvironment.fromPlatform(),
      );
  return p.join(configDir, 'projects', encodeClaudeProjectPath(canonical));
}

/// Applies upstream's darwin-only NFC pass.
///
/// It runs *after* canonicalization, not before: macOS filesystems are
/// normalization-insensitive but form-preserving, so realpath hands back
/// whatever form is stored on disk (often NFD). Normalizing first and then
/// resolving would let realpath undo the normalization.
String _normalizeClaudeProjectPath(
  String canonical,
  ClaudeProjectDirectoryOptions options,
) => (options.normalizeUnicode ?? Platform.isMacOS)
    ? unorm.nfc(canonical)
    : canonical;

Future<String> _canonicalizeClaudeProjectPath(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } catch (_) {
    // Upstream's bare `catch {}`: any failure at all means "use the input".
    return path;
  }
}

String _canonicalizeClaudeProjectPathSync(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return path;
  }
}

/// Java's `String.hashCode` as JavaScript computes it: a 32-bit-wrapping
/// `hash * 31 + charCode` fold over UTF-16 code units, rendered base-36.
///
/// `hash << 5) - hash` is `hash * 31`; `| 0` truncates to a signed 32-bit
/// value after every step, which is what makes the result reproducible across
/// languages. Dart integers are 64-bit, so the truncation is explicit via
/// [int.toSigned]. `Math.abs` of the most-negative value is 2147483648 in
/// JavaScript (numbers are doubles) and [int.abs] agrees.
String _javaScriptStringHash(String input) {
  var hash = 0;
  for (final codeUnit in input.codeUnits) {
    hash = ((hash << 5) - hash + codeUnit).toSigned(32);
  }
  return hash.abs().toRadixString(36);
}

// ---------------------------------------------------------------------------
// cursor-acp-agent.ts
// ---------------------------------------------------------------------------

/// A provider-level ACP session config option that Paseo surfaces to the user
/// as a first-class feature toggle.
///
/// ACP agents describe their own knobs generically; this descriptor is how a
/// provider adapter says "this particular knob deserves a labelled control",
/// mapping the agent's raw [configId] onto Paseo's stable feature [id].
final class AcpConfigFeatureOption {
  const AcpConfigFeatureOption({
    required this.id,
    required this.configId,
    required this.label,
    this.category,
    this.description,
    this.tooltip,
    this.icon,
    this.emptyOptionLabel,
  });

  /// Paseo's stable id for the feature. Kept separate from [configId] so a
  /// provider can rename its ACP option without breaking persisted selections.
  final String id;

  /// The ACP `configOptions[].id` this feature reads and writes.
  final String configId;

  /// Optional extra match on the ACP option's `category`. When `null` the
  /// [configId] match alone decides, which is what Cursor's `fast` needs
  /// because the agent publishes it without a category.
  final String? category;

  final String label;
  final String? description;
  final String? tooltip;
  final String? icon;

  /// Label used for a choice whose value is the empty string and whose name is
  /// blank — the ACP idiom for "no selection".
  final String? emptyOptionLabel;
}

/// The default ACP wait for an agent's first `available_commands_update`.
const defaultAcpInitialCommandsWaitTimeout = Duration(milliseconds: 1500);

/// `cursor-agent` publishes its slash commands asynchronously, well after the
/// session handshake, so Cursor raises the wait from the 1.5 s default.
const cursorInitialCommandsWaitTimeout = Duration(milliseconds: 10000);

/// Cursor encodes model *parameters* (context length, reasoning effort, fast
/// mode) into the model id itself — `gpt-5.4[context=272k,...]`. Advertising
/// `parameterizedModelPicker` tells the client to treat those ids as opaque
/// rather than trying to pretty-print or re-derive them.
const cursorClientCapabilityMeta = <String, Object?>{
  'parameterizedModelPicker': true,
};

/// Cursor's fast-mode switch, surfaced as a Paseo feature.
const cursorFastFeatureOption = AcpConfigFeatureOption(
  id: 'fast',
  configId: 'fast',
  label: 'Fast',
  description: 'Cursor fast mode',
  tooltip: 'Select Cursor fast mode',
  icon: 'zap',
);

/// The ACP client knobs a provider adapter overrides.
///
/// Upstream expresses these as constructor options threaded from
/// `CursorACPAgentClient` through `GenericACPAgentClient` into
/// `ACPAgentClient`. This daemon's [GenericAcpAgentClient] has no such knobs,
/// so the port is the value object: it pins *what Cursor asks for* without
/// inventing a subclass that would have nothing to subclass.
final class AcpAgentClientOverrides {
  const AcpAgentClientOverrides({
    this.waitForInitialCommands = false,
    this.initialCommandsWaitTimeout = defaultAcpInitialCommandsWaitTimeout,
    this.clientCapabilityMeta,
    this.configFeatureOptions = const [],
  });

  /// Whether to hold the session handshake open until the agent has published
  /// its slash commands.
  final bool waitForInitialCommands;

  /// How long that wait may last before giving up and continuing.
  final Duration initialCommandsWaitTimeout;

  /// Extra `_meta` advertised in the ACP client capabilities.
  final Map<String, Object?>? clientCapabilityMeta;

  /// ACP config options promoted to Paseo features.
  final List<AcpConfigFeatureOption> configFeatureOptions;
}

/// Everything `CursorACPAgentClient`'s constructor sets.
///
/// Cursor is otherwise a stock generic ACP client: notably it installs *no*
/// model transformer, which is why its ACP model ids reach the catalog
/// verbatim and why an ACP session reporting no models yields no models rather
/// than falling back to a `cursor-agent`-CLI list. That absence is a rule, and
/// `paseo_claude_rules_test.dart` pins it against [deriveAcpProviderCatalog].
const cursorAcpAgentClientOverrides = AcpAgentClientOverrides(
  waitForInitialCommands: true,
  initialCommandsWaitTimeout: cursorInitialCommandsWaitTimeout,
  clientCapabilityMeta: cursorClientCapabilityMeta,
  configFeatureOptions: [cursorFastFeatureOption],
);

/// Finds the ACP select config option a [featureOption] is bound to.
///
/// Matches on `type == "select"` and `id`, plus `category` only when the
/// descriptor names one — an unset [AcpConfigFeatureOption.category] matches
/// any category, including none at all.
///
/// DEVIATION: this cannot reuse `acp_catalog.dart`'s option lookup, which
/// matches by *category* (`mode`, `model`, `thought_level`) rather than by id.
/// Feature options are keyed the other way round.
Map<String, Object?>? findAcpFeatureConfigOption(
  List<Map<String, Object?>>? configOptions,
  AcpConfigFeatureOption featureOption,
) {
  if (configOptions == null) return null;
  for (final entry in configOptions) {
    if (entry['type'] == 'select' &&
        entry['id'] == featureOption.configId &&
        (featureOption.category == null ||
            entry['category'] == featureOption.category)) {
      return entry;
    }
  }
  return null;
}

/// Turns the ACP session's config options into the features Paseo shows.
///
/// Iteration order follows [featureOptions], not the agent's config order, so
/// the UI ordering is the adapter's choice. A descriptor with no matching ACP
/// option contributes nothing: an agent build that dropped the knob must not
/// leave a dead control on screen.
///
/// The select-choice flattening (including group inheritance) is
/// `acp_catalog.dart`'s [flattenAcpSelectOptions], shared with model and mode
/// derivation.
List<AgentFeature> deriveAcpFeatures(
  List<Map<String, Object?>>? configOptions,
  List<AcpConfigFeatureOption> featureOptions,
) {
  final features = <AgentFeature>[];
  for (final featureOption in featureOptions) {
    final option = findAcpFeatureConfigOption(configOptions, featureOption);
    if (option == null) continue;
    final currentValue = option['currentValue'];
    features.add(
      AgentFeatureSelect(
        id: featureOption.id,
        label: featureOption.label,
        description: featureOption.description,
        tooltip: featureOption.tooltip,
        icon: featureOption.icon,
        // Upstream's `option.currentValue ?? null` collapses an absent value
        // to null; a non-string value is equally "no selection" here.
        value: currentValue is String ? currentValue : null,
        options: _deriveAcpFeatureChoices(option, featureOption),
      ),
    );
  }
  return features;
}

List<ProviderSelectOption> _deriveAcpFeatureChoices(
  Map<String, Object?> option,
  AcpConfigFeatureOption featureOption,
) {
  final choices = <ProviderSelectOption>[];
  for (final choice in flattenAcpSelectOptions(option)) {
    final value = choice['value'];
    // The ACP schema makes `value` a required string, so this guard is
    // unreachable against a conforming agent; upstream has no equivalent
    // because TypeScript erases the check.
    if (value is! String) continue;
    final description = choice['description'];
    final group = choice['group'];
    choices.add(
      ProviderSelectOption(
        id: value,
        label: _acpFeatureChoiceLabel(choice, value, featureOption),
        description: description is String ? description : null,
        // Always a concrete boolean, matching upstream's
        // `choice.value === option.currentValue`.
        isDefault: value == option['currentValue'],
        metadata: group is String && group.isNotEmpty ? {'group': group} : null,
      ),
    );
  }
  return choices;
}

/// Upstream's `normalizeConfigFeatureOptionLabel`.
///
/// A trimmed non-blank name wins; otherwise the "no selection" choice borrows
/// [AcpConfigFeatureOption.emptyOptionLabel]; otherwise the raw value is shown,
/// which is better than a blank row even when it is an opaque id.
///
/// The `emptyOptionLabel` test is upstream's truthiness check, so an
/// empty-string label falls through to the value rather than rendering blank.
String _acpFeatureChoiceLabel(
  Map<String, Object?> choice,
  String value,
  AcpConfigFeatureOption featureOption,
) {
  final rawName = choice['name'];
  final name = rawName is String ? rawName.trim() : '';
  if (name.isNotEmpty) return name;
  final emptyOptionLabel = featureOption.emptyOptionLabel;
  if (value.isEmpty &&
      emptyOptionLabel != null &&
      emptyOptionLabel.isNotEmpty) {
    return emptyOptionLabel;
  }
  return value;
}

// ---------------------------------------------------------------------------
// provider-runner.ts
// ---------------------------------------------------------------------------

/// The events [runProviderTurn] reduces.
///
/// Upstream's `AgentStreamEvent` is a fifteen-arm structural union, but the
/// runner only ever asks four questions of it, so the port narrows to those
/// four arms plus [ProviderTurnIgnoredEvent] for everything else. The daemon's
/// own [ProviderEvent] could not stand in: it carries no turn id, and turn
/// scoping is the whole point of the filter below.
sealed class ProviderTurnEvent {
  const ProviderTurnEvent({this.turnId});

  /// Upstream's `getAgentStreamEventTurnId`: `undefined` for the event arms
  /// that have no `turnId` property at all, which is why an untagged event is
  /// never filtered out by turn.
  final String? turnId;
}

/// One timeline item produced during the turn.
final class ProviderTurnTimelineEvent extends ProviderTurnEvent {
  const ProviderTurnTimelineEvent({required this.item, super.turnId});

  final TimelineItem item;
}

/// The turn finished normally.
final class ProviderTurnCompletedEvent extends ProviderTurnEvent {
  const ProviderTurnCompletedEvent({this.usage, super.turnId});

  /// Optional upstream; a provider that reports no usage leaves the result's
  /// usage unset rather than zeroed.
  final AgentUsage? usage;
}

/// The turn failed. [error] becomes the thrown [ProviderTurnFailure]'s message.
final class ProviderTurnFailedEvent extends ProviderTurnEvent {
  const ProviderTurnFailedEvent({required this.error, super.turnId});

  final String error;
}

/// The turn was canceled.
///
/// Upstream resolves rather than rejects: a user-initiated stop is not an
/// error, and whatever timeline arrived before the stop is still the answer.
final class ProviderTurnCanceledEvent extends ProviderTurnEvent {
  const ProviderTurnCanceledEvent({required this.reason, super.turnId});

  final String reason;
}

/// Any event the runner does not reduce — `turn_started`, `usage_updated`,
/// `permission_requested` and friends.
///
/// Carried explicitly rather than dropped at the source so the turn filter
/// still sees them, matching upstream where every arm reaches `processEvent`.
final class ProviderTurnIgnoredEvent extends ProviderTurnEvent {
  const ProviderTurnIgnoredEvent({required this.type, super.turnId});

  /// The upstream `event.type` string, kept for diagnostics.
  final String type;
}

/// Thrown by [runProviderTurn] when the turn reports failure.
final class ProviderTurnFailure implements Exception {
  const ProviderTurnFailure(this.message);

  /// Verbatim `ProviderTurnFailedEvent.error`, matching upstream's
  /// `new Error(event.error)`.
  final String message;

  @override
  String toString() => 'ProviderTurnFailure: $message';
}

/// What one completed turn amounts to — upstream's `AgentRunResult`.
///
/// `canceled` is absent on purpose: upstream declares the field but
/// `runProviderTurn` never sets it, so a canceled turn is indistinguishable
/// from a completed one in this result.
final class ProviderTurnResult {
  const ProviderTurnResult({
    required this.sessionId,
    required this.finalText,
    required this.timeline,
    this.usage,
  });

  final String sessionId;
  final String finalText;
  final List<TimelineItem> timeline;
  final AgentUsage? usage;
}

/// Folds each timeline item into the turn's final text.
typedef ProviderFinalTextReducer =
    String Function({required String current, required TimelineItem item});

/// Cancels a subscription made with [ProviderTurnSubscribe].
typedef ProviderTurnUnsubscribe = void Function();

/// Registers a listener and returns its canceller.
typedef ProviderTurnSubscribe =
    ProviderTurnUnsubscribe Function(
      void Function(ProviderTurnEvent event) listener,
    );

/// Starts the turn and resolves with its id.
typedef ProviderTurnStarter = Future<String> Function();

/// Runs one provider turn to completion and collects it into a single result.
///
/// The ordering here is the entire point of the rule. The subscription is
/// installed *before* the turn is started, because a fast provider can emit
/// its first timeline item before `startTurn` resolves; those events are
/// buffered and replayed once the turn id is known, so nothing is lost and
/// nothing is attributed to the wrong turn. Once the id is known, events
/// tagged with a *different* turn are dropped — a shared session stream
/// carries other turns' traffic too.
///
/// The subscription is torn down in a `finally`, so a `startTurn` that throws
/// and a turn that fails both leave no listener behind. The session id is read
/// only after a successful completion, matching upstream: a failed turn throws
/// before it is consulted.
///
/// DEVIATION: upstream threads `(prompt, runOptions)` through into `startTurn`.
/// This daemon's prompt surface is four arguments wide (text, images,
/// attachments, output schema) rather than upstream's two-value union, and the
/// runner never inspects either value, so [startTurn] is a nullary closure the
/// caller binds its prompt into.
Future<ProviderTurnResult> runProviderTurn({
  required ProviderTurnStarter startTurn,
  required ProviderTurnSubscribe subscribe,
  required FutureOr<String> Function() getSessionId,
  ProviderFinalTextReducer reduceFinalText =
      replaceFinalTextWithAssistantMessage,
}) async {
  final timeline = <TimelineItem>[];
  final bufferedEvents = <ProviderTurnEvent>[];
  final completion = Completer<void>();
  var finalText = '';
  AgentUsage? usage;
  String? turnId;
  var settled = false;

  void processEvent(ProviderTurnEvent event) {
    if (settled) return;
    final eventTurnId = event.turnId;
    // Upstream's guard is `if (turnId && eventTurnId && eventTurnId !== turnId)`
    // — both halves are truthiness tests, so an empty-string turn id on either
    // side disables the filter entirely rather than matching nothing.
    if (turnId != null &&
        turnId.isNotEmpty &&
        eventTurnId != null &&
        eventTurnId.isNotEmpty &&
        eventTurnId != turnId) {
      return;
    }
    switch (event) {
      case final ProviderTurnTimelineEvent timelineEvent:
        timeline.add(timelineEvent.item);
        finalText = reduceFinalText(
          current: finalText,
          item: timelineEvent.item,
        );
      case final ProviderTurnCompletedEvent completed:
        usage = completed.usage;
        settled = true;
        completion.complete();
      case final ProviderTurnFailedEvent failed:
        settled = true;
        completion.completeError(ProviderTurnFailure(failed.error));
      case ProviderTurnCanceledEvent():
        settled = true;
        completion.complete();
      case ProviderTurnIgnoredEvent():
        break;
    }
  }

  final unsubscribe = subscribe((event) {
    // The same truthiness quirk: a provider that hands back an empty turn id
    // leaves this buffer permanently armed, so only the events replayed below
    // are ever reduced. Preserved rather than "fixed" — a provider doing that
    // is broken, and papering over it would hide the breakage.
    if (turnId == null || turnId.isEmpty) {
      bufferedEvents.add(event);
      return;
    }
    processEvent(event);
  });

  try {
    turnId = await startTurn();
    for (final event in bufferedEvents) {
      processEvent(event);
    }
    await completion.future;
  } finally {
    unsubscribe();
  }

  return ProviderTurnResult(
    sessionId: await getSessionId(),
    finalText: finalText,
    usage: usage,
    timeline: List.unmodifiable(timeline),
  );
}

/// Default reducer: the last assistant message *is* the final text.
///
/// Suits providers that re-send a complete message each time it changes.
String replaceFinalTextWithAssistantMessage({
  required String current,
  required TimelineItem item,
}) => item is AssistantMessageItem ? item.text : current;

/// Reducer for providers that stream assistant text as a growing snapshot but
/// occasionally restart the snapshot mid-turn.
///
/// If the new text extends what we have, it replaces it; otherwise it is
/// appended, because the provider has started a fresh block rather than grown
/// the old one. The empty-`current` case short-circuits so a first item that
/// happens not to start with `""`... always does, but upstream's `!current`
/// guard is preserved because it also skips the `startsWith` on the hot path.
String appendOrReplaceGrowingAssistantMessage({
  required String current,
  required TimelineItem item,
}) {
  if (item is! AssistantMessageItem) return current;
  if (current.isEmpty) return item.text;
  return item.text.startsWith(current) ? item.text : '$current${item.text}';
}
