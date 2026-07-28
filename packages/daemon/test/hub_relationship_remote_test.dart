import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/hub/relationship_remote.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('enroll sends the Paseo ceremony and validates the response', () async {
    late http.Request captured;
    final remote = DirectHubRelationshipRemote(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'daemonId': 'daemon-1',
            'scopes': ['hub.execution.*'],
            'webSocketUrl': 'wss://hub.example.test/socket',
          }),
          201,
        );
      }),
    );

    final result = await remote.enroll(
      const HubEnrollment(
        daemonId: 'daemon-1',
        idempotencyKey: 'ceremony-1',
        hubOrigin: 'https://hub.example.test',
        token: 'enrollment-token',
        serverId: 'server-1',
        daemonPublicKey: 'public-key',
        credentialVerifier: 'verifier',
        scopes: ['hub.execution.*'],
      ),
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/daemons/enroll');
    expect(captured.headers['authorization'], 'Bearer enrollment-token');
    expect(jsonDecode(captured.body), {
      'daemonId': 'daemon-1',
      'idempotencyKey': 'ceremony-1',
      'serverId': 'server-1',
      'daemonPublicKey': 'public-key',
      'credentialVerifier': 'verifier',
      'scopes': ['hub.execution.*'],
    });
    expect(result.webSocketUrl, 'wss://hub.example.test/socket');
  });

  test('enroll rejects authority failures and cross-origin sockets', () async {
    final rejected = DirectHubRelationshipRemote(
      client: MockClient((_) async => http.Response('', 403)),
    );
    await expectLater(
      rejected.enroll(_enrollment()),
      throwsA(
        isA<HubEnrollmentRejectedError>().having(
          (error) => error.statusCode,
          'statusCode',
          403,
        ),
      ),
    );

    final crossOrigin = DirectHubRelationshipRemote(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'daemonId': 'daemon-1',
            'scopes': ['hub.execution.*'],
            'webSocketUrl': 'wss://attacker.example.test/socket',
          }),
          200,
        ),
      ),
    );
    await expectLater(crossOrigin.enroll(_enrollment()), throwsFormatException);
    final failed = DirectHubRelationshipRemote(
      client: MockClient((_) async => http.Response('', 500)),
    );
    await expectLater(failed.enroll(_enrollment()), throwsStateError);
    expect(
      const HubEnrollmentRejectedError(401).toString(),
      'Hub enrollment failed (401)',
    );
  });

  test(
    'revoke uses the stored credential and accepts terminal statuses',
    () async {
      final requests = <http.Request>[];
      final remote = DirectHubRelationshipRemote(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('', requests.length == 1 ? 404 : 500);
        }),
      );
      const revocation = HubRevocation(
        daemonId: 'daemon/id',
        hubOrigin: 'https://hub.example.test',
        credential: 'credential',
      );

      await remote.revoke(revocation);
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '/api/daemons/daemon%2Fid');
      expect(requests.single.headers['authorization'], 'Bearer credential');
      await expectLater(remote.revoke(revocation), throwsStateError);
    },
  );

  test(
    'socket authenticates with compatible and Tinyrack daemon headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final headers = Completer<HttpHeaders>();
      final accepted = Completer<WebSocket>();
      final subscription = server.listen((request) async {
        headers.complete(request.headers);
        accepted.complete(await WebSocketTransformer.upgrade(request));
      });
      final connected = Completer<HubSocket>();
      final remote = DirectHubRelationshipRemote();
      final connection = remote.openSocket(
        HubSocketCredentials(
          daemonId: 'daemon-1',
          webSocketUrl: 'ws://127.0.0.1:${server.port}/socket',
          credential: 'socket-secret',
        ),
        HubSocketEvents(
          connected: connected.complete,
          rejected: (status) => fail('unexpected rejection $status'),
          closed: (_) {},
          failed: (error) => fail('unexpected socket failure: $error'),
        ),
      );

      final requestHeaders = await headers.future;
      expect(requestHeaders.value('authorization'), 'Bearer socket-secret');
      expect(requestHeaders.value('x-paseo-daemon-id'), 'daemon-1');
      expect(requestHeaders.value('x-tinyrack-daemon-id'), 'daemon-1');
      final socket = await connected.future;
      final serverSocket = await accepted.future;
      final frame = expectLater(socket.frames, emits('hello'));
      serverSocket.add('hello');
      await frame;
      final sent = serverSocket.first;
      socket.send('from-daemon');
      expect(await sent, 'from-daemon');

      await serverSocket.close();
      await Future<void>.delayed(Duration.zero);
      await connection.close();
      await subscription.cancel();
      await server.close(force: true);
    },
  );

  test('socket reports connector rejection and generic failure', () async {
    final rejected = Completer<int>();
    DirectHubRelationshipRemote(
      connectWebSocket: (_, {required headers, required timeout}) =>
          Future.error(const WebSocketException('upgrade rejected: 403')),
    ).openSocket(
      const HubSocketCredentials(
        daemonId: 'daemon-1',
        webSocketUrl: 'wss://hub.example.test/socket',
        credential: 'secret',
      ),
      HubSocketEvents(
        connected: (_) => fail('unexpected connection'),
        rejected: rejected.complete,
        closed: (_) {},
        failed: (error) => fail('unexpected socket failure: $error'),
      ),
    );
    expect(await rejected.future, 403);

    final failed = Completer<Object>();
    DirectHubRelationshipRemote(
      connectWebSocket: (_, {required headers, required timeout}) =>
          Future.error(StateError('socket unavailable')),
    ).openSocket(
      const HubSocketCredentials(
        daemonId: 'daemon-1',
        webSocketUrl: 'wss://hub.example.test/socket',
        credential: 'secret',
      ),
      HubSocketEvents(
        connected: (_) => fail('unexpected connection'),
        rejected: (_) => fail('unexpected rejection'),
        closed: (_) {},
        failed: failed.complete,
      ),
    );
    expect(await failed.future, isA<StateError>());
  });

  test('request timeout is surfaced without leaking a raw timeout', () async {
    final remote = DirectHubRelationshipRemote(
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      }),
      requestTimeout: const Duration(milliseconds: 1),
    );
    await expectLater(
      remote.enroll(_enrollment()),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Hub request timed out'),
        ),
      ),
    );
  });
}

HubEnrollment _enrollment() => const HubEnrollment(
  daemonId: 'daemon-1',
  idempotencyKey: 'ceremony-1',
  hubOrigin: 'https://hub.example.test',
  token: 'token',
  serverId: 'server-1',
  daemonPublicKey: 'public-key',
  credentialVerifier: 'verifier',
  scopes: ['hub.execution.*'],
);
