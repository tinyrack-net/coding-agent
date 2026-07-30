import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'daemon update progress does not consume the correlated response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<WebSocket>();
      unawaited(() async {
        final request = await server.first;
        accepted.complete(await WebSocketTransformer.upgrade(request));
      }());
      final client = DaemonClient(
        uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server.port),
      );
      addTearDown(() async {
        client.dispose();
        await server.close(force: true);
      });

      final connected = client.connect();
      final socket = await accepted.future;
      final frames = socket.asBroadcastStream();
      await frames.firstWhere(
        (frame) => jsonDecode(frame as String)['type'] == 'hello',
      );
      socket.add(
        jsonEncode({
          'status': 'server_info',
          'serverId': 'remote',
          'hostname': 'build-host',
          'version': '0.1.9',
          'desktopManaged': false,
          'features': {'daemonSelfUpdate': true},
        }),
      );
      await connected;

      final progressFuture = client.daemonUpdateProgress.first;
      final updateFuture = client.updateDaemon(requestId: 'update-1');
      var responseCompleted = false;
      unawaited(updateFuture.then((_) => responseCompleted = true));
      final request = await frames
          .map(
            (frame) => (jsonDecode(frame as String)['message'] as Map)
                .cast<String, Object?>(),
          )
          .firstWhere((message) => message['type'] == DaemonUpdateRequest.type);
      expect(request['requestId'], 'update-1');

      socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': DaemonUpdateProgress.type,
            'payload': {'requestId': 'update-1', 'phase': 'installing'},
          },
        }),
      );
      final progress = await progressFuture;
      expect(progress.phase, DaemonUpdatePhase.installing);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(responseCompleted, isFalse);

      socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': DaemonUpdateResponse.type,
            'payload': {
              'requestId': 'update-1',
              'success': false,
              'error': 'npm install failed',
              'previousVersion': '0.1.9',
              'newVersion': null,
            },
          },
        }),
      );
      final response = await updateFuture;
      expect(response.success, isFalse);
      expect(response.error, 'npm install failed');
    },
  );

  test(
    'malformed correlated update frames fail immediately as protocol errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<WebSocket>();
      unawaited(() async {
        final request = await server.first;
        accepted.complete(await WebSocketTransformer.upgrade(request));
      }());
      final client = DaemonClient(
        uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server.port),
      );
      addTearDown(() async {
        client.dispose();
        await server.close(force: true);
      });

      final connected = client.connect();
      final socket = await accepted.future;
      final frames = socket.asBroadcastStream();
      await frames.firstWhere(
        (frame) => jsonDecode(frame as String)['type'] == 'hello',
      );
      socket.add(
        jsonEncode({
          'status': 'server_info',
          'serverId': 'remote',
          'hostname': 'build-host',
          'version': '0.1.9',
          'desktopManaged': false,
          'features': {'daemonSelfUpdate': true},
        }),
      );
      await connected;

      final malformedProgress = client.updateDaemon(requestId: 'progress-bad');
      await frames
          .map(
            (frame) => (jsonDecode(frame as String)['message'] as Map)
                .cast<String, Object?>(),
          )
          .firstWhere((message) => message['requestId'] == 'progress-bad');
      final progressFailure = expectLater(
        malformedProgress,
        throwsA(
          isA<DaemonProtocolException>()
              .having((error) => error.requestId, 'requestId', 'progress-bad')
              .having(
                (error) => error.responseType,
                'responseType',
                DaemonUpdateProgress.type,
              ),
        ),
      );
      socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': DaemonUpdateProgress.type,
            'payload': {'requestId': 'progress-bad', 'phase': 'corrupt'},
          },
        }),
      );
      await progressFailure;

      final malformedResponse = client.updateDaemon(requestId: 'response-bad');
      await frames
          .map(
            (frame) => (jsonDecode(frame as String)['message'] as Map)
                .cast<String, Object?>(),
          )
          .firstWhere((message) => message['requestId'] == 'response-bad');
      final responseFailure = expectLater(
        malformedResponse,
        throwsA(
          isA<DaemonProtocolException>()
              .having((error) => error.requestId, 'requestId', 'response-bad')
              .having(
                (error) => error.responseType,
                'responseType',
                DaemonUpdateResponse.type,
              ),
        ),
      );
      socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': DaemonUpdateResponse.type,
            'payload': {
              'requestId': 'response-bad',
              'success': 'not-a-bool',
              'error': null,
              'previousVersion': '0.1.9',
              'newVersion': null,
            },
          },
        }),
      );
      await responseFailure;
    },
  );
}
