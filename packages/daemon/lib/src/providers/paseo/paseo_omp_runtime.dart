/// OMP provider runtime rules, ported from Paseo 0.2.0.
///
/// Upstream keeps these as four sibling modules under
/// `packages/server/src/server/agent/providers/omp/`:
///
/// * `tool-call-mapper.ts` — OMP-specific overrides on top of the shared tool
///   detail mapping (`task`, `edit`, `read`, and the suppressed `todo` card)
/// * `system-notice.ts`    — `<system-notice>` prompts rendered as synthetic
///   `task_notification` tool cards
/// * `runtime.ts`          — the launch descriptor assembled for an OMP session
/// * `subagent-index.ts`   — per-parent subagent descriptors and their child
///   timelines
///
/// They are grouped into one Dart library for the same reason
/// `paseo_provider_mappers.dart` groups its six: each is a handful of pure
/// functions (plus one small stateful index) with no independent lifecycle, and
/// Dart has no barrel re-export that would let them stay separate without
/// multiplying import lines at every call site.
///
/// ## What this library reuses rather than re-declaring
///
/// * [parseOmpSystemNotice] from `omp_system_notice.dart` already ports every
///   parsing rule of upstream's `system-notice.ts` (tag detection, typographic
///   quote attributes, label/lifecycle/callId derivation). This library only
///   adds the projection onto a timeline item, which upstream folds into the
///   same function.
/// * [ProviderRuntimeSettings] / [ProviderCommand] from
///   `provider_launch_config.dart` stand in for upstream's
///   `ProviderRuntimeSettings`.
/// * [ProviderSubagentUpserted] / [ProviderSubagentTimelineChanged] from
///   `../provider_event.dart` stand in for upstream's `provider_subagent`
///   `AgentStreamEvent` variants, and [ProviderSubagentStatus] from the protocol
///   package stands in for its inline status union.
/// * `paseo_provider_mappers.dart` owns `parseOmpToolResult`
///   (upstream's `parseToolResult`) and [resolveOmpEmittedToolCallId]; callers
///   run raw provider payloads through the former before handing them to
///   [mapOmpToolDetail], exactly as upstream's history mapper does.
///
/// ## Scope: supporting port of `omp/tool-call-detail.ts`
///
/// `tool-call-mapper.ts` is unusable — and untestable — without its sibling
/// `tool-call-detail.ts`, whose `parseToolArgs` / `mapToolDetail` /
/// `extractTextFromToolResult` the upstream suite calls directly. Those three
/// (plus `resolveToolCallName`, which pairs with the xdev branch of
/// `mapToolDetail`) are therefore ported here. `parseToolResult` is *not*
/// re-ported: `paseo_provider_mappers.dart` already owns it as
/// `parseOmpToolResult`.
///
/// ## Architecture note: what has no live counterpart
///
/// This daemon runs a native LLM harness rather than driving a provider binary,
/// so upstream's `OmpRuntime` / `OmpRuntimeSession` interfaces — a 25-method
/// facade over a spawned `omp --mode rpc` process — have nothing to bind to and
/// are deliberately not ported. Their two *observable* rules are:
///
/// * how the process argv is assembled, ported as [buildOmpLaunch]; and
/// * the subagent subscription downgrade the session performs at construction,
///   ported as [subscribeOmpSubagentEvents] — the only behaviour upstream's
///   `runtime.test.ts` actually pins.
///
/// Likewise `subagent-index.ts` delegates child-message mapping to
/// `message-history.ts`'s `OmpHistoryMapper`, a separate parity unit. Rather
/// than duplicate it, [OmpSubagentIndex] takes an
/// [OmpSubagentTimelineMapperFactory]; the default,
/// [OmpSubagentAssistantTimelineMapper], reproduces the assistant branch that
/// upstream's suite pins and nothing else.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../provider_event.dart';
import 'omp_system_notice.dart';
import 'provider_launch_config.dart';

// ---------------------------------------------------------------------------
// Shared JS-semantics helpers
// ---------------------------------------------------------------------------

/// Upstream's `isRecord`: a plain object, excluding arrays and `null`.
///
/// Dart's [Map] is never a [List], so the array exclusion is implicit.
Map<String, Object?>? _record(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// Upstream's `firstString`: the first argument that is a string with a
/// non-blank trim, returned *untrimmed*.
///
/// Takes a list because Dart has no rest parameters; the argument order is the
/// upstream precedence order and is load-bearing.
String? _firstString(List<Object?> values) {
  for (final value in values) {
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

/// Zod's `z.string().optional()`: an absent key is accepted, an explicit `null`
/// is rejected, and any non-string is rejected.
///
/// Dart maps preserve the absent/explicit-null distinction through
/// [Map.containsKey], so this reproduces Zod exactly rather than approximating.
bool _optionalStringOk(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is String;

/// Zod's `z.number().optional()`, with the same absent/null rules as
/// [_optionalStringOk].
bool _optionalNumberOk(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is num;

/// Zod's `z.boolean().optional()`, with the same absent/null rules as
/// [_optionalStringOk].
bool _optionalBoolOk(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is bool;

/// Coerces an arbitrary payload into [GenericDetail]'s map-shaped `input`.
///
/// Deviation: upstream's `unknown` detail carries `input: unknown`, so a raw
/// string or list survives verbatim. [GenericDetail.input] is a map, matching
/// the rest of the protocol, so non-map payloads are wrapped as
/// `{'value': input}` — the same wrapping [ToolCallDetail.fromPaseoJson]
/// already applies on the decode side.
Map<String, Object?> _unknownDetailInput(Object? input) =>
    input is Map ? input.cast<String, Object?>() : {'value': input};

// ---------------------------------------------------------------------------
// omp/tool-call-detail.ts — supporting port (see library doc for scope)
// ---------------------------------------------------------------------------

/// A single hash-line edit operation inside an OMP `edit` call.
final class OmpEditOperation {
  const OmpEditOperation({required this.oldText, required this.newText});

  /// Text being replaced.
  final String oldText;

  /// Replacement text.
  final String newText;

  /// The object JavaScript sees after Zod validation, used to rebuild [args].
  Map<String, Object?> _toArgs() => {'oldText': oldText, 'newText': newText};
}

/// An OMP tool call whose arguments have been validated against the shape
/// upstream declares for that tool.
///
/// TypeScript models this as a discriminated union on `kind`; Dart uses a sealed
/// hierarchy so exhaustive `switch` replaces the `default:` fallthrough.
///
/// Every variant exposes [args], the argument object *as JavaScript sees it
/// after Zod validation*. That matters: Zod strips undeclared keys, so a
/// successfully parsed call cannot expose fields the schema did not name. Only
/// [OmpUnknownToolCall] carries the raw payload, which is why the patch-input
/// fallback in [mapOmpToolDetail] only ever fires for unparsed `edit` calls.
sealed class OmpTrackedToolCall {
  const OmpTrackedToolCall();

  /// Name OMP invoked the tool under.
  String get toolName;

  /// The post-validation argument object.
  Object? get args;
}

/// A validated `bash` call.
final class OmpBashToolCall extends OmpTrackedToolCall {
  const OmpBashToolCall({required this.command, this.timeout});

  /// Shell command line OMP asked to run.
  final String command;

  /// Optional per-call timeout, in whatever unit OMP declares. Never read by
  /// this cluster; modelled so [args] round-trips faithfully.
  final num? timeout;

  @override
  String get toolName => 'bash';

  @override
  Map<String, Object?> get args => {
    'command': command,
    if (timeout != null) 'timeout': timeout,
  };
}

/// A validated `read` call.
final class OmpReadToolCall extends OmpTrackedToolCall {
  const OmpReadToolCall({required this.path, this.offset, this.limit});

  /// File OMP read.
  final String path;

  /// First line requested, when OMP windowed the read.
  final num? offset;

  /// Line budget requested, when OMP windowed the read.
  final num? limit;

  @override
  String get toolName => 'read';

  @override
  Map<String, Object?> get args => {
    'path': path,
    if (offset != null) 'offset': offset,
    if (limit != null) 'limit': limit,
  };
}

/// A validated `edit` call, in either the current or the legacy argument shape.
final class OmpEditToolCall extends OmpTrackedToolCall {
  const OmpEditToolCall({required this.path, required this.edits});

  /// File being edited.
  final String path;

  /// Ordered replacements. Only the first reaches the timeline card, matching
  /// upstream's `toolCall.args.edits[0]`.
  final List<OmpEditOperation> edits;

  @override
  String get toolName => 'edit';

  @override
  Map<String, Object?> get args => {
    'path': path,
    'edits': edits.map((edit) => edit._toArgs()).toList(growable: false),
  };
}

/// A validated `write` call.
final class OmpWriteToolCall extends OmpTrackedToolCall {
  const OmpWriteToolCall({required this.path, required this.content});

  /// File being written.
  final String path;

  /// Full contents OMP wrote.
  final String content;

  @override
  String get toolName => 'write';

  @override
  Map<String, Object?> get args => {'path': path, 'content': content};
}

/// A validated `find` call.
final class OmpFindToolCall extends OmpTrackedToolCall {
  const OmpFindToolCall({required this.pattern, this.path, this.limit});

  /// Glob or name pattern searched for.
  final String pattern;

  /// Root the search was scoped to.
  final String? path;

  /// Result budget.
  final num? limit;

  @override
  String get toolName => 'find';

  @override
  Map<String, Object?> get args => {
    'pattern': pattern,
    if (path != null) 'path': path,
    if (limit != null) 'limit': limit,
  };
}

/// A validated `grep` call.
final class OmpGrepToolCall extends OmpTrackedToolCall {
  const OmpGrepToolCall({
    required this.pattern,
    this.path,
    this.glob,
    this.ignoreCase,
    this.literal,
    this.context,
    this.limit,
  });

  /// Regex (or literal, see [literal]) searched for.
  final String pattern;

  /// Root the search was scoped to.
  final String? path;

  /// File-name filter.
  final String? glob;

  /// Case-insensitive matching.
  final bool? ignoreCase;

  /// Treat [pattern] as a literal rather than a regex.
  final bool? literal;

  /// Context lines around each hit.
  final num? context;

  /// Result budget.
  final num? limit;

  @override
  String get toolName => 'grep';

  @override
  Map<String, Object?> get args => {
    'pattern': pattern,
    if (path != null) 'path': path,
    if (glob != null) 'glob': glob,
    if (ignoreCase != null) 'ignoreCase': ignoreCase,
    if (literal != null) 'literal': literal,
    if (context != null) 'context': context,
    if (limit != null) 'limit': limit,
  };
}

/// A validated `ls` call.
final class OmpLsToolCall extends OmpTrackedToolCall {
  const OmpLsToolCall({this.path, this.limit});

  /// Directory listed; absent means the session cwd.
  final String? path;

  /// Entry budget.
  final num? limit;

  @override
  String get toolName => 'ls';

  @override
  Map<String, Object?> get args => {
    if (path != null) 'path': path,
    if (limit != null) 'limit': limit,
  };
}

/// A call whose name is not one of the seven modelled tools, or whose arguments
/// failed validation.
///
/// [args] is the raw, unvalidated payload, which is what makes the patch-input
/// path recovery in [mapOmpToolDetail] possible for hash-line `edit` calls.
final class OmpUnknownToolCall extends OmpTrackedToolCall {
  const OmpUnknownToolCall({required this.toolName, this.args});

  @override
  final String toolName;

  @override
  final Object? args;
}

/// Validates a raw OMP tool-argument payload for [toolName].
///
/// Mirrors upstream's `parseToolArgs`: `edit` gets a two-schema cascade
/// (current shape, then the legacy `old_string`/`new_string` shape), the six
/// simple tools get their own schema, and anything else — or anything that
/// fails — becomes an [OmpUnknownToolCall] carrying the payload verbatim.
///
/// Never throws: an unparseable call still has to render a card.
OmpTrackedToolCall parseOmpToolArgs(String toolName, Object? rawArgs) {
  if (toolName == 'edit') return _parseOmpEditToolArgs(rawArgs);

  final record = _record(rawArgs);
  final parsed = record == null
      ? null
      : switch (toolName) {
          'bash' => _parseOmpBashToolArgs(record),
          'read' => _parseOmpReadToolArgs(record),
          'write' => _parseOmpWriteToolArgs(record),
          'find' => _parseOmpFindToolArgs(record),
          'grep' => _parseOmpGrepToolArgs(record),
          'ls' => _parseOmpLsToolArgs(record),
          _ => null,
        };
  return parsed ?? OmpUnknownToolCall(toolName: toolName, args: rawArgs);
}

OmpBashToolCall? _parseOmpBashToolArgs(Map<String, Object?> json) {
  final command = json['command'];
  if (command is! String) return null;
  if (!_optionalNumberOk(json, 'timeout')) return null;
  return OmpBashToolCall(command: command, timeout: json['timeout'] as num?);
}

OmpReadToolCall? _parseOmpReadToolArgs(Map<String, Object?> json) {
  final path = json['path'];
  if (path is! String) return null;
  if (!_optionalNumberOk(json, 'offset')) return null;
  if (!_optionalNumberOk(json, 'limit')) return null;
  return OmpReadToolCall(
    path: path,
    offset: json['offset'] as num?,
    limit: json['limit'] as num?,
  );
}

OmpWriteToolCall? _parseOmpWriteToolArgs(Map<String, Object?> json) {
  final path = json['path'];
  final content = json['content'];
  if (path is! String || content is! String) return null;
  return OmpWriteToolCall(path: path, content: content);
}

OmpFindToolCall? _parseOmpFindToolArgs(Map<String, Object?> json) {
  final pattern = json['pattern'];
  if (pattern is! String) return null;
  if (!_optionalStringOk(json, 'path')) return null;
  if (!_optionalNumberOk(json, 'limit')) return null;
  return OmpFindToolCall(
    pattern: pattern,
    path: json['path'] as String?,
    limit: json['limit'] as num?,
  );
}

OmpGrepToolCall? _parseOmpGrepToolArgs(Map<String, Object?> json) {
  final pattern = json['pattern'];
  if (pattern is! String) return null;
  if (!_optionalStringOk(json, 'path')) return null;
  if (!_optionalStringOk(json, 'glob')) return null;
  if (!_optionalBoolOk(json, 'ignoreCase')) return null;
  if (!_optionalBoolOk(json, 'literal')) return null;
  if (!_optionalNumberOk(json, 'context')) return null;
  if (!_optionalNumberOk(json, 'limit')) return null;
  return OmpGrepToolCall(
    pattern: pattern,
    path: json['path'] as String?,
    glob: json['glob'] as String?,
    ignoreCase: json['ignoreCase'] as bool?,
    literal: json['literal'] as bool?,
    context: json['context'] as num?,
    limit: json['limit'] as num?,
  );
}

OmpLsToolCall? _parseOmpLsToolArgs(Map<String, Object?> json) {
  if (!_optionalStringOk(json, 'path')) return null;
  if (!_optionalNumberOk(json, 'limit')) return null;
  return OmpLsToolCall(
    path: json['path'] as String?,
    limit: json['limit'] as num?,
  );
}

OmpTrackedToolCall _parseOmpEditToolArgs(Object? rawArgs) {
  final record = _record(rawArgs);
  if (record != null) {
    final current = _parseOmpCurrentEditToolArgs(record);
    if (current != null) return current;
    final legacy = _parseOmpLegacyEditToolArgs(record);
    if (legacy != null) return legacy;
  }
  return OmpUnknownToolCall(toolName: 'edit', args: rawArgs);
}

OmpEditToolCall? _parseOmpCurrentEditToolArgs(Map<String, Object?> json) {
  final path = json['path'];
  final rawEdits = json['edits'];
  if (path is! String || rawEdits is! List) return null;

  final edits = <OmpEditOperation>[];
  for (final entry in rawEdits) {
    final edit = _record(entry);
    if (edit == null) return null;
    final oldText = edit['oldText'];
    final newText = edit['newText'];
    if (oldText is! String || newText is! String) return null;
    edits.add(OmpEditOperation(oldText: oldText, newText: newText));
  }
  return OmpEditToolCall(path: path, edits: edits);
}

/// Upstream's `normalizeLegacyEditArgs`.
///
/// The `!oldText` guard is a JS truthiness test, so an *empty* `old_string`
/// rejects the legacy shape while an empty `new_string` is accepted — only
/// `newText === undefined` rejects. Reproduced literally.
OmpEditToolCall? _parseOmpLegacyEditToolArgs(Map<String, Object?> json) {
  final path = json['path'];
  if (path is! String) return null;
  for (final key in const [
    'old_string',
    'oldString',
    'new_string',
    'newString',
  ]) {
    if (!_optionalStringOk(json, key)) return null;
  }

  final oldText = (json['old_string'] ?? json['oldString']) as String?;
  final newText = (json['new_string'] ?? json['newString']) as String?;
  if (oldText == null || oldText.isEmpty || newText == null) return null;
  return OmpEditToolCall(
    path: path,
    edits: [OmpEditOperation(oldText: oldText, newText: newText)],
  );
}

/// Extracts the human-readable text out of an OMP tool result.
///
/// Precedence is `output`, `stdout`, `text`, then the concatenation of the
/// `text` content blocks joined by a single newline. The direct-field check is
/// a JS truthiness test upstream, so an *empty* `output` falls through to the
/// content blocks rather than short-circuiting as an empty answer.
///
/// Returns `null` (upstream's `undefined`) when nothing textual is present.
String? extractOmpToolResultText(Object? result) {
  if (result is String) return result;
  final record = _record(result);
  if (record == null) return null;

  final direct = record['output'] ?? record['stdout'] ?? record['text'];
  if (direct is String && direct.isNotEmpty) return direct;

  final content = record['content'];
  if (content is! List) return null;

  final parts = <String>[];
  for (final block in content) {
    final chunk = _record(block);
    if (chunk == null || chunk['type'] != 'text') continue;
    final text = chunk['text'];
    if (text is String) parts.add(text);
  }
  return parts.isEmpty ? null : parts.join('\n');
}

/// Upstream's `resultDetails`: text results and absent results carry no details.
Map<String, Object?>? _ompToolResultDetails(Object? result) {
  if (result is String || result == null) return null;
  final record = _record(result);
  if (record == null) return null;
  return _record(record['details']);
}

/// The `details.xdev` envelope OMP attaches when a `write` call is really a
/// proxied execution of some other tool.
final class _OmpXdevExecuteDetails {
  const _OmpXdevExecuteDetails({
    required this.tool,
    required this.args,
    required this.inner,
  });

  final String tool;
  final Object? args;
  final Object? inner;
}

/// Mirrors upstream's `XdevExecuteDetailsSchema`.
///
/// `tool` is `z.string().trim().min(1)`, so the trim happens *before* the
/// non-empty check and the trimmed value is what the schema outputs.
_OmpXdevExecuteDetails? _parseOmpXdevExecuteDetails(Object? value) {
  final record = _record(value);
  if (record == null) return null;
  final tool = record['tool'];
  if (tool is! String) return null;
  final trimmed = tool.trim();
  if (trimmed.isEmpty) return null;
  if (record['mode'] != 'execute') return null;
  return _OmpXdevExecuteDetails(
    tool: trimmed,
    args: record['args'],
    inner: record['inner'],
  );
}

/// Resolves the display name for a tool call.
///
/// A `write` whose result carries a well-formed `details.xdev` execute envelope
/// is really a proxied invocation of `xdev.tool`, so the card is titled with the
/// proxied tool rather than with `write`.
String resolveOmpToolCallName(OmpTrackedToolCall toolCall, [Object? result]) {
  if (toolCall is OmpWriteToolCall && result != null && result is! String) {
    final details = _ompToolResultDetails(result);
    final xdev = _parseOmpXdevExecuteDetails(details?['xdev']);
    if (xdev != null) return xdev.tool;
  }
  return toolCall.toolName;
}

/// Maps a validated OMP tool call and its result onto a timeline detail card,
/// using only the tool vocabulary shared with every other provider.
///
/// This is upstream's `mapToolDetail` from `tool-call-detail.ts`;
/// [mapOmpToolDetail] layers the OMP-specific overrides on top and falls back
/// here for everything else.
///
/// Deviations, all forced by the protocol's narrower types:
/// * upstream's shell `exitCode` is `number | null | undefined`; [ShellDetail]
///   stores `int?`, so a fractional exit code is truncated toward zero and the
///   `null`/absent distinction collapses (both serialise as "no exit code").
/// * `offset` / `limit` are JS numbers upstream and `int?` on [ReadDetail], with
///   the same truncation. OMP only ever reports whole line numbers.
/// * upstream reads `details.diff` off a schema that requires it to be a string;
///   the shared `parseOmpToolResult` does not enforce that, so the type check is
///   repeated here to keep a non-string `diff` out of the card.
ToolCallDetail mapOmpCoreToolDetail(
  OmpTrackedToolCall toolCall, [
  Object? result,
]) {
  switch (toolCall) {
    case OmpBashToolCall():
      return ShellDetail(
        command: toolCall.command,
        output: _resolveOmpToolCallOutput(result),
        exitCode: _resolveOmpToolCallExitCode(result),
      );
    case OmpReadToolCall():
      return ReadDetail(
        path: toolCall.path,
        content: extractOmpToolResultText(result),
        offset: toolCall.offset?.toInt(),
        limit: toolCall.limit?.toInt(),
      );
    case OmpEditToolCall():
      final firstEdit = toolCall.edits.isEmpty ? null : toolCall.edits.first;
      final diff = _ompToolResultDetails(result)?['diff'];
      return EditDetail(
        path: toolCall.path,
        oldString: firstEdit?.oldText,
        newString: firstEdit?.newText,
        diff: diff is String ? diff : null,
      );
    case OmpWriteToolCall():
      return _mapOmpWriteToolDetail(toolCall, result);
    case OmpFindToolCall():
      return SearchDetail(
        query: toolCall.pattern,
        toolName: 'search',
        content: result is String ? result : null,
      );
    case OmpGrepToolCall():
      return SearchDetail(
        query: toolCall.pattern,
        toolName: 'grep',
        content: result is String ? result : null,
      );
    case OmpLsToolCall():
      return SearchDetail(
        query: toolCall.path ?? 'ls',
        content: result is String ? result : null,
      );
    case OmpUnknownToolCall():
      return GenericDetail(
        input: _unknownDetailInput(toolCall.args),
        output: result,
      );
  }
}

ToolCallDetail _mapOmpWriteToolDetail(OmpWriteToolCall call, Object? result) {
  final record = result is String ? null : _record(result);
  final details = record == null ? null : _record(record['details']);
  if (details != null && details.containsKey('xdev')) {
    final xdev = _parseOmpXdevExecuteDetails(details['xdev']);
    if (xdev != null) {
      return GenericDetail(
        input: _unknownDetailInput(xdev.args),
        // Upstream spreads the whole result and replaces `details` with the
        // proxied tool's own payload, so the outer envelope stays inspectable.
        output: {...record!, 'details': xdev.inner},
      );
    }
    return GenericDetail(input: _unknownDetailInput(call.args), output: result);
  }
  return WriteDetail(path: call.path, contentPreview: call.content);
}

String? _resolveOmpToolCallOutput(Object? result) =>
    result is String ? result : extractOmpToolResultText(result);

/// Upstream's `resolveToolCallOutput` exit-code half.
///
/// A string result reports no exit code at all (`undefined`), an absent result
/// reports none either, and an object result falls back to `exitCode`, then
/// `code`, then an explicit `null`. All three collapse to Dart `null`; see the
/// deviation note on [mapOmpCoreToolDetail].
int? _resolveOmpToolCallExitCode(Object? result) {
  if (result is String) return null;
  final record = _record(result);
  if (record == null) return null;
  final exitCode = record['exitCode'];
  if (exitCode is num) return exitCode.toInt();
  final code = record['code'];
  if (code is num) return code.toInt();
  return null;
}

// ---------------------------------------------------------------------------
// omp/tool-call-mapper.ts
// ---------------------------------------------------------------------------

/// Optional context threaded into [mapOmpToolDetail].
///
/// Upstream passes this as an inline object; it is a class here so the
/// subagent hook can be documented and so callers cannot accidentally supply
/// only half of it.
final class OmpToolDetailContext {
  const OmpToolDetailContext({
    required this.toolCallId,
    this.mapSubagentDetail,
  });

  /// Provider-assigned id of the call being mapped.
  ///
  /// Accepted for call-site parity with upstream's history mapper, which
  /// threads it through so subagent hooks can correlate a `task` card with the
  /// tracker entry it owns. Not read by [mapOmpToolDetail] itself.
  final String toolCallId;

  /// Enriches the base `sub_agent` card for a `task` call — upstream's
  /// subagent card tracker splices live child activity into it.
  ///
  /// Only invoked for `task` calls, and only after the base card exists, so a
  /// hook can never fabricate a card for a different tool.
  final ToolCallDetail Function(ToolCallDetail baseDetail)? mapSubagentDetail;
}

/// Matches the transcript path OMP prints when a `task` finishes.
///
/// Anchored on an absolute path so a bare word like `session: pending` cannot be
/// mistaken for a child transcript.
final _ompChildSessionPattern = RegExp(
  r'(?:session|transcript)(?: file)?:\s*(/\S+\.jsonl)',
  caseSensitive: false,
);

/// Matches the `[path#hash]` header of an OMP hash-line patch.
///
/// Multi-line because the header follows a `*** Begin Patch` line rather than
/// opening the payload.
final _ompPatchInputPathPattern = RegExp(
  r'^\[(.+?)#[^\]\n]+]',
  multiLine: true,
);

/// Maps an OMP tool call onto a timeline detail card, applying the four
/// OMP-specific overrides on top of [mapOmpCoreToolDetail].
///
/// Returns `null` for `todo` calls: OMP's todo tool result is projected into a
/// dedicated `todo` timeline item by `mapOmpTodoToolResult`, so rendering the
/// raw tool card as well would duplicate the plan on screen.
///
/// The other three overrides recover information the shared mapper cannot see:
/// * `task` becomes a `sub_agent` card, with the child transcript path dug out
///   of either the result details or the result text;
/// * `edit` prefers the *result's* reported path, because OMP's hash-line patch
///   format carries the path inside an opaque `input` string the argument
///   schema cannot parse;
/// * `read` prefers `details.displayContent.text`, which is the gutter-free
///   rendering of the file, over the line-numbered text block.
///
/// Note the branches key off [OmpTrackedToolCall.toolName], not the variant:
/// `task` and `todo` have no argument schema, so they arrive as
/// [OmpUnknownToolCall].
ToolCallDetail? mapOmpToolDetail(
  OmpTrackedToolCall toolCall,
  Object? result, {
  OmpToolDetailContext? context,
}) {
  switch (toolCall.toolName) {
    case 'todo':
      return null;
    case 'task':
      final detail = _mapOmpTaskDetail(toolCall.args, result);
      return context?.mapSubagentDetail?.call(detail) ?? detail;
    case 'edit':
      return _mapOmpEditDetail(toolCall, result);
    case 'read':
      return _mapOmpReadDetail(toolCall, result);
    default:
      return mapOmpCoreToolDetail(toolCall, result);
  }
}

/// Builds the `sub_agent` card for a `task` call.
///
/// The four-way alias lists for the agent type and the description are
/// upstream's: OMP has spelled these differently across releases and transcripts
/// from older sessions still have to render.
SubAgentDetail _mapOmpTaskDetail(Object? args, Object? result) {
  final argRecord = _record(args) ?? const <String, Object?>{};
  final resultText = extractOmpToolResultText(result);
  return SubAgentDetail(
    subAgentType: _firstString([
      argRecord['agent'],
      argRecord['subAgentType'],
      argRecord['agentType'],
      argRecord['type'],
    ]),
    description: _firstString([
      argRecord['description'],
      argRecord['task'],
      argRecord['prompt'],
      argRecord['assignment'],
    ]),
    childSessionId: _readOmpChildSessionId(result),
    log: resultText?.trim() ?? '',
  );
}

String? _readOmpChildSessionId(Object? result) {
  final details = _ompToolResultDetails(result);
  final direct = _firstString([
    details?['sessionFile'],
    details?['session_file'],
    details?['childSessionId'],
  ]);
  if (direct != null) return direct;

  final text = extractOmpToolResultText(result);
  if (text == null) return null;
  return _ompChildSessionPattern.firstMatch(text)?.group(1);
}

ToolCallDetail? _mapOmpEditDetail(OmpTrackedToolCall toolCall, Object? result) {
  final fallback = mapOmpCoreToolDetail(toolCall, result);
  final details = _ompToolResultDetails(result);
  final filePath =
      _firstString([details?['path'], details?['filePath']]) ??
      _readOmpPatchInputPath(toolCall.args);
  if (filePath == null) return fallback;

  return EditDetail(
    path: filePath,
    oldString: _firstString([details?['oldText'], details?['old_string']]),
    newString: _firstString([details?['newText'], details?['new_string']]),
    diff: _firstString([details?['diff']]),
  );
}

String? _readOmpPatchInputPath(Object? args) {
  final input = _record(args)?['input'];
  if (input is! String) return null;
  return _ompPatchInputPathPattern.firstMatch(input)?.group(1);
}

ToolCallDetail? _mapOmpReadDetail(OmpTrackedToolCall toolCall, Object? result) {
  final fallback = mapOmpCoreToolDetail(toolCall, result);
  if (fallback is! ReadDetail) return fallback;

  final details = _ompToolResultDetails(result);
  final displayContent = _record(details?['displayContent']);
  final displayText = _firstString([displayContent?['text']]);
  if (displayText == null) return fallback;

  return ReadDetail(
    path: fallback.path,
    content: displayText,
    offset: fallback.offset,
    limit: fallback.limit,
  );
}

// ---------------------------------------------------------------------------
// omp/system-notice.ts — timeline projection
// ---------------------------------------------------------------------------

/// Tool name every synthetic system-notice card is filed under.
const String ompSystemNoticeToolName = 'task_notification';

/// Whether [text] is an OMP `<system-notice>` prompt rather than a user turn.
///
/// Only a *leading* tag counts: a user asking "what does `<system-notice>` mean"
/// must stay a user message, which is why this is a `startsWith` on the
/// left-trimmed text rather than a `contains`.
bool isOmpSystemNotice(String text) =>
    text.trimLeft().startsWith(ompSystemNoticeOpenTag);

/// Renders an OMP `<system-notice>` prompt as a synthetic, already-terminal
/// tool card.
///
/// OMP injects these as ordinary prompts when a detached background task
/// finishes, so without this projection a completed background job would appear
/// in the transcript as if the *user* had typed the notice.
///
/// Returns `null` when [text] is not a notice.
///
/// Every parsing rule — tag detection, typographic-quote attributes, the
/// `Background job <id> <status>` label, the stable sha1 call id for
/// notices without a `<task-result>`, and the failed/canceled/completed
/// lifecycle — lives in [parseOmpSystemNotice] and is reused verbatim.
///
/// Deviation: upstream's timeline item carries `error: null` explicitly on the
/// non-failed branches; [ToolCallItem.errorMessage] is simply absent instead.
ToolCallItem? mapOmpSystemNoticeToToolCall(String text) {
  final notice = parseOmpSystemNotice(text);
  if (notice == null) return null;

  return ToolCallItem(
    id: notice.callId,
    toolName: ompSystemNoticeToolName,
    status: notice.status,
    detail: PlainTextDetail(
      label: notice.label,
      text: notice.text,
      icon: 'wrench',
    ),
    errorMessage: notice.errorMessage,
    metadata: notice.metadata,
  );
}

// ---------------------------------------------------------------------------
// omp/runtime.ts
// ---------------------------------------------------------------------------

/// Wire protocol an OMP session speaks.
///
/// `rpc-ui` adds the interactive permission/extension surface on top of plain
/// `rpc`; the value is passed straight through to `--mode`.
enum OmpProtocolMode {
  rpc('rpc'),
  rpcUi('rpc-ui');

  const OmpProtocolMode(this.flagValue);

  /// The literal OMP expects after `--mode`, which differs from the Dart enum
  /// name for [OmpProtocolMode.rpcUi].
  final String flagValue;
}

/// Everything the daemon knows about a session before OMP is launched.
final class OmpStartSessionInput {
  const OmpStartSessionInput({
    required this.cwd,
    this.env,
    this.protocolMode,
    this.model,
    this.thinkingOptionId,
    this.modeId,
    this.session,
    this.noSession,
    this.systemPrompt,
    this.extraArgs,
  });

  /// Working directory OMP runs in.
  final String cwd;

  /// Extra environment for the process. Deliberately nullable: "no environment
  /// supplied" and "an empty environment supplied" are distinguishable upstream
  /// and drive whether [OmpRuntimeLaunch.env] is populated at all.
  final Map<String, String>? env;

  /// Protocol to request; defaults to [OmpProtocolMode.rpc].
  final OmpProtocolMode? protocolMode;

  /// Model id to pin, when the user chose one.
  final String? model;

  /// Thinking-budget option id to pin.
  final String? thinkingOptionId;

  /// OMP mode (plan/build/…) to select.
  ///
  /// Carried on the launch descriptor but never turned into an argv flag —
  /// upstream applies it over RPC after the session starts.
  final String? modeId;

  /// Existing OMP session id to resume.
  final String? session;

  /// Suppress session persistence entirely. Wins over [session] when set.
  final bool? noSession;

  /// Extra system prompt appended to OMP's own.
  final String? systemPrompt;

  /// Raw arguments forwarded verbatim, inserted right after `--mode`.
  final List<String>? extraArgs;
}

/// The fully assembled description of an OMP process launch.
///
/// Kept as a value object rather than being handed straight to a process
/// spawner so it can be asserted on, logged, and — in this daemon — inspected
/// without any process ever being started.
final class OmpRuntimeLaunch {
  const OmpRuntimeLaunch({
    required this.cwd,
    required this.argv,
    required this.protocolMode,
    this.env,
    this.model,
    this.thinkingOptionId,
    this.modeId,
    this.session,
    this.noSession,
    this.systemPrompt,
    this.extraArgs,
  });

  /// Working directory for the process.
  final String cwd;

  /// Executable plus every argument, in order.
  final List<String> argv;

  /// Merged environment, or `null` when neither source contributed any.
  final Map<String, String>? env;

  /// Resolved protocol mode, never null once defaulting has run.
  final OmpProtocolMode protocolMode;

  /// Model id, echoed from the session input.
  final String? model;

  /// Thinking-budget option id, echoed from the session input.
  final String? thinkingOptionId;

  /// OMP mode id, echoed from the session input for the post-launch RPC.
  final String? modeId;

  /// Session id to resume, echoed from the session input.
  final String? session;

  /// Session-persistence suppression, echoed from the session input.
  final bool? noSession;

  /// Trimmed system prompt. Note this is the *trimmed* value, so a
  /// whitespace-only prompt is recorded as an empty string and no flag is
  /// emitted for it.
  final String? systemPrompt;

  /// Extra arguments, echoed from the session input.
  final List<String>? extraArgs;
}

/// Assembles the argv and environment for an OMP session launch.
///
/// [command] is the provider's default executable-and-args tuple and must not be
/// empty. A `replace`-mode runtime override wins over it, but only when the
/// override actually names an executable — an override whose first element is
/// blank is discarded rather than producing an unlaunchable argv.
///
/// Argument order is load-bearing and matches upstream exactly: `--mode` first
/// (unless the caller already pinned one), then the caller's raw `extraArgs`,
/// then model, thinking, session, and finally the appended system prompt. Each
/// optional flag is emitted only for a non-empty value, reproducing upstream's
/// JS truthiness guards.
///
/// Deviation: upstream distinguishes `env: undefined` from `env: {}` on the
/// runtime settings, and an explicit empty object there still produces a
/// (merged, possibly empty) environment. [ProviderRuntimeSettings.environment]
/// is a non-nullable map defaulting to `{}`, so that distinction is not
/// representable and an empty override environment is treated as absent. The
/// session's own [OmpStartSessionInput.env] *is* nullable and reproduces the
/// upstream behaviour exactly.
OmpRuntimeLaunch buildOmpLaunch({
  required List<String> command,
  required OmpStartSessionInput session,
  ProviderRuntimeSettings? runtimeSettings,
}) {
  final override = runtimeSettings?.command;
  final useOverride =
      override != null &&
      override.mode == ProviderCommandMode.replace &&
      override.argv.isNotEmpty &&
      override.argv.first.isNotEmpty;
  final argv = [...useOverride ? override.argv : command];

  final protocolMode = session.protocolMode ?? OmpProtocolMode.rpc;
  final systemPrompt = session.systemPrompt?.trim();
  _appendOmpLaunchArgs(argv, session, protocolMode, systemPrompt);

  final overrideEnv = runtimeSettings?.environment ?? const <String, String>{};
  final hasEnv = overrideEnv.isNotEmpty || session.env != null;

  return OmpRuntimeLaunch(
    cwd: session.cwd,
    argv: List.unmodifiable(argv),
    env: hasEnv ? Map.unmodifiable({...overrideEnv, ...?session.env}) : null,
    model: session.model,
    thinkingOptionId: session.thinkingOptionId,
    protocolMode: protocolMode,
    modeId: session.modeId,
    session: session.session,
    noSession: session.noSession,
    systemPrompt: systemPrompt,
    extraArgs: session.extraArgs,
  );
}

void _appendOmpLaunchArgs(
  List<String> argv,
  OmpStartSessionInput session,
  OmpProtocolMode protocolMode,
  String? systemPrompt,
) {
  if (!_hasOmpModeFlag(argv)) {
    argv.addAll(['--mode', protocolMode.flagValue]);
  }
  final extraArgs = session.extraArgs;
  if (extraArgs != null && extraArgs.isNotEmpty) {
    argv.addAll(extraArgs);
  }
  final model = session.model;
  if (model != null && model.isNotEmpty) {
    argv.addAll(['--model', model]);
  }
  final thinkingOptionId = session.thinkingOptionId;
  if (thinkingOptionId != null && thinkingOptionId.isNotEmpty) {
    argv.addAll(['--thinking', thinkingOptionId]);
  }
  final sessionId = session.session;
  if (session.noSession == true) {
    argv.add('--no-session');
  } else if (sessionId != null && sessionId.isNotEmpty) {
    argv.addAll(['--session', sessionId]);
  }
  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    argv.addAll(['--append-system-prompt', systemPrompt]);
  }
}

/// Whether the caller already pinned `--mode`, in either the separate-argument
/// or the `--mode=value` spelling.
bool _hasOmpModeFlag(List<String> argv) {
  for (final arg in argv) {
    if (arg == '--mode' || arg.startsWith('--mode=')) return true;
  }
  return false;
}

/// How much of a subagent's activity OMP should stream back.
enum OmpSubagentSubscriptionLevel {
  off('off'),
  progress('progress'),
  events('events');

  const OmpSubagentSubscriptionLevel(this.wireName);

  /// The literal OMP puts on the wire.
  final String wireName;
}

/// Requests the richest subagent subscription OMP supports, downgrading once.
///
/// Older OMP builds reject `events` outright. Upstream fires both calls and
/// discards their failures, because a session that cannot stream child activity
/// must still run — losing the subagent panel is not a fatal error.
///
/// Returns the levels that were actually attempted, in order: `[events]` when
/// the first call succeeds and `[events, progress]` when it had to downgrade.
/// That return value is what makes the downgrade observable to a caller (and to
/// tests) without a logger.
///
/// [setLevel] is the seam onto the provider session; [onError] receives each
/// rejection so a caller can log it exactly as upstream does. Never throws: a
/// failing `progress` call is swallowed too.
Future<List<OmpSubagentSubscriptionLevel>> subscribeOmpSubagentEvents({
  required Future<void> Function(OmpSubagentSubscriptionLevel level) setLevel,
  void Function(OmpSubagentSubscriptionLevel level, Object error)? onError,
}) async {
  final attempted = <OmpSubagentSubscriptionLevel>[
    OmpSubagentSubscriptionLevel.events,
  ];
  try {
    await setLevel(OmpSubagentSubscriptionLevel.events);
    return List.unmodifiable(attempted);
  } on Object catch (error) {
    onError?.call(OmpSubagentSubscriptionLevel.events, error);
  }

  attempted.add(OmpSubagentSubscriptionLevel.progress);
  try {
    await setLevel(OmpSubagentSubscriptionLevel.progress);
  } on Object catch (error) {
    onError?.call(OmpSubagentSubscriptionLevel.progress, error);
  }
  return List.unmodifiable(attempted);
}

// ---------------------------------------------------------------------------
// omp/subagent-title.ts
// ---------------------------------------------------------------------------

/// Fallback shown when OMP names a subagent with nothing but whitespace.
const String ompSubagentFallbackTitle = 'OMP subagent';

/// Formats the title shown on a subagent descriptor.
///
/// OMP reports the resolved model as `provider/model`, which is too long and too
/// backwards to read well in a list, so it is flipped to `model (provider)`. A
/// model string that is not in that shape — no slash, a leading slash, or a
/// trailing slash — is appended verbatim rather than being mangled.
String formatOmpSubagentTitle(String title, [String? resolvedModel]) {
  final trimmedTitle = title.trim();
  final name = trimmedTitle.isEmpty ? ompSubagentFallbackTitle : trimmedTitle;
  final model = resolvedModel?.trim();
  if (model == null || model.isEmpty) return name;

  final separator = model.indexOf('/');
  if (separator <= 0 || separator == model.length - 1) {
    return '$name · $model';
  }
  final provider = model.substring(0, separator);
  final modelName = model.substring(separator + 1);
  return '$name · $modelName ($provider)';
}

// ---------------------------------------------------------------------------
// omp/subagent-index.ts
// ---------------------------------------------------------------------------

/// Lifecycle transitions OMP announces for a subagent.
enum OmpSubagentLifecycleStatus { started, completed, failed, aborted }

/// Statuses OMP reports on a subagent progress poll.
///
/// Wider than [OmpSubagentLifecycleStatus]: a poll can catch a child that has
/// been spawned but not yet started running.
enum OmpSubagentProgressStatus { pending, running, completed, failed, aborted }

/// A `subagent_lifecycle` frame.
///
/// Only the fields [OmpSubagentIndex] observes are modelled; upstream's schema
/// is `.passthrough()` and also carries `agentSource`, `sessionFile`, `index`
/// and `detached`, none of which change the emitted descriptor.
final class OmpSubagentLifecyclePayload {
  const OmpSubagentLifecyclePayload({
    required this.id,
    required this.agent,
    required this.status,
    this.description,
    this.parentToolCallId,
  });

  /// Stable id of the child session.
  final String id;

  /// Agent type OMP spawned, e.g. `explore`. May be empty, in which case the
  /// previously known title is kept.
  final String agent;

  /// Lifecycle transition being reported.
  final OmpSubagentLifecycleStatus status;

  /// Assignment text, when OMP includes it.
  final String? description;

  /// Id of the parent `task` tool call that spawned this child, used to anchor
  /// the descriptor to its card.
  final String? parentToolCallId;
}

/// The inner `progress` object of a `subagent_progress` frame.
final class OmpSubagentProgress {
  const OmpSubagentProgress({
    required this.id,
    required this.status,
    this.description,
    this.resolvedModel,
  });

  /// Stable id of the child session. This — not the frame's `index` — is the
  /// key the index is stored under.
  final String id;

  /// Current status of the child.
  final OmpSubagentProgressStatus status;

  /// Assignment text, when OMP includes it.
  final String? description;

  /// `provider/model` string OMP resolved for the child, when known.
  final String? resolvedModel;
}

/// A `subagent_progress` frame.
final class OmpSubagentProgressPayload {
  const OmpSubagentProgressPayload({
    required this.agent,
    required this.progress,
    this.assignment,
    this.parentToolCallId,
  });

  /// Agent type, same semantics as [OmpSubagentLifecyclePayload.agent].
  final String agent;

  /// The progress snapshot.
  final OmpSubagentProgress progress;

  /// Fallback description, used when the progress snapshot carries none.
  final String? assignment;

  /// Id of the parent `task` tool call.
  final String? parentToolCallId;
}

/// A `subagent_event` frame: one raw child session event.
///
/// [event] stays as decoded JSON rather than a typed union because
/// `omp/rpc-types.ts` is a separate parity unit; only the `message_end` variant
/// is observable here.
final class OmpSubagentEventPayload {
  const OmpSubagentEventPayload({required this.id, required this.event});

  /// Stable id of the child session the event belongs to.
  final String id;

  /// The raw `OmpAgentSessionEvent`.
  final Map<String, Object?> event;
}

/// Maps a child session's messages onto timeline items for its descriptor.
///
/// One instance is created per child and keeps whatever numbering state the
/// mapping needs, which is why [OmpSubagentIndex] takes a factory rather than a
/// shared instance.
abstract interface class OmpSubagentTimelineMapper {
  /// Maps one raw `OmpAgentMessage`, returning the items it produces.
  List<TimelineItem> mapMessage(Map<String, Object?> message);
}

/// Creates the per-child mapper used by [OmpSubagentIndex].
typedef OmpSubagentTimelineMapperFactory = OmpSubagentTimelineMapper Function();

/// The default [OmpSubagentTimelineMapper]: assistant messages only.
///
/// Upstream hands child messages to `message-history.ts`'s `OmpHistoryMapper`,
/// which also covers user, custom, tool-result and bash-execution roles. That
/// module is a separate parity unit (and its custom-message branch depends on
/// two further un-ported modules), so this default reproduces exactly the
/// branch upstream's subagent suite pins — assistant text and thinking blocks —
/// and ignores every other role. Inject a fuller mapper to widen it.
///
/// Message ids follow upstream: the provider's own `responseId` when present,
/// otherwise `<provider>-history-assistant-<n>` with `n` counting assistant
/// messages seen by *this* mapper from 1.
///
/// Deviation: upstream's reasoning items carry no id at all. The protocol's
/// [TimelineItem] requires one, so thinking blocks get a deterministic
/// `<messageId>-thinking-<n>` id — deterministic so a replayed history upserts
/// rather than duplicating.
final class OmpSubagentAssistantTimelineMapper
    implements OmpSubagentTimelineMapper {
  OmpSubagentAssistantTimelineMapper({this.provider = 'omp'});

  /// Provider slug used to build synthetic message ids.
  final String provider;

  int _assistantIndex = 0;

  @override
  List<TimelineItem> mapMessage(Map<String, Object?> message) {
    if (message['role'] != 'assistant') return const [];

    // Incremented before the content is inspected, matching upstream: a
    // contentless assistant message still consumes an index.
    _assistantIndex += 1;
    final responseId = message['responseId'];
    final messageId = responseId is String && responseId.isNotEmpty
        ? responseId
        : '$provider-history-assistant-$_assistantIndex';

    final content = message['content'];
    if (content is! List) return const [];

    final items = <TimelineItem>[];
    var thinkingIndex = 0;
    for (final entry in content) {
      final block = _record(entry);
      if (block == null) continue;
      if (block['type'] == 'text') {
        final text = block['text'];
        // Upstream guards with `content.text` truthiness, so an empty text
        // block emits nothing rather than an empty bubble.
        if (text is String && text.isNotEmpty) {
          items.add(
            AssistantMessageItem(id: messageId, text: text, complete: true),
          );
        }
        continue;
      }
      if (block['type'] == 'thinking') {
        final thinking = block['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          thinkingIndex += 1;
          items.add(
            ReasoningItem(
              id: '$messageId-thinking-$thinkingIndex',
              text: thinking,
              complete: true,
            ),
          );
        }
      }
    }
    return items;
  }
}

final class _OmpSubagentState {
  _OmpSubagentState({required this.title, required this.mapper});

  String title;
  String? description;
  String? resolvedModel;
  String? toolCallId;
  ProviderSubagentStatus status = ProviderSubagentStatus.running;
  final OmpSubagentTimelineMapper mapper;
}

/// Tracks OMP's subagents per parent session and turns its three subagent
/// frames into provider events.
///
/// OMP reports a child through whichever channels the running build supports —
/// lifecycle only, lifecycle plus progress polls, or all three — and the frames
/// carry overlapping, partial information. The index merges them into one
/// descriptor per child so a late progress poll cannot blank out a title the
/// lifecycle frame already established.
///
/// State is keyed on an opaque *parent* object, which lets one index serve every
/// session in the process. Upstream uses a `WeakMap`; Dart's [Expando] is the
/// direct analogue and keeps the entry alive only as long as the parent is.
/// The consequence is upstream's too: parents must be real objects — [Expando]
/// rejects strings, numbers, booleans, records and `null`.
final class OmpSubagentIndex {
  OmpSubagentIndex({OmpSubagentTimelineMapperFactory? timelineMapperFactory})
    : _timelineMapperFactory =
          timelineMapperFactory ?? OmpSubagentAssistantTimelineMapper.new;

  final OmpSubagentTimelineMapperFactory _timelineMapperFactory;
  final Expando<Map<String, _OmpSubagentState>> _statesByParent = Expando();

  /// Folds a `subagent_lifecycle` frame in and emits the refreshed descriptor.
  ///
  /// An empty [OmpSubagentLifecyclePayload.agent] keeps the existing title —
  /// upstream's `payload.agent || state.title` — and an absent description or
  /// parent tool call leaves whatever was already known.
  List<ProviderEvent> handleLifecycle(
    Object parent,
    OmpSubagentLifecyclePayload payload,
  ) {
    final state = _stateFor(parent, payload.id, payload.agent);
    if (payload.agent.isNotEmpty) state.title = payload.agent;
    state.description = payload.description ?? state.description;
    state.toolCallId = payload.parentToolCallId ?? state.toolCallId;
    state.status = _mapOmpLifecycleStatus(payload.status);
    return [_upsert(payload.id, state.status, state)];
  }

  /// Folds a `subagent_progress` frame in and emits the refreshed descriptor.
  ///
  /// The description falls back through the progress snapshot, then the frame's
  /// `assignment`, then whatever was already known. A blank `resolvedModel` is
  /// ignored rather than clearing a model the index already resolved, so a
  /// later poll that omits it cannot shorten the title.
  List<ProviderEvent> handleProgress(
    Object parent,
    OmpSubagentProgressPayload payload,
  ) {
    final id = payload.progress.id;
    final state = _stateFor(parent, id, payload.agent);
    if (payload.agent.isNotEmpty) state.title = payload.agent;
    state.description =
        payload.progress.description ?? payload.assignment ?? state.description;
    final resolvedModel = payload.progress.resolvedModel;
    if (resolvedModel != null && resolvedModel.trim().isNotEmpty) {
      state.resolvedModel = resolvedModel;
    }
    state.toolCallId = payload.parentToolCallId ?? state.toolCallId;
    state.status = _mapOmpProgressStatus(payload.progress.status);
    return [_upsert(id, state.status, state)];
  }

  /// Folds a `subagent_event` frame in and emits the child's timeline items.
  ///
  /// Emits no descriptor update: an event frame carries no status, so upserting
  /// here would republish a stale one. Only `message_end` produces items —
  /// upstream ignores every other session event, because partial deltas would
  /// double up against the final message.
  ///
  /// Deviation: upstream forwards an optional `timestamp` from the history
  /// mapper. `OmpHistoryMapper` never sets one, so
  /// [ProviderSubagentTimelineChanged.timestamp] is always left absent and the
  /// store stamps arrival time instead.
  List<ProviderEvent> handleEvent(
    Object parent,
    OmpSubagentEventPayload payload,
  ) {
    final state = _stateFor(parent, payload.id, ompSubagentFallbackTitle);
    final events = <ProviderEvent>[];
    for (final message in _ompMessagesFromSessionEvent(payload.event)) {
      for (final item in state.mapper.mapMessage(message)) {
        events.add(
          ProviderSubagentTimelineChanged(subagentId: payload.id, item: item),
        );
      }
    }
    return events;
  }

  /// Marks every still-running child of [parent] as canceled.
  ///
  /// Called when the parent turn ends: OMP does not send a terminal frame for
  /// children that were still in flight, so without this they would spin
  /// forever in the UI. Children that already reached a terminal status are left
  /// alone, and the emission order is OMP's announcement order.
  List<ProviderEvent> terminalizeRunning(Object parent) {
    final states = _statesByParent[parent];
    if (states == null) return const [];

    final events = <ProviderEvent>[];
    for (final entry in states.entries) {
      final state = entry.value;
      if (state.status != ProviderSubagentStatus.running) continue;
      state.status = ProviderSubagentStatus.canceled;
      events.add(_upsert(entry.key, state.status, state));
    }
    return events;
  }

  /// Drops every child of [parent].
  ///
  /// Emits nothing: the caller is discarding the parent's whole subagent panel,
  /// so per-child removal events would be redundant.
  void clear(Object parent) {
    _statesByParent[parent] = null;
  }

  _OmpSubagentState _stateFor(Object parent, String id, String title) {
    final states = _statesByParent[parent] ?? <String, _OmpSubagentState>{};
    final existing = states[id];
    if (existing != null) return existing;

    final state = _OmpSubagentState(
      title: title,
      mapper: _timelineMapperFactory(),
    );
    states[id] = state;
    _statesByParent[parent] = states;
    return state;
  }

  ProviderSubagentUpserted _upsert(
    String id,
    ProviderSubagentStatus status,
    _OmpSubagentState state,
  ) => ProviderSubagentUpserted(
    subagentId: id,
    title: formatOmpSubagentTitle(state.title, state.resolvedModel),
    description: state.description,
    status: status,
    toolCallId: state.toolCallId,
  );
}

/// Upstream's `messagesFromSessionEvent`: only a completed message is mapped.
List<Map<String, Object?>> _ompMessagesFromSessionEvent(
  Map<String, Object?> event,
) {
  if (event['type'] != 'message_end') return const [];
  final message = _record(event['message']);
  return message == null ? const [] : [message];
}

/// `started` means the child is live; `aborted` is the wire spelling of the
/// protocol's `canceled`.
ProviderSubagentStatus _mapOmpLifecycleStatus(
  OmpSubagentLifecycleStatus status,
) => switch (status) {
  OmpSubagentLifecycleStatus.started => ProviderSubagentStatus.running,
  OmpSubagentLifecycleStatus.aborted => ProviderSubagentStatus.canceled,
  OmpSubagentLifecycleStatus.completed => ProviderSubagentStatus.completed,
  OmpSubagentLifecycleStatus.failed => ProviderSubagentStatus.failed,
};

/// Only the two terminal successes map straight across; `pending` collapses into
/// `running` because the protocol has no queued state and a queued child must
/// still show as active work.
ProviderSubagentStatus _mapOmpProgressStatus(
  OmpSubagentProgressStatus status,
) => switch (status) {
  OmpSubagentProgressStatus.completed => ProviderSubagentStatus.completed,
  OmpSubagentProgressStatus.failed => ProviderSubagentStatus.failed,
  OmpSubagentProgressStatus.aborted => ProviderSubagentStatus.canceled,
  OmpSubagentProgressStatus.pending ||
  OmpSubagentProgressStatus.running => ProviderSubagentStatus.running,
};
