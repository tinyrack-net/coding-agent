/// Payload mappers for the OMP and OpenCode providers, ported from Paseo
/// 0.2.0.
///
/// Upstream keeps these as six sibling modules under
/// `packages/server/src/server/agent/providers/`:
///
/// * `omp/usage-mapper.ts`     — folds OMP context-window usage into `AgentUsage`
/// * `omp/tool-call-id.ts`     — stable synthetic ids for subagent poll calls
/// * `omp/todo-mapper.ts`      — OMP todo payloads to `todo` timeline items
/// * `omp/commands.ts`         — OMP slash-command catalogue merging
/// * `opencode/rewind.ts`      — OpenCode conversation + file revert
/// * `opencode/tool-call-mapper.ts` — OpenCode tool calls to timeline items
///
/// They are grouped into one Dart library because each is a handful of pure
/// functions with no state of its own, and because Dart has no equivalent of
/// the TypeScript barrel re-exports that let upstream keep them as separate
/// files without multiplying import lines at the call sites.
///
/// ## Scope: what is deliberately *not* ported here
///
/// Upstream these six modules lean on four larger sibling modules that are
/// separate parity units and are not ported yet. Rather than duplicate them,
/// this library:
///
/// * takes narrow value types instead of porting `omp/rpc-types.ts`. Upstream's
///   `OmpSessionStateSchema` / `OmpSessionStatsSchema` are wide `.passthrough()`
///   envelopes; only `contextUsage` and `todoPhases` are observable to this
///   cluster, so [OmpSessionState] models just those.
/// * takes an [OmpToolCallRef] instead of porting `omp/tool-call-detail.ts`'s
///   `OmpTrackedToolCall` discriminated union. Only `toolName` and `args` are
///   observable to [resolveOmpEmittedToolCallId]. The one exception is
///   [parseOmpToolResult], a narrow port of that module's `parseToolResult`,
///   which is included because rejecting a malformed tool result is observable
///   to [mapOmpTodoToolResult].
/// * ports exactly one function, [normalizeProviderToolCallStatus], out of
///   `providers/tool-call-mapper-utils.ts`; the rest of that module (Codex shell
///   envelope stripping, read-gutter stripping, diff truncation, id coercion)
///   belongs to other units.
/// * injects the OpenCode tool *detail* derivation as
///   [OpencodeToolDetailDeriver] instead of porting
///   `opencode/tool-call-detail-parser.ts` and the 1000-line
///   `providers/tool-call-detail-primitives.ts` it builds on. The default
///   deriver, [deriveOpencodeUnknownToolDetail], reproduces upstream's terminal
///   fallback branch (`{type: "unknown", input, output}`) exactly; richer
///   per-tool details arrive when those units are ported and wired in.
/// * ports only the non-`Error` branches of `providers/diagnostic-utils.ts`'s
///   `toDiagnosticErrorMessage` (see [toProviderDiagnosticErrorMessage]); the
///   rest of that module formats Node `child_process` failures and probes
///   provider binaries, neither of which applies to this daemon's native LLM
///   harness.
///
/// ## Architecture note
///
/// [revertOpenCodeConversationAndFiles] talks to an OpenCode *server* over its
/// RPC client, not to a provider CLI, so it ports cleanly: the transport is
/// abstracted behind [OpenCodeRewindClient]. Upstream's sibling assertion that
/// `OpenCodeAgentClient` advertises only the combined rewind capability lives on
/// `opencode-agent.ts` and is not part of this unit.
library;

import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

// ---------------------------------------------------------------------------
// Shared JS-semantics helpers
// ---------------------------------------------------------------------------

/// Mirrors JavaScript truthiness for the handful of upstream `if (value)`
/// guards this library reproduces.
///
/// Dart has no truthiness, so an upstream `if (response.error)` would otherwise
/// silently become `!= null` and start throwing on `error: ""`, `error: 0` or
/// `error: false` — payload shapes upstream deliberately treats as "no error".
bool _isJsTruthy(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

/// Upstream's `isRecord`: a plain object, excluding arrays and `null`.
///
/// Dart's `Map` is never a `List`, so the array exclusion is implicit.
Map<String, Object?>? _record(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// Upstream's `readNonEmptyString`: trims, then rejects the empty result.
String? _trimmedNonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Zod's `z.string().optional()`: an absent key is accepted, an explicit `null`
/// is rejected, and any non-string is rejected.
///
/// Returns `true` when the field is acceptable. Unlike upstream's JSON-to-JS
/// decoding, Dart maps preserve the absent/explicit-null distinction through
/// `containsKey`, so this reproduces Zod exactly rather than approximating.
bool _optionalStringOk(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is String;

/// Zod's `z.number().optional()`, with the same absent/null rules as
/// [_optionalStringOk].
bool _optionalNumberOk(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is num;

// ---------------------------------------------------------------------------
// omp/rpc-types.ts — narrow projections (see library doc for scope)
// ---------------------------------------------------------------------------

/// OMP's live context-window accounting, as reported on session state and
/// session stats.
///
/// Every field is nullable upstream (`z.number().nullable().optional()`), so a
/// session that has not yet been measured reports `null` rather than omitting
/// the object.
final class OmpContextUsage {
  const OmpContextUsage({this.tokens, this.contextWindow, this.percent});

  /// Tokens currently occupying the context window.
  final num? tokens;

  /// Total size of the model's context window.
  final num? contextWindow;

  /// Convenience percentage OMP computes from the two above. Never read by
  /// this cluster; modelled so callers can pass a faithful payload through.
  final num? percent;
}

/// The slice of upstream's `OmpSessionStateSchema` that this cluster observes.
///
/// Upstream's schema is a wide `.passthrough()` envelope (model, thinking
/// level, streaming flags, session id, message counts, …). Porting it belongs
/// to the `omp/rpc-types.ts` unit; only these two fields change what the
/// mappers here emit.
final class OmpSessionState {
  const OmpSessionState({this.contextUsage, this.todoPhases});

  /// Context-window accounting consumed by [mapOmpUsage].
  final OmpContextUsage? contextUsage;

  /// Raw `todoPhases` payload consumed by [mapOmpTodoState].
  ///
  /// Deliberately `Object?`: upstream types it `z.unknown().optional()` and
  /// validates it lazily with `OmpTodoPhaseSchema.array().safeParse`, so an
  /// ill-formed value must reach the mapper and be dropped there rather than
  /// failing session-state parsing.
  final Object? todoPhases;
}

// ---------------------------------------------------------------------------
// omp/usage-mapper.ts
// ---------------------------------------------------------------------------

/// Folds OMP's live context-window numbers into the usage totals the daemon
/// already accumulated for the turn.
///
/// OMP reports cumulative token/cost totals and *current* context occupancy
/// through two different channels; only the latter can shrink (compaction), so
/// it overrides rather than accumulates.
///
/// Returns [baseUsage] untouched when OMP has reported neither number, so a
/// provider that never emits `contextUsage` cannot blank out totals that were
/// derived elsewhere.
///
/// [stats] is accepted for call-site parity with upstream, which threads
/// `OmpSessionStats` through this function without reading it. It is
/// deliberately unused; token and cost totals reach here already folded into
/// [baseUsage].
///
/// Deviation: upstream carries JS numbers, so a fractional `tokens` would round
/// -trip unchanged. [AgentUsage] stores token counts as `int`, so fractional
/// values are truncated toward zero. OMP only ever reports whole tokens.
AgentUsage? mapOmpUsage({
  required OmpSessionState state,
  AgentUsage? baseUsage,
  Map<String, Object?>? stats,
}) {
  final contextWindowUsedTokens = _finiteNumber(state.contextUsage?.tokens);
  final contextWindowMaxTokens = _finiteNumber(
    state.contextUsage?.contextWindow,
  );
  if (contextWindowUsedTokens == null && contextWindowMaxTokens == null) {
    return baseUsage;
  }

  // Reproduces upstream's `{...base, ...(max !== undefined ? {max} : {})}`
  // spread: an absent OMP number leaves whatever the base usage already had.
  return AgentUsage(
    inputTokens: baseUsage?.inputTokens,
    cachedInputTokens: baseUsage?.cachedInputTokens,
    outputTokens: baseUsage?.outputTokens,
    totalCostUsd: baseUsage?.totalCostUsd,
    contextWindowMaxTokens:
        contextWindowMaxTokens?.toInt() ?? baseUsage?.contextWindowMaxTokens,
    contextWindowUsedTokens:
        contextWindowUsedTokens?.toInt() ?? baseUsage?.contextWindowUsedTokens,
  );
}

/// Upstream's `finiteNumber` guard: `NaN` and the infinities are treated as
/// "not reported" rather than propagated into the UI as token counts.
num? _finiteNumber(num? value) =>
    value != null && value.isFinite ? value : null;

// ---------------------------------------------------------------------------
// omp/tool-call-id.ts
// ---------------------------------------------------------------------------

/// The pair of fields [resolveOmpEmittedToolCallId] observes on a tracked OMP
/// tool call.
///
/// Upstream passes its full `OmpTrackedToolCall` discriminated union; the id
/// resolver only ever branches on the tool name and reads the raw args, so this
/// avoids duplicating the union ahead of the `omp/tool-call-detail.ts` port.
final class OmpToolCallRef {
  const OmpToolCallRef({required this.toolName, this.args});

  /// Name OMP invoked the tool under, e.g. `subagent` or `bash`.
  final String toolName;

  /// Raw, unvalidated argument payload as OMP sent it.
  final Object? args;
}

/// Reads the sorted set of subagent job ids a `subagent` call is polling.
///
/// Returns `null` — meaning "not a poll call" — unless *every* entry of
/// `args.poll` is a non-blank string and there is at least one. A partially
/// malformed list is rejected wholesale so a synthetic id can never be built
/// from a truncated target set, which would collide two distinct polls.
///
/// Renamed from upstream's `readPollTargets`: this library hosts six modules,
/// so OMP-specific helpers carry the `Omp` prefix to stay unambiguous.
List<String>? readOmpPollTargets(Object? args) {
  final record = _record(args);
  final poll = record?['poll'];
  if (poll is! List) return null;

  final targets = <String>[];
  for (final target in poll) {
    final value = _trimmedNonEmpty(target);
    if (value == null) return null;
    targets.add(value);
  }
  if (targets.isEmpty) return null;
  // JS `toSorted()` on strings compares UTF-16 code units, which is exactly
  // what Dart's default `String.compareTo` does.
  targets.sort();
  return List.unmodifiable(targets);
}

/// Resolves the tool-call id the daemon emits for an OMP tool call.
///
/// Subagent *poll* calls get a synthetic id derived from their sorted target
/// list. OMP issues a fresh call id every poll tick, so passing them through
/// would append a new card to the timeline on every tick; keying on the targets
/// instead makes successive polls of the same jobs upsert one card. Every other
/// call — including `subagent` spawns — keeps its provider id.
String resolveOmpEmittedToolCallId(String toolCallId, OmpToolCallRef toolCall) {
  if (toolCall.toolName != 'subagent') return toolCallId;

  final targets = readOmpPollTargets(toolCall.args);
  if (targets == null) return toolCallId;
  return 'omp-poll:${targets.join(',')}';
}

// ---------------------------------------------------------------------------
// omp/tool-call-detail.ts — narrow port of parseToolResult
// ---------------------------------------------------------------------------

/// Validates a raw OMP tool result against upstream's `OmpToolResultSchema`,
/// returning `null` when it does not conform.
///
/// A narrow port of `omp/tool-call-detail.ts`'s `parseToolResult`, included
/// because rejection is observable to [mapOmpTodoToolResult]: a result whose
/// unrelated `content` field is malformed is rejected wholesale upstream and so
/// yields no todo item even when `details.phases` is perfectly well formed.
///
/// Returns the original `String` for text results, the same map (unmodified,
/// unknown keys intact — upstream's schema is `.passthrough()`) for object
/// results, and `null` for `null` and for anything that fails validation.
Object? parseOmpToolResult(Object? rawResult) {
  if (rawResult is String) return rawResult;
  if (rawResult == null) return null;

  final record = _record(rawResult);
  if (record == null) return null;

  for (final key in const ['output', 'stdout', 'text']) {
    if (!_optionalStringOk(record, key)) return null;
  }
  for (final key in const ['exitCode', 'code']) {
    if (!_optionalNumberOk(record, key)) return null;
  }
  if (record.containsKey('details')) {
    final details = _record(record['details']);
    // `OmpToolResultDetailsSchema` is `{diff: z.string().optional()}` with
    // passthrough, so a non-string `diff` rejects the whole result — every
    // other key rides through untouched.
    if (details == null || !_optionalStringOk(details, 'diff')) return null;
  }
  if (record.containsKey('content')) {
    final content = record['content'];
    if (content is! List) return null;
    for (final entry in content) {
      final chunk = _record(entry);
      // Upstream's content union accepts `{type: "text", text: string}` or any
      // other object carrying a string `type`; both branches require `type`.
      if (chunk == null || chunk['type'] is! String) return null;
      if (chunk['type'] == 'text' && chunk['text'] is! String) return null;
    }
  }
  return record;
}

// ---------------------------------------------------------------------------
// omp/todo-mapper.ts
// ---------------------------------------------------------------------------

/// Lifecycle state of an OMP todo entry.
///
/// Not `PaseoTodoStatus` from `utils/paseo_process_utils.dart`: that enum
/// models the Claude-shaped `TodosSchema`, whose union is
/// `pending | in_progress | completed`. OMP's union additionally admits
/// [abandoned], and reusing the narrower enum would make OMP reject — rather
/// than render — an abandoned task.
enum OmpTodoStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed'),
  abandoned('abandoned');

  const OmpTodoStatus(this.wireName);

  /// The literal OMP puts on the wire, which differs from the Dart enum name
  /// for [OmpTodoStatus.inProgress].
  final String wireName;

  /// Parses [value], returning `null` for anything outside the union — the
  /// equivalent of a failed `z.enum` check.
  static OmpTodoStatus? fromWire(Object? value) {
    for (final status in OmpTodoStatus.values) {
      if (status.wireName == value) return status;
    }
    return null;
  }
}

/// A single OMP todo task.
final class OmpTodoItem {
  const OmpTodoItem({required this.content, required this.status});

  /// Human-readable description of the task.
  final String content;

  /// Current lifecycle state.
  final OmpTodoStatus status;
}

/// A named group of OMP todo tasks.
///
/// OMP plans in phases; the timeline has no phase concept, so [mapOmpTodoPhases]
/// flattens them and drops [name].
final class OmpTodoPhase {
  const OmpTodoPhase({required this.name, required this.tasks});

  /// Phase label, e.g. `Tasks`. Retained for parity; not projected.
  final String name;

  /// Tasks belonging to this phase, in OMP's order.
  final List<OmpTodoItem> tasks;
}

/// Parses one `OmpTodoItemSchema` object, or `null` when it does not conform.
OmpTodoItem? _parseOmpTodoItem(Object? value) {
  final record = _record(value);
  if (record == null) return null;
  final content = record['content'];
  if (content is! String) return null;
  final status = OmpTodoStatus.fromWire(record['status']);
  if (status == null) return null;
  return OmpTodoItem(content: content, status: status);
}

/// Parses a `z.array(OmpTodoItemSchema)`: one bad entry rejects the whole list.
List<OmpTodoItem>? _parseOmpTodoItems(Object? value) {
  if (value is! List) return null;
  final items = <OmpTodoItem>[];
  for (final entry in value) {
    final item = _parseOmpTodoItem(entry);
    if (item == null) return null;
    items.add(item);
  }
  return items;
}

/// Parses a `z.array(OmpTodoPhaseSchema)`, returning `null` when any phase or
/// any task inside it is malformed.
List<OmpTodoPhase>? parseOmpTodoPhases(Object? value) {
  if (value is! List) return null;
  final phases = <OmpTodoPhase>[];
  for (final entry in value) {
    final record = _record(entry);
    if (record == null) return null;
    final name = record['name'];
    if (name is! String) return null;
    final tasks = _parseOmpTodoItems(record['tasks']);
    if (tasks == null) return null;
    phases.add(OmpTodoPhase(name: name, tasks: tasks));
  }
  return phases;
}

/// Maps the result of OMP's todo tool into a `todo` timeline item.
///
/// [result] is the raw provider payload; run it through [parseOmpToolResult]
/// first to reproduce upstream's rejection of malformed results. Returns `null`
/// — meaning "emit nothing" — for text results, for results without a
/// well-formed `details.phases`, and for an empty task list.
///
/// [id] is supplied by the caller because timeline items are upserted by id and
/// the correct id depends on whether this replaces an existing todo card. It is
/// never generated here, so the mapper stays pure and clock-free.
TodoItem? mapOmpTodoToolResult(Object? result, {required String id}) {
  final details = _ompToolResultDetails(result);
  final phases = parseOmpTodoPhases(details?['phases']);
  return phases == null ? null : mapOmpTodoPhases(phases, id: id);
}

/// Maps OMP's out-of-band `todo_reminder` event into a `todo` timeline item.
///
/// OMP re-broadcasts the full todo list whenever it nudges the model about
/// outstanding work, which is the only refresh some turns get. Returns `null`
/// when [event] is not a well-formed reminder or carries no todos.
TodoItem? mapOmpTodoReminderEvent(Object? event, {required String id}) {
  final record = _record(event);
  if (record == null || record['type'] != 'todo_reminder') return null;
  final todos = _parseOmpTodoItems(record['todos']);
  return todos == null ? null : _mapOmpTodoItems(todos, id: id);
}

/// Hydrates the current todo list from an OMP session-state snapshot.
///
/// Returns a list — empty or single — because the caller splices it into a
/// rebuilt timeline; upstream returns `AgentTimelineItem[]` for the same reason.
List<TodoItem> mapOmpTodoState(OmpSessionState state, {required String id}) {
  final phases = parseOmpTodoPhases(state.todoPhases);
  if (phases == null) return const [];
  final item = mapOmpTodoPhases(phases, id: id);
  return item == null ? const [] : [item];
}

/// Flattens OMP's phased plan into a single ordered todo card.
///
/// Returns `null` when the flattened list is empty, so an empty plan renders as
/// no card rather than an empty one.
TodoItem? mapOmpTodoPhases(List<OmpTodoPhase> phases, {required String id}) =>
    _mapOmpTodoItems([for (final phase in phases) ...phase.tasks], id: id);

/// Collapses OMP's four-state status down to the timeline's completed boolean.
///
/// Only [OmpTodoStatus.completed] counts as done — in particular `abandoned`
/// renders as not-completed, matching upstream's `status === "completed"`.
TodoItem? _mapOmpTodoItems(List<OmpTodoItem> items, {required String id}) {
  if (items.isEmpty) return null;
  return TodoItem(
    id: id,
    items: [
      for (final item in items)
        TodoEntry(
          text: item.content,
          completed: item.status == OmpTodoStatus.completed,
        ),
    ],
  );
}

/// Upstream's `resultDetails`: text and absent results carry no details.
Map<String, Object?>? _ompToolResultDetails(Object? result) {
  if (result is String || result == null) return null;
  final record = _record(result);
  if (record == null) return null;
  return _record(record['details']);
}

// ---------------------------------------------------------------------------
// omp/commands.ts
// ---------------------------------------------------------------------------

/// Argument-hint envelope OMP attaches to a command.
final class OmpCommandInput {
  const OmpCommandInput({this.hint});

  /// Placeholder shown after the command name, e.g. `[on|off|toggle]`.
  final String? hint;
}

/// A command as advertised by OMP's `available_commands_update` event.
final class OmpAvailableCommand {
  const OmpAvailableCommand({
    required this.name,
    this.description,
    this.source,
    this.input,
  });

  /// Command name without the leading slash.
  final String name;

  /// Human-readable description; falls back to [source] then `"command"`.
  final String? description;

  /// Where OMP loaded the command from, e.g. `builtin` or `skill`. Drives
  /// [AgentSlashCommandKind].
  final String? source;

  /// Argument hint, when OMP declares one.
  final OmpCommandInput? input;
}

/// A command as returned by OMP's synchronous slash-command RPC.
///
/// Structurally identical to [OmpAvailableCommand] upstream but reached through
/// a different schema, and — importantly — mapped with different empty-string
/// handling; see [mapOmpRuntimeSlashCommands].
final class OmpRpcSlashCommand {
  const OmpRpcSlashCommand({
    required this.name,
    this.description,
    this.source,
    this.input,
  });

  /// Command name without the leading slash.
  final String name;

  /// Human-readable description.
  final String? description;

  /// Where OMP loaded the command from.
  final String? source;

  /// Argument hint, when OMP declares one.
  final OmpCommandInput? input;
}

/// Slash commands the daemon handles itself for OMP, in menu order.
///
/// These never appear in OMP's advertised catalogue because the daemon
/// intercepts them out-of-band (compaction control, plan handoff, mid-turn
/// steering, follow-up queueing), so they have to be seeded rather than
/// discovered. OMP may still *override* any of them by advertising the same
/// name.
const List<AgentSlashCommand> ompHandledBuiltinSlashCommands = [
  AgentSlashCommand(
    name: 'compact',
    description: 'Manually compact the session context',
    argumentHint: '[instructions]',
  ),
  AgentSlashCommand(
    name: 'autocompact',
    description: 'Toggle automatic context compaction',
    argumentHint: '[on|off|toggle]',
  ),
  AgentSlashCommand(
    name: 'handoff',
    description: 'Hand off from planning to implementation',
    argumentHint: '[instructions]',
  ),
  AgentSlashCommand(
    name: 'steer',
    description: 'Steer the active OMP turn',
    argumentHint: '<message>',
  ),
  AgentSlashCommand(
    name: 'follow-up',
    description: 'Queue a follow-up message for OMP',
    argumentHint: '<message>',
  ),
];

/// Merges OMP's advertised commands over the daemon-handled built-ins.
///
/// Built-ins are seeded first and keep their menu position even when OMP
/// re-advertises them, so `/handoff` never jumps around as the catalogue
/// refreshes; commands OMP adds are appended in advertisement order. Dart's
/// insertion-ordered maps reproduce this the same way upstream's `Map` does.
///
/// An overriding command inherits the built-in's argument hint when it declares
/// none, which is why re-advertised `/handoff` keeps `[instructions]`.
List<AgentSlashCommand> mapOmpSlashCommands(
  List<OmpAvailableCommand> commands,
) {
  final mapped = <String, AgentSlashCommand>{
    for (final command in ompHandledBuiltinSlashCommands) command.name: command,
  };
  for (final command in commands) {
    final knownCommand = mapped[command.name];
    mapped[command.name] = AgentSlashCommand(
      name: command.name,
      description: command.description ?? command.source ?? 'command',
      argumentHint: command.input?.hint ?? knownCommand?.argumentHint ?? '',
      kind: _mapOmpCommandKind(command.source),
    );
  }
  return mapped.values.toList(growable: false);
}

/// Merges commands from OMP's synchronous RPC over the built-ins.
///
/// Deviation from [mapOmpSlashCommands], faithfully reproduced from upstream:
/// this path drops an *empty-string* description (`command.description ? … : …`
/// is a JS truthiness test, not a null check) so it falls through to the
/// `source` / `"command"` fallback, whereas the event path preserves `""`.
List<AgentSlashCommand> mapOmpRuntimeSlashCommands(
  List<OmpRpcSlashCommand> commands,
) => mapOmpSlashCommands([
  for (final command in commands)
    OmpAvailableCommand(
      name: command.name,
      description: _isJsTruthy(command.description)
          ? command.description
          : null,
      source: command.source,
      input: command.input,
    ),
]);

/// Maps a raw `available_commands_update` event, or `null` when it is
/// malformed.
///
/// Returning `null` rather than an empty list matters: the caller must leave the
/// existing catalogue in place on a bad event instead of clearing the menu.
List<AgentSlashCommand>? mapOmpAvailableCommandsUpdate(Object? event) {
  final commands = parseOmpAvailableCommandsUpdate(event);
  return commands == null ? null : mapOmpSlashCommands(commands);
}

/// Validates a raw `available_commands_update` payload.
///
/// Mirrors `OmpAvailableCommandsUpdateEventSchema`: `type` must be the literal,
/// `commands` must be an array, and every entry must carry a string `name`. One
/// malformed entry rejects the whole event.
List<OmpAvailableCommand>? parseOmpAvailableCommandsUpdate(Object? event) {
  final record = _record(event);
  if (record == null || record['type'] != 'available_commands_update') {
    return null;
  }
  final rawCommands = record['commands'];
  if (rawCommands is! List) return null;

  final commands = <OmpAvailableCommand>[];
  for (final entry in rawCommands) {
    final command = _parseOmpAvailableCommand(entry);
    if (command == null) return null;
    commands.add(command);
  }
  return commands;
}

OmpAvailableCommand? _parseOmpAvailableCommand(Object? value) {
  final record = _record(value);
  if (record == null) return null;
  final name = record['name'];
  if (name is! String) return null;
  if (!_optionalStringOk(record, 'description')) return null;
  if (!_optionalStringOk(record, 'source')) return null;

  // `input` is `.nullable().optional()` upstream, so an explicit null is legal
  // here even though it is not for `description` / `source`.
  OmpCommandInput? input;
  if (record.containsKey('input') && record['input'] != null) {
    final rawInput = _record(record['input']);
    if (rawInput == null) return null;
    if (!_optionalStringOk(rawInput, 'hint')) return null;
    input = OmpCommandInput(hint: rawInput['hint'] as String?);
  }

  return OmpAvailableCommand(
    name: name,
    description: record['description'] as String?,
    source: record['source'] as String?,
    input: input,
  );
}

/// OMP tags skill-backed commands via `source`; everything else is a plain
/// command.
AgentSlashCommandKind _mapOmpCommandKind(String? source) => source == 'skill'
    ? AgentSlashCommandKind.skill
    : AgentSlashCommandKind.command;

// ---------------------------------------------------------------------------
// providers/diagnostic-utils.ts — narrow port (see library doc for scope)
// ---------------------------------------------------------------------------

/// Renders an arbitrary provider error payload as a diagnostic string.
///
/// Ports the non-`Error` branches of upstream's `toDiagnosticErrorMessage`:
/// strings are trimmed, absent values become `"Unknown error"`, and structured
/// payloads are JSON-encoded so a `{name, message}` error object stays legible.
///
/// Deviation: upstream's `error instanceof Error` branch reassembles a Node
/// error from `message`/`code`/`signal`/`stderr`/`stdout`/`cause`. Dart's
/// [Error] and [Exception] carry none of those, so they simply stringify. The
/// Node-shaped branch belongs to the un-ported `diagnostic-utils.ts` unit,
/// which formats `child_process` failures this daemon does not produce.
String toProviderDiagnosticErrorMessage(Object? error) {
  if (error == null) return 'Unknown error';
  if (error is String) {
    final trimmed = error.trim();
    return trimmed.isEmpty ? 'Unknown error' : trimmed;
  }
  if (error is Error || error is Exception) {
    final message = error.toString().trim();
    return message.isEmpty ? 'Unknown error' : message;
  }

  try {
    final serialized = jsonEncode(error);
    if (serialized != '{}' && serialized != '""') return serialized;
  } on Object {
    // Not JSON-encodable; fall through to `toString()` exactly as upstream
    // falls through from a `JSON.stringify` throw.
  }
  final stringified = error.toString();
  return stringified.isEmpty ? 'Unknown error' : stringified;
}

// ---------------------------------------------------------------------------
// opencode/rewind.ts
// ---------------------------------------------------------------------------

/// Arguments for OpenCode's `session.revert` call.
///
/// Field names follow Dart conventions; [toJson] emits OpenCode's wire spelling
/// (`sessionID` / `messageID`), which is the part that must match exactly.
final class OpenCodeRevertRequest {
  const OpenCodeRevertRequest({
    required this.sessionId,
    required this.directory,
    required this.messageId,
  });

  /// OpenCode session to rewind.
  final String sessionId;

  /// Working directory the session runs in; OpenCode scopes file reverts to it.
  final String directory;

  /// The user message to rewind back to.
  final String messageId;

  /// Encodes the request in OpenCode's wire casing.
  Map<String, Object?> toJson() => {
    'sessionID': sessionId,
    'directory': directory,
    'messageID': messageId,
  };
}

/// OpenCode's `session.revert` response.
///
/// OpenCode reports failures in-band rather than by rejecting, so [error] is
/// the only signal that the revert did not happen.
final class OpenCodeRevertResponse {
  const OpenCodeRevertResponse({this.error});

  /// Provider-shaped error payload, or `null`/absent on success.
  final Object? error;
}

/// Transport seam for [revertOpenCodeConversationAndFiles].
///
/// Narrowed to the single method the rewind path uses so tests — and any future
/// OpenCode client — can satisfy it without standing up a whole RPC client.
abstract interface class OpenCodeRewindClient {
  /// Issues OpenCode's `session.revert`.
  Future<OpenCodeRevertResponse> revert(OpenCodeRevertRequest request);
}

/// Rewinds an OpenCode session's conversation *and* working-tree files back to
/// [messageId].
///
/// OpenCode exposes revert and unrevert, but keeps unrevert available only until
/// a later prompt triggers its cleanup, which permanently drops the reverted
/// messages. Paseo therefore only ever exposes the one-way revert, and the two
/// rewind flavours (conversation-only, files-only) collapse into this single
/// combined operation.
///
/// Throws [StateError] carrying [toProviderDiagnosticErrorMessage] of the
/// provider payload when OpenCode reports an error. The check is a JS-truthiness
/// check upstream, so an `error` of `""`, `0` or `false` is treated as success.
Future<void> revertOpenCodeConversationAndFiles({
  required OpenCodeRewindClient client,
  required String sessionId,
  required String cwd,
  required String messageId,
}) async {
  final response = await client.revert(
    OpenCodeRevertRequest(
      sessionId: sessionId,
      directory: cwd,
      messageId: messageId,
    ),
  );
  if (_isJsTruthy(response.error)) {
    throw StateError(toProviderDiagnosticErrorMessage(response.error));
  }
}

// ---------------------------------------------------------------------------
// providers/tool-call-mapper-utils.ts — normalizeToolCallStatus only
// ---------------------------------------------------------------------------

/// Provider-agnostic tool-call lifecycle, before projection onto the protocol's
/// [ToolCallStatus].
///
/// Kept as its own enum rather than reusing [ToolCallStatus] because upstream's
/// vocabulary has no `pending`: an unrecognised status word means "the provider
/// told us something we do not model, and the call is still in flight".
enum NormalizedToolCallStatus {
  running,
  completed,
  failed,
  canceled;

  /// Projection onto the protocol's timeline status.
  ///
  /// `completed` becomes [ToolCallStatus.success] and `failed` becomes
  /// [ToolCallStatus.error]; the daemon's timeline never emits
  /// [ToolCallStatus.pending] for these providers.
  ToolCallStatus get toolCallStatus => switch (this) {
    NormalizedToolCallStatus.running => ToolCallStatus.running,
    NormalizedToolCallStatus.completed => ToolCallStatus.success,
    NormalizedToolCallStatus.failed => ToolCallStatus.error,
    NormalizedToolCallStatus.canceled => ToolCallStatus.canceled,
  };
}

const Set<String> _failedStatusVocabulary = {
  'failed',
  'failure',
  'error',
  'errored',
  'rejected',
  'denied',
};
const Set<String> _canceledStatusVocabulary = {
  'canceled',
  'cancelled',
  'interrupted',
  'aborted',
};
const Set<String> _completedStatusVocabulary = {
  'completed',
  'complete',
  'done',
  'success',
  'succeeded',
};

/// Normalises the many status words providers use into four states.
///
/// Precedence matters: a present [error] wins over any status word, because
/// providers routinely report `status: "completed"` alongside a tool error. When
/// no usable status word is present the call is judged by whether [output] has
/// arrived. An unrecognised word means "still running", never "done", so a card
/// is never prematurely frozen.
NormalizedToolCallStatus normalizeProviderToolCallStatus(
  String? rawStatus,
  Object? error,
  Object? output,
) {
  if (error != null) return NormalizedToolCallStatus.failed;

  if (rawStatus != null) {
    final normalized = rawStatus.trim().toLowerCase();
    if (normalized.isNotEmpty) {
      if (_failedStatusVocabulary.contains(normalized)) {
        return NormalizedToolCallStatus.failed;
      }
      if (_canceledStatusVocabulary.contains(normalized)) {
        return NormalizedToolCallStatus.canceled;
      }
      if (_completedStatusVocabulary.contains(normalized)) {
        return NormalizedToolCallStatus.completed;
      }
      return NormalizedToolCallStatus.running;
    }
  }

  return output != null
      ? NormalizedToolCallStatus.completed
      : NormalizedToolCallStatus.running;
}

// ---------------------------------------------------------------------------
// opencode/tool-call-mapper.ts
// ---------------------------------------------------------------------------

/// Derives the rich detail card for an OpenCode tool call.
///
/// Injected so this module can be ported ahead of
/// `opencode/tool-call-detail-parser.ts` and the
/// `providers/tool-call-detail-primitives.ts` schema library it builds on.
typedef OpencodeToolDetailDeriver =
    ToolCallDetail Function(
      String toolName,
      Object? input,
      Object? output,
      Object? error,
    );

/// Upstream's terminal fallback: an unrecognised tool renders as its raw
/// payloads.
///
/// This is the default [OpencodeToolDetailDeriver] and is byte-for-byte the
/// branch upstream reaches when no known-tool schema matches, so OpenCode calls
/// map correctly today and gain richer cards once the detail-parser unit lands.
///
/// Deviation: [GenericDetail] types `input` as a map, matching the rest of the
/// protocol, so a non-map input is wrapped as `{'value': input}` — the same
/// wrapping `ToolCallDetail.fromPaseoJson` already applies on the decode side.
ToolCallDetail deriveOpencodeUnknownToolDetail(
  String toolName,
  Object? input,
  Object? output,
  Object? error,
) => GenericDetail(
  input: input is Map ? input.cast<String, Object?>() : {'value': input},
  output: output,
);

/// Maps a raw OpenCode tool call onto a `tool_call` timeline item.
///
/// Returns `null` when the call cannot be addressed — a blank [toolName] or a
/// missing/blank [callId] — because timeline items are upserted by id and an
/// unidentifiable call would append a duplicate card on every update.
///
/// [metadata] is passed through untouched when present and omitted otherwise, so
/// late-arriving provider metadata can be merged by the caller without this
/// mapper stamping an empty map over it.
///
/// Deviations from upstream, both forced by the protocol's shape:
/// * upstream carries `error` as an arbitrary structured value and defaults it
///   to `{message: "Tool call failed"}`; [ToolCallItem.errorMessage] is a
///   string, so the payload is flattened via [toProviderDiagnosticErrorMessage]
///   and the default becomes the bare string `Tool call failed`.
/// * upstream's four-state status is projected onto [ToolCallStatus] by
///   [NormalizedToolCallStatus.toolCallStatus].
ToolCallItem? mapOpencodeToolCall({
  required String toolName,
  String? callId,
  Object? status,
  Object? input,
  Object? output,
  Object? error,
  Map<String, Object?>? metadata,
  OpencodeToolDetailDeriver deriveDetail = deriveOpencodeUnknownToolDetail,
}) {
  // `z.string().min(1)` runs before the trim, so a whitespace-only tool name
  // passes validation and then collapses to an empty display name upstream.
  if (toolName.isEmpty) return null;

  final resolvedCallId = _trimmedNonEmpty(callId);
  if (resolvedCallId == null) return null;

  final name = toolName.trim();
  final rawStatus = status is String ? status : null;
  final normalized = normalizeProviderToolCallStatus(rawStatus, error, output);
  final detail = deriveDetail(name, input, output, error);

  return ToolCallItem(
    id: resolvedCallId,
    toolName: name,
    status: normalized.toolCallStatus,
    detail: detail,
    errorMessage: normalized == NormalizedToolCallStatus.failed
        ? (error == null
              ? 'Tool call failed'
              : toProviderDiagnosticErrorMessage(error))
        : null,
    metadata: metadata ?? const {},
  );
}
