/// Frozen Paseo 0.2.0 port of the quota-fetcher support helpers, the Expo push
/// token store, and task execution-order derivation.
///
/// Upstream sources (read-only, `packages/server/src`):
///
/// * `services/quota-fetcher/service.ts` — already ported as
///   [ProviderUsageService] in `../providers/usage/provider_usage.dart`; this
///   library re-exports it so the cluster has a single entry point instead of a
///   second, divergent copy.
/// * `services/quota-fetcher/usage.ts` — the tone/percentage helpers were also
///   already ported (and are re-exported below). The *remaining* helpers
///   (`unavailableUsage`, `windowFromUsedPct`, `toIsoStringOrNull`,
///   `fetchProviderApi`, and the `z.coerce` API schemas) had no Dart analogue
///   and are ported here.
/// * `server/push/token-store.ts` — [PushTokenStore].
/// * `tasks/execution-order.ts` — [computeExecutionOrder] and
///   [buildSortedChildrenMap], plus the `tasks/task-graph.ts` helpers they
///   depend on.
///
/// Every seam that would otherwise touch the network, the disk, or the wall
/// clock is injected, so the suite runs hermetically.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;

import '../providers/usage/provider_usage_fetchers.dart'
    show ProviderUsageHttpCall;
import '../server/private_files.dart';

// Reused rather than re-ported. `service.ts` and the tone/percentage half of
// `usage.ts` already exist in this package; duplicating them would create two
// sources of truth for the same frozen thresholds.
export '../providers/usage/provider_usage.dart'
    show
        ProviderUsageFetcher,
        ProviderUsageListResult,
        ProviderUsageService,
        providerBalanceToneFromRemaining,
        providerUsageToneFromUsedPct,
        providerUsageUsedPctOf;
export '../providers/usage/provider_usage_fetchers.dart'
    show ProviderUsageHttpCall;

// ---------------------------------------------------------------------------
// quota-fetcher/usage.ts
// ---------------------------------------------------------------------------

/// Upstream `PROVIDER_HTTP_TIMEOUT_MS`.
///
/// Provider quota endpoints hang rather than fail, so every call carries a
/// deadline. Upstream attaches `AbortSignal.timeout(15_000)` unless the caller
/// already supplied a signal; Dart has no ambient signal, so [fetchProviderApi]
/// takes an explicit `timeout` override in its place.
const Duration providerApiTimeout = Duration(seconds: 15);

/// Port of `fetchProviderApi`.
///
/// Wraps an injected [ProviderUsageHttpCall] — the seam the existing provider
/// fetchers already use — so quota requests cannot outlive
/// [providerApiTimeout].
///
/// Deviation: upstream aborts the underlying request via `AbortSignal`, which
/// rejects the fetch promise. Dart's `Future.timeout` cannot cancel the socket,
/// so the observable behaviour (the caller sees a timeout error at 15s) matches
/// while the in-flight request may still be draining underneath.
Future<http.Response> fetchProviderApi(
  ProviderUsageHttpCall httpCall,
  Uri uri, {
  String method = 'GET',
  Map<String, String>? headers,
  Object? body,
  Duration? timeout,
}) => httpCall(
  method,
  uri,
  headers: headers,
  body: body,
).timeout(timeout ?? providerApiTimeout);

/// Port of `unavailableUsage`.
///
/// The placeholder a provider reports when its quota could not be read. Status
/// is `error` only when an error message is present, mirroring the upstream
/// truthiness check.
///
/// Deviation: upstream tests `provider.error ? ... : ...`, so an **empty**
/// error string is falsy and yields `unavailable` while still being echoed back
/// as `error: ""`. Dart has no truthiness, so the emptiness check is explicit —
/// and the empty string is deliberately preserved rather than normalised to
/// null, because that is what the wire payload carried.
ProviderUsage unavailableProviderUsage({
  required String providerId,
  required String displayName,
  String? error,
}) => ProviderUsage(
  providerId: providerId,
  displayName: displayName,
  status: (error != null && error.isNotEmpty)
      ? ProviderUsageStatus.error
      : ProviderUsageStatus.unavailable,
  planLabel: null,
  windows: const [],
  balances: const [],
  details: const [],
  error: error,
);

/// Port of the inline `reason instanceof Error ? reason.message : String(reason)`
/// used by `service.ts` when a fetcher rejects.
///
/// Deviation worth knowing: the already-ported [ProviderUsageService] formats
/// failures with Dart string interpolation, so a `StateError('x')` surfaces as
/// `"Bad state: x"` where upstream would surface `"x"`. This helper exposes the
/// upstream rule for fetchers that want the bare message, and documents the gap
/// without editing the shipped service.
String providerFetchErrorMessage(Object? reason) => switch (reason) {
  final Exception error => _exceptionMessage(error),
  final Error error => '$error',
  _ => '$reason',
};

String _exceptionMessage(Exception error) {
  final text = '$error';
  // `Exception('boom').toString()` is "Exception: boom"; strip the class prefix
  // so the payload reads like a JS `Error.message`.
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

/// Port of `windowFromUsedPct`.
///
/// Builds a usage window from a utilisation percentage, deriving the remaining
/// percentage and clamping it at zero so an over-quota provider never renders a
/// negative bar.
///
/// Deviation: upstream's `typeof input.utilizationPct === "number"` guard
/// admits `NaN`, which then propagates into `remainingPct`. Dart reproduces
/// that (a non-null `double.nan` flows straight through) rather than silently
/// nulling it, so malformed provider payloads stay visible.
ProviderUsageWindow windowFromUsedPct({
  required String id,
  required String label,
  required double? utilizationPct,
  String? resetsAt,
  ProviderUsageTone? tone,
}) => ProviderUsageWindow(
  id: id,
  label: label,
  usedPct: utilizationPct,
  remainingPct: utilizationPct == null
      ? null
      : math.max(0.0, 100 - utilizationPct),
  resetsAt: resetsAt,
  tone: tone,
);

/// Largest epoch millisecond value JavaScript's `Date` can represent.
const int _maxJsTimeValue = 8640000000000000;

/// Port of `toIsoStringOrNull`.
///
/// Upstream builds a `Date` and returns null when it is Invalid — which happens
/// for NaN and for magnitudes beyond the ECMAScript time-value range. Dart's
/// [DateTime.fromMillisecondsSinceEpoch] would instead throw or silently wrap,
/// so the range check is explicit here.
String? toIsoStringOrNull(num timestampMs) {
  if (timestampMs.isNaN || timestampMs.isInfinite) return null;
  final ms = timestampMs.toInt();
  if (ms.abs() > _maxJsTimeValue) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
}

/// Port of `ApiNumberSchema` (`z.coerce.number().finite()`).
///
/// Provider APIs return percentages and credit balances as numbers *or* as
/// numeric strings, so upstream coerces before validating. Throws a
/// [FormatException] when the value cannot become a finite number, matching a
/// Zod parse failure.
///
/// Deviation: this is a best-effort emulation of ECMAScript `ToNumber` covering
/// the forms provider payloads actually carry (numbers, numeric strings with
/// surrounding whitespace, hex/binary/octal literals, `Infinity`, booleans,
/// null, and the array shapes `[]`/`[x]`). Exotic JS coercions such as
/// `Number(new Date())` have no analogue and are treated as failures.
double coerceApiNumber(Object? value) {
  final coerced = _jsToNumber(value);
  if (coerced.isFinite) return coerced;
  throw FormatException('Expected a finite number, got: $value');
}

/// Port of `ApiNullableNumberSchema`.
///
/// Upstream preprocesses `value == null ? null : value`, which collapses both
/// `null` and `undefined` to `null` before the nullable number check. Dart has
/// a single absent value, so null in means null out; everything else goes
/// through [coerceApiNumber].
double? coerceApiNullableNumber(Object? value) =>
    value == null ? null : coerceApiNumber(value);

/// Port of `ApiOptionalStringSchema` (`z.coerce.string().optional()` behind a
/// null-to-undefined preprocess).
///
/// Returns null for an absent value and otherwise stringifies, so a provider
/// that reports an id as a number still yields a usable label.
///
/// Deviation: JavaScript's number-to-string differs from Dart's — `String(42.0)`
/// is `"42"` while `42.0.toString()` is `"42.0"`. [_jsToString] reproduces the
/// JS spelling so wire payloads round-trip identically.
String? coerceApiOptionalString(Object? value) =>
    value == null ? null : _jsToString(value);

double _jsToNumber(Object? value) {
  switch (value) {
    case null:
      return 0; // Number(null) === 0
    case final bool flag:
      return flag ? 1 : 0;
    case final num number:
      return number.toDouble();
    case final String text:
      return _jsStringToNumber(text);
    case final List<Object?> list:
      // Number([]) === 0, Number([5]) === 5, Number([1,2]) is NaN.
      if (list.isEmpty) return 0;
      if (list.length == 1) return _jsToNumber(list.single);
      return double.nan;
    default:
      return double.nan;
  }
}

double _jsStringToNumber(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return 0; // Number("") and Number("   ") are 0.
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  final radix = switch (text.length >= 2 ? text.substring(0, 2) : '') {
    '0x' || '0X' => 16,
    '0b' || '0B' => 2,
    '0o' || '0O' => 8,
    _ => null,
  };
  if (radix != null) {
    // JS rejects a sign on these literals, and so does int.tryParse here
    // because the sign would sit before the prefix we already stripped.
    return (int.tryParse(text.substring(2), radix: radix) ?? double.nan)
        .toDouble();
  }
  return (num.tryParse(text) ?? double.nan).toDouble();
}

String _jsToString(Object? value) => switch (value) {
  final String text => text,
  final bool flag => flag ? 'true' : 'false',
  final int number => '$number',
  final double number => _jsNumberToString(number),
  _ => '$value',
};

String _jsNumberToString(double value) {
  if (value.isNaN) return 'NaN';
  if (value == double.infinity) return 'Infinity';
  if (value == double.negativeInfinity) return '-Infinity';
  if (value == 0) return '0'; // JS renders -0 as "0".
  // JS drops the fractional part for integral doubles below 1e21, above which
  // it switches to exponential notation — as Dart's toString already does.
  if (value == value.roundToDouble() && value.abs() < 1e21) {
    return value.toStringAsFixed(0);
  }
  return '$value';
}

// ---------------------------------------------------------------------------
// server/push/token-store.ts
// ---------------------------------------------------------------------------

/// Narrow persistence seam for [PushTokenStore].
///
/// Upstream reaches straight for `node:fs`; injecting the four operations it
/// actually performs lets the suite exercise load/persist failure paths without
/// touching a real filesystem.
abstract interface class PushTokenStorage {
  /// Whether a token file is present. A missing file is not an error.
  bool exists();

  /// Tightens the file's permissions before it is read back.
  void ensurePrivate();

  /// Reads the raw JSON document.
  String read();

  /// Atomically replaces the document with [contents].
  void write(String contents);
}

/// Default [PushTokenStorage], reusing this package's existing
/// `private_files.dart` helpers so push tokens inherit the same 0600 handling
/// as every other secret the daemon writes.
final class FilePushTokenStorage implements PushTokenStorage {
  /// Creates storage backed by [file].
  const FilePushTokenStorage(this.file);

  /// The token document on disk.
  final File file;

  @override
  bool exists() => file.existsSync();

  @override
  void ensurePrivate() => ensurePrivateFile(file);

  @override
  String read() => file.readAsStringSync();

  @override
  void write(String contents) => writePrivateFileAtomic(file, contents);
}

/// Severity of a [PushTokenStore] diagnostic, mirroring the upstream pino call
/// that produced it.
enum PushTokenLogLevel {
  /// `logger.debug` — routine add/remove bookkeeping.
  debug,

  /// `logger.info` — tokens loaded at startup.
  info,

  /// `logger.warn` — a load or persist failure that was swallowed.
  warn,
}

/// Diagnostic emitted by [PushTokenStore], standing in for upstream's injected
/// pino logger.
typedef PushTokenLogger =
    void Function(PushTokenLogLevel level, String message, {Object? error});

/// Port of `PushTokenStore`.
///
/// Holds the Expo push tokens registered by mobile clients. Tokens are
/// persisted so pushes keep working across daemon restarts, and every disk
/// failure is swallowed with a warning — losing push delivery must never take
/// the daemon down with it.
final class PushTokenStore {
  /// Loads any previously persisted tokens from [storage].
  ///
  /// Loading happens in the constructor, exactly as upstream does, so a
  /// corrupt file leaves the store empty rather than half-populated.
  PushTokenStore(this.storage, {PushTokenLogger? logger}) : _log = logger {
    _loadFromStorage();
  }

  /// Where tokens are read from and written to.
  final PushTokenStorage storage;
  final PushTokenLogger? _log;

  // Insertion-ordered, matching the iteration order of a JS `Set`.
  Set<String> _tokens = <String>{};

  /// Registers [token], ignoring blank input and duplicates.
  ///
  /// Persists only when the set actually changed, so a client re-registering
  /// the same token on every reconnect does not rewrite the file.
  void addToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) return;
    if (_tokens.contains(normalized)) return;
    _tokens.add(normalized);
    _persist();
    _log?.call(PushTokenLogLevel.debug, 'Added token');
  }

  /// Unregisters [token], ignoring blank input and unknown tokens.
  void removeToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) return;
    if (_tokens.remove(normalized)) {
      _persist();
      _log?.call(PushTokenLogLevel.debug, 'Removed token');
    }
  }

  /// Every registered token, in registration order.
  List<String> getAllTokens() => _tokens.toList(growable: false);

  void _loadFromStorage() {
    try {
      if (!storage.exists()) return;
      storage.ensurePrivate();
      final decoded = jsonDecode(storage.read());
      _tokens = <String>{
        for (final token in _tokensFrom(decoded))
          if (token is String && token.trim().isNotEmpty) token.trim(),
      };
      _log?.call(PushTokenLogLevel.info, 'Loaded push tokens');
    } catch (error) {
      _log?.call(
        PushTokenLogLevel.warn,
        'Failed to load push tokens',
        error: error,
      );
    }
  }

  /// Reproduces `(JSON.parse(raw) as { tokens?: unknown }).tokens`.
  ///
  /// Deviation, made explicit because Dart cannot read a property off a
  /// non-object: reading `.tokens` off `null` throws in JS (so the document
  /// `null` is a load failure), while reading it off a number, string, boolean,
  /// or array yields `undefined` and degrades to an empty token list.
  static List<Object?> _tokensFrom(Object? decoded) {
    if (decoded == null) {
      throw const FormatException('Cannot read tokens of null');
    }
    if (decoded is! Map) return const [];
    final tokens = decoded['tokens'];
    return tokens is List ? tokens : const [];
  }

  void _persist() {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      storage.write(
        '${encoder.convert({'tokens': _tokens.toList(growable: false)})}\n',
      );
    } catch (error) {
      _log?.call(
        PushTokenLogLevel.warn,
        'Failed to persist push tokens',
        error: error,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// tasks/types.ts + tasks/task-graph.ts + tasks/execution-order.ts
// ---------------------------------------------------------------------------

/// Lifecycle state of a [Task]. Wire values match the upstream string union.
enum TaskStatus {
  /// Not yet available for execution.
  draft('draft'),

  /// Available once dependencies and children are done.
  open('open'),

  /// Currently being worked on; scheduled just like [open].
  inProgress('in_progress'),

  /// Completed; satisfies dependents.
  done('done'),

  /// Terminal failure; never satisfies dependents.
  failed('failed');

  const TaskStatus(this.wireValue);

  /// The `TaskStatus` string this value serialises to.
  final String wireValue;

  /// Parses a wire value, throwing on anything unrecognised.
  static TaskStatus fromWire(Object? value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown task status: $value'),
  );
}

/// A timestamped markdown note attached to a [Task].
final class TaskNote {
  /// Creates a note.
  const TaskNote({required this.timestamp, required this.content});

  /// ISO-8601 instant the note was written.
  final String timestamp;

  /// Markdown body.
  final String content;
}

/// Port of the upstream `Task` document.
///
/// Only the scheduling-relevant fields participate in execution order; the
/// rest are carried so a ported store can round-trip the document unchanged.
final class Task {
  /// Creates a task.
  const Task({
    required this.id,
    required this.title,
    required this.status,
    required this.created,
    this.deps = const [],
    this.parentId,
    this.body = '',
    this.acceptanceCriteria = const [],
    this.notes = const [],
    this.assignee,
    this.priority,
    this.raw = '',
  });

  /// Short random hash, e.g. `a1b2c3d4`.
  final String id;

  /// Human-readable summary.
  final String title;

  /// Lifecycle state.
  final TaskStatus status;

  /// Task IDs that must be [TaskStatus.done] before this one can start.
  final List<String> deps;

  /// Parent task ID, forming the hierarchy that drives context inheritance.
  final String? parentId;

  /// Long-form markdown document.
  final String body;

  /// Immutable verification checklist.
  final List<String> acceptanceCriteria;

  /// Append-only note log.
  final List<TaskNote> notes;

  /// ISO-8601 creation instant; the tiebreaker for execution order.
  final String created;

  /// Optional agent override.
  final String? assignee;

  /// Lower number sorts first; absent sorts after every prioritised task.
  final int? priority;

  /// Raw markdown file content.
  final String raw;
}

/// The slice of the upstream `TaskStore` that graph loading needs.
///
/// Narrowed deliberately: execution order never mutates, so a caller can back
/// this with an in-memory map without stubbing two dozen unused methods.
abstract interface class TaskGraphStore {
  /// Every task known to the store.
  Future<List<Task>> list();

  /// A single task, or null when it does not exist.
  Future<Task?> get(String id);

  /// Every transitive child of [id].
  Future<List<Task>> getDescendants(String id);
}

/// Precomputed view over a task set, scoped to the subtree under consideration.
final class TaskGraph {
  /// Creates a graph. Prefer [loadScopedTaskGraph].
  const TaskGraph({
    required this.allTasks,
    required this.candidates,
    required this.taskMap,
    required this.childrenMap,
    required this.candidateIds,
    required this.doneTaskIds,
  });

  /// Every task in the store, used to resolve dependencies that point outside
  /// the scope.
  final List<Task> allTasks;

  /// Tasks inside the requested scope; the only ones ever scheduled.
  final List<Task> candidates;

  /// [allTasks] indexed by ID.
  final Map<String, Task> taskMap;

  /// Parent ID to direct children, over [allTasks].
  final Map<String, List<Task>> childrenMap;

  /// IDs of [candidates], for the scoped child check.
  final Set<String> candidateIds;

  /// IDs of tasks already done anywhere in the store.
  final Set<String> doneTaskIds;
}

/// Port of `sortByPriorityThenCreated`.
///
/// Prioritised tasks sort before unprioritised ones, then by ascending
/// priority, then by creation instant.
///
/// Deviation: upstream compares timestamps with `localeCompare`. Dart uses
/// [String.compareTo] (UTF-16 code-unit order), which agrees with locale
/// collation for the ASCII ISO-8601 timestamps these fields hold.
int sortByPriorityThenCreated(Task a, Task b) {
  if (a.priority != null && b.priority == null) return -1;
  if (a.priority == null && b.priority != null) return 1;
  if (a.priority != null && b.priority != null) {
    if (a.priority != b.priority) return a.priority! - b.priority!;
  }
  return a.created.compareTo(b.created);
}

/// Port of `buildTaskMap`.
///
/// Later duplicates win, matching `new Map(entries)`.
Map<String, Task> buildTaskMap(List<Task> tasks) => {
  for (final task in tasks) task.id: task,
};

/// Port of `buildChildrenMap`.
///
/// Children keep their input order; [buildSortedChildrenMap] is what reorders
/// them for display.
Map<String, List<Task>> buildChildrenMap(List<Task> tasks) {
  final childrenMap = <String, List<Task>>{};
  for (final task in tasks) {
    final parentId = task.parentId;
    // Upstream guards with `if (task.parentId)`, so an empty-string parent is
    // falsy and skipped; the emptiness check keeps that behaviour.
    if (parentId == null || parentId.isEmpty) continue;
    (childrenMap[parentId] ??= <Task>[]).add(task);
  }
  return childrenMap;
}

/// Port of `getTasksById`.
///
/// Unknown IDs are dropped rather than erroring, because a scope can reference
/// dependencies that were deleted.
List<Task> getTasksById(TaskGraph graph, Iterable<String> taskIds) => [
  for (final taskId in taskIds)
    if (graph.taskMap[taskId] case final task?) task,
];

/// Port of `isTaskExecutableInOrder`.
///
/// A task can run once every dependency is complete and every *in-scope* child
/// is complete. Out-of-scope children are ignored so scoping to a subtree does
/// not deadlock on siblings the caller never asked about.
bool isTaskExecutableInOrder(
  TaskGraph graph,
  String taskId,
  Set<String> completedTaskIds,
) {
  final task = graph.taskMap[taskId];
  return task != null &&
      _areTaskDepsDone(graph, task, completedTaskIds) &&
      _areTaskChildrenDone(graph, task.id, completedTaskIds, scoped: true);
}

/// Port of `loadScopedTaskGraph`.
///
/// With no [scopeId] every task is a candidate; with one, the scope task and
/// its descendants are.
///
/// Deviation: upstream's `if (!scopeId)` treats an empty string as "no scope",
/// which the explicit emptiness check reproduces.
Future<TaskGraph> loadScopedTaskGraph(
  TaskGraphStore store, [
  String? scopeId,
]) async {
  final allTasks = await store.list();
  final candidates = await _loadScopedCandidates(store, allTasks, scopeId);

  return TaskGraph(
    allTasks: allTasks,
    candidates: candidates,
    taskMap: buildTaskMap(allTasks),
    childrenMap: buildChildrenMap(allTasks),
    candidateIds: {for (final task in candidates) task.id},
    doneTaskIds: {
      for (final task in allTasks)
        if (task.status == TaskStatus.done) task.id,
    },
  );
}

Future<List<Task>> _loadScopedCandidates(
  TaskGraphStore store,
  List<Task> allTasks,
  String? scopeId,
) async {
  if (scopeId == null || scopeId.isEmpty) return allTasks;

  final scopeTask = await store.get(scopeId);
  final descendants = await store.getDescendants(scopeId);
  return scopeTask != null ? [scopeTask, ...descendants] : descendants;
}

/// A dependency only counts as satisfied when it both exists and is complete —
/// a dangling dependency blocks forever rather than being silently ignored.
bool _areTaskDepsDone(
  TaskGraph graph,
  Task task,
  Set<String> completedTaskIds,
) => task.deps.every(
  (depId) =>
      graph.taskMap.containsKey(depId) && completedTaskIds.contains(depId),
);

bool _areTaskChildrenDone(
  TaskGraph graph,
  String taskId,
  Set<String> completedTaskIds, {
  bool scoped = false,
}) {
  final children = graph.childrenMap[taskId] ?? const <Task>[];
  return children.every((child) {
    if (scoped && !graph.candidateIds.contains(child.id)) return true;
    return completedTaskIds.contains(child.id);
  });
}

/// Result of [computeExecutionOrder].
final class ExecutionOrderResult {
  /// Creates a result.
  const ExecutionOrderResult({
    required this.timeline,
    required this.orderMap,
    required this.blocked,
  });

  /// Tasks in execution order: completed history first, then the simulated
  /// future.
  final List<Task> timeline;

  /// Task ID to its index in [timeline].
  final Map<String, int> orderMap;

  /// Task IDs that can never become runnable — missing dependencies, dependency
  /// cycles, or children that will never complete.
  final Set<String> blocked;
}

/// Port of `computeExecutionOrder`.
///
/// Replays `task ready` until nothing else can run, which is what turns a
/// dependency graph into the linear plan the UI renders. Done tasks are
/// emitted first in historical order so the timeline reads as past-then-future;
/// whatever is still unscheduled when the simulation stalls is [blocked].
Future<ExecutionOrderResult> computeExecutionOrder(
  TaskGraphStore store, [
  String? scopeId,
]) async {
  final graph = await loadScopedTaskGraph(store, scopeId);

  final simDone = {...graph.doneTaskIds};
  final remaining = <String>{
    for (final task in graph.candidates)
      if (task.status == TaskStatus.open ||
          task.status == TaskStatus.inProgress)
        task.id,
  };

  final timeline = <Task>[];
  final orderMap = <String, int>{};
  var orderIdx = 0;

  final done = _stableSorted([
    for (final task in graph.candidates)
      if (task.status == TaskStatus.done) task,
  ], (a, b) => a.created.compareTo(b.created));
  for (final task in done) {
    timeline.add(task);
    orderMap[task.id] = orderIdx++;
  }

  while (remaining.isNotEmpty) {
    final readyNow = _stableSorted([
      for (final task in getTasksById(graph, remaining))
        if (isTaskExecutableInOrder(graph, task.id, simDone)) task,
    ], sortByPriorityThenCreated);

    if (readyNow.isEmpty) break;

    final next = readyNow.first;
    timeline.add(next);
    orderMap[next.id] = orderIdx++;
    simDone.add(next.id);
    remaining.remove(next.id);
  }

  return ExecutionOrderResult(
    timeline: timeline,
    orderMap: orderMap,
    blocked: remaining,
  );
}

/// Port of `buildSortedChildrenMap`.
///
/// Reorders each sibling list to match the execution plan so the tree view and
/// the timeline agree. Tasks absent from [orderMap] sort last, preserving their
/// relative order.
Map<String, List<Task>> buildSortedChildrenMap(
  List<Task> tasks,
  Map<String, int> orderMap,
) {
  final childrenMap = buildChildrenMap(tasks);

  for (final parentId in childrenMap.keys.toList(growable: false)) {
    childrenMap[parentId] = _stableSorted(childrenMap[parentId]!, (a, b) {
      // Upstream uses `orderMap.get(id) ?? Infinity` and subtracts. Two absent
      // tasks yield `Infinity - Infinity`, i.e. NaN, which V8's stable sort
      // treats as "equal"; comparing doubles reproduces that exactly.
      final orderA = (orderMap[a.id] ?? double.infinity).toDouble();
      final orderB = (orderMap[b.id] ?? double.infinity).toDouble();
      return orderA.compareTo(orderB);
    });
  }

  return childrenMap;
}

/// Stable sort.
///
/// Deviation guard: `Array.prototype.sort` has been stable since ES2019 and the
/// upstream comparators rely on it for ties (equal priority and equal `created`,
/// or two tasks both missing from the order map). Dart's [List.sort] is only
/// stable for short lists, so ties are broken by original index here.
List<T> _stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final decorated = List<(int, T)>.generate(
    items.length,
    (index) => (index, items[index]),
  );
  decorated.sort((a, b) {
    final result = compare(a.$2, b.$2);
    return result != 0 ? result : a.$1.compareTo(b.$1);
  });
  return [for (final entry in decorated) entry.$2];
}
