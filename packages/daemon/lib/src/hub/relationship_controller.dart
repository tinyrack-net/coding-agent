import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../server/private_files.dart';
import 'relationship_remote.dart';
import 'relationship_retry.dart';

const hubRelationshipFileName = 'hub-relationship.json';
const hubExecutionScope = 'hub.execution.*';
const _forceDisconnectWarning =
    'Local Hub credential removed; remote revocation may remain pending.';

abstract interface class ScheduledHubRelationshipTask {
  void cancel();
}

abstract interface class HubRelationshipClock {
  DateTime now();
  ScheduledHubRelationshipTask schedule(Duration delay, void Function() task);
}

final class SystemHubRelationshipClock implements HubRelationshipClock {
  const SystemHubRelationshipClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  ScheduledHubRelationshipTask schedule(Duration delay, void Function() task) =>
      _TimerHubRelationshipTask(Timer(delay, task));
}

final class _TimerHubRelationshipTask implements ScheduledHubRelationshipTask {
  const _TimerHubRelationshipTask(this.timer);
  final Timer timer;

  @override
  void cancel() => timer.cancel();
}

typedef HubSocketAttacher =
    FutureOr<void> Function(
      HubSocket socket, {
      required String daemonId,
      required List<String> scopes,
    });

final class HubDisconnectResult {
  const HubDisconnectResult({required this.status, this.warning});
  final HubRelationshipStatus status;
  final String? warning;
}

final class HubRelationshipController {
  HubRelationshipController({
    required this.home,
    required this.serverId,
    required this.daemonPublicKey,
    required this.remote,
    required this.attachSocket,
    this.clock = const SystemHubRelationshipClock(),
    HubRelationshipRetryPolicy? retryPolicy,
    String Function()? createDaemonId,
    String Function()? createIdempotencyKey,
    List<int> Function(int length)? randomBytes,
    void Function(String message)? log,
  }) : retryPolicy = retryPolicy ?? BoundedExponentialHubRetryPolicy(),
       _createDaemonId = createDaemonId ?? const Uuid().v4,
       _createIdempotencyKey = createIdempotencyKey ?? const Uuid().v4,
       _randomBytes = randomBytes ?? _secureRandomBytes,
       _log = log ?? _ignoreLog {
    _file = File(p.join(home, hubRelationshipFileName));
    _record = _load();
    switch (_record?.state) {
      case 'revoked':
        _state = HubConnectionState.revoked;
        _lastError = _record?.reason;
      case 'disconnecting':
        _state = HubConnectionState.disconnecting;
      case 'pending' || 'active':
        _state = HubConnectionState.connecting;
      case null:
        _state = HubConnectionState.notConnected;
    }
  }

  final String home;
  final String serverId;
  final String daemonPublicKey;
  final HubRelationshipRemote remote;
  final HubSocketAttacher attachSocket;
  final HubRelationshipClock clock;
  final HubRelationshipRetryPolicy retryPolicy;
  final String Function() _createDaemonId;
  final String Function() _createIdempotencyKey;
  final List<int> Function(int length) _randomBytes;
  final void Function(String message) _log;

  late final File _file;
  _HubRelationshipRecord? _record;
  HubConnectionState _state = HubConnectionState.notConnected;
  String? _connectedAt;
  String? _lastError;
  HubSocketConnection? _socket;
  ScheduledHubRelationshipTask? _retry;
  var _generation = 0;
  var _enrollmentGeneration = 0;
  var _retryAttempt = 0;
  final Set<Future<void>> _inFlightEnrollments = {};

  HubRelationshipStatus get status => HubRelationshipStatus(
    state: _state,
    daemonId: _record?.daemonId,
    hubOrigin: _record?.hubOrigin,
    scopes: List<String>.unmodifiable(_record?.scopes ?? const []),
    connectedAt: _connectedAt,
    lastError: _lastError,
  );

  Future<void> start() async {
    final record = _record;
    if (record == null || record.state == 'revoked') return;
    if (record.state == 'active') {
      _openSocket(record, reconnecting: false);
      return;
    }
    if (record.state == 'pending') {
      final enrollmentGeneration = _beginEnrollmentAttempt();
      try {
        await _tryEnrollment(record, enrollmentGeneration);
      } on HubEnrollmentRejectedError catch (error) {
        _log(
          'discarded rejected pending Hub enrollment during startup '
          '(${error.statusCode})',
        );
      }
      return;
    }
    await _tryRevocation(record);
  }

  Future<void> stop() async {
    _cancelLifecycle();
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<HubRelationshipStatus> connect({
    required String hubUrl,
    required String token,
  }) async {
    if (token.trim().isEmpty) {
      throw const FormatException('Hub enrollment token is required');
    }
    final hubOrigin = normalizeHubUrl(hubUrl);
    final existing = _record;
    if (existing?.state == 'pending') {
      if (hubOrigin != existing!.hubOrigin) {
        throw StateError(
          'A pending Hub enrollment already exists for a different Hub',
        );
      }
      final pending = existing.withEnrollmentToken(token);
      _persist(pending);
      _record = pending;
      _state = HubConnectionState.connecting;
      _lastError = null;
      await _tryEnrollment(pending, _beginEnrollmentAttempt());
      return status;
    }
    if (existing != null && existing.state != 'revoked') {
      throw StateError('This daemon already has a Hub relationship');
    }

    final credential = _base64UrlNoPadding(_randomBytes(32));
    final pending = _HubRelationshipRecord.pending(
      daemonId: _createDaemonId(),
      idempotencyKey: _createIdempotencyKey(),
      hubOrigin: hubOrigin,
      createdAt: clock.now().toUtc().toIso8601String(),
      credential: credential,
      token: token,
      serverId: serverId,
      daemonPublicKey: daemonPublicKey,
    );
    _persist(pending);
    _record = pending;
    _state = HubConnectionState.connecting;
    _lastError = null;
    await _tryEnrollment(pending, _beginEnrollmentAttempt());
    return status;
  }

  Future<HubDisconnectResult> disconnect({bool force = false}) async {
    final waitForEnrollment = _record?.state == 'pending';
    _cancelLifecycle();
    final socket = _socket;
    _socket = null;
    await socket?.close();

    final record = _record;
    if (record == null || record.state == 'revoked') {
      _remove();
      return HubDisconnectResult(status: status);
    }
    if (force) {
      _remove();
      return HubDisconnectResult(
        status: status,
        warning: _forceDisconnectWarning,
      );
    }

    final disconnecting = record.asDisconnecting();
    _persist(disconnecting);
    _record = disconnecting;
    _state = HubConnectionState.disconnecting;
    if (waitForEnrollment) {
      await Future.wait(_inFlightEnrollments.toList(growable: false));
    }
    await _tryRevocation(disconnecting);
    return HubDisconnectResult(status: status);
  }

  Future<void> _tryEnrollment(
    _HubRelationshipRecord pending,
    int enrollmentGeneration,
  ) async {
    if (enrollmentGeneration != _enrollmentGeneration) return;
    final request = remote.enroll(
      HubEnrollment(
        daemonId: pending.daemonId,
        idempotencyKey: pending.idempotencyKey!,
        hubOrigin: pending.hubOrigin,
        token: pending.enrollmentToken!,
        serverId: pending.identityServerId!,
        daemonPublicKey: pending.identityPublicKey!,
        credentialVerifier: sha256
            .convert(utf8.encode(pending.credential!))
            .bytes
            .let(_base64UrlNoPadding),
        scopes: pending.scopes,
      ),
    );
    final settled = request.then<void>((_) {}, onError: (_) {});
    _inFlightEnrollments.add(settled);
    try {
      final enrollment = await request;
      if (enrollmentGeneration != _enrollmentGeneration) return;
      if (enrollment.daemonId != pending.daemonId ||
          !enrollment.scopes.contains(hubExecutionScope)) {
        throw StateError(
          'Hub enrollment response did not match the pending relationship',
        );
      }
      final active = pending.asActive(enrollment.webSocketUrl);
      _persist(active);
      _record = active;
      _retry = null;
      _retryAttempt = 0;
      _openSocket(active, reconnecting: false);
    } catch (error) {
      if (enrollmentGeneration != _enrollmentGeneration) return;
      if (error is HubEnrollmentRejectedError) {
        _remove();
        rethrow;
      }
      _lastError = '$error';
      _scheduleEnrollment(pending, enrollmentGeneration);
    } finally {
      _inFlightEnrollments.remove(settled);
    }
  }

  void _openSocket(
    _HubRelationshipRecord record, {
    required bool reconnecting,
  }) {
    final generation = ++_generation;
    _state = reconnecting
        ? HubConnectionState.reconnecting
        : HubConnectionState.connecting;
    _socket = remote.openSocket(
      HubSocketCredentials(
        daemonId: record.daemonId,
        webSocketUrl: record.webSocketUrl!,
        credential: record.credential!,
      ),
      HubSocketEvents(
        connected: (socket) => _socketConnected(generation, record, socket),
        rejected: (statusCode) => _socketRejected(generation, statusCode),
        closed: (code) => _socketClosed(generation, record, code),
        failed: (error) => _socketFailed(generation, record, error),
      ),
    );
  }

  void _socketConnected(
    int generation,
    _HubRelationshipRecord record,
    HubSocket socket,
  ) {
    if (generation != _generation) {
      unawaited(socket.close());
      return;
    }
    _retryAttempt = 0;
    _state = HubConnectionState.connected;
    _connectedAt = clock.now().toUtc().toIso8601String();
    _lastError = null;
    unawaited(
      Future.sync(
        () => attachSocket(
          socket,
          daemonId: record.daemonId,
          scopes: List<String>.unmodifiable(record.scopes),
        ),
      ).catchError((Object error) {
        _socketFailed(generation, record, error);
      }),
    );
  }

  void _socketRejected(int generation, int statusCode) {
    if (generation != _generation) return;
    _revoke('Hub rejected socket authentication ($statusCode)');
  }

  void _socketClosed(int generation, _HubRelationshipRecord record, int code) {
    if (generation != _generation) return;
    if (code == 4403) {
      _revoke('Hub revoked this relationship');
      return;
    }
    if (_record?.state == 'active') _scheduleSocket(record);
  }

  void _socketFailed(
    int generation,
    _HubRelationshipRecord record,
    Object error,
  ) {
    if (generation != _generation) return;
    _lastError = '$error';
    if (_record?.state == 'active') _scheduleSocket(record);
  }

  void _scheduleSocket(_HubRelationshipRecord record) {
    _state = HubConnectionState.reconnecting;
    _schedule(() => _openSocket(record, reconnecting: true));
  }

  void _scheduleEnrollment(
    _HubRelationshipRecord record,
    int enrollmentGeneration,
  ) {
    if (enrollmentGeneration != _enrollmentGeneration) return;
    _state = HubConnectionState.reconnecting;
    _retry?.cancel();
    final delay = retryPolicy.delay(_retryAttempt++);
    _retry = clock.schedule(delay, () {
      if (enrollmentGeneration != _enrollmentGeneration) return;
      unawaited(
        _tryEnrollment(record, enrollmentGeneration).catchError((Object error) {
          if (error is! HubEnrollmentRejectedError) {
            _log('scheduled Hub enrollment retry failed: $error');
          }
        }),
      );
    });
  }

  Future<void> _tryRevocation(_HubRelationshipRecord record) async {
    final generation = _generation;
    try {
      await remote.revoke(
        HubRevocation(
          daemonId: record.daemonId,
          hubOrigin: record.hubOrigin,
          credential: record.credential!,
        ),
      );
      if (generation == _generation) _remove();
    } catch (error) {
      if (generation != _generation) return;
      _lastError = '$error';
      _state = HubConnectionState.disconnecting;
      _schedule(() => unawaited(_tryRevocation(record)));
    }
  }

  void _schedule(void Function() task) {
    _retry?.cancel();
    final generation = _generation;
    final delay = retryPolicy.delay(_retryAttempt++);
    _retry = clock.schedule(delay, () {
      if (generation == _generation) task();
    });
  }

  void _revoke(String reason) {
    _cancelLifecycle();
    final record = _record;
    if (record == null) return;
    final revoked = record.asRevoked(reason);
    _persist(revoked);
    _record = revoked;
    _state = HubConnectionState.revoked;
    _lastError = reason;
  }

  void _cancelLifecycle() {
    ++_generation;
    ++_enrollmentGeneration;
    _retry?.cancel();
    _retry = null;
  }

  int _beginEnrollmentAttempt() {
    _retry?.cancel();
    _retry = null;
    _retryAttempt = 0;
    return ++_enrollmentGeneration;
  }

  void _persist(_HubRelationshipRecord record) {
    writePrivateFileAtomic(
      _file,
      '${const JsonEncoder.withIndent('  ').convert(record.toJson())}\n',
    );
  }

  void _remove() {
    _cancelLifecycle();
    if (_file.existsSync()) _file.deleteSync();
    _record = null;
    _state = HubConnectionState.notConnected;
    _connectedAt = null;
    _lastError = null;
  }

  _HubRelationshipRecord? _load() {
    if (!_file.existsSync()) return null;
    try {
      ensurePrivateFile(_file);
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Hub relationship must be an object');
      }
      return _HubRelationshipRecord.fromJson(decoded);
    } catch (error) {
      final quarantine = File(
        p.join(
          home,
          'hub-relationship.invalid-'
          '${clock.now().millisecondsSinceEpoch}-${const Uuid().v4()}.json',
        ),
      );
      _file.renameSync(quarantine.path);
      ensurePrivateFile(quarantine);
      _log(
        'quarantined invalid Hub relationship authority '
        'at ${quarantine.path}: $error',
      );
      return null;
    }
  }
}

final class _HubRelationshipRecord {
  const _HubRelationshipRecord._(this.json);
  final Map<String, Object?> json;

  factory _HubRelationshipRecord.pending({
    required String daemonId,
    required String idempotencyKey,
    required String hubOrigin,
    required String createdAt,
    required String credential,
    required String token,
    required String serverId,
    required String daemonPublicKey,
  }) => _HubRelationshipRecord._({
    'version': 1,
    'state': 'pending',
    'relationship': {
      'daemonId': daemonId,
      'idempotencyKey': idempotencyKey,
      'hubOrigin': hubOrigin,
      'createdAt': createdAt,
      'scopes': [hubExecutionScope],
    },
    'credential': {'secret': credential},
    'enrollment': {'token': token},
    'identity': {'serverId': serverId, 'daemonPublicKey': daemonPublicKey},
  });

  factory _HubRelationshipRecord.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1 ||
        !const {
          'pending',
          'active',
          'disconnecting',
          'revoked',
        }.contains(json['state'])) {
      throw const FormatException('Invalid Hub relationship version or state');
    }
    final relationship = _map(json['relationship'], 'relationship');
    _string(relationship['daemonId'], 'relationship.daemonId');
    final hubOrigin = normalizeHubUrl(
      _string(relationship['hubOrigin'], 'relationship.hubOrigin'),
    );
    if (hubOrigin != relationship['hubOrigin']) {
      throw const FormatException('Hub origin must be normalized');
    }
    _string(relationship['createdAt'], 'relationship.createdAt');
    final scopes = relationship['scopes'];
    if (scopes is! List ||
        scopes.length != 1 ||
        scopes.single != hubExecutionScope) {
      throw const FormatException('Invalid Hub relationship scopes');
    }
    final state = json['state'] as String;
    if (state != 'revoked') {
      _string(relationship['idempotencyKey'], 'relationship.idempotencyKey');
      _string(
        _map(json['credential'], 'credential')['secret'],
        'credential.secret',
      );
    } else if (relationship.containsKey('idempotencyKey') ||
        json.containsKey('credential')) {
      throw const FormatException('Revoked relationship contains authority');
    }
    if (state == 'pending') {
      _string(
        _map(json['enrollment'], 'enrollment')['token'],
        'enrollment.token',
      );
      final identity = _map(json['identity'], 'identity');
      _string(identity['serverId'], 'identity.serverId');
      _string(identity['daemonPublicKey'], 'identity.daemonPublicKey');
    }
    if (state == 'active' || json['transport'] != null) {
      final transport = _map(json['transport'], 'transport');
      if (transport['kind'] != 'direct_websocket') {
        throw const FormatException('Unsupported Hub transport');
      }
      final socketUrl = _string(
        transport['webSocketUrl'],
        'transport.webSocketUrl',
      );
      ensureHubWebSocketMatchesOrigin(hubOrigin, socketUrl);
    }
    if (json['reason'] != null) _string(json['reason'], 'reason');
    return _HubRelationshipRecord._(json);
  }

  String get state => json['state']! as String;
  Map<String, Object?> get _relationship =>
      json['relationship']! as Map<String, Object?>;
  String get daemonId => _relationship['daemonId']! as String;
  String get hubOrigin => _relationship['hubOrigin']! as String;
  String? get idempotencyKey => _relationship['idempotencyKey'] as String?;
  List<String> get scopes => (_relationship['scopes']! as List).cast<String>();
  String? get credential =>
      (json['credential'] as Map<String, Object?>?)?['secret'] as String?;
  String? get enrollmentToken =>
      (json['enrollment'] as Map<String, Object?>?)?['token'] as String?;
  String? get identityServerId =>
      (json['identity'] as Map<String, Object?>?)?['serverId'] as String?;
  String? get identityPublicKey =>
      (json['identity'] as Map<String, Object?>?)?['daemonPublicKey']
          as String?;
  String? get webSocketUrl =>
      (json['transport'] as Map<String, Object?>?)?['webSocketUrl'] as String?;
  String? get reason => json['reason'] as String?;

  _HubRelationshipRecord withEnrollmentToken(String token) =>
      _HubRelationshipRecord._({
        ...json,
        'enrollment': {'token': token},
      });

  _HubRelationshipRecord asActive(String webSocketUrl) =>
      _HubRelationshipRecord._({
        'version': 1,
        'state': 'active',
        'relationship': _relationship,
        'credential': json['credential'],
        'transport': {'kind': 'direct_websocket', 'webSocketUrl': webSocketUrl},
      });

  _HubRelationshipRecord asDisconnecting() => _HubRelationshipRecord._({
    'version': 1,
    'state': 'disconnecting',
    'relationship': _relationship,
    'credential': json['credential'],
    if (state == 'active') 'transport': json['transport'],
  });

  _HubRelationshipRecord asRevoked(String reason) => _HubRelationshipRecord._({
    'version': 1,
    'state': 'revoked',
    'relationship': {
      'daemonId': daemonId,
      'hubOrigin': hubOrigin,
      'createdAt': _relationship['createdAt'],
      'scopes': scopes,
    },
    if (json['transport'] != null) 'transport': json['transport'],
    'reason': reason,
  });

  Map<String, Object?> toJson() => json;
}

String normalizeHubUrl(String value) {
  final url = Uri.parse(value);
  if (!url.hasScheme || (url.scheme != 'http' && url.scheme != 'https')) {
    throw const FormatException('Hub URL must use HTTP or HTTPS');
  }
  if (url.userInfo.isNotEmpty) {
    throw const FormatException('Hub URL cannot include credentials');
  }
  if (url.hasQuery || url.hasFragment) {
    throw const FormatException('Hub URL cannot include a query or fragment');
  }
  final normalizedPath = url.path.endsWith('/')
      ? url.path.substring(0, url.path.length - 1)
      : url.path;
  return url.replace(path: normalizedPath).toString();
}

void ensureHubWebSocketMatchesOrigin(String hubOrigin, String webSocketUrl) {
  final hub = Uri.parse(hubOrigin);
  final socket = Uri.parse(webSocketUrl);
  final expectedScheme = hub.scheme == 'https' ? 'wss' : 'ws';
  if (socket.scheme != expectedScheme ||
      socket.host != hub.host ||
      _effectivePort(socket) != _effectivePort(hub) ||
      socket.hasFragment) {
    throw const FormatException('Hub WebSocket URL must match the Hub origin');
  }
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme) {
    'https' || 'wss' => 443,
    'http' || 'ws' => 80,
    _ => uri.port,
  };
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value;
}

String _string(Object? value, String name) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$name must be a non-empty string');
  }
  return value;
}

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

void _ignoreLog(String _) {}

extension<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}
