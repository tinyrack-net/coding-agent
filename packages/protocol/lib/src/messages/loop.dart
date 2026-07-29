enum LoopStatus {
  running,
  succeeded,
  failed,
  stopped;

  static LoopStatus fromWire(Object? value) => switch (value) {
    'running' => running,
    'succeeded' => succeeded,
    'failed' => failed,
    'stopped' => stopped,
    _ => throw FormatException('invalid loop status: $value'),
  };

  String get wireName => name;
}

enum LoopIterationStatus {
  running,
  succeeded,
  failed,
  stopped;

  static LoopIterationStatus fromWire(Object? value) => switch (value) {
    'running' => running,
    'succeeded' => succeeded,
    'failed' => failed,
    'stopped' => stopped,
    _ => throw FormatException('invalid loop iteration status: $value'),
  };

  String get wireName => name;
}

enum LoopWorkerOutcome {
  completed,
  failed,
  canceled;

  static LoopWorkerOutcome? fromWire(Object? value) => switch (value) {
    null => null,
    'completed' => completed,
    'failed' => failed,
    'canceled' => canceled,
    _ => throw FormatException('invalid loop worker outcome: $value'),
  };

  String get wireName => name;
}

enum LoopLogSource {
  loop,
  worker,
  verifier,
  verifyCheck;

  static LoopLogSource fromWire(Object? value) => switch (value) {
    'loop' => loop,
    'worker' => worker,
    'verifier' => verifier,
    'verify-check' => verifyCheck,
    _ => throw FormatException('invalid loop log source: $value'),
  };

  String get wireName => this == verifyCheck ? 'verify-check' : name;
}

enum LoopLogLevel {
  info,
  error;

  static LoopLogLevel fromWire(Object? value) => switch (value) {
    'info' => info,
    'error' => error,
    _ => throw FormatException('invalid loop log level: $value'),
  };

  String get wireName => name;
}

final class LoopLogEntry {
  const LoopLogEntry({
    required this.seq,
    required this.timestamp,
    required this.iteration,
    required this.source,
    required this.level,
    required this.text,
  });

  final int seq;
  final String timestamp;
  final int? iteration;
  final LoopLogSource source;
  final LoopLogLevel level;
  final String text;

  factory LoopLogEntry.fromJson(Map<String, Object?> json) => LoopLogEntry(
    seq: _positiveInt(json, 'seq'),
    timestamp: _string(json, 'timestamp'),
    iteration: _nullablePositiveInt(json, 'iteration'),
    source: LoopLogSource.fromWire(json['source']),
    level: LoopLogLevel.fromWire(json['level']),
    text: _string(json, 'text'),
  );

  Map<String, Object?> toJson() => {
    'seq': seq,
    'timestamp': timestamp,
    'iteration': iteration,
    'source': source.wireName,
    'level': level.wireName,
    'text': text,
  };
}

final class LoopVerifyCheckResult {
  const LoopVerifyCheckResult({
    required this.command,
    required this.exitCode,
    required this.passed,
    required this.stdout,
    required this.stderr,
    required this.startedAt,
    required this.completedAt,
  });

  final String command;
  final int exitCode;
  final bool passed;
  final String stdout;
  final String stderr;
  final String startedAt;
  final String completedAt;

  factory LoopVerifyCheckResult.fromJson(Map<String, Object?> json) =>
      LoopVerifyCheckResult(
        command: _string(json, 'command'),
        exitCode: _int(json, 'exitCode'),
        passed: _bool(json, 'passed'),
        stdout: _string(json, 'stdout'),
        stderr: _string(json, 'stderr'),
        startedAt: _string(json, 'startedAt'),
        completedAt: _string(json, 'completedAt'),
      );

  Map<String, Object?> toJson() => {
    'command': command,
    'exitCode': exitCode,
    'passed': passed,
    'stdout': stdout,
    'stderr': stderr,
    'startedAt': startedAt,
    'completedAt': completedAt,
  };
}

final class LoopVerifyPromptResult {
  const LoopVerifyPromptResult({
    required this.passed,
    required this.reason,
    required this.verifierAgentId,
    required this.startedAt,
    required this.completedAt,
  });

  final bool passed;
  final String reason;
  final String? verifierAgentId;
  final String startedAt;
  final String completedAt;

  factory LoopVerifyPromptResult.fromJson(Map<String, Object?> json) =>
      LoopVerifyPromptResult(
        passed: _bool(json, 'passed'),
        reason: _string(json, 'reason'),
        verifierAgentId: _nullableString(json, 'verifierAgentId'),
        startedAt: _string(json, 'startedAt'),
        completedAt: _string(json, 'completedAt'),
      );

  Map<String, Object?> toJson() => {
    'passed': passed,
    'reason': reason,
    'verifierAgentId': verifierAgentId,
    'startedAt': startedAt,
    'completedAt': completedAt,
  };
}

final class LoopIterationRecord {
  const LoopIterationRecord({
    required this.index,
    required this.workerAgentId,
    required this.workerStartedAt,
    required this.workerCompletedAt,
    required this.verifierAgentId,
    required this.status,
    required this.workerOutcome,
    required this.failureReason,
    required this.verifyChecks,
    required this.verifyPrompt,
  });

  final int index;
  final String? workerAgentId;
  final String workerStartedAt;
  final String? workerCompletedAt;
  final String? verifierAgentId;
  final LoopIterationStatus status;
  final LoopWorkerOutcome? workerOutcome;
  final String? failureReason;
  final List<LoopVerifyCheckResult> verifyChecks;
  final LoopVerifyPromptResult? verifyPrompt;

  factory LoopIterationRecord.fromJson(Map<String, Object?> json) =>
      LoopIterationRecord(
        index: _positiveInt(json, 'index'),
        workerAgentId: _nullableString(json, 'workerAgentId'),
        workerStartedAt: _string(json, 'workerStartedAt'),
        workerCompletedAt: _nullableString(json, 'workerCompletedAt'),
        verifierAgentId: _nullableString(json, 'verifierAgentId'),
        status: LoopIterationStatus.fromWire(json['status']),
        workerOutcome: LoopWorkerOutcome.fromWire(json['workerOutcome']),
        failureReason: _nullableString(json, 'failureReason'),
        verifyChecks: _objectList(
          json,
          'verifyChecks',
          LoopVerifyCheckResult.fromJson,
        ),
        verifyPrompt: json['verifyPrompt'] == null
            ? null
            : LoopVerifyPromptResult.fromJson(
                _object(json['verifyPrompt'], 'verifyPrompt'),
              ),
      );

  Map<String, Object?> toJson() => {
    'index': index,
    'workerAgentId': workerAgentId,
    'workerStartedAt': workerStartedAt,
    'workerCompletedAt': workerCompletedAt,
    'verifierAgentId': verifierAgentId,
    'status': status.wireName,
    'workerOutcome': workerOutcome?.wireName,
    'failureReason': failureReason,
    'verifyChecks': verifyChecks.map((value) => value.toJson()).toList(),
    'verifyPrompt': verifyPrompt?.toJson(),
  };
}

final class LoopRecord {
  const LoopRecord({
    required this.id,
    required this.name,
    required this.prompt,
    required this.cwd,
    required this.provider,
    required this.model,
    required this.modeId,
    required this.workerProvider,
    required this.workerModel,
    required this.verifierProvider,
    required this.verifierModel,
    required this.verifierModeId,
    required this.verifyPrompt,
    required this.verifyChecks,
    required this.archive,
    required this.sleepMs,
    required this.maxIterations,
    required this.maxTimeMs,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    required this.completedAt,
    required this.stopRequestedAt,
    required this.iterations,
    required this.logs,
    required this.nextLogSeq,
    required this.activeIteration,
    required this.activeWorkerAgentId,
    required this.activeVerifierAgentId,
  });

  final String id;
  final String? name;
  final String prompt;
  final String cwd;
  final String provider;
  final String? model;
  final String? modeId;
  final String? workerProvider;
  final String? workerModel;
  final String? verifierProvider;
  final String? verifierModel;
  final String? verifierModeId;
  final String? verifyPrompt;
  final List<String> verifyChecks;
  final bool archive;
  final int sleepMs;
  final int? maxIterations;
  final int? maxTimeMs;
  final LoopStatus status;
  final String createdAt;
  final String updatedAt;
  final String startedAt;
  final String? completedAt;
  final String? stopRequestedAt;
  final List<LoopIterationRecord> iterations;
  final List<LoopLogEntry> logs;
  final int nextLogSeq;
  final int? activeIteration;
  final String? activeWorkerAgentId;
  final String? activeVerifierAgentId;

  factory LoopRecord.fromJson(Map<String, Object?> json) => LoopRecord(
    id: _string(json, 'id'),
    name: _nullableString(json, 'name'),
    prompt: _string(json, 'prompt'),
    cwd: _string(json, 'cwd'),
    provider: _string(json, 'provider'),
    model: _nullableString(json, 'model'),
    modeId: _nullableString(json, 'modeId'),
    workerProvider: _nullableString(json, 'workerProvider'),
    workerModel: _nullableString(json, 'workerModel'),
    verifierProvider: _nullableString(json, 'verifierProvider'),
    verifierModel: _nullableString(json, 'verifierModel'),
    verifierModeId: _nullableString(json, 'verifierModeId'),
    verifyPrompt: _nullableString(json, 'verifyPrompt'),
    verifyChecks: _stringList(json, 'verifyChecks'),
    archive: _bool(json, 'archive'),
    sleepMs: _nonNegativeInt(json, 'sleepMs'),
    maxIterations: _nullablePositiveInt(json, 'maxIterations'),
    maxTimeMs: _nullablePositiveInt(json, 'maxTimeMs'),
    status: LoopStatus.fromWire(json['status']),
    createdAt: _string(json, 'createdAt'),
    updatedAt: _string(json, 'updatedAt'),
    startedAt: _string(json, 'startedAt'),
    completedAt: _nullableString(json, 'completedAt'),
    stopRequestedAt: _nullableString(json, 'stopRequestedAt'),
    iterations: _objectList(json, 'iterations', LoopIterationRecord.fromJson),
    logs: _objectList(json, 'logs', LoopLogEntry.fromJson),
    nextLogSeq: _positiveInt(json, 'nextLogSeq'),
    activeIteration: _nullablePositiveInt(json, 'activeIteration'),
    activeWorkerAgentId: _nullableString(json, 'activeWorkerAgentId'),
    activeVerifierAgentId: _nullableString(json, 'activeVerifierAgentId'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'cwd': cwd,
    'provider': provider,
    'model': model,
    'modeId': modeId,
    'workerProvider': workerProvider,
    'workerModel': workerModel,
    'verifierProvider': verifierProvider,
    'verifierModel': verifierModel,
    'verifierModeId': verifierModeId,
    'verifyPrompt': verifyPrompt,
    'verifyChecks': verifyChecks,
    'archive': archive,
    'sleepMs': sleepMs,
    'maxIterations': maxIterations,
    'maxTimeMs': maxTimeMs,
    'status': status.wireName,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'startedAt': startedAt,
    'completedAt': completedAt,
    'stopRequestedAt': stopRequestedAt,
    'iterations': iterations.map((value) => value.toJson()).toList(),
    'logs': logs.map((value) => value.toJson()).toList(),
    'nextLogSeq': nextLogSeq,
    'activeIteration': activeIteration,
    'activeWorkerAgentId': activeWorkerAgentId,
    'activeVerifierAgentId': activeVerifierAgentId,
  };
}

final class LoopListItem {
  const LoopListItem({
    required this.id,
    required this.name,
    required this.status,
    required this.cwd,
    required this.createdAt,
    required this.updatedAt,
    required this.activeIteration,
  });

  final String id;
  final String? name;
  final LoopStatus status;
  final String cwd;
  final String createdAt;
  final String updatedAt;
  final int? activeIteration;

  factory LoopListItem.fromJson(Map<String, Object?> json) => LoopListItem(
    id: _string(json, 'id'),
    name: _nullableString(json, 'name'),
    status: LoopStatus.fromWire(json['status']),
    cwd: _string(json, 'cwd'),
    createdAt: _string(json, 'createdAt'),
    updatedAt: _string(json, 'updatedAt'),
    activeIteration: _nullablePositiveInt(json, 'activeIteration'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'status': status.wireName,
    'cwd': cwd,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'activeIteration': activeIteration,
  };
}

final class LoopRunRequest {
  const LoopRunRequest({
    required this.requestId,
    required this.prompt,
    required this.cwd,
    this.provider,
    this.model,
    this.modeId,
    this.workerProvider,
    this.workerModel,
    this.verifierProvider,
    this.verifierModel,
    this.verifierModeId,
    this.verifyPrompt,
    this.verifyChecks = const [],
    this.archive,
    this.name,
    this.sleepMs,
    this.maxIterations,
    this.maxTimeMs,
  });

  static const type = 'loop/run';

  final String requestId;
  final String prompt;
  final String cwd;
  final String? provider;
  final String? model;
  final String? modeId;
  final String? workerProvider;
  final String? workerModel;
  final String? verifierProvider;
  final String? verifierModel;
  final String? verifierModeId;
  final String? verifyPrompt;
  final List<String> verifyChecks;
  final bool? archive;
  final String? name;
  final int? sleepMs;
  final int? maxIterations;
  final int? maxTimeMs;

  factory LoopRunRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return LoopRunRequest(
      requestId: _string(json, 'requestId'),
      prompt: _nonEmptyString(json, 'prompt'),
      cwd: _string(json, 'cwd'),
      provider: _optionalString(json, 'provider'),
      model: _optionalNonEmptyString(json, 'model'),
      modeId: _optionalNonEmptyString(json, 'modeId'),
      workerProvider: _optionalString(json, 'workerProvider'),
      workerModel: _optionalNonEmptyString(json, 'workerModel'),
      verifierProvider: _optionalString(json, 'verifierProvider'),
      verifierModel: _optionalNonEmptyString(json, 'verifierModel'),
      verifierModeId: _optionalNonEmptyString(json, 'verifierModeId'),
      verifyPrompt: _optionalNonEmptyString(json, 'verifyPrompt'),
      verifyChecks: json.containsKey('verifyChecks')
          ? _nonEmptyStringList(json, 'verifyChecks')
          : const [],
      archive: _optionalBool(json, 'archive'),
      name: _optionalNonEmptyString(json, 'name'),
      sleepMs: _optionalNonNegativeInt(json, 'sleepMs'),
      maxIterations: _optionalPositiveInt(json, 'maxIterations'),
      maxTimeMs: _optionalPositiveInt(json, 'maxTimeMs'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'prompt': prompt,
    'cwd': cwd,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (modeId != null) 'modeId': modeId,
    if (workerProvider != null) 'workerProvider': workerProvider,
    if (workerModel != null) 'workerModel': workerModel,
    if (verifierProvider != null) 'verifierProvider': verifierProvider,
    if (verifierModel != null) 'verifierModel': verifierModel,
    if (verifierModeId != null) 'verifierModeId': verifierModeId,
    if (verifyPrompt != null) 'verifyPrompt': verifyPrompt,
    if (verifyChecks.isNotEmpty) 'verifyChecks': verifyChecks,
    if (archive != null) 'archive': archive,
    if (name != null) 'name': name,
    if (sleepMs != null) 'sleepMs': sleepMs,
    if (maxIterations != null) 'maxIterations': maxIterations,
    if (maxTimeMs != null) 'maxTimeMs': maxTimeMs,
  };
}

final class LoopListRequest {
  const LoopListRequest({required this.requestId});

  static const type = 'loop/list';
  final String requestId;

  factory LoopListRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return LoopListRequest(requestId: _string(json, 'requestId'));
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class LoopIdRequest {
  const LoopIdRequest({
    required this.type,
    required this.requestId,
    required this.id,
    this.afterSeq,
  });

  static const inspectType = 'loop/inspect';
  static const logsType = 'loop/logs';
  static const stopType = 'loop/stop';

  final String type;
  final String requestId;
  final String id;
  final int? afterSeq;

  factory LoopIdRequest.fromJson(Map<String, Object?> json) {
    final type = _string(json, 'type');
    if (!const {inspectType, logsType, stopType}.contains(type)) {
      throw FormatException('invalid loop request type: $type');
    }
    if (type != logsType && json.containsKey('afterSeq')) {
      throw FormatException('afterSeq is only valid for $logsType');
    }
    return LoopIdRequest(
      type: type,
      requestId: _string(json, 'requestId'),
      id: _nonEmptyString(json, 'id'),
      afterSeq: type == logsType
          ? _optionalNonNegativeInt(json, 'afterSeq')
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'id': id,
    if (afterSeq != null) 'afterSeq': afterSeq,
  };
}

Map<String, Object?> loopResponse({
  required String requestType,
  required String requestId,
  required Map<String, Object?> payload,
}) => {
  'type': '$requestType/response',
  'payload': {'requestId': requestId, ...payload},
};

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('expected type $expected');
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String _nonEmptyString(Map<String, Object?> json, String key) {
  final value = _string(json, key).trim();
  if (value.isEmpty) throw FormatException('$key cannot be empty');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

String? _optionalNonEmptyString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _nonEmptyString(json, key);
}

String? _optionalString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _string(json, key);
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _bool(json, key);
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = _int(json, key);
  if (value <= 0) throw FormatException('$key must be a positive integer');
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) {
  final value = _int(json, key);
  if (value < 0) throw FormatException('$key must be a non-negative integer');
  return value;
}

int? _nullablePositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw FormatException('$key must be a positive integer or null');
  }
  return value;
}

int? _optionalPositiveInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _positiveInt(json, key);
}

int? _optionalNonNegativeInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _nonNegativeInt(json, key);
}

List<String> _stringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$key must be a string array');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

List<String> _nonEmptyStringList(Map<String, Object?> json, String key) {
  final values = _stringList(json, key);
  if (values.any((value) => value.trim().isEmpty)) {
    throw FormatException('$key cannot contain empty strings');
  }
  return List.unmodifiable(values.map((value) => value.trim()));
}

Map<String, Object?> _object(Object? value, String key) {
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

List<T> _objectList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> value) decode,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return List<T>.unmodifiable(value.map((item) => decode(_object(item, key))));
}
