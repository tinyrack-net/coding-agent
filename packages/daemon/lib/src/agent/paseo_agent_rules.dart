/// Port of four small, frozen Paseo 0.2.0 agent rules that had no Dart home:
///
/// - `server/agent/agent-archive.ts` — how a persisted agent record is
///   rewritten when the agent is archived.
/// - `server/agent/agent-timeline-content.ts` — the 64 KiB budget applied to
///   tool-call payloads before they are stored or broadcast.
/// - `server/agent/provider-history-timestamps.ts` — normalizing the wildly
///   inconsistent timestamps found in provider-native history files.
/// - `server/agent/rewind/rewind.ts` — dispatching a rewind request onto the
///   provider capability that can serve it.
///
/// Each rule is expressed against the types this daemon already owns
/// ([AgentSummary], [TimelineItem], [AgentSession]) rather than against
/// re-declared mirrors of the upstream TypeScript interfaces. Where a
/// JavaScript idiom has no Dart analogue the deviation is called out inline.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../providers/agent_session.dart';

// ---------------------------------------------------------------------------
// agent-archive.ts
// ---------------------------------------------------------------------------

/// Rewrites [record] into the shape an archived agent is persisted in.
///
/// This is the durable-record rule, not the live-teardown rule: archiving must
/// never leave a reloaded agent claiming to be mid-turn, and must never leave
/// a stale attention badge lit for an agent the user has put away.
///
/// Upstream's `StoredAgentRecord` is this daemon's [AgentSummary] (the value
/// `PersistedAgent.summary` round-trips to disk), so the port mutates an
/// [AgentSummary] instead of declaring a parallel record type.
///
/// [archivedAt] and [updatedAt] override the stamps upstream lets callers
/// supply. When [archivedAt] is omitted the [now] clock supplies it; upstream
/// calls `new Date()` inline, which this port refuses to do so the rule stays
/// testable. `updatedAt` is deliberately *not* advanced by default: archiving
/// is a filing action, not activity, so the caller must opt in by passing
/// [updatedAt] (as `AgentManager` does when it wants both stamps aligned).
AgentSummary buildArchivedAgentSummary(
  AgentSummary record, {
  required DateTime Function() now,
  String? archivedAt,
  String? updatedAt,
}) {
  final resolvedArchivedAt = archivedAt ?? now().toUtc().toIso8601String();
  return record.copyWith(
    runState: archivedRunState(record.runState),
    archivedAt: resolvedArchivedAt,
    updatedAt: updatedAt ?? record.updatedAt,
    requiresAttention: false,
    clearAttention: true,
  );
}

/// The run state an archived agent is persisted with.
///
/// Upstream collapses only `running` and `initializing` to `idle` and passes
/// every other status through untouched, so `error` and `closed` survive
/// archival and stay visible in the archive list.
///
/// DEVIATION: upstream's `AGENT_LIFECYCLE_STATUSES` has no
/// `awaitingPermission` — that state is this daemon's own extension. It is a
/// busy state by the same reasoning that makes `running` one (the agent is
/// mid-turn, blocked on a permission prompt that archival tears down), so it
/// is collapsed to `idle` alongside the two upstream busy states. Leaving it
/// alone would strand a reloaded archived agent waiting on a prompt that no
/// longer exists.
AgentRunState archivedRunState(AgentRunState status) => switch (status) {
  AgentRunState.running ||
  AgentRunState.initializing ||
  AgentRunState.awaitingPermission => AgentRunState.idle,
  AgentRunState.idle || AgentRunState.error || AgentRunState.closed => status,
};

// ---------------------------------------------------------------------------
// agent-timeline-content.ts
// ---------------------------------------------------------------------------

/// Frozen Paseo 0.2.0 `TOOL_CALL_CONTENT_MAX_LENGTH`: the per-field ceiling on
/// tool-call payloads that get persisted and broadcast.
///
/// The unit is UTF-16 code units in both languages — JavaScript's
/// `String.prototype.slice` and Dart's [String.substring] index identically —
/// so a surrogate pair straddling the boundary is split the same way by both.
const agentToolCallContentMaxLength = 64 * 1024;

/// Clamps the oversized fields of a tool-call timeline item to
/// [agentToolCallContentMaxLength].
///
/// A single runaway `cat`, test run, or terminal buffer can otherwise pin
/// megabytes into every durable snapshot and every stream frame. Only
/// tool-call items carry unbounded provider output, so every other item kind
/// is returned unchanged (identically, not copied).
///
/// Three fields are budgeted, matching upstream's three passes in order:
/// 1. the error text of a *failed shell* call,
/// 2. the text of a `plain_text` detail (any status — this is how the
///    terminal tool ships its input),
/// 3. the output of a `shell` detail (any status).
///
/// Passes 1 and 3 can both fire on one failed shell call; pass 2 is mutually
/// exclusive with them because a detail has exactly one kind.
///
/// DEVIATION: upstream types a failed tool call's `error` as `unknown` and
/// only clamps it when it happens to be an object carrying a string
/// `content` property, leaving every other shape alone. This daemon models
/// tool-call failure as a plain `String? errorMessage`, so the observable rule
/// ports as "clamp the failed shell call's error text" and upstream's
/// not-an-object / no-string-content escape hatches have no representable
/// counterpart.
TimelineItem limitAgentTimelineItemContent(TimelineItem item) {
  if (item is! ToolCallItem) return item;
  var limited = _limitFailedShellError(item);
  limited = _limitPlainTextDetail(limited);
  return _limitShellOutput(limited);
}

ToolCallItem _limitFailedShellError(ToolCallItem item) {
  final error = item.errorMessage;
  if (item.status != ToolCallStatus.error ||
      item.detail is! ShellDetail ||
      error == null ||
      error.length <= agentToolCallContentMaxLength) {
    return item;
  }
  return _withToolCallFields(
    item,
    errorMessage: error.substring(0, agentToolCallContentMaxLength),
  );
}

ToolCallItem _limitPlainTextDetail(ToolCallItem item) {
  final detail = item.detail;
  if (detail is! PlainTextDetail) return item;
  final text = detail.text;
  if (text == null || text.length <= agentToolCallContentMaxLength) {
    return item;
  }
  return _withToolCallFields(
    item,
    detail: PlainTextDetail(
      label: detail.label,
      text: text.substring(0, agentToolCallContentMaxLength),
      icon: detail.icon,
    ),
  );
}

ToolCallItem _limitShellOutput(ToolCallItem item) {
  final detail = item.detail;
  if (detail is! ShellDetail) return item;
  final output = detail.output;
  if (output == null || output.length <= agentToolCallContentMaxLength) {
    return item;
  }
  return _withToolCallFields(
    item,
    detail: ShellDetail(
      command: detail.command,
      cwd: detail.cwd,
      output: output.substring(0, agentToolCallContentMaxLength),
      exitCode: detail.exitCode,
    ),
  );
}

/// Stands in for upstream's `{ ...item, field }` spread. [ToolCallItem] has no
/// `copyWith`, and adding one would mean editing a shared protocol type.
ToolCallItem _withToolCallFields(
  ToolCallItem item, {
  ToolCallDetail? detail,
  String? errorMessage,
}) => ToolCallItem(
  id: item.id,
  toolName: item.toolName,
  status: item.status,
  detail: detail ?? item.detail,
  errorMessage: errorMessage ?? item.errorMessage,
  metadata: item.metadata,
);

// ---------------------------------------------------------------------------
// provider-history-timestamps.ts
// ---------------------------------------------------------------------------

/// ECMAScript's `TimeClip` bound: milliseconds beyond ±100,000,000 days from
/// the epoch are not a representable instant.
const _maxTimeValueMs = 8640000000000000;

/// Below this, a numeric provider timestamp is read as seconds; above it, as
/// milliseconds. Strictly greater-than, matching upstream.
const _millisecondThreshold = 1000000000000;

/// The portable half of ECMAScript's Date Time String Format: an optional
/// expanded year, an optional month and day, and an optional time with an
/// optional zone.
final _isoDateTimeFormat = RegExp(
  r'^([+-]\d{6}|\d{4})'
  r'(?:-(\d{2})(?:-(\d{2}))?)?'
  r'(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:Z|[+-](\d{2}):(\d{2}))?)?$',
);

/// Normalizes one timestamp read out of a provider's own history file into an
/// ISO-8601 string, or `null` when it cannot be trusted.
///
/// Replaying a provider session means adopting timestamps written by code this
/// daemon does not control: Claude writes ISO strings, Codex writes epoch
/// seconds in some records and epoch milliseconds in others, and any of them
/// may be absent or malformed. A `null` return tells the caller to fall back to
/// its own ordering rather than fabricate an instant.
///
/// String inputs are validated and returned *trimmed but otherwise verbatim* —
/// the provider's own spelling of the instant is preserved, not re-serialized.
/// Numeric inputs are disambiguated by magnitude and rendered as UTC ISO-8601.
///
/// DEVIATION: upstream validates strings with JavaScript's `Date.parse`, whose
/// accepted grammar is the ECMAScript Date Time String Format *plus* an
/// unspecified, engine-specific fallback. This port validates against the
/// specified format only, which differs from V8 in both directions:
///
/// - Rejected here, accepted by V8: RFC 2822 (`Mon, 14 May 2026 12:41:15 GMT`),
///   prose dates (`May 14, 2026`), a space instead of `T`, and a lowercase
///   `z`. These are explicitly non-portable in ECMAScript.
/// - Rejected here, also rejected by V8, but which a naive
///   `DateTime.tryParse` would have *wrongly accepted*: bare digit runs such
///   as `"1778762475"` (Dart reads that as the year 1778762 in basic format,
///   silently turning an epoch-seconds string into a year-177878 instant) and
///   out-of-range components such as `"2026-13-01T00:00:00Z"` (Dart rolls
///   month 13 over into the next year). Both would corrupt a replayed
///   timeline, so the format check runs before any parse.
String? normalizeProviderReplayTimestamp(Object? value) {
  if (value is String) {
    final timestamp = value.trim();
    // Upstream's `!timestamp` guard: an all-whitespace stamp is as absent as
    // a missing one. Dart has no truthiness, so the emptiness test is
    // explicit.
    if (timestamp.isEmpty || !_isParsableTimestamp(timestamp)) return null;
    return timestamp;
  }

  // Upstream's `typeof value !== "number"` also rejects booleans, objects and
  // null; Dart's `is! num` covers the same ground. `isFinite` reproduces
  // `Number.isFinite`, dropping NaN and both infinities.
  if (value is! num || !value.isFinite) return null;

  // JavaScript numbers are all doubles, so the seconds-to-milliseconds scaling
  // is done in double arithmetic here too: a Dart `int` multiplication would
  // stay exact past 2^53 where the upstream value has already lost precision.
  final milliseconds = value > _millisecondThreshold
      ? value.toDouble()
      : value.toDouble() * 1000;
  if (!milliseconds.isFinite || milliseconds.abs() > _maxTimeValueMs) {
    // `new Date(out-of-range)` yields an Invalid Date, which upstream maps to
    // null. Dart's `fromMillisecondsSinceEpoch` throws instead, so the range
    // is checked up front.
    return null;
  }
  // `new Date(x)` truncates a fractional millisecond toward zero.
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds.truncate(),
    isUtc: true,
  ).toIso8601String();
}

bool _isParsableTimestamp(String timestamp) {
  final match = _isoDateTimeFormat.firstMatch(timestamp);
  if (match == null) return false;

  int? group(int index) {
    final raw = match.group(index);
    return raw == null ? null : int.parse(raw);
  }

  final month = group(2);
  if (month != null && (month < 1 || month > 12)) return false;
  // ECMAScript range-checks the day as 01-31 without consulting the month, so
  // `2026-02-30` is accepted and rolls over. That is upstream's behavior.
  final day = group(3);
  if (day != null && (day < 1 || day > 31)) return false;
  final hour = group(4);
  // Hour 24 is legal and denotes the following midnight.
  if (hour != null && hour > 24) return false;
  final minute = group(5);
  if (minute != null && minute > 59) return false;
  final second = group(6);
  if (second != null && second > 59) return false;
  final offsetHour = group(8);
  if (offsetHour != null && offsetHour > 23) return false;
  final offsetMinute = group(9);
  if (offsetMinute != null && offsetMinute > 59) return false;
  return true;
}

// ---------------------------------------------------------------------------
// rewind/rewind.ts
// ---------------------------------------------------------------------------

/// What a rewind request asks the provider to undo.
///
/// Upstream models this as the string union `"conversation" | "files" |
/// "both"`; the wire spelling is [Enum.name] in every case.
enum RewindMode { conversation, files, both }

/// Raised when the session backing an agent cannot serve the requested
/// [RewindMode].
///
/// Rewinding is strictly opt-in per provider: a provider that cannot restore
/// files must fail loudly rather than silently rewinding only the transcript
/// and leaving the working tree ahead of it.
final class RewindCapabilityError implements Exception {
  const RewindCapabilityError(this.mode);

  /// Matches upstream's `Error.name`, which clients match on.
  static const name = 'RewindCapabilityError';

  final RewindMode mode;

  /// Byte-for-byte upstream's `Error.message`.
  String get message => 'Provider does not support rewinding ${mode.name}';

  @override
  String toString() => '$name: $message';
}

/// The three optional `supportsRewind*` flags of upstream's
/// `AgentCapabilityFlags`, narrowed to the ones rewinding consults.
///
/// Upstream declares all three as `boolean | undefined`, and an absent flag is
/// falsy — so "unset" and "false" are the same answer. Dart's non-nullable
/// `false` default reproduces that without a third state.
final class RewindCapabilities {
  const RewindCapabilities({
    this.supportsRewindConversation = false,
    this.supportsRewindFiles = false,
    this.supportsRewindBoth = false,
  });

  /// What a session that advertises nothing is treated as.
  static const none = RewindCapabilities();

  final bool supportsRewindConversation;
  final bool supportsRewindFiles;
  final bool supportsRewindBoth;
}

/// A session that advertises whether it can rewind.
///
/// This daemon's provider boundary expresses optional capabilities as
/// additional interfaces on [AgentSession] (see `ConfigurableAgentSession`,
/// `HistoryRestoringAgentSession`) rather than as one fat interface of
/// optional members, so upstream's `session.capabilities.supportsRewind*` and
/// its optional `revert*` methods are split across this flag carrier and the
/// three mode interfaces below.
abstract interface class RewindAwareAgentSession implements AgentSession {
  RewindCapabilities get rewindCapabilities;
}

/// Restores the provider's transcript to just before a message, leaving the
/// working tree alone.
abstract interface class ConversationRewindingAgentSession
    implements RewindAwareAgentSession {
  Future<void> revertConversation({required String messageId});
}

/// Restores the files a turn touched, leaving the transcript alone.
abstract interface class FileRewindingAgentSession
    implements RewindAwareAgentSession {
  Future<void> revertFiles({required String messageId});
}

/// Restores transcript and files together.
///
/// Upstream keeps this separate from calling the other two in sequence
/// because a provider that can do both atomically is not the same as one that
/// can do each independently.
abstract interface class CombinedRewindingAgentSession
    implements RewindAwareAgentSession {
  Future<void> revertBoth({required String messageId});
}

/// Dispatches a rewind request onto the one provider entry point that serves
/// [mode], or throws [RewindCapabilityError] when the session cannot.
///
/// Upstream guards each branch twice — the capability flag must be set *and*
/// the optional method must actually be present — because a provider adapter
/// can advertise a flag it never wired up. Both halves are reproduced here:
/// the flag comes from [RewindAwareAgentSession.rewindCapabilities] and the
/// method's presence is the session implementing the matching mode interface.
/// A session implementing neither is treated as advertising nothing.
///
/// NOTE: upstream's `rewind.test.ts` is an `AgentManager` integration suite
/// that also pins aborting an in-flight turn, rehydrating the timeline from
/// provider history, and gating new prompts on the rehydrate epoch. Those are
/// manager responsibilities, not this function's; this is the capability
/// dispatch alone.
Future<void> invokeRewindCapability(
  AgentSession session, {
  required String messageId,
  required RewindMode mode,
}) async {
  final capabilities = session is RewindAwareAgentSession
      ? session.rewindCapabilities
      : RewindCapabilities.none;

  switch (mode) {
    case RewindMode.conversation:
      if (!capabilities.supportsRewindConversation ||
          session is! ConversationRewindingAgentSession) {
        throw RewindCapabilityError(mode);
      }
      await session.revertConversation(messageId: messageId);
    case RewindMode.files:
      if (!capabilities.supportsRewindFiles ||
          session is! FileRewindingAgentSession) {
        throw RewindCapabilityError(mode);
      }
      await session.revertFiles(messageId: messageId);
    case RewindMode.both:
      if (!capabilities.supportsRewindBoth ||
          session is! CombinedRewindingAgentSession) {
        throw RewindCapabilityError(mode);
      }
      await session.revertBoth(messageId: messageId);
  }
}
