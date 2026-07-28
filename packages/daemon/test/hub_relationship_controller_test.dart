import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/hub/relationship_controller.dart';
import 'package:agent_daemon/src/hub/relationship_remote.dart';
import 'package:agent_daemon/src/hub/relationship_retry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late _FakeHubRemote remote;
  late _FakeClock clock;
  late List<HubSocket> attached;

  setUp(() {
    home = Directory.systemTemp.createTempSync('hub-relationship-test-');
    remote = _FakeHubRemote();
    clock = _FakeClock(DateTime.utc(2026, 7, 27, 1, 2, 3));
    attached = [];
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  HubRelationshipController createController({
    HubRelationshipRemote? withRemote,
    void Function(String)? log,
  }) => HubRelationshipController(
    home: home.path,
    serverId: 'srv_test',
    daemonPublicKey: 'public_test',
    remote: withRemote ?? remote,
    attachSocket: (socket, {required daemonId, required scopes}) {
      expect(daemonId, 'daemon_test');
      expect(scopes, [hubExecutionScope]);
      attached.add(socket);
    },
    clock: clock,
    retryPolicy: _FixedRetryPolicy(),
    createDaemonId: () => 'daemon_test',
    createIdempotencyKey: () => 'ceremony_test',
    randomBytes: (length) => List<int>.generate(length, (index) => index),
    log: log,
  );

  test(
    'persists pending authority before enrollment and activates it',
    () async {
      final enrollment = Completer<HubEnrollmentResult>();
      remote.enrollment = enrollment.future;
      final controller = createController();

      final connecting = controller.connect(
        hubUrl: 'https://hub.example.test/',
        token: 'fresh-token',
      );
      final pending = _readRecord(home);
      expect(pending['state'], 'pending');
      expect(
        (pending['enrollment'] as Map<String, dynamic>)['token'],
        'fresh-token',
      );
      expect(remote.enrollments.single.hubOrigin, 'https://hub.example.test');
      expect(
        remote.enrollments.single.credentialVerifier,
        base64Url
            .encode(
              sha256
                  .convert(
                    utf8.encode(
                      base64Url
                          .encode(List<int>.generate(32, (index) => index))
                          .replaceAll('=', ''),
                    ),
                  )
                  .bytes,
            )
            .replaceAll('=', ''),
      );

      enrollment.complete(
        const HubEnrollmentResult(
          daemonId: 'daemon_test',
          scopes: [hubExecutionScope],
          webSocketUrl: 'wss://hub.example.test/daemon',
        ),
      );
      await connecting;
      expect(_readRecord(home)['state'], 'active');
      expect(controller.status.state, HubConnectionState.connecting);

      remote.sockets.single.events.connected(remote.sockets.single.socket);
      expect(controller.status.state, HubConnectionState.connected);
      expect(controller.status.connectedAt, '2026-07-27T01:02:03.000Z');
      expect(attached, hasLength(1));
    },
  );

  test(
    'retry keeps the same ceremony and accepts a fresh pending token',
    () async {
      remote.enrollment = Future.error(StateError('offline'));
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'first',
      );

      expect(controller.status.state, HubConnectionState.reconnecting);
      expect(clock.tasks, hasLength(1));
      final first = remote.enrollments.single;

      remote.enrollment = Future.value(
        const HubEnrollmentResult(
          daemonId: 'daemon_test',
          scopes: [hubExecutionScope],
          webSocketUrl: 'wss://hub.example.test/ws',
        ),
      );
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'second',
      );

      expect(remote.enrollments, hasLength(2));
      expect(remote.enrollments.last.idempotencyKey, first.idempotencyKey);
      expect(remote.enrollments.last.token, 'second');
      expect(clock.tasks.single.cancelled, isTrue);
      expect(_readRecord(home)['state'], 'active');
    },
  );

  test('rejected enrollment removes local authority', () async {
    remote.enrollment = Future.error(const HubEnrollmentRejectedError(403));
    final controller = createController();

    await expectLater(
      controller.connect(hubUrl: 'https://hub.example.test', token: 'rejected'),
      throwsA(isA<HubEnrollmentRejectedError>()),
    );
    expect(
      controller.status.toJson(),
      const HubRelationshipStatus.notConnected().toJson(),
    );
    expect(
      File(p.join(home.path, hubRelationshipFileName)).existsSync(),
      isFalse,
    );
  });

  test(
    'socket close reconnects and 4403 persists sanitized revoked state',
    () async {
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'token',
      );
      remote.sockets.single.events.connected(remote.sockets.single.socket);
      remote.sockets.single.events.closed(1006);
      expect(controller.status.state, HubConnectionState.reconnecting);

      clock.tasks.single.run();
      expect(remote.sockets, hasLength(2));
      remote.sockets.last.events.closed(4403);
      expect(controller.status.state, HubConnectionState.revoked);
      expect(controller.status.lastError, 'Hub revoked this relationship');
      final revoked = _readRecord(home);
      expect(revoked['state'], 'revoked');
      expect(revoked, isNot(contains('credential')));
      expect(revoked['relationship'], isNot(contains('idempotencyKey')));
    },
  );

  test(
    'disconnect revokes remotely and force removal returns exact warning',
    () async {
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'token',
      );
      final disconnected = await controller.disconnect();
      expect(disconnected.warning, isNull);
      expect(remote.revocations.single.credential, isNotEmpty);
      expect(disconnected.status.state, HubConnectionState.notConnected);

      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'again',
      );
      final forced = await controller.disconnect(force: true);
      expect(
        forced.warning,
        'Local Hub credential removed; remote revocation may remain pending.',
      );
      expect(remote.revocations, hasLength(1));
    },
  );

  test(
    'revocation failure persists disconnecting and retries on restart',
    () async {
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'token',
      );
      remote.revocationError = StateError('offline');
      final result = await controller.disconnect();
      expect(result.status.state, HubConnectionState.disconnecting);
      expect(_readRecord(home)['state'], 'disconnecting');

      remote.revocationError = null;
      final restartLogs = <String>[];
      final restarted = createController(log: restartLogs.add);
      expect(restartLogs, isEmpty);
      expect(restarted.status.state, HubConnectionState.disconnecting);
      await restarted.start();
      expect(restarted.status.state, HubConnectionState.notConnected);
      expect(remote.revocations, hasLength(2));
    },
  );

  test(
    'start resumes active socket and rejected pending is discarded',
    () async {
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'token',
      );
      final restartLogs = <String>[];
      final restarted = createController(log: restartLogs.add);
      expect(restartLogs, isEmpty);
      expect(restarted.status.state, HubConnectionState.connecting);
      await restarted.start();
      expect(remote.sockets, hasLength(2));

      await restarted.disconnect(force: true);
      remote.enrollment = Future.error(StateError('offline'));
      final pending = createController();
      await pending.connect(hubUrl: 'https://hub.example.test', token: 'token');
      remote.enrollment = Future.error(const HubEnrollmentRejectedError(401));
      final pendingRestart = createController();
      await pendingRestart.start();
      expect(pendingRestart.status.state, HubConnectionState.notConnected);
    },
  );

  test('invalid persisted authority is quarantined', () {
    File(p.join(home.path, hubRelationshipFileName))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"version":1,"state":"active"}');
    final logs = <String>[];

    final controller = createController(log: logs.add);

    expect(controller.status.state, HubConnectionState.notConnected);
    expect(
      home.listSync().whereType<File>().where(
        (file) => p.basename(file.path).startsWith('hub-relationship.invalid-'),
      ),
      hasLength(1),
    );
    expect(logs.single, contains('quarantined invalid Hub relationship'));
  });

  test('URL and retry policy match the Paseo contract', () {
    expect(normalizeHubUrl('http://host:8080/path/'), 'http://host:8080/path');
    for (final invalid in [
      'ftp://host',
      'https://user:pass@host',
      'https://host?query=1',
      'https://host#fragment',
    ]) {
      expect(() => normalizeHubUrl(invalid), throwsFormatException);
    }
    expect(
      () => ensureHubWebSocketMatchesOrigin(
        'https://hub.example.test',
        'ws://hub.example.test/ws',
      ),
      throwsFormatException,
    );

    final low = BoundedExponentialHubRetryPolicy(random: () => 0);
    final high = BoundedExponentialHubRetryPolicy(random: () => 1);
    expect(low.delay(0), const Duration(milliseconds: 375));
    expect(high.delay(0), const Duration(milliseconds: 625));
    expect(low.delay(20), const Duration(milliseconds: 22500));
    expect(high.delay(20), const Duration(milliseconds: 37500));
  });

  test('system clock schedules and cancels real tasks', () async {
    const system = SystemHubRelationshipClock();
    final fired = Completer<void>();
    system.schedule(Duration.zero, fired.complete);
    await fired.future;
    var cancelledFired = false;
    final cancelled = system.schedule(
      const Duration(milliseconds: 20),
      () => cancelledFired = true,
    );
    cancelled.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(cancelledFired, isFalse);
  });

  test('stop closes socket and empty disconnect stays disconnected', () async {
    final controller = createController();
    await controller.connect(
      hubUrl: 'https://hub.example.test',
      token: 'token',
    );
    await controller.stop();
    expect(remote.sockets.single.closed, isTrue);
    final forced = await controller.disconnect(force: true);
    expect(forced.status.state, HubConnectionState.notConnected);
    final empty = await controller.disconnect();
    expect(empty.status.state, HubConnectionState.notConnected);
  });

  test('pending relationship rejects a different Hub', () async {
    remote.enrollment = Future.error(StateError('offline'));
    final controller = createController();
    await controller.connect(
      hubUrl: 'https://hub.example.test',
      token: 'token',
    );
    await expectLater(
      controller.connect(hubUrl: 'https://other.example.test', token: 'token'),
      throwsStateError,
    );
  });

  test('mismatch and socket failure enter retry state', () async {
    remote.enrollment = Future.value(
      const HubEnrollmentResult(
        daemonId: 'wrong-daemon',
        scopes: [hubExecutionScope],
        webSocketUrl: 'wss://hub.example.test/ws',
      ),
    );
    final controller = createController();
    await controller.connect(
      hubUrl: 'https://hub.example.test',
      token: 'token',
    );
    expect(controller.status.lastError, contains('did not match'));
    await controller.disconnect(force: true);

    remote.enrollment = Future.value(
      const HubEnrollmentResult(
        daemonId: 'daemon_test',
        scopes: [hubExecutionScope],
        webSocketUrl: 'wss://hub.example.test/ws',
      ),
    );
    await controller.connect(
      hubUrl: 'https://hub.example.test',
      token: 'token',
    );
    remote.sockets.last.events.failed(StateError('socket failed'));
    expect(controller.status.state, HubConnectionState.reconnecting);
    expect(controller.status.lastError, contains('socket failed'));
  });

  test(
    'socket rejection persists sanitized revoked status across restart',
    () async {
      final controller = createController();
      await controller.connect(
        hubUrl: 'https://hub.example.test',
        token: 'token',
      );
      remote.sockets.single.events.rejected(401);
      final restarted = createController();
      expect(restarted.status.state, HubConnectionState.revoked);
      expect(
        restarted.status.lastError,
        'Hub rejected socket authentication (401)',
      );
      expect(
        (await restarted.disconnect()).status.state,
        HubConnectionState.notConnected,
      );
    },
  );

  test('revoked records containing authority are quarantined', () {
    File(p.join(home.path, hubRelationshipFileName)).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'state': 'revoked',
        'relationship': {
          'daemonId': 'daemon',
          'idempotencyKey': 'must-not-survive',
          'hubOrigin': 'https://hub.example.test',
          'createdAt': '2026-07-27T00:00:00.000Z',
          'scopes': [hubExecutionScope],
        },
        'credential': {'secret': 'must-not-survive'},
      }),
    );
    expect(createController().status.state, HubConnectionState.notConnected);
  });
}

Map<String, dynamic> _readRecord(Directory home) =>
    jsonDecode(
          File(p.join(home.path, hubRelationshipFileName)).readAsStringSync(),
        )
        as Map<String, dynamic>;

final class _FakeHubRemote implements HubRelationshipRemote {
  Future<HubEnrollmentResult> enrollment = Future.value(
    const HubEnrollmentResult(
      daemonId: 'daemon_test',
      scopes: [hubExecutionScope],
      webSocketUrl: 'wss://hub.example.test/ws',
    ),
  );
  Object? revocationError;
  final enrollments = <HubEnrollment>[];
  final revocations = <HubRevocation>[];
  final sockets = <_FakeSocketConnection>[];

  @override
  Future<HubEnrollmentResult> enroll(HubEnrollment input) {
    enrollments.add(input);
    return enrollment;
  }

  @override
  HubSocketConnection openSocket(
    HubSocketCredentials input,
    HubSocketEvents events,
  ) {
    final connection = _FakeSocketConnection(events);
    sockets.add(connection);
    return connection;
  }

  @override
  Future<void> revoke(HubRevocation input) async {
    revocations.add(input);
    final error = revocationError;
    if (error != null) throw error;
  }
}

final class _FakeSocketConnection implements HubSocketConnection {
  _FakeSocketConnection(this.events);
  final HubSocketEvents events;
  final socket = _FakeSocket();
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _FakeSocket implements HubSocket {
  final controller = StreamController<Object>.broadcast();
  final sent = <Object>[];

  @override
  Stream<Object> get frames => controller.stream;

  @override
  void send(Object data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) => controller.close();
}

final class _FixedRetryPolicy implements HubRelationshipRetryPolicy {
  @override
  Duration delay(int attempt) => Duration(milliseconds: 10 + attempt);
}

final class _FakeClock implements HubRelationshipClock {
  _FakeClock(this.current);
  DateTime current;
  final tasks = <_FakeTask>[];

  @override
  DateTime now() => current;

  @override
  ScheduledHubRelationshipTask schedule(Duration delay, void Function() task) {
    final scheduled = _FakeTask(delay, task);
    tasks.add(scheduled);
    return scheduled;
  }
}

final class _FakeTask implements ScheduledHubRelationshipTask {
  _FakeTask(this.delay, this.task);
  final Duration delay;
  final void Function() task;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  void run() {
    if (!cancelled) task();
  }
}
