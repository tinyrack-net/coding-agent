/// OMP and Pi CLI runtime rules, ported from Paseo 0.2.0.
///
/// Upstream keeps these as five sibling modules under
/// `packages/server/src/server/agent/providers/`:
///
/// * `omp/rpc-ui-permission-mapper.ts` — turns OMP's generic `extension_ui`
///   *select* prompts into renderable tool-approval requests, and turns the
///   user's decision back into the exact select value OMP expects
/// * `omp/host-tools.ts`  — routes OMP's `host_tool_*` frames into the Paseo
///   tool catalogue and streams partial/final results back
/// * `omp/cli-runtime.ts` — the schema-validating RPC facade over a spawned
///   `omp --mode rpc` process
/// * `pi/cli-runtime.ts`  — the same facade for `pi`, with Pi's own timeout
///   policy and no schema validation
/// * `pi/history-mapper.ts` — replays a Pi transcript onto the timeline
///
/// They are grouped into one Dart library because the two CLI runtimes are
/// near-identical twins whose *differences* are the interesting parity surface,
/// because the permission mapper and the host-tool router exist only to be
/// driven by the OMP runtime, and because Dart has no barrel re-export that
/// would let them stay separate without multiplying import lines at every call
/// site. This matches how `paseo_provider_mappers.dart` and
/// `paseo_omp_runtime.dart` are already organised.
///
/// ## What this library reuses rather than re-declaring
///
/// From `paseo_omp_runtime.dart`:
///
/// * [OmpProtocolMode] — upstream declares the identical `"rpc" | "rpc-ui"`
///   union twice, once in `omp/runtime.ts` and once in `pi/runtime.ts`. The
///   OMP-named enum is reused for Pi rather than declaring a parallel copy.
/// * [OmpStartSessionInput] / [OmpRuntimeLaunch] / [buildOmpLaunch] — the whole
///   OMP argv-assembly rule, called by [OmpCliRuntime.startSession].
/// * [OmpTrackedToolCall] and [parseOmpToolArgs] / [mapOmpCoreToolDetail] /
///   [extractOmpToolResultText] / [resolveOmpToolCallName] — upstream's
///   `pi/tool-call-mapper.ts` is a byte-for-byte duplicate of
///   `omp/tool-call-detail.ts` except for one extra MCP branch in
///   `resolveToolCallName`. [PiHistoryMapper] therefore drives the OMP-named
///   port directly and this library adds only the missing branch, as
///   [resolvePiToolCallName].
///
/// From `paseo_provider_mappers.dart`:
///
/// * [parseOmpToolResult] — upstream's `parseToolResult`, run over a raw tool
///   result before it reaches the detail mapper.
/// * [OmpContextUsage] / [OmpSessionState] — the context-window value types the
///   `get_session_stats` fallback produces and [OmpRpcSessionState] projects to.
/// * [OmpRpcSlashCommand] / [OmpCommandInput] — the slash-command shape
///   `get_available_commands` returns, so [mapOmpSlashCommands] can consume
///   [OmpCliRuntimeSession.getCommands] output unchanged.
///
/// From `jsonl_rpc_process.dart`: the entire transport. [JsonlRpcProcess]
/// already ports request correlation, the `null`/zero timeout meaning "wait
/// forever" (upstream's `JSONL_RPC_NO_TIMEOUT`), stderr-suffixed exit errors,
/// and graceful-then-forced shutdown, so neither runtime re-implements any of
/// it.
///
/// From `provider_launch_config.dart`: [ProviderRuntimeSettings] and
/// [ProviderCommandMode] for the `replace`-mode command override.
///
/// From `provider_event.dart`: [PermissionDecision] stands in for upstream's
/// `AgentPermissionResponse["behavior"]` union.
///
/// `lib/src/utils/paseo_process_utils.dart` owns spawning and shell invocation;
/// this library never spawns. [JsonlRpcProcess.start] takes the process
/// starter, and both runtimes expose it as an injection point
/// ([OmpCliRuntimeOptions.spawnProcess] / [PiCliRuntimeOptions.spawnProcess]),
/// so every launch decision here is assertable without a child process.
///
/// ## Architecture note: what has no live counterpart
///
/// This daemon runs a native LLM harness rather than driving a third-party
/// provider binary, so nothing in production calls [OmpCliRuntime] or
/// [PiCliRuntime] today. What is ported is what upstream's suites actually pin
/// and what a future binary-driving integration would have to reproduce
/// verbatim: argv assembly, environment merging, the RPC command vocabulary and
/// its per-command timeout policy, the frame-validation rule that decides which
/// stdout lines become events, the `get_session_stats` → `get_state` compat
/// fallback, and the permission/history/host-tool mappings around them.
///
/// Two upstream concerns are deliberately *not* ported because they have no
/// observable rule to port:
///
/// * `pino` structured logging. Upstream threads a `Logger` through both
///   runtimes and the host-tool router purely to emit debug/warn lines. Here
///   that is a nullable [PaseoRuntimeLogSink] callback; when it is omitted the
///   messages are dropped, which is what `pino({level: "silent"})` does in
///   every upstream test.
/// * Zod-to-JSON-Schema conversion. Upstream's `serializePaseoToolInputParameters`
///   runs the MCP SDK's `toJsonSchemaCompat` over a Zod shape. Dart has no Zod,
///   so [PaseoToolDefinition.inputSchema] carries the already-built JSON Schema
///   and [serializeOmpHostTools] only supplies upstream's empty-object default.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../provider_event.dart' show PermissionDecision;
import 'jsonl_rpc_process.dart';
import 'paseo_omp_runtime.dart'
    show
        OmpProtocolMode,
        OmpRuntimeLaunch,
        OmpStartSessionInput,
        OmpTrackedToolCall,
        buildOmpLaunch,
        extractOmpToolResultText,
        mapOmpCoreToolDetail,
        parseOmpToolArgs,
        resolveOmpToolCallName;
import 'paseo_provider_mappers.dart'
    show
        OmpCommandInput,
        OmpContextUsage,
        OmpRpcSlashCommand,
        OmpSessionState,
        parseOmpToolResult;
import 'provider_launch_config.dart'
    show ProviderCommandMode, ProviderRuntimeSettings;

// ---------------------------------------------------------------------------
// Shared JS-semantics helpers
// ---------------------------------------------------------------------------

/// Upstream's `isRecord`: a plain object, excluding arrays and `null`.
///
/// Decoded JSON already yields `Map<String, dynamic>`, which satisfies
/// `Map<String, Object?>` directly; a `Map<dynamic, dynamic>` a caller
/// hand-built is copied when every key is a string and rejected otherwise,
/// matching Zod's object check.
Map<String, Object?>? _asRecord(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is! Map) return null;
  final copy = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    copy[entry.key as String] = entry.value;
  }
  return copy;
}

/// Mirrors JavaScript truthiness for the upstream `if (value)` guards this
/// library reproduces. Dart has no truthiness, so an upstream `if (command)`
/// would otherwise silently become `!= null` and accept the empty string that
/// upstream deliberately rejects.
bool _isJsTruthy(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

/// `z.string().optional()`: absent is fine, present must be a string. An
/// explicit `null` fails, because upstream did not add `.nullable()`.
bool _optStr(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is String;

/// `z.string().nullable().optional()`.
bool _optNullableStr(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] == null || json[key] is String;

/// `z.boolean().optional()`.
bool _optBool(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is bool;

/// `z.number().optional()`.
bool _optNum(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] is num;

/// `z.number().nullable().optional()`.
bool _optNullableNum(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] == null || json[key] is num;

/// `z.record(z.string(), z.unknown()).optional()`.
bool _optRecord(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || _asRecord(json[key]) != null;

/// `<object>.nullable().optional()`.
bool _optNullableRecord(Map<String, Object?> json, String key) =>
    !json.containsKey(key) || json[key] == null || _asRecord(json[key]) != null;

/// `z.number().int().nonnegative()`.
bool _isNonNegativeInt(Object? value) =>
    value is num &&
    !value.isNaN &&
    value == value.truncateToDouble() &&
    value >= 0;

/// `z.number().int().positive()`.
bool _isPositiveInt(Object? value) =>
    _isNonNegativeInt(value) && (value! as num) > 0;

bool _isListOf(Object? value, bool Function(Object?) predicate) =>
    value is List && value.every(predicate);

bool _optListOf(
  Map<String, Object?> json,
  String key,
  bool Function(Object?) predicate,
) => !json.containsKey(key) || _isListOf(json[key], predicate);

String? _readNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Diagnostic sink standing in for upstream's `pino` logger.
///
/// [message] is upstream's log message and [detail] the structured object it
/// attached. Callers that pass nothing get upstream's `level: "silent"`
/// behaviour.
typedef PaseoRuntimeLogSink = void Function(String message, Object? detail);

// ===========================================================================
// omp/rpc-ui-permission-mapper.ts
// ===========================================================================

const String _ompProvider = 'omp';

/// Marker written into [OmpRpcUiPermissionRequest.metadata] so the *response*
/// builder can tell one of these synthesized approvals apart from a permission
/// raised by any other provider.
const String ompRpcUiToolApprovalMetadata = 'omp_rpc_ui_tool_approval';

/// The literal select option OMP treats as approval.
const String ompRpcUiToolApprovalApproveValue = 'Approve';

/// The literal select option OMP treats as denial.
const String ompRpcUiToolApprovalDenyValue = 'Deny';

/// The exact, ordered option list that marks a select prompt as a tool
/// approval. A prompt offering `["Yes", "No"]` is passed through untouched.
const List<String> ompRpcUiToolApprovalOptions = [
  ompRpcUiToolApprovalApproveValue,
  ompRpcUiToolApprovalDenyValue,
];

const String _ompToolTitlePrefix = 'Allow tool: ';

/// How the daemon should render one button of a permission prompt.
///
/// Upstream inlines these objects in the mapper; they are a class here so the
/// daemon cannot silently drop `variant` or `intent` when it forwards the
/// request to a client.
final class OmpRpcUiPermissionAction {
  const OmpRpcUiPermissionAction({
    required this.id,
    required this.label,
    required this.behavior,
    required this.variant,
    this.intent,
  });

  /// Stable action id echoed back as `selectedActionId`.
  final String id;

  /// Button text. Deliberately the *same* string OMP expects back as the select
  /// value, so the label and the wire value cannot drift apart.
  final String label;

  /// Whether choosing this action allows or denies the call.
  final PermissionDecision behavior;

  /// Presentation hint, upstream's `"danger" | "primary"`.
  final String variant;

  /// Optional presentation hint, upstream's `"dismiss"` on the deny action.
  final String? intent;
}

/// A tool-approval permission synthesized from an OMP `extension_ui_request`.
///
/// This is the slice of upstream's `AgentPermissionRequest` that the mapper
/// populates. It is a dedicated type rather than the daemon's
/// [PermissionRequested] provider event because that event carries only
/// `permissionId`, `toolName`, `detail` and a responder — it has no place for
/// the [actions] list or the [metadata] that
/// [buildOmpRpcUiPermissionResponse] reads back. Bridging to
/// [PermissionRequested] is the session's job, not the mapper's.
final class OmpRpcUiPermissionRequest {
  const OmpRpcUiPermissionRequest({
    required this.id,
    required this.provider,
    required this.name,
    required this.kind,
    required this.title,
    required this.detail,
    required this.actions,
    required this.metadata,
    this.description,
  });

  /// The `extension_ui_request` id, used to address the response back to OMP.
  final String id;

  /// Provider that raised the request; `omp` unless a wrapper overrides it.
  final String provider;

  /// Tool being approved: `bash`, `edit` or `write`.
  final String name;

  /// Upstream's permission discriminator, always `tool` here. Kept as a field
  /// rather than hard-coded so [buildOmpRpcUiPermissionResponse] can reproduce
  /// upstream's guard, which runs against permissions from *any* provider.
  final String kind;

  /// Rendered headline, `Allow tool: <name>`.
  final String title;

  /// One-line summary of the operation, omitted when the prompt carried none.
  final String? description;

  /// Detail card describing the pending operation.
  final ToolCallDetail detail;

  /// Buttons, deny first — upstream's order, which puts the safe choice under
  /// the cursor.
  final List<OmpRpcUiPermissionAction> actions;

  /// Round-trip data for [buildOmpRpcUiPermissionResponse]: the approval
  /// marker, the tool name and arguments, and the exact select values.
  final Map<String, Object?> metadata;
}

/// Result of inspecting an OMP `extension_ui_request`.
///
/// A sealed hierarchy rather than a nullable request because "this is not a
/// tool approval" is a *decision* the caller must act on — it forwards the
/// prompt to the generic extension-UI surface — and not an error.
sealed class OmpRpcUiPermissionClassification {
  const OmpRpcUiPermissionClassification();
}

/// The prompt is a tool approval and should be rendered as [request].
final class OmpRpcUiToolPermission extends OmpRpcUiPermissionClassification {
  const OmpRpcUiToolPermission(this.request);

  final OmpRpcUiPermissionRequest request;
}

/// The prompt is some other extension-UI interaction and must be forwarded
/// unchanged.
final class OmpRpcUiPassthrough extends OmpRpcUiPermissionClassification {
  const OmpRpcUiPassthrough();
}

/// Internal shape shared by the three per-tool parsers.
final class _OmpToolApprovalDescriptor {
  const _OmpToolApprovalDescriptor({
    required this.toolName,
    required this.args,
    required this.detail,
    this.description,
  });

  final String toolName;
  final Map<String, Object?> args;
  final ToolCallDetail detail;
  final String? description;
}

/// Classifies an OMP `extension_ui_request` frame.
///
/// OMP has no dedicated permission RPC: it asks for tool approval through the
/// same generic `select` prompt it uses for every other extension interaction,
/// encoding the tool and its arguments in the prompt *title*. Recognising that
/// encoding is what lets the daemon render a real approval card — with a diff
/// or a command preview — instead of a bare two-button list.
///
/// A prompt qualifies only when all of the following hold, which is what keeps
/// an ordinary extension select from being hijacked into an auto-approvable
/// permission:
///
/// * `method` is exactly `select`;
/// * `options` is exactly `["Approve", "Deny"]`, in that order;
/// * the first line of `title` starts with `Allow tool: `; and
/// * the named tool is one of `bash`, `edit`, `write` *and* its body parses.
///
/// [provider] overrides the recorded provider for wrappers that re-badge OMP.
OmpRpcUiPermissionClassification classifyOmpRpcUiPermissionRequest(
  Map<String, Object?> event, {
  String provider = _ompProvider,
}) {
  final descriptor = _parseOmpToolApprovalDescriptor(event);
  if (descriptor == null) return const OmpRpcUiPassthrough();

  return OmpRpcUiToolPermission(
    OmpRpcUiPermissionRequest(
      id: event['id']! as String,
      provider: provider,
      name: descriptor.toolName,
      kind: 'tool',
      title: '$_ompToolTitlePrefix${descriptor.toolName}',
      description: descriptor.description,
      detail: descriptor.detail,
      actions: const [
        OmpRpcUiPermissionAction(
          id: 'deny',
          label: ompRpcUiToolApprovalDenyValue,
          behavior: PermissionDecision.deny,
          variant: 'danger',
          intent: 'dismiss',
        ),
        OmpRpcUiPermissionAction(
          id: 'approve',
          label: ompRpcUiToolApprovalApproveValue,
          behavior: PermissionDecision.allow,
          variant: 'primary',
        ),
      ],
      metadata: {
        'extensionUiMethod': 'select',
        'toolApproval': ompRpcUiToolApprovalMetadata,
        'toolName': descriptor.toolName,
        'toolArgs': descriptor.args,
        'approveValue': ompRpcUiToolApprovalApproveValue,
        'denyValue': ompRpcUiToolApprovalDenyValue,
      },
    ),
  );
}

/// Convenience wrapper returning the request, or `null` for a passthrough.
///
/// Kept alongside [classifyOmpRpcUiPermissionRequest] because upstream exports
/// both: call sites that only forward permissions use this one, while the
/// session loop needs the classification so it can route passthroughs onward.
OmpRpcUiPermissionRequest? mapOmpRpcUiPermissionRequest(
  Map<String, Object?> event, {
  String provider = _ompProvider,
}) {
  final classification = classifyOmpRpcUiPermissionRequest(
    event,
    provider: provider,
  );
  return classification is OmpRpcUiToolPermission
      ? classification.request
      : null;
}

/// The payload OMP expects back on an `extension_ui_response` frame.
///
/// All three fields are optional upstream and only ever set one at a time: a
/// select answer carries [value], a confirm answer carries [confirmed], and a
/// dismissal carries [cancelled].
final class OmpExtensionUiResponse {
  const OmpExtensionUiResponse({this.value, this.confirmed, this.cancelled});

  /// Chosen option for a `select` prompt.
  final String? value;

  /// Answer to a confirm prompt.
  final bool? confirmed;

  /// Set when the daemon abandoned the prompt without answering it.
  final bool? cancelled;

  /// Wire form, omitting every field upstream would have left `undefined`.
  Map<String, Object?> toJson() => {
    if (value != null) 'value': value,
    if (confirmed != null) 'confirmed': confirmed,
    if (cancelled != null) 'cancelled': cancelled,
  };
}

/// Translates the user's decision into the exact select value OMP is waiting
/// for.
///
/// Returns `null` for any permission this mapper did not create, so a caller
/// can safely funnel every permission response through here and fall back to
/// its normal path.
///
/// The approve/deny strings are read back out of [metadata] rather than being
/// re-derived, so a future OMP that localises its option labels keeps working:
/// whatever literal arrived on the prompt is what goes back. The constants are
/// only a fallback for a request whose metadata was rebuilt lossily.
///
/// Deviation: upstream's `AgentPermissionResponse` also carries
/// `selectedActionId` and `message`, and deliberately ignores both here — every
/// allow-shaped action, including `allow_always`, maps to the same single
/// approval value because OMP's select prompt has no "always" option. This port
/// takes only [decision] for that reason; accepting the other two fields would
/// imply they affect the result.
Map<String, Object?>? buildOmpRpcUiPermissionResponse(
  OmpRpcUiPermissionRequest request,
  PermissionDecision decision,
) {
  if (request.kind != 'tool' ||
      request.metadata['toolApproval'] != ompRpcUiToolApprovalMetadata) {
    return null;
  }

  final approveValue =
      _readNonEmptyOrNull(request.metadata['approveValue']) ??
      ompRpcUiToolApprovalApproveValue;
  final denyValue =
      _readNonEmptyOrNull(request.metadata['denyValue']) ??
      ompRpcUiToolApprovalDenyValue;
  return OmpExtensionUiResponse(
    value: decision == PermissionDecision.allow ? approveValue : denyValue,
  ).toJson();
}

/// Upstream's `readString`: a non-empty string, or `null`.
String? _readNonEmptyOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

_OmpToolApprovalDescriptor? _parseOmpToolApprovalDescriptor(
  Map<String, Object?> event,
) {
  if (event['type'] != 'extension_ui_request') return null;
  if (event['id'] is! String) return null;
  if (event['method'] != 'select') return null;
  if (!_hasExactOmpToolApprovalOptions(event['options'])) return null;
  final title = _readNonEmptyOrNull(event['title']);
  if (title == null) return null;

  final lineBreak = RegExp(r'\r?\n').firstMatch(title);
  final firstLine =
      (lineBreak == null ? title : title.substring(0, lineBreak.start)).trim();
  if (!firstLine.startsWith(_ompToolTitlePrefix)) return null;
  final rawToolName = firstLine.substring(_ompToolTitlePrefix.length).trim();
  final body = lineBreak == null
      ? ''
      : title.substring(lineBreak.start).replaceFirst(RegExp(r'^\r?\n'), '');
  final bodyLines = body.split(RegExp(r'\r?\n'));

  return switch (rawToolName) {
    'bash' => _parseOmpBashApproval(body),
    'edit' => _parseOmpEditApproval(bodyLines),
    'write' => _parseOmpWriteApproval(bodyLines),
    _ => null,
  };
}

/// Matches upstream's `/(?:^|\r?\n)[\t ]*Command:[\t ]?(.*)$/s`.
///
/// The `s` (dotAll) flag is load-bearing: it makes `(.*)$` swallow the rest of
/// the body verbatim, newlines included, so a multi-line — and possibly
/// destructive — command reaches the approval card exactly as OMP will run it
/// rather than truncated at the first line break. Line endings are preserved
/// too, CRLF included.
final _ompBashCommandPattern = RegExp(
  r'(?:^|\r?\n)[\t ]*Command:[\t ]?(.*)$',
  dotAll: true,
);

_OmpToolApprovalDescriptor? _parseOmpBashApproval(String body) {
  final match = _ompBashCommandPattern.firstMatch(body);
  final command = match?.group(1);
  // Upstream's `if (!command)` also rejects the empty capture.
  if (!_isJsTruthy(command)) return null;
  return _OmpToolApprovalDescriptor(
    toolName: 'bash',
    args: {'command': command},
    description: 'Command: $command',
    detail: ShellDetail(command: command!),
  );
}

_OmpToolApprovalDescriptor? _parseOmpEditApproval(List<String> lines) {
  final filePath = _readOmpPrefixedValue(lines, 'File:');
  if (filePath == null) return null;
  return _OmpToolApprovalDescriptor(
    toolName: 'edit',
    args: {'path': filePath},
    description: 'File: $filePath',
    detail: EditDetail(path: filePath),
  );
}

_OmpToolApprovalDescriptor? _parseOmpWriteApproval(List<String> lines) {
  final pathLineIndex = lines.indexWhere(
    (line) => line.trim().startsWith('Path:'),
  );
  if (pathLineIndex < 0) return null;
  final filePath = _stripOmpPrefix(lines[pathLineIndex], 'Path:')?.trim();
  if (filePath == null || filePath.isEmpty) return null;

  var contentLineIndex = -1;
  for (var index = pathLineIndex + 1; index < lines.length; index += 1) {
    if (lines[index].trim() == 'Content:') {
      contentLineIndex = index;
      break;
    }
  }
  if (contentLineIndex < 0) return null;
  final content = lines.sublist(contentLineIndex + 1).join('\n');
  return _OmpToolApprovalDescriptor(
    toolName: 'write',
    args: {'path': filePath, 'content': content},
    description: 'Path: $filePath',
    // Deviation: upstream's write detail is `{type, filePath, content}` and the
    // protocol's [WriteDetail] names the same field `contentPreview`. The value
    // is the full pending content either way; only the field name differs.
    detail: WriteDetail(path: filePath, contentPreview: content),
  );
}

bool _hasExactOmpToolApprovalOptions(Object? options) {
  if (options is! List) return false;
  if (options.length != ompRpcUiToolApprovalOptions.length) return false;
  for (var index = 0; index < options.length; index += 1) {
    if (options[index] != ompRpcUiToolApprovalOptions[index]) return false;
  }
  return true;
}

/// First line whose trimmed form starts with [prefix], with the prefix stripped
/// and the remainder trimmed. Skips lines whose remainder is empty, matching
/// upstream's truthiness check.
String? _readOmpPrefixedValue(List<String> lines, String prefix) {
  for (final line in lines) {
    final value = _stripOmpPrefix(line, prefix)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String? _stripOmpPrefix(String? line, String prefix) {
  final trimmed = line?.trim();
  if (trimmed == null || !trimmed.startsWith(prefix)) return null;
  return trimmed.substring(prefix.length);
}

// ===========================================================================
// omp/host-tools.ts
// ===========================================================================

/// Sentinel separating "no structured content" (upstream's `undefined`) from an
/// explicit `null`.
///
/// The distinction is observable twice: `addModelVisibleStructuredContent`
/// synthesizes a `"null"` text block for an explicit null but leaves an absent
/// value alone, and `toOmpAgentToolResult` emits a `details: null` key for the
/// former and no key at all for the latter.
const Object absentStructuredContent = Object();

/// Cooperative cancellation handed to a Paseo tool, standing in for upstream's
/// `AbortSignal`.
///
/// Dart has no `AbortController`, so the router owns the abort side and hands
/// the tool this read-only view. A long-running tool polls [isAborted] or awaits
/// [whenAborted].
final class PaseoToolCancellation {
  PaseoToolCancellation();

  final Completer<void> _completer = Completer<void>();
  Object? _reason;

  /// Whether the call has been cancelled.
  bool get isAborted => _completer.isCompleted;

  /// Why it was cancelled, once it has been.
  Object? get reason => _reason;

  /// Completes when the call is cancelled, and never otherwise.
  Future<void> get whenAborted => _completer.future;

  void _abort(Object reason) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete();
  }
}

/// Ambient state a Paseo tool receives alongside its arguments.
final class PaseoToolExecutionContext {
  const PaseoToolExecutionContext({this.cancellation, this.sendUpdate});

  /// Cancellation view for the in-flight call, when the caller supports it.
  final PaseoToolCancellation? cancellation;

  /// Streams a partial result back to the model mid-call.
  final void Function(PaseoToolResult update)? sendUpdate;
}

/// What a Paseo tool returns.
final class PaseoToolResult {
  const PaseoToolResult({
    required this.content,
    Object? structuredContent = absentStructuredContent,
    this.isError,
  }) : _structuredContent = structuredContent;

  /// Model-visible content blocks, each carrying at least a `type`.
  final List<Map<String, Object?>> content;

  final Object? _structuredContent;

  /// Whether the call failed. `null` means the tool did not say, which is
  /// distinct from `false` on the wire.
  final bool? isError;

  /// Whether the tool attached structured content at all.
  bool get hasStructuredContent =>
      !identical(_structuredContent, absentStructuredContent);

  /// Structured payload, or `null` when [hasStructuredContent] is false.
  Object? get structuredContent =>
      hasStructuredContent ? _structuredContent : null;

  /// Copy carrying different [content] and the same structured payload.
  PaseoToolResult withContent(List<Map<String, Object?>> content) =>
      hasStructuredContent
      ? PaseoToolResult(
          content: content,
          structuredContent: _structuredContent,
          isError: isError,
        )
      : PaseoToolResult(content: content, isError: isError);
}

/// Handler signature for a Paseo tool.
typedef PaseoToolHandler =
    Future<PaseoToolResult> Function(
      Object? input,
      PaseoToolExecutionContext context,
    );

/// A tool the daemon exposes to a provider.
final class PaseoToolDefinition {
  const PaseoToolDefinition({
    required this.name,
    required this.description,
    required this.handler,
    this.title,
    this.inputSchema,
  });

  /// Wire name the provider calls.
  final String name;

  /// Model-facing description.
  final String description;

  /// Human-facing label; becomes `label` on the serialized definition.
  final String? title;

  /// JSON Schema for the arguments.
  ///
  /// Deviation: upstream stores a Zod shape and converts it at serialization
  /// time via the MCP SDK. Dart has no Zod, so the already-built schema is
  /// stored directly; [serializeOmpHostTools] reproduces only upstream's
  /// empty-object default for a tool that declares none.
  final Map<String, Object?>? inputSchema;

  /// Implementation.
  final PaseoToolHandler handler;
}

/// The set of tools available to one caller.
///
/// An interface rather than a concrete map so a caller-scoped catalogue can
/// wrap another one — upstream builds these per agent, with voice-only and
/// subagent variants.
abstract interface class PaseoToolCatalog {
  /// Tools by name, in declaration order.
  Map<String, PaseoToolDefinition> get tools;

  /// Looks a tool up, or returns `null`.
  PaseoToolDefinition? getTool(String name);

  /// Runs a tool. Throws when [name] is unknown.
  Future<PaseoToolResult> executeTool(
    String name,
    Object? input, [
    PaseoToolExecutionContext context,
  ]);
}

/// Straightforward map-backed [PaseoToolCatalog].
final class PaseoToolMapCatalog implements PaseoToolCatalog {
  PaseoToolMapCatalog(List<PaseoToolDefinition> definitions)
    : tools = {for (final tool in definitions) tool.name: tool};

  @override
  final Map<String, PaseoToolDefinition> tools;

  @override
  PaseoToolDefinition? getTool(String name) => tools[name];

  @override
  Future<PaseoToolResult> executeTool(
    String name,
    Object? input, [
    PaseoToolExecutionContext context = const PaseoToolExecutionContext(),
  ]) async {
    final tool = tools[name];
    if (tool == null) throw StateError('Missing tool $name');
    return await tool.handler(input, context);
  }
}

const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

/// Renders structured content as the text the *model* will read.
///
/// Upstream prefixes the raw JSON with a compact summary of every array-valued
/// key — `<key>_count=N`, plus `<key>_ids=…` when every element carries a
/// string `id`. That summary exists so a model skimming a large tool result can
/// see how many items came back, and which, without parsing the JSON body.
String formatPaseoStructuredContentForModel(Object? structuredContent) {
  final record = _asRecord(structuredContent);
  if (record == null || structuredContent is List) {
    return _prettyJson.convert(structuredContent);
  }

  final summary = <String>[];
  for (final entry in record.entries) {
    final value = entry.value;
    if (value is! List) continue;
    summary.add('${entry.key}_count=${value.length}');
    final ids = <String>[];
    for (final item in value) {
      final itemRecord = item is List ? null : _asRecord(item);
      final id = itemRecord?['id'];
      if (id is String && id.isNotEmpty) ids.add(id);
    }
    if (ids.length == value.length && ids.isNotEmpty) {
      summary.add('${entry.key}_ids=${ids.join(',')}');
    }
  }

  final json = _prettyJson.convert(structuredContent);
  return summary.isEmpty ? json : '${summary.join('\n')}\n\n$json';
}

/// Gives a structured-only result a model-visible text block.
///
/// A tool that returns `{content: [], structuredContent: {...}}` would otherwise
/// look empty to the model, which sees only `content`. Results that already
/// carry content are returned untouched so a tool keeps full control of its own
/// prose.
PaseoToolResult addModelVisibleStructuredContent(PaseoToolResult result) {
  if (!result.hasStructuredContent || result.content.isNotEmpty) {
    return result;
  }
  return result.withContent([
    {
      'type': 'text',
      'text': formatPaseoStructuredContentForModel(result.structuredContent),
    },
  ]);
}

/// A tool as advertised to OMP through `set_host_tools`.
final class OmpHostToolDefinition {
  const OmpHostToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    this.label,
  });

  /// Wire name.
  final String name;

  /// Model-facing description.
  final String description;

  /// JSON Schema for the arguments.
  final Map<String, Object?> parameters;

  /// Human-facing label, omitted when the tool declares no title.
  final String? label;

  /// Wire form; `label` is emitted only when present, matching upstream's
  /// conditional assignment.
  Map<String, Object?> toJson() => {
    'name': name,
    if (label != null) 'label': label,
    'description': description,
    'parameters': parameters,
  };
}

/// A tool result OMP can consume.
final class OmpAgentToolResult {
  const OmpAgentToolResult({
    required this.content,
    Object? details = absentStructuredContent,
    this.isError,
  }) : _details = details;

  /// Content blocks, shallow-copied from the Paseo result so later mutation of
  /// the tool's own objects cannot rewrite an already-sent frame.
  final List<Map<String, Object?>> content;

  final Object? _details;

  /// Whether the call failed, or `null` when unspecified.
  final bool? isError;

  /// Whether a `details` key should appear on the wire at all.
  bool get hasDetails => !identical(_details, absentStructuredContent);

  /// Structured payload, or `null` when [hasDetails] is false.
  Object? get details => hasDetails ? _details : null;

  /// Projects a Paseo result onto OMP's shape.
  factory OmpAgentToolResult.fromPaseo(PaseoToolResult result) {
    final content = [
      for (final item in result.content) {...item},
    ];
    return result.hasStructuredContent
        ? OmpAgentToolResult(
            content: content,
            details: result.structuredContent,
            isError: result.isError,
          )
        : OmpAgentToolResult(content: content, isError: result.isError);
  }

  /// Wire form, omitting every field upstream would leave `undefined`.
  Map<String, Object?> toJson() => {
    'content': content,
    if (hasDetails) 'details': details,
    if (isError != null) 'isError': isError,
  };
}

/// A terminal `host_tool_result` frame.
final class OmpHostToolResultFrame {
  const OmpHostToolResultFrame({
    required this.id,
    required this.result,
    this.isError,
  });

  /// Correlates with the originating `host_tool_call`.
  final String id;

  /// The mapped result.
  final OmpAgentToolResult result;

  /// Mirrored to the frame's top level so OMP does not have to look inside
  /// [result]. Present only when the tool actually said.
  final bool? isError;

  /// Wire form.
  Map<String, Object?> toJson() => {
    'type': 'host_tool_result',
    'id': id,
    'result': result.toJson(),
    if (isError != null) 'isError': isError,
  };
}

/// A streaming `host_tool_update` frame.
final class OmpHostToolUpdateFrame {
  const OmpHostToolUpdateFrame({required this.id, required this.partialResult});

  /// Correlates with the originating `host_tool_call`.
  final String id;

  /// Partial result so far.
  final OmpAgentToolResult partialResult;

  /// Wire form.
  Map<String, Object?> toJson() => {
    'type': 'host_tool_update',
    'id': id,
    'partialResult': partialResult.toJson(),
  };
}

/// The half of an OMP session the host-tool router needs.
///
/// Narrowed from upstream's 25-method `OmpRuntimeSession` so the router can be
/// exercised — and the [Expando] keyed — without a process.
abstract interface class OmpHostToolSink {
  /// Sends a terminal result.
  void sendHostToolResult(OmpHostToolResultFrame result);

  /// Sends a partial result.
  void sendHostToolUpdate(OmpHostToolUpdateFrame update);
}

/// Serializes a caller-scoped catalogue for `set_host_tools`.
///
/// Order follows the catalogue's insertion order, which is how upstream's
/// `[...catalog.tools.values()]` behaves and what makes the advertised list
/// stable between sessions.
List<OmpHostToolDefinition> serializeOmpHostTools(PaseoToolCatalog catalog) => [
  for (final tool in catalog.tools.values)
    OmpHostToolDefinition(
      name: tool.name,
      description: tool.description,
      parameters:
          tool.inputSchema ??
          const {'type': 'object', 'properties': <String, Object?>{}},
      label: tool.title,
    ),
];

/// Advertises [catalog] to a live session and returns the names OMP accepted.
Future<List<String>> setOmpHostTools(
  OmpCliRuntimeSession runtimeSession,
  PaseoToolCatalog catalog,
) => runtimeSession.setHostTools(serializeOmpHostTools(catalog));

/// One router per session, discarded with the session.
///
/// [Expando] is Dart's `WeakMap`: it keeps no strong reference to the session,
/// so a dropped session takes its router with it even if [clearOmpHostToolState]
/// is never called.
final Expando<_OmpHostToolRouter> _ompHostToolRouters =
    Expando<_OmpHostToolRouter>('ompHostToolRouters');

/// Whether [event] is a host-tool frame this module owns.
bool isOmpHostToolEventType(String type) =>
    type == 'host_tool_call' ||
    type == 'host_tool_cancel' ||
    type == 'host_tool_update';

/// Handles one inbound frame, returning whether it was a host-tool frame.
///
/// Returning `true` for *malformed* host-tool frames as well as well-formed
/// ones is deliberate: the frame is claimed and dropped rather than falling
/// through to the generic event path, where a half-parsed `host_tool_call`
/// would surface to the user as an unknown event.
///
/// A call that arrives before [paseoTools] exists is answered with an error
/// result rather than ignored, so OMP is never left waiting on a tool the
/// daemon will never run.
bool handleOmpHostToolRuntimeEvent(
  Object? event, {
  required OmpHostToolSink runtimeSession,
  PaseoToolCatalog? paseoTools,
  PaseoRuntimeLogSink? logger,
}) {
  final record = _asRecord(event);
  final type = record?['type'];
  if (record == null || type is! String || !isOmpHostToolEventType(type)) {
    return false;
  }

  if (type == 'host_tool_call' && _isOmpHostToolCallRequest(record)) {
    final router = _ompHostToolRouter(
      runtimeSession: runtimeSession,
      paseoTools: paseoTools,
      logger: logger,
    );
    if (router == null) {
      runtimeSession.sendHostToolResult(
        _toOmpHostToolErrorResult(
          record['id']! as String,
          'Host tool "${record['toolName']}" was called before Paseo tools '
          'were registered',
        ),
      );
      return true;
    }
    router.handleCall(record);
    return true;
  }

  if (type == 'host_tool_cancel' && _isOmpHostToolCancelRequest(record)) {
    _ompHostToolRouter(
      runtimeSession: runtimeSession,
      paseoTools: paseoTools,
      logger: logger,
    )?.handleCancel(record['targetId']! as String);
    return true;
  }

  if (type == 'host_tool_update' && _isOmpHostToolUpdate(record)) {
    logger?.call('Ignoring unexpected inbound OMP host tool update', {
      'id': record['id'],
    });
    return true;
  }

  logger?.call('Dropped malformed OMP host tool frame', {'event': record});
  return true;
}

/// Aborts every in-flight call for [runtimeSession] and forgets its router.
void clearOmpHostToolState(OmpHostToolSink runtimeSession) {
  _ompHostToolRouters[runtimeSession]?.clear();
  _ompHostToolRouters[runtimeSession] = null;
}

/// Resolves once no host tool is running for [runtimeSession].
///
/// Used before tearing a session down so a tool's side effects finish — or its
/// abort propagates — before the transport disappears.
Future<void> waitForOmpHostToolsIdle(OmpHostToolSink runtimeSession) async {
  await _ompHostToolRouters[runtimeSession]?.waitForIdle();
}

_OmpHostToolRouter? _ompHostToolRouter({
  required OmpHostToolSink runtimeSession,
  required PaseoToolCatalog? paseoTools,
  required PaseoRuntimeLogSink? logger,
}) {
  if (paseoTools == null) return null;
  final existing = _ompHostToolRouters[runtimeSession];
  if (existing != null) return existing;
  final router = _OmpHostToolRouter(
    runtimeSession: runtimeSession,
    catalog: paseoTools,
    logger: logger,
  );
  _ompHostToolRouters[runtimeSession] = router;
  return router;
}

final class _PendingOmpHostToolCall {
  _PendingOmpHostToolCall();

  final PaseoToolCancellation cancellation = PaseoToolCancellation();
  bool canceled = false;
}

final class _OmpHostToolRouter {
  _OmpHostToolRouter({
    required this.runtimeSession,
    required this.catalog,
    required this.logger,
  });

  final OmpHostToolSink runtimeSession;
  final PaseoToolCatalog catalog;
  final PaseoRuntimeLogSink? logger;
  final Map<String, _PendingOmpHostToolCall> _pendingCalls = {};
  final List<Completer<void>> _idleWaiters = [];

  void handleCall(Map<String, Object?> request) {
    final id = request['id']! as String;
    final entry = _PendingOmpHostToolCall();
    _pendingCalls[id] = entry;
    unawaited(
      _executeCall(request, entry).catchError((Object error) {
        logger?.call('OMP host tool call failed', {
          'err': error,
          'toolName': request['toolName'],
        });
      }),
    );
  }

  void handleCancel(String targetId) {
    final pending = _pendingCalls[targetId];
    if (pending == null) return;
    pending.canceled = true;
    pending.cancellation._abort(
      StateError('OMP host tool call $targetId cancelled'),
    );
  }

  void clear() {
    for (final pending in _pendingCalls.values) {
      pending.canceled = true;
      pending.cancellation._abort(StateError('OMP session closed'));
    }
    _pendingCalls.clear();
    _resolveIdleWaiters();
  }

  Future<void> waitForIdle() {
    if (_pendingCalls.isEmpty) return Future<void>.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  Future<void> _executeCall(
    Map<String, Object?> request,
    _PendingOmpHostToolCall entry,
  ) async {
    final id = request['id']! as String;
    try {
      final result = await catalog.executeTool(
        request['toolName']! as String,
        request['arguments'],
        PaseoToolExecutionContext(
          cancellation: entry.cancellation,
          sendUpdate: (update) {
            if (entry.canceled || entry.cancellation.isAborted) return;
            _sendUpdate(id, update);
          },
        ),
      );
      if (entry.canceled || entry.cancellation.isAborted) return;
      runtimeSession.sendHostToolResult(_toOmpHostToolResult(id, result));
    } on Object catch (error) {
      if (entry.canceled || entry.cancellation.isAborted) return;
      runtimeSession.sendHostToolResult(_toOmpHostToolErrorResult(id, error));
    } finally {
      _pendingCalls.remove(id);
      _resolveIdleWaiters();
    }
  }

  void _resolveIdleWaiters() {
    if (_pendingCalls.isNotEmpty) return;
    for (final waiter in _idleWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _idleWaiters.clear();
  }

  void _sendUpdate(String callId, PaseoToolResult result) {
    runtimeSession.sendHostToolUpdate(
      OmpHostToolUpdateFrame(
        id: callId,
        partialResult: OmpAgentToolResult.fromPaseo(
          addModelVisibleStructuredContent(result),
        ),
      ),
    );
  }
}

OmpHostToolResultFrame _toOmpHostToolResult(String id, PaseoToolResult result) {
  final modelVisible = addModelVisibleStructuredContent(result);
  return OmpHostToolResultFrame(
    id: id,
    result: OmpAgentToolResult.fromPaseo(modelVisible),
    isError: modelVisible.isError,
  );
}

/// Builds the failure frame OMP receives when a host tool throws.
///
/// Both the inner and the outer `isError` are set: OMP reads the outer flag to
/// decide the card's status and the model reads the inner text.
OmpHostToolResultFrame _toOmpHostToolErrorResult(String id, Object error) {
  final message = error is StateError
      ? error.message
      : (error is Exception || error is Error)
      ? _errorMessage(error)
      : '$error';
  return OmpHostToolResultFrame(
    id: id,
    result: OmpAgentToolResult(
      content: [
        {'type': 'text', 'text': message},
      ],
      details: const <String, Object?>{},
      isError: true,
    ),
    isError: true,
  );
}

/// Upstream's `error instanceof Error ? error.message : String(error)`.
///
/// Dart has no single `Error.message`, so the common carriers are unwrapped and
/// everything else falls back to `toString()`.
String _errorMessage(Object error) => switch (error) {
  StateError() => error.message,
  ArgumentError() => '${error.message}',
  FormatException() => error.message,
  _ => '$error',
};

bool _isOmpHostToolCallRequest(Map<String, Object?> event) =>
    event['id'] is String &&
    event['toolCallId'] is String &&
    event['toolName'] is String &&
    _asRecord(event['arguments']) != null;

bool _isOmpHostToolCancelRequest(Map<String, Object?> event) =>
    event['id'] is String && event['targetId'] is String;

bool _isOmpHostToolUpdate(Map<String, Object?> event) =>
    event['id'] is String && _isOmpAgentToolResult(event['partialResult']);

bool _isOmpAgentToolResult(Object? value) {
  final record = _asRecord(value);
  if (record == null) return false;
  final content = record['content'];
  if (content is! List) return false;
  for (final block in content) {
    final chunk = _asRecord(block);
    if (chunk == null || chunk['type'] is! String) return false;
    if (!_optStr(chunk, 'text')) return false;
  }
  return _optBool(record, 'isError');
}

// ===========================================================================
// omp/rpc-types.ts — the validation surface omp/cli-runtime.ts depends on
// ===========================================================================

/// OMP's validated `get_state` reply.
///
/// Validation is the point of this type: OMP's stdout is an untrusted transport
/// and upstream deliberately rejects a malformed state rather than letting a
/// `"no"` string flow into an `isStreaming` boolean downstream. Unknown keys ride
/// through in [raw] because every upstream schema is `.passthrough()`.
final class OmpRpcSessionState {
  const OmpRpcSessionState({
    required this.sessionId,
    required this.isStreaming,
    required this.isCompacting,
    required this.messageCount,
    required this.queuedMessageCount,
    required this.raw,
    this.model,
    this.thinkingLevel,
    this.autoCompactionEnabled,
    this.sessionFile,
    this.sessionName,
    this.contextUsage,
    this.todoPhases,
  });

  /// OMP's id for the live session.
  final String sessionId;

  /// Whether a turn is streaming right now.
  final bool isStreaming;

  /// Whether a compaction is running right now.
  final bool isCompacting;

  /// Messages in the transcript.
  final num messageCount;

  /// Messages queued behind the current turn.
  final num queuedMessageCount;

  /// Selected model, as OMP reported it. Left raw — the model envelope is wide
  /// and nothing in this cluster reads inside it.
  final Map<String, Object?>? model;

  /// Thinking level, absent for models that encode effort in the model id and
  /// are therefore marked `reasoning: false`.
  final String? thinkingLevel;

  /// Whether OMP compacts on its own.
  final bool? autoCompactionEnabled;

  /// Path of the session transcript on disk.
  final String? sessionFile;

  /// Human-assigned session name.
  final String? sessionName;

  /// Context-window accounting.
  final OmpContextUsage? contextUsage;

  /// Raw `todoPhases`, validated lazily by the todo mapper.
  final Object? todoPhases;

  /// Every key OMP sent, unknown ones included.
  final Map<String, Object?> raw;

  /// Narrows to the value type `paseo_provider_mappers.dart` consumes, so
  /// `mapOmpUsage` and `mapOmpTodoState` can be fed straight from a live state.
  OmpSessionState toSessionState() =>
      OmpSessionState(contextUsage: contextUsage, todoPhases: todoPhases);
}

/// Parses and validates a `get_state` reply.
///
/// Throws [FormatException] rather than returning `null` because upstream calls
/// the schema's throwing `.parse`, and a caller awaiting `getState()` must see
/// the rejection instead of a silently empty state.
OmpRpcSessionState parseOmpSessionState(Object? data) {
  final record = _asRecord(data);
  if (record == null ||
      !_optNullableRecord(record, 'model') ||
      !_isOptionalOmpThinkingLevel(record) ||
      record['isStreaming'] is! bool ||
      record['isCompacting'] is! bool ||
      !_optBool(record, 'autoCompactionEnabled') ||
      !_optStr(record, 'sessionFile') ||
      record['sessionId'] is! String ||
      !_optStr(record, 'sessionName') ||
      !_isNonNegativeInt(record['messageCount']) ||
      !_isNonNegativeInt(record['queuedMessageCount']) ||
      !_isOptionalOmpContextUsage(record)) {
    throw const FormatException('Malformed OMP session state');
  }
  return OmpRpcSessionState(
    sessionId: record['sessionId']! as String,
    isStreaming: record['isStreaming']! as bool,
    isCompacting: record['isCompacting']! as bool,
    messageCount: record['messageCount']! as num,
    queuedMessageCount: record['queuedMessageCount']! as num,
    model: _asRecord(record['model']),
    thinkingLevel: record['thinkingLevel'] as String?,
    autoCompactionEnabled: record['autoCompactionEnabled'] as bool?,
    sessionFile: record['sessionFile'] as String?,
    sessionName: record['sessionName'] as String?,
    contextUsage: _readOmpContextUsage(record['contextUsage']),
    todoPhases: record['todoPhases'],
    raw: record,
  );
}

/// OMP's thinking-budget vocabulary.
const Set<String> ompThinkingLevels = {
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
};

bool _isOptionalOmpThinkingLevel(Map<String, Object?> json) =>
    !json.containsKey('thinkingLevel') ||
    ompThinkingLevels.contains(json['thinkingLevel']);

bool _isOptionalOmpContextUsage(Map<String, Object?> json) {
  if (!json.containsKey('contextUsage')) return true;
  final usage = _asRecord(json['contextUsage']);
  if (usage == null) return false;
  return _optNullableNum(usage, 'tokens') &&
      _optNullableNum(usage, 'contextWindow') &&
      _optNullableNum(usage, 'percent');
}

OmpContextUsage? _readOmpContextUsage(Object? value) {
  final usage = _asRecord(value);
  if (usage == null) return null;
  return OmpContextUsage(
    tokens: usage['tokens'] as num?,
    contextWindow: usage['contextWindow'] as num?,
    percent: usage['percent'] as num?,
  );
}

/// Token, cost and context accounting for a live session.
///
/// Shared by both runtimes: `omp/cli-runtime.ts` and `pi/cli-runtime.ts` declare
/// byte-identical `*SessionStats` shapes and byte-identical fallback logic, so
/// one type and one fallback serve both.
final class ProviderSessionStats {
  const ProviderSessionStats({
    this.tokens,
    this.cost,
    this.contextUsage,
    this.raw = const {},
  });

  /// Cumulative token counts (`input`, `output`, `cacheRead`, `cacheWrite`,
  /// `total`). Left as a map: the shape is `.passthrough()` upstream and every
  /// consumer reads named keys out of it.
  final Map<String, Object?>? tokens;

  /// Cumulative cost in USD. `0` is a real, reported value — see
  /// [resolveProviderSessionStats].
  final num? cost;

  /// Current context-window occupancy.
  final OmpContextUsage? contextUsage;

  /// Everything the provider sent.
  final Map<String, Object?> raw;

  /// Whether the provider reported nothing usable at all.
  bool get isEmpty => tokens == null && cost == null && contextUsage == null;
}

/// Reads a `get_session_stats` reply, validating when [strict] is set.
///
/// [strict] is what separates the two runtimes: OMP parses through a Zod schema
/// (so a malformed reply throws and triggers the fallback), while Pi casts the
/// payload unchecked.
ProviderSessionStats parseProviderSessionStats(
  Object? data, {
  required bool strict,
}) {
  final record = _asRecord(data);
  if (record == null) {
    if (strict) throw const FormatException('Malformed provider session stats');
    return const ProviderSessionStats();
  }
  if (strict) {
    final tokens = record.containsKey('tokens')
        ? _asRecord(record['tokens'])
        : null;
    if (record.containsKey('tokens') && tokens == null) {
      throw const FormatException('Malformed provider session stats tokens');
    }
    if (tokens != null) {
      for (final key in const [
        'input',
        'output',
        'cacheRead',
        'cacheWrite',
        'total',
      ]) {
        if (!_optNum(tokens, key)) {
          throw const FormatException(
            'Malformed provider session stats tokens',
          );
        }
      }
    }
    if (!_optNum(record, 'cost') || !_isOptionalOmpContextUsage(record)) {
      throw const FormatException('Malformed provider session stats');
    }
  }
  return ProviderSessionStats(
    tokens: _asRecord(record['tokens']),
    cost: record['cost'] as num?,
    contextUsage: _readOmpContextUsage(record['contextUsage']),
    raw: record,
  );
}

/// COMPAT(providerGetStateFallback): `get_session_stats` was added in v0.1.105.
///
/// Older OMP and Oh My Pi binaries reject the RPC outright, so a session against
/// one would silently show no context-window meter. When the dedicated RPC is
/// missing *or* returns nothing usable, `get_state` is asked for its
/// `contextUsage` instead — the one number that matters for the meter.
///
/// The emptiness test is `tokens == null && cost == null && contextUsage == null`
/// on purpose: a reported `cost: 0` is a real answer from a session that has not
/// spent anything yet and must not trigger a second round trip.
///
/// Upstream schedules its removal after 2027-01-10, once the supported binary
/// floor includes the RPC.
///
/// Both callbacks may throw; each failure is swallowed exactly as upstream's
/// bare `catch {}` does, and a total failure yields empty stats rather than an
/// error, because usage reporting must never fail a turn.
Future<ProviderSessionStats> resolveProviderSessionStats({
  required Future<ProviderSessionStats> Function() getSessionStats,
  required Future<OmpContextUsage?> Function() getStateContextUsage,
}) async {
  ProviderSessionStats? stats;
  try {
    stats = await getSessionStats();
  } on Object {
    // get_session_stats not supported by this binary — try get_state below.
  }
  if (stats == null || stats.isEmpty) {
    try {
      final usage = await getStateContextUsage();
      if (usage != null) {
        return ProviderSessionStats(
          contextUsage: OmpContextUsage(
            tokens: usage.tokens,
            contextWindow: usage.contextWindow,
          ),
        );
      }
    } on Object {
      // get_state also failed — nothing we can do.
    }
  }
  return stats ?? const ProviderSessionStats();
}

/// Acknowledgement of a `prompt` command.
final class ProviderPromptAck {
  const ProviderPromptAck({required this.requestId, this.agentInvoked});

  /// Transport request id, minted locally and correlated with later events.
  final String requestId;

  /// Whether the prompt actually started a turn; `null` when the binary is old
  /// enough not to say.
  final bool? agentInvoked;
}

/// Every runtime-event `type` OMP's discriminated union accepts.
///
/// Membership is the first half of the drop rule: an unrecognised `type` never
/// reaches subscribers, so a future OMP can add frames without this daemon
/// surfacing them as garbage. The second half is per-type field validation in
/// [parseOmpRuntimeEvent].
Set<String> get ompKnownRuntimeEventTypes =>
    _ompRuntimeEventValidators.keys.toSet();

/// Validates an inbound OMP stdout frame.
///
/// Returns the frame unchanged when it matches a known event shape, and `null`
/// otherwise. Unknown keys survive because every upstream schema is
/// `.passthrough()`.
Map<String, Object?>? parseOmpRuntimeEvent(Object? frame) {
  final record = _asRecord(frame);
  final type = record?['type'];
  if (record == null || type is! String) return null;
  final validator = _ompRuntimeEventValidators[type];
  if (validator == null) return null;
  return validator(record) ? record : null;
}

bool _always(Map<String, Object?> event) => true;

/// The `agent_session` half of the union, also reused for `subagent_event`.
final Map<String, bool Function(Map<String, Object?>)>
_ompAgentSessionEventValidators = {
  'agent_start': _always,
  'turn_start': _always,
  'message_start': (event) => isOmpAgentMessage(event['message']),
  'message_end': (event) => isOmpAgentMessage(event['message']),
  'message_update': (event) =>
      isOmpAgentMessage(event['message']) &&
      _isOmpAssistantMessageEvent(event['assistantMessageEvent']),
  'tool_execution_start': (event) =>
      event['toolCallId'] is String && event['toolName'] is String,
  'tool_execution_update': (event) =>
      event['toolCallId'] is String && event['toolName'] is String,
  'tool_execution_end': (event) =>
      event['toolCallId'] is String &&
      event['toolName'] is String &&
      _optBool(event, 'isError'),
  'compaction_start': (event) => _optStr(event, 'reason'),
  'compaction_end': (event) =>
      _optStr(event, 'reason') &&
      _optStr(event, 'errorMessage') &&
      _optBool(event, 'aborted'),
  'agent_end': (event) => _optListOf(event, 'messages', isOmpAgentMessage),
};

final Map<String, bool Function(Map<String, Object?>)>
_ompRuntimeEventValidators = {
  ..._ompAgentSessionEventValidators,
  'extension_ui_request': (event) =>
      event['id'] is String &&
      event['method'] is String &&
      _optStr(event, 'title') &&
      _optStr(event, 'message') &&
      _optListOf(event, 'options', (option) => option is String) &&
      _optStr(event, 'placeholder') &&
      _optStr(event, 'url') &&
      _optStr(event, 'launchUrl') &&
      _optStr(event, 'instructions'),
  'command_output': (event) => _optStr(event, 'text'),
  'prompt_result': (event) =>
      _optStr(event, 'id') && _optBool(event, 'agentInvoked'),
  'process_exit': (event) => event['error'] is String,
  'subagent_lifecycle': (event) =>
      _isOmpSubagentLifecyclePayload(event['payload']),
  'subagent_progress': (event) =>
      _isOmpSubagentProgressPayload(event['payload']),
  'subagent_event': (event) => _isOmpSubagentEventPayload(event['payload']),
  'todo_reminder': (event) => _isListOf(event['todos'], _isOmpTodoItem),
  'notice': (event) =>
      const {'info', 'warning', 'error'}.contains(event['level']) &&
      event['message'] is String &&
      _optStr(event, 'source'),
  'goal_updated': (event) =>
      _optNullableRecord(event, 'goal') && _optRecord(event, 'state'),
  'auto_retry_start': (event) =>
      _isNonNegativeInt(event['attempt']) &&
      _isPositiveInt(event['maxAttempts']) &&
      _isNonNegativeInt(event['delayMs']) &&
      event['errorMessage'] is String,
  'auto_retry_end': (event) =>
      event['success'] is bool &&
      _isNonNegativeInt(event['attempt']) &&
      _optStr(event, 'finalError'),
  'retry_fallback_applied': (event) =>
      event['from'] is String &&
      event['to'] is String &&
      event['role'] is String,
  'retry_fallback_succeeded': (event) =>
      event['model'] is String && event['role'] is String,
  'auto_compaction_start': (event) =>
      event['reason'] is String && event['action'] is String,
  'auto_compaction_end': (event) =>
      _optStr(event, 'action') &&
      event['aborted'] is bool &&
      event['willRetry'] is bool &&
      _optStr(event, 'errorMessage') &&
      _optBool(event, 'skipped'),
  'available_commands_update': (event) =>
      _isListOf(event['commands'], _isOmpAvailableCommand),
  'host_tool_call': _isOmpHostToolCallRequest,
  'host_tool_cancel': _isOmpHostToolCancelRequest,
  'host_tool_update': _isOmpHostToolUpdate,
};

bool _isOmpAssistantMessageEvent(Object? value) {
  final record = _asRecord(value);
  final type = record?['type'];
  if (record == null || type is! String) return false;
  return switch (type) {
    'text_delta' || 'thinking_delta' => _optStr(record, 'delta'),
    'start' ||
    'text_start' ||
    'text_end' ||
    'thinking_start' ||
    'thinking_end' ||
    'done' => true,
    _ => false,
  };
}

/// Whether [value] matches OMP's `AgentMessage` discriminated union.
///
/// Exposed because the same union gates `message_start`/`message_end`,
/// `agent_end.messages` and the `get_messages` reply, and because a history
/// replay needs the same acceptance test the live path uses.
bool isOmpAgentMessage(Object? value) {
  final record = _asRecord(value);
  final role = record?['role'];
  if (record == null || role is! String) return false;
  return switch (role) {
    'user' || 'custom' => _isOmpUserContent(record['content']),
    'assistant' =>
      _isListOf(record['content'], _isOmpAssistantContent) &&
          _optStr(record, 'provider') &&
          _optStr(record, 'model') &&
          _optStr(record, 'responseId') &&
          _optStr(record, 'responseModel') &&
          _optNullableStr(record, 'errorMessage') &&
          _optStr(record, 'stopReason'),
    'toolResult' =>
      record['toolCallId'] is String &&
          record['toolName'] is String &&
          _optBool(record, 'isError'),
    'bashExecution' =>
      record['command'] is String &&
          _optStr(record, 'output') &&
          _optNullableNum(record, 'exitCode') &&
          _optBool(record, 'cancelled') &&
          record['timestamp'] is num,
    _ => false,
  };
}

bool _isOmpUserContent(Object? content) {
  if (content is String) return true;
  return _isListOf(
    content,
    (block) => _isOmpTextContent(block) || _isOmpImageContent(block),
  );
}

bool _isOmpTextContent(Object? value) {
  final record = _asRecord(value);
  return record != null && record['type'] == 'text' && record['text'] is String;
}

bool _isOmpImageContent(Object? value) {
  final record = _asRecord(value);
  return record != null &&
      record['type'] == 'image' &&
      record['data'] is String &&
      record['mimeType'] is String;
}

bool _isOmpAssistantContent(Object? value) {
  final record = _asRecord(value);
  final type = record?['type'];
  if (record == null || type is! String) return false;
  return switch (type) {
    'text' => record['text'] is String,
    'thinking' => record['thinking'] is String,
    'toolCall' => record['id'] is String && record['name'] is String,
    _ => false,
  };
}

const Set<String> _ompSubagentStatuses = {
  'pending',
  'running',
  'completed',
  'failed',
  'aborted',
};

bool _isOmpSubagentLifecyclePayload(Object? value) {
  final record = _asRecord(value);
  if (record == null) return false;
  return record['id'] is String &&
      record['agent'] is String &&
      _optStr(record, 'agentSource') &&
      _optStr(record, 'description') &&
      const {
        'started',
        'completed',
        'failed',
        'aborted',
      }.contains(record['status']) &&
      _optStr(record, 'sessionFile') &&
      _optStr(record, 'parentToolCallId') &&
      _isNonNegativeInt(record['index']) &&
      _optBool(record, 'detached');
}

bool _isOmpSubagentProgressPayload(Object? value) {
  final record = _asRecord(value);
  if (record == null) return false;
  final progress = _asRecord(record['progress']);
  if (progress == null) return false;
  return _isNonNegativeInt(record['index']) &&
      record['agent'] is String &&
      _optStr(record, 'agentSource') &&
      record['task'] is String &&
      _optStr(record, 'parentToolCallId') &&
      _optStr(record, 'assignment') &&
      _optStr(record, 'sessionFile') &&
      _optBool(record, 'detached') &&
      progress['id'] is String &&
      _ompSubagentStatuses.contains(progress['status']) &&
      _optStr(progress, 'description') &&
      _optStr(progress, 'resolvedModel');
}

bool _isOmpSubagentEventPayload(Object? value) {
  final record = _asRecord(value);
  if (record == null || record['id'] is! String) return false;
  final inner = _asRecord(record['event']);
  final type = inner?['type'];
  if (inner == null || type is! String) return false;
  final validator = _ompAgentSessionEventValidators[type];
  return validator != null && validator(inner);
}

bool _isOmpTodoItem(Object? value) {
  final record = _asRecord(value);
  return record != null &&
      record['content'] is String &&
      const {
        'pending',
        'in_progress',
        'completed',
        'abandoned',
      }.contains(record['status']);
}

bool _isOmpAvailableCommand(Object? value) {
  final record = _asRecord(value);
  return record != null &&
      record['name'] is String &&
      _optStr(record, 'description') &&
      _optStr(record, 'source');
}

/// Validates an OMP model descriptor and returns it unchanged.
///
/// Returns `null` when the descriptor is malformed. `maxTokens` is explicitly
/// nullable: newer OMP binaries report `null` for models whose ceiling they do
/// not know, and rejecting that would blank the whole model picker.
Map<String, Object?>? parseOmpModel(Object? value) {
  final record = _asRecord(value);
  if (record == null) return null;
  final ok =
      record['provider'] is String &&
      record['id'] is String &&
      _optStr(record, 'name') &&
      _optBool(record, 'reasoning') &&
      _optNum(record, 'contextWindow') &&
      _optNullableNum(record, 'maxTokens') &&
      _optStr(record, 'api') &&
      _optStr(record, 'baseUrl') &&
      _optListOf(record, 'input', (item) => item is String) &&
      _optRecord(record, 'cost');
  return ok ? record : null;
}

/// Validates an OMP slash command, reusing the value type
/// `paseo_provider_mappers.dart` already declares for the command catalogue.
OmpRpcSlashCommand? parseOmpRpcSlashCommand(Object? value) {
  final record = _asRecord(value);
  if (record == null || record['name'] is! String) return null;
  if (!_optStr(record, 'description') ||
      !_optStr(record, 'source') ||
      !_optRecord(record, 'sourceInfo')) {
    return null;
  }
  if (record.containsKey('input') && record['input'] != null) {
    final input = _asRecord(record['input']);
    if (input == null || !_optStr(input, 'hint')) return null;
    return OmpRpcSlashCommand(
      name: record['name']! as String,
      description: record['description'] as String?,
      source: record['source'] as String?,
      input: OmpCommandInput(hint: input['hint'] as String?),
    );
  }
  return OmpRpcSlashCommand(
    name: record['name']! as String,
    description: record['description'] as String?,
    source: record['source'] as String?,
  );
}

// ===========================================================================
// omp/cli-runtime.ts
// ===========================================================================

/// Environment variable that overrides the OMP executable.
const String ompCommandEnvVar = 'OMP_COMMAND';

/// Environment variables that override the Pi executable, in precedence order.
const List<String> piCommandEnvVars = ['PI_COMMAND', 'PI_ACP_PI_COMMAND'];

/// Resolves the default OMP command tuple.
///
/// [environment] is injected rather than read from [Platform.environment] so the
/// decision stays testable and so a daemon can hand a session a scrubbed
/// environment.
List<String> defaultOmpCommand([Map<String, String>? environment]) {
  final override = environment?[ompCommandEnvVar];
  return [_isJsTruthy(override) ? override! : 'omp'];
}

/// Resolves the default Pi command tuple.
///
/// `PI_COMMAND` wins over `PI_ACP_PI_COMMAND`, which exists so a machine already
/// configured for Pi's ACP bridge does not need a second variable.
List<String> defaultPiCommand([Map<String, String>? environment]) {
  for (final key in piCommandEnvVars) {
    final override = environment?[key];
    if (_isJsTruthy(override)) return [override!];
  }
  return ['pi'];
}

/// The only slash-command RPC name OMP accepts.
const String ompCommandsRpcName = 'get_available_commands';

/// Pi's slash-command RPC name, which differs from OMP's.
const String piCommandsRpcName = 'get_commands';

/// Spawner signature for an OMP launch.
typedef OmpProcessStarter = Future<Process> Function(OmpRuntimeLaunch launch);

/// Construction options for [OmpCliRuntime].
final class OmpCliRuntimeOptions {
  const OmpCliRuntimeOptions({
    this.logger,
    this.runtimeSettings,
    this.command,
    this.commandsRpcName = ompCommandsRpcName,
    this.spawnProcess,
    this.environment,
  });

  /// Diagnostic sink; silent when omitted.
  final PaseoRuntimeLogSink? logger;

  /// User overrides for the command and environment.
  final ProviderRuntimeSettings? runtimeSettings;

  /// Executable-and-args tuple; defaults to [defaultOmpCommand].
  final List<String>? command;

  /// Slash-command RPC name. Only [ompCommandsRpcName] is meaningful; it is a
  /// parameter because upstream types it as a one-member union so a future
  /// rename is a single-line change.
  final String commandsRpcName;

  /// Process starter. Injected so a launch can be asserted without spawning.
  final OmpProcessStarter? spawnProcess;

  /// Environment consulted for [ompCommandEnvVar].
  final Map<String, String>? environment;
}

/// Drives an `omp --mode rpc` child process.
///
/// Every reply is schema-validated on the way in: OMP's stdout is a foreign
/// process's output, and upstream would rather fail a command than let a
/// half-typed payload reach the timeline.
final class OmpCliRuntime {
  OmpCliRuntime(this.options);

  /// Construction options.
  final OmpCliRuntimeOptions options;

  /// Resolved executable tuple.
  List<String> get command =>
      options.command ?? defaultOmpCommand(options.environment);

  /// Spawns OMP and wraps the transport in a session facade.
  Future<OmpCliRuntimeSession> startSession(OmpStartSessionInput input) async {
    final launch = buildOmpLaunch(
      command: command,
      runtimeSettings: options.runtimeSettings,
      session: input,
    );
    final spawn = options.spawnProcess;
    final process = await JsonlRpcProcess.start(
      launch: JsonlRpcLaunch(
        command: launch.argv.first,
        args: launch.argv.skip(1).toList(growable: false),
        cwd: launch.cwd,
        environment: launch.env ?? const {},
      ),
      diagnosticName: 'OMP RPC',
      onWarning: options.logger == null
          ? null
          : (message, error, line) =>
                options.logger!(message, {'err': error, 'line': line}),
      spawn: spawn == null ? null : (_) => spawn(launch),
    );
    return OmpCliRuntimeSession(process, options.commandsRpcName);
  }
}

/// RPC facade over one OMP process.
final class OmpCliRuntimeSession implements OmpHostToolSink {
  /// Subscribes to transport frames and turns the process exit into a
  /// synthetic `process_exit` event, so a caller watching [onEvent] learns
  /// about the death without also watching the transport.
  OmpCliRuntimeSession(this._process, this._commandsRpcName) {
    _process.onMessage((message) {
      final event = parseOmpRuntimeEvent(message);
      if (event != null) _emit(event);
    });
    _process.onExit((exit) {
      _emit({'type': 'process_exit', 'error': exit.error.message});
    });
  }

  final JsonlRpcProcess _process;
  final String _commandsRpcName;
  final Set<void Function(Map<String, Object?>)> _subscribers = {};

  /// Entry the session was last branched from, or `null` on the main line.
  String? activeBranchEntryId;

  /// Subscribes to validated runtime events; call the result to unsubscribe.
  void Function() onEvent(void Function(Map<String, Object?> event) callback) {
    _subscribers.add(callback);
    return () => _subscribers.remove(callback);
  }

  /// Sends a prompt and returns the ack.
  ///
  /// The `requestId` is the *transport's* id, minted before the frame is sent,
  /// so events that reference it can be correlated even if OMP's own ack is
  /// empty — which is exactly what OMP 17 returns.
  Future<ProviderPromptAck> prompt(
    String message, {
    List<Map<String, Object?>>? images,
  }) async {
    final handle = _process.startRequest({
      'type': 'prompt',
      'message': message,
      if (images != null && images.isNotEmpty) 'images': images,
    });
    final data = await handle.response;
    if (data == null) return ProviderPromptAck(requestId: handle.id);
    final record = _asRecord(data);
    if (record == null || !_optBool(record, 'agentInvoked')) {
      throw const FormatException('Malformed OMP prompt acknowledgement');
    }
    return ProviderPromptAck(
      requestId: handle.id,
      agentInvoked: record['agentInvoked'] as bool?,
    );
  }

  /// Requests a context compaction.
  Future<void> compact([String? customInstructions]) async {
    await _request({
      'type': 'compact',
      if (_isJsTruthy(customInstructions))
        'customInstructions': customInstructions,
    });
  }

  /// Turns OMP's own compaction on or off.
  Future<void> setAutoCompaction(bool enabled) async {
    await _request({'type': 'set_auto_compaction', 'enabled': enabled});
  }

  /// Interrupts the running turn.
  Future<void> abort() async {
    await _request({'type': 'abort'});
  }

  /// Reads and validates the session state.
  Future<OmpRpcSessionState> getState() async =>
      parseOmpSessionState(await _request({'type': 'get_state'}));

  /// Reads the transcript, dropping nothing: a malformed message rejects the
  /// whole reply, matching upstream's array schema.
  Future<List<Map<String, Object?>>> getMessages() async {
    final data = _asRecord(await _request({'type': 'get_messages'}));
    if (data == null) throw const FormatException('Malformed OMP messages');
    final messages = data['messages'];
    if (messages == null) return const [];
    if (!_isListOf(messages, isOmpAgentMessage)) {
      throw const FormatException('Malformed OMP messages');
    }
    return [for (final message in messages as List) _asRecord(message)!];
  }

  /// Lists available models.
  ///
  /// [timeout] follows [JsonlRpcProcess]'s convention: omitted uses the 30s
  /// control-plane default, `null` waits indefinitely. Model discovery can
  /// require a network round trip, which is why upstream lets callers extend it.
  Future<List<Map<String, Object?>>> getAvailableModels({
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) async {
    final data = _asRecord(
      await _request({'type': 'get_available_models'}, timeout: timeout),
    );
    if (data == null) throw const FormatException('Malformed OMP models');
    final models = data['models'];
    if (models == null) return const [];
    if (models is! List) throw const FormatException('Malformed OMP models');
    final parsed = <Map<String, Object?>>[];
    for (final model in models) {
      final validated = parseOmpModel(model);
      if (validated == null) {
        throw const FormatException('Malformed OMP models');
      }
      parsed.add(validated);
    }
    return parsed;
  }

  /// Pins the model for subsequent turns.
  Future<Map<String, Object?>> setModel(String provider, String modelId) async {
    final model = parseOmpModel(
      await _request({
        'type': 'set_model',
        'provider': provider,
        'modelId': modelId,
      }),
    );
    if (model == null) throw const FormatException('Malformed OMP model');
    return model;
  }

  /// Pins the thinking budget.
  Future<void> setThinkingLevel(String level) async {
    if (!ompThinkingLevels.contains(level)) {
      throw FormatException('Unknown OMP thinking level: $level');
    }
    await _request({'type': 'set_thinking_level', 'level': level});
  }

  /// Reads usage totals, falling back to `get_state` on older binaries.
  Future<ProviderSessionStats> getSessionStats() => resolveProviderSessionStats(
    getSessionStats: () async => parseProviderSessionStats(
      await _request({'type': 'get_session_stats'}),
      strict: true,
    ),
    getStateContextUsage: () async => (await getState()).contextUsage,
  );

  /// Lists slash commands through OMP's `get_available_commands` RPC.
  Future<List<OmpRpcSlashCommand>> getCommands() async {
    final data = _asRecord(await _request({'type': _commandsRpcName}));
    if (data == null) throw const FormatException('Malformed OMP commands');
    final commands = data['commands'];
    if (commands == null) return const [];
    if (commands is! List)
      throw const FormatException('Malformed OMP commands');
    final parsed = <OmpRpcSlashCommand>[];
    for (final command in commands) {
      final validated = parseOmpRpcSlashCommand(command);
      if (validated == null) {
        throw const FormatException('Malformed OMP commands');
      }
      parsed.add(validated);
    }
    return parsed;
  }

  /// Chooses how much subagent activity OMP streams back.
  Future<void> setSubagentSubscription(String level) async {
    await _request({'type': 'set_subagent_subscription', 'level': level});
  }

  /// Advertises host tools and returns the names OMP accepted.
  Future<List<String>> setHostTools(List<OmpHostToolDefinition> tools) async {
    final data = _asRecord(
      await _request({
        'type': 'set_host_tools',
        'tools': [for (final tool in tools) tool.toJson()],
      }),
    );
    if (data == null) throw const FormatException('Malformed OMP host tools');
    final names = data['toolNames'];
    if (names == null) return const [];
    if (!_isListOf(names, (name) => name is String)) {
      throw const FormatException('Malformed OMP host tools');
    }
    return [for (final name in names as List) name as String];
  }

  @override
  void sendHostToolResult(OmpHostToolResultFrame result) =>
      _process.send(result.toJson());

  @override
  void sendHostToolUpdate(OmpHostToolUpdateFrame update) =>
      _process.send(update.toJson());

  /// Rewinds the conversation to [entryId] and returns the restored prompt.
  ///
  /// A cancelled branch and a branch that came back without text both throw:
  /// silently returning an empty prompt would clear the composer the user was
  /// about to edit.
  Future<String> branch(String entryId) async {
    final data = _asRecord(
      await _request({'type': 'branch', 'entryId': entryId}),
    );
    if (data == null) throw const FormatException('Malformed OMP branch');
    if (data['cancelled'] == true) {
      throw StateError('OMP branch was cancelled');
    }
    final text = data['text'];
    if (text is! String) {
      throw StateError(
        'OMP branch response did not include restored prompt text',
      );
    }
    activeBranchEntryId = entryId;
    return text;
  }

  /// Lists the entries the session can be branched from.
  Future<List<({String entryId, String text})>> getBranchMessages() async {
    final data = _asRecord(await _request({'type': 'get_branch_messages'}));
    if (data == null) {
      throw const FormatException('Malformed OMP branch messages');
    }
    final messages = data['messages'];
    if (messages == null) return const [];
    if (messages is! List) {
      throw const FormatException('Malformed OMP branch messages');
    }
    return [
      for (final message in messages)
        if (_asRecord(message) case final record?
            when record['entryId'] is String && record['text'] is String)
          (
            entryId: record['entryId']! as String,
            text: record['text']! as String,
          )
        else
          throw const FormatException('Malformed OMP branch messages'),
    ];
  }

  /// Injects a mid-turn steer. Fire-and-forget: OMP acknowledges it through the
  /// event stream, not with an RPC response.
  void steer(String message, {List<Map<String, Object?>>? images}) {
    _process.send({
      'type': 'steer',
      'message': message,
      if (images != null && images.isNotEmpty) 'images': images,
    });
  }

  /// Queues a follow-up for after the current turn. Also fire-and-forget.
  void followUp(String message, {List<Map<String, Object?>>? images}) {
    _process.send({
      'type': 'follow_up',
      'message': message,
      if (images != null && images.isNotEmpty) 'images': images,
    });
  }

  /// Hands the session off to a fresh context.
  Future<void> handoff([String? customInstructions]) async {
    await _request({
      'type': 'handoff',
      if (_isJsTruthy(customInstructions))
        'customInstructions': customInstructions,
    });
  }

  /// Answers an extension-UI prompt.
  void respondToExtensionUiRequest(String id, OmpExtensionUiResponse response) {
    _process.send({
      'type': 'extension_ui_response',
      'id': id,
      ...response.toJson(),
    });
  }

  /// Abandons an extension-UI prompt.
  void cancelExtensionUiRequest(String id) => respondToExtensionUiRequest(
    id,
    const OmpExtensionUiResponse(cancelled: true),
  );

  /// Shuts the process down, failing every pending request.
  Future<void> close() =>
      _process.close(StateError('OMP RPC session is closed'));

  Future<Object?> _request(
    Map<String, Object?> command, {
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) => _process.request(command, timeout: timeout);

  void _emit(Map<String, Object?> event) {
    for (final subscriber in _subscribers.toList(growable: false)) {
      subscriber(event);
    }
  }
}

// ===========================================================================
// pi/runtime.ts — the launch descriptor pi/cli-runtime.ts depends on
// ===========================================================================

/// Everything the daemon knows about a Pi session before `pi` is launched.
///
/// Diverges from [OmpStartSessionInput] in exactly two places, which is the
/// whole reason it is a separate type: Pi accepts an MCP config file and a list
/// of extension paths, and has no `--append-system-prompt`.
final class PiStartSessionInput {
  const PiStartSessionInput({
    required this.cwd,
    this.env,
    this.protocolMode,
    this.model,
    this.thinkingOptionId,
    this.modeId,
    this.session,
    this.noSession,
    this.mcpConfigPath,
    this.extensionPaths,
    this.extraArgs,
  });

  /// Working directory Pi runs in.
  final String cwd;

  /// Extra environment. Nullable because "absent" and "empty" drive whether
  /// [PiRuntimeLaunch.env] is populated at all.
  final Map<String, String>? env;

  /// Protocol to request; defaults to [OmpProtocolMode.rpc].
  final OmpProtocolMode? protocolMode;

  /// Model id to pin.
  final String? model;

  /// Thinking-budget option id to pin.
  final String? thinkingOptionId;

  /// Pi mode to select. Carried on the descriptor but never turned into argv —
  /// upstream applies it over RPC after the session starts.
  final String? modeId;

  /// Session file to resume.
  final String? session;

  /// Suppress session persistence. Wins over [session].
  final bool? noSession;

  /// Path to a generated MCP configuration file.
  final String? mcpConfigPath;

  /// Extension bundles to load, one `--extension` flag each.
  final List<String>? extensionPaths;

  /// Raw arguments forwarded verbatim, inserted right after `--mode`.
  final List<String>? extraArgs;
}

/// The fully assembled description of a Pi process launch.
final class PiRuntimeLaunch {
  const PiRuntimeLaunch({
    required this.cwd,
    required this.argv,
    required this.protocolMode,
    this.env,
    this.model,
    this.thinkingOptionId,
    this.modeId,
    this.session,
    this.noSession,
    this.mcpConfigPath,
    this.extensionPaths,
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

  /// Pi mode id, echoed for the post-launch RPC.
  final String? modeId;

  /// Session file, echoed from the session input.
  final String? session;

  /// Session-persistence suppression, echoed from the session input.
  final bool? noSession;

  /// MCP config path, echoed from the session input.
  final String? mcpConfigPath;

  /// Extension paths, echoed from the session input.
  final List<String>? extensionPaths;

  /// Extra arguments, echoed from the session input.
  final List<String>? extraArgs;
}

/// Assembles the argv and environment for a Pi session launch.
///
/// Argument order is load-bearing and matches upstream exactly: `--mode` first
/// (unless the caller already pinned one, in either the `--mode value` or
/// `--mode=value` spelling), then the caller's raw `extraArgs`, then model,
/// thinking, session, MCP config, and finally one `--extension` per bundle.
///
/// A `replace`-mode override wins over [command], but only when it actually
/// names an executable — an override whose first element is blank is discarded
/// rather than producing an unlaunchable argv.
///
/// Deviation, inherited from [buildOmpLaunch] and forced by the same type:
/// upstream distinguishes `env: undefined` from `env: {}` on the runtime
/// settings and an explicit empty object there still produces a (possibly
/// empty) merged environment. [ProviderRuntimeSettings.environment] is a
/// non-nullable map defaulting to `{}`, so that distinction is not
/// representable and an empty override environment is treated as absent. The
/// session's own [PiStartSessionInput.env] *is* nullable and reproduces the
/// upstream behaviour exactly.
PiRuntimeLaunch buildPiLaunch({
  required List<String> command,
  required PiStartSessionInput session,
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
  _appendPiLaunchArgs(argv, session, protocolMode);

  final overrideEnv = runtimeSettings?.environment ?? const <String, String>{};
  final hasEnv = overrideEnv.isNotEmpty || session.env != null;

  return PiRuntimeLaunch(
    cwd: session.cwd,
    argv: List.unmodifiable(argv),
    env: hasEnv ? Map.unmodifiable({...overrideEnv, ...?session.env}) : null,
    protocolMode: protocolMode,
    model: session.model,
    thinkingOptionId: session.thinkingOptionId,
    modeId: session.modeId,
    session: session.session,
    noSession: session.noSession,
    mcpConfigPath: session.mcpConfigPath,
    extensionPaths: session.extensionPaths,
    extraArgs: session.extraArgs,
  );
}

void _appendPiLaunchArgs(
  List<String> argv,
  PiStartSessionInput session,
  OmpProtocolMode protocolMode,
) {
  if (!_hasPiModeFlag(argv)) {
    argv.addAll(['--mode', protocolMode.flagValue]);
  }
  final extraArgs = session.extraArgs;
  if (extraArgs != null && extraArgs.isNotEmpty) argv.addAll(extraArgs);
  final model = session.model;
  if (_isJsTruthy(model)) argv.addAll(['--model', model!]);
  final thinking = session.thinkingOptionId;
  if (_isJsTruthy(thinking)) argv.addAll(['--thinking', thinking!]);
  final sessionFile = session.session;
  if (session.noSession == true) {
    argv.add('--no-session');
  } else if (_isJsTruthy(sessionFile)) {
    argv.addAll(['--session', sessionFile!]);
  }
  final mcpConfigPath = session.mcpConfigPath;
  if (_isJsTruthy(mcpConfigPath)) {
    argv.addAll(['--mcp-config', mcpConfigPath!]);
  }
  for (final extensionPath in session.extensionPaths ?? const <String>[]) {
    argv.addAll(['--extension', extensionPath]);
  }
}

bool _hasPiModeFlag(List<String> argv) {
  for (final arg in argv) {
    if (arg == '--mode' || arg.startsWith('--mode=')) return true;
  }
  return false;
}

// ===========================================================================
// pi/cli-runtime.ts
// ===========================================================================

/// Spawner signature for a Pi launch.
typedef PiProcessStarter = Future<Process> Function(PiRuntimeLaunch launch);

/// Construction options for [PiCliRuntime].
final class PiCliRuntimeOptions {
  const PiCliRuntimeOptions({
    this.logger,
    this.runtimeSettings,
    this.command,
    this.commandsRpcName = piCommandsRpcName,
    this.spawnProcess,
    this.environment,
  });

  /// Diagnostic sink; silent when omitted.
  final PaseoRuntimeLogSink? logger;

  /// User overrides for the command and environment.
  final ProviderRuntimeSettings? runtimeSettings;

  /// Executable-and-args tuple; defaults to [defaultPiCommand].
  final List<String>? command;

  /// Slash-command RPC name; defaults to [piCommandsRpcName]. Unlike OMP's,
  /// upstream types this as a free string because Pi forks rename it.
  final String commandsRpcName;

  /// Process starter. Injected so a launch can be asserted without spawning.
  final PiProcessStarter? spawnProcess;

  /// Environment consulted for [piCommandEnvVars].
  final Map<String, String>? environment;
}

/// Drives a `pi --mode rpc` child process.
///
/// The contrast with [OmpCliRuntime] is the interesting part: Pi's replies are
/// cast, not validated, so a malformed payload propagates instead of throwing.
/// That is upstream's deliberate choice, not an omission — Pi's RPC surface
/// evolves faster than the schemas could track.
final class PiCliRuntime {
  PiCliRuntime(this.options);

  /// Construction options.
  final PiCliRuntimeOptions options;

  /// Resolved executable tuple.
  List<String> get command =>
      options.command ?? defaultPiCommand(options.environment);

  /// Spawns Pi and wraps the transport in a session facade.
  Future<PiCliRuntimeSession> startSession(PiStartSessionInput input) async {
    final launch = buildPiLaunch(
      command: command,
      runtimeSettings: options.runtimeSettings,
      session: input,
    );
    final spawn = options.spawnProcess;
    final process = await JsonlRpcProcess.start(
      launch: JsonlRpcLaunch(
        command: launch.argv.first,
        args: launch.argv.skip(1).toList(growable: false),
        cwd: launch.cwd,
        environment: launch.env ?? const {},
      ),
      diagnosticName: 'Pi RPC',
      onWarning: options.logger == null
          ? null
          : (message, error, line) =>
                options.logger!(message, {'err': error, 'line': line}),
      spawn: spawn == null ? null : (_) => spawn(launch),
    );
    return PiCliRuntimeSession(process, options.commandsRpcName);
  }
}

/// Pi's compaction timeout: none.
///
/// Compact is a blocking LLM summarization job and Pi only responds once the
/// summary is written. Applying the 30s control-plane default would fail long
/// sessions while the real compaction kept running (upstream issue #1946). The
/// request still terminates on a response, on process death, or on
/// [PiCliRuntimeSession.close].
const Duration? piCompactRequestTimeout = null;

/// RPC facade over one Pi process.
final class PiCliRuntimeSession {
  /// Subscribes to transport frames. Unlike OMP's session, *every* non-response
  /// frame is forwarded verbatim: Pi performs no validation upstream, so an
  /// unrecognised frame reaches subscribers rather than being dropped.
  PiCliRuntimeSession(this._process, this._commandsRpcName) {
    _process.onMessage(_emit);
    _process.onExit((exit) {
      _emit({'type': 'process_exit', 'error': exit.error.message});
    });
  }

  final JsonlRpcProcess _process;
  final String _commandsRpcName;
  final Set<void Function(Map<String, Object?>)> _subscribers = {};

  /// Subscribes to runtime events; call the result to unsubscribe.
  void Function() onEvent(void Function(Map<String, Object?> event) callback) {
    _subscribers.add(callback);
    return () => _subscribers.remove(callback);
  }

  /// Sends a prompt and returns the ack.
  ///
  /// A reply that is not an object, or that omits a boolean `agentInvoked`,
  /// yields an ack carrying only the transport request id — Pi never throws
  /// here, in contrast with [OmpCliRuntimeSession.prompt].
  Future<ProviderPromptAck> prompt(
    String message, {
    List<Map<String, Object?>>? images,
  }) async {
    final handle = _process.startRequest({
      'type': 'prompt',
      'message': message,
      if (images != null && images.isNotEmpty) 'images': images,
    });
    final data = await handle.response;
    final record = _asRecord(data);
    final agentInvoked = record?['agentInvoked'];
    if (agentInvoked is bool) {
      return ProviderPromptAck(
        requestId: handle.id,
        agentInvoked: agentInvoked,
      );
    }
    return ProviderPromptAck(requestId: handle.id);
  }

  /// Requests a context compaction, waiting indefinitely.
  Future<void> compact([String? customInstructions]) async {
    await request({
      'type': 'compact',
      if (_isJsTruthy(customInstructions))
        'customInstructions': customInstructions,
    }, timeout: piCompactRequestTimeout);
  }

  /// Turns Pi's own compaction on or off.
  Future<void> setAutoCompaction(bool enabled) async {
    await request({'type': 'set_auto_compaction', 'enabled': enabled});
  }

  /// Interrupts the running turn.
  Future<void> abort() async {
    await request({'type': 'abort'});
  }

  /// Reads the session state, unvalidated.
  Future<Map<String, Object?>> getState() async =>
      _asRecord(await request({'type': 'get_state'})) ?? const {};

  /// Reads the transcript, unvalidated.
  Future<List<Object?>> getMessages() async {
    final data = _asRecord(await request({'type': 'get_messages'}));
    final messages = data?['messages'];
    return messages is List ? messages : const [];
  }

  /// Lists available models, unvalidated.
  Future<List<Object?>> getAvailableModels({
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) async {
    final data = _asRecord(
      await request({'type': 'get_available_models'}, timeout: timeout),
    );
    final models = data?['models'];
    return models is List ? models : const [];
  }

  /// Pins the model for subsequent turns.
  Future<Object?> setModel(String provider, String modelId) =>
      request({'type': 'set_model', 'provider': provider, 'modelId': modelId});

  /// Pins the thinking budget.
  ///
  /// Deviation: upstream casts the level with `as never` and sends whatever it
  /// is given, so an unknown level reaches Pi and Pi decides. That behaviour is
  /// reproduced — no vocabulary check here, unlike
  /// [OmpCliRuntimeSession.setThinkingLevel].
  Future<void> setThinkingLevel(String level) async {
    await request({'type': 'set_thinking_level', 'level': level});
  }

  /// Reads usage totals, falling back to `get_state` on older binaries.
  Future<ProviderSessionStats> getSessionStats() => resolveProviderSessionStats(
    getSessionStats: () async => parseProviderSessionStats(
      await request({'type': 'get_session_stats'}),
      strict: false,
    ),
    getStateContextUsage: () async =>
        _readOmpContextUsage((await getState())['contextUsage']),
  );

  /// Lists slash commands through Pi's configured RPC name, unvalidated.
  Future<List<Object?>> getCommands() async {
    final data = _asRecord(await request({'type': _commandsRpcName}));
    final commands = data?['commands'];
    return commands is List ? commands : const [];
  }

  /// Sends an arbitrary frame.
  ///
  /// Pi's RPC surface is wider than this facade; upstream keeps this escape
  /// hatch so an agent can drive a command the facade has not grown a method
  /// for yet.
  void sendRawFrame(Map<String, Object?> frame) => _process.send(frame);

  /// Answers an extension-UI prompt.
  void respondToExtensionUiRequest(String id, OmpExtensionUiResponse response) {
    _process.send({
      'type': 'extension_ui_response',
      'id': id,
      ...response.toJson(),
    });
  }

  /// Abandons an extension-UI prompt.
  void cancelExtensionUiRequest(String id) => respondToExtensionUiRequest(
    id,
    const OmpExtensionUiResponse(cancelled: true),
  );

  /// Shuts the process down, failing every pending request.
  Future<void> close() =>
      _process.close(StateError('Pi RPC session is closed'));

  /// Issues an RPC. Public, matching upstream's `PiRuntimeSession.request`.
  Future<Object?> request(
    Map<String, Object?> command, {
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) => _process.request(command, timeout: timeout);

  void _emit(Map<String, Object?> event) {
    for (final subscriber in _subscribers.toList(growable: false)) {
      subscriber(event);
    }
  }
}

// ===========================================================================
// pi/history-mapper.ts
// ===========================================================================

/// A user turn recovered from Pi's own conversation tree.
///
/// Pi's transcript does not carry the daemon's message ids, so replayed user
/// messages would otherwise get fresh ids and break every reference the client
/// already holds. These entries, captured when the turn was first sent, restore
/// them positionally.
final class PiCapturedUserMessageEntry {
  const PiCapturedUserMessageEntry({required this.id, required this.text});

  /// Pi tree entry id, adopted as the replayed item's id.
  final String id;

  /// The prompt text, carried for call-site parity; the mapper matches by
  /// position, not by content, exactly as upstream does.
  final String text;
}

/// Per-call overrides for [PiHistoryMapper].
///
/// The live Pi agent needs the same replay with three substitutions — custom
/// messages rendered as system notices, tool call ids rewritten for subagent
/// polling, and richer tool details — so upstream threads them as hooks rather
/// than forking the mapper.
final class PiHistoryHooks {
  const PiHistoryHooks({
    this.mapCustomMessage,
    this.resolveToolCallId,
    this.mapToolDetail,
  });

  /// Renders a `custom` message as something other than assistant text.
  final TimelineItem? Function(String text, String provider)? mapCustomMessage;

  /// Rewrites a tool call id before it becomes a timeline item id.
  final String Function(String toolCallId, OmpTrackedToolCall toolCall)?
  resolveToolCallId;

  /// Replaces the detail card for a tool call. Returning `null` suppresses the
  /// card entirely, which is how upstream hides bookkeeping tools.
  final ToolCallDetail? Function(
    OmpTrackedToolCall toolCall,
    Object? result,
    String toolCallId,
  )?
  mapToolDetail;
}

/// Flattens a Pi message body into plain text.
///
/// Image blocks are dropped and text blocks joined with a blank line, so a
/// prompt that interleaved screenshots with prose replays as readable prose
/// rather than as base64.
String getPiUserMessageText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    final record = _asRecord(block);
    if (record == null || record['type'] != 'text') continue;
    final text = record['text'];
    if (text is String) parts.add(text);
  }
  return parts.join('\n\n');
}

/// Resolves the display name for a Pi tool call.
///
/// Delegates to [resolveOmpToolCallName] for the shared rules — the `write`
/// call that is really a proxied `xdev` execution — and adds the MCP branch that
/// is the *only* difference between upstream's `pi/tool-call-mapper.ts` and
/// `omp/tool-call-detail.ts`.
///
/// An `mcp` call is a proxy: the interesting name is the server and tool it
/// forwarded to, taken from the result when it came back and from the arguments
/// when it has not. The underscore split is the last resort for a proxy that
/// named the tool `<server>_<tool>` without saying so.
String resolvePiToolCallName(OmpTrackedToolCall toolCall, [Object? result]) {
  final base = resolveOmpToolCallName(toolCall, result);
  // A different name means the xdev branch already fired; upstream returns
  // there before ever reaching the MCP branch.
  if (base != toolCall.toolName) return base;
  if (toolCall.toolName != 'mcp') return toolCall.toolName;

  if (result != null && result is! String) {
    final details = _asRecord(_asRecord(result)?['details']);
    final serverName = _readNonEmptyString(details?['server']);
    final toolName = _readNonEmptyString(details?['tool']);
    if (serverName != null && toolName != null) return '$serverName.$toolName';
  }

  final args = _asRecord(toolCall.args);
  if (args != null) {
    final requestedTool = _readNonEmptyString(args['tool']);
    final requestedServer = _readNonEmptyString(args['server']);
    if (requestedTool != null && requestedServer != null) {
      return '$requestedServer.'
          '${_stripPiMcpProxyPrefix(requestedTool, requestedServer)}';
    }
    if (requestedTool != null) {
      final parts = requestedTool.split('_');
      if (parts.length > 1 && parts.first.isNotEmpty) {
        return '${parts.first}.${parts.skip(1).join('_')}';
      }
    }
  }

  return toolCall.toolName;
}

String _stripPiMcpProxyPrefix(String toolName, String serverName) {
  final prefix = '${serverName}_';
  return toolName.startsWith(prefix)
      ? toolName.substring(prefix.length)
      : toolName;
}

/// Replays a Pi transcript onto the provider-neutral timeline.
///
/// Stateful across [mapMessages] calls: the pending tool-call map lets a
/// `toolResult` recover the arguments of the `toolCall` that preceded it, and
/// the two counters mint the synthetic ids described on [projectPiHistory].
final class PiHistoryMapper {
  PiHistoryMapper(
    this.provider, {
    this.userEntries = const [],
    this.hooks = const PiHistoryHooks(),
  });

  /// Provider name used in synthetic ids.
  final String provider;

  /// Captured user entries, matched positionally against `user` messages.
  final List<PiCapturedUserMessageEntry> userEntries;

  /// Per-call overrides.
  final PiHistoryHooks hooks;

  final Map<String, OmpTrackedToolCall> _pendingToolCalls = {};
  var _userIndex = 0;
  var _assistantIndex = 0;
  var _reasoningIndex = 0;
  var _customIndex = 0;

  /// Maps a batch of Pi messages onto timeline items.
  ///
  /// Unknown roles are skipped rather than raising: a transcript written by a
  /// newer Pi must still replay the parts this daemon understands.
  List<TimelineItem> mapMessages(Iterable<Object?> messages) {
    final items = <TimelineItem>[];
    for (final message in messages) {
      final record = _asRecord(message);
      if (record == null) continue;
      switch (record['role']) {
        case 'user':
          items.addAll(_mapUserMessage(record));
        case 'custom':
          items.addAll(_mapCustomMessage(record));
        case 'assistant':
          items.addAll(_mapAssistantMessage(record));
        case 'toolResult':
          final item = _mapToolResultMessage(record);
          if (item != null) items.add(item);
        case 'bashExecution':
          items.add(_mapBashExecutionMessage(record));
      }
    }
    return items;
  }

  List<TimelineItem> _mapUserMessage(Map<String, Object?> message) {
    final text = getPiUserMessageText(message['content']);
    // Incremented before the empty check so an empty prompt still consumes its
    // captured entry, keeping later messages aligned.
    _userIndex += 1;
    if (text.isEmpty) return const [];
    final entry = _userIndex - 1 < userEntries.length
        ? userEntries[_userIndex - 1]
        : null;
    return [
      UserMessageItem(
        id: entry?.id ?? '$provider-history-user-$_userIndex',
        text: text,
      ),
    ];
  }

  List<TimelineItem> _mapCustomMessage(Map<String, Object?> message) {
    final text = getPiUserMessageText(message['content']);
    _customIndex += 1;
    final mapped = text.isEmpty
        ? null
        : hooks.mapCustomMessage?.call(text, provider);
    if (mapped != null) return [mapped];
    if (text.isEmpty) return const [];
    return [
      AssistantMessageItem(
        id: '$provider-history-custom-$_customIndex',
        text: text,
        complete: true,
      ),
    ];
  }

  List<TimelineItem> _mapAssistantMessage(Map<String, Object?> message) {
    final items = <TimelineItem>[];
    _assistantIndex += 1;
    final responseId = message['responseId'];
    final messageId = _isJsTruthy(responseId)
        ? responseId! as String
        : '$provider-history-assistant-$_assistantIndex';
    final content = message['content'];
    if (content is! List) return items;
    for (final entry in content) {
      final block = _asRecord(entry);
      if (block == null) continue;
      final type = block['type'];
      if (type == 'text' && _isJsTruthy(block['text'])) {
        items.add(
          AssistantMessageItem(
            id: messageId,
            text: block['text']! as String,
            complete: true,
          ),
        );
        continue;
      }
      if (type == 'thinking' && _isJsTruthy(block['thinking'])) {
        _reasoningIndex += 1;
        items.add(
          ReasoningItem(
            id: '$provider-history-reasoning-$_reasoningIndex',
            text: block['thinking']! as String,
            complete: true,
          ),
        );
        continue;
      }
      if (type == 'toolCall') {
        final id = block['id'];
        final name = block['name'];
        if (id is! String || name is! String) continue;
        final tracked = parseOmpToolArgs(name, block['arguments']);
        _pendingToolCalls[id] = tracked;
        final detail = _mapToolDetail(id, tracked, null);
        if (detail == null) continue;
        items.add(
          ToolCallItem(
            id: _resolveToolCallId(id, tracked),
            toolName: tracked.toolName,
            status: ToolCallStatus.running,
            detail: detail,
          ),
        );
      }
    }
    return items;
  }

  TimelineItem? _mapToolResultMessage(Map<String, Object?> message) {
    final toolCallId = message['toolCallId'];
    if (toolCallId is! String) return null;
    final toolName = message['toolName'];
    final tracked =
        _pendingToolCalls[toolCallId] ??
        parseOmpToolArgs(toolName is String ? toolName : '', null);
    _pendingToolCalls.remove(toolCallId);
    // Upstream re-wraps the message's own fields into the result envelope the
    // shared parser expects. Each key is copied only when the message carried
    // it: upstream's `{content: undefined}` satisfies an optional field, while
    // a Dart map with an explicit `null` would fail it and drop the card.
    final result = parseOmpToolResult({
      if (message.containsKey('content')) 'content': message['content'],
      if (message.containsKey('details')) 'details': message['details'],
    });
    final detail = _mapToolDetail(toolCallId, tracked, result);
    if (detail == null) return null;
    final isError = message['isError'] == true;
    return ToolCallItem(
      id: _resolveToolCallId(toolCallId, tracked),
      toolName: resolvePiToolCallName(tracked, result),
      status: isError ? ToolCallStatus.error : ToolCallStatus.success,
      detail: detail,
      errorMessage: isError
          ? (extractOmpToolResultText(result) ?? 'Tool call failed')
          : null,
    );
  }

  /// Pi records interactive shell runs outside the tool-call stream, so they are
  /// synthesized into `bash` cards keyed by their timestamp — the only id Pi
  /// gives them.
  TimelineItem _mapBashExecutionMessage(Map<String, Object?> message) {
    final command = message['command'];
    final exitCode = message['exitCode'];
    return ToolCallItem(
      id: 'pi-bash-${message['timestamp']}',
      toolName: 'bash',
      status: message['cancelled'] == true
          ? ToolCallStatus.canceled
          : ToolCallStatus.success,
      detail: ShellDetail(
        command: command is String ? command : '',
        output: message['output'] as String?,
        exitCode: exitCode is num ? exitCode.toInt() : null,
      ),
    );
  }

  String _resolveToolCallId(String toolCallId, OmpTrackedToolCall toolCall) =>
      hooks.resolveToolCallId?.call(toolCallId, toolCall) ?? toolCallId;

  ToolCallDetail? _mapToolDetail(
    String toolCallId,
    OmpTrackedToolCall toolCall,
    Object? result,
  ) {
    final hook = hooks.mapToolDetail;
    return hook != null
        ? hook(toolCall, result, toolCallId)
        : mapOmpCoreToolDetail(toolCall, result);
  }
}

/// Replays a whole Pi transcript in one call.
///
/// Upstream exposes this as `streamPiHistory`, an async generator, because its
/// caller pipes events into a stream. Nothing here is asynchronous, and the
/// repo's other history ports (`projectCodexThreadHistory`,
/// `projectClaudeHistory`) return a list, so this returns a list too — the
/// order and content are identical.
///
/// Deviation, forced by [TimelineItem] requiring an `id` where upstream's items
/// carry an optional `messageId`: items that upstream leaves unidentified get a
/// synthetic, position-derived id — `<provider>-history-user-N`,
/// `<provider>-history-custom-N` and `<provider>-history-reasoning-N`. Assistant
/// text keeps upstream's own `responseId ?? <provider>-history-assistant-N`,
/// which means — as upstream — two text blocks in one assistant message share an
/// id and therefore upsert onto one timeline item.
List<TimelineItem> projectPiHistory(
  String provider,
  Iterable<Object?> messages, {
  List<PiCapturedUserMessageEntry> userEntries = const [],
  PiHistoryHooks hooks = const PiHistoryHooks(),
}) => PiHistoryMapper(
  provider,
  userEntries: userEntries,
  hooks: hooks,
).mapMessages(messages);
