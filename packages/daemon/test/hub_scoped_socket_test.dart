import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Hub socket is pre-authenticated and restricted to enrollment scopes',
    () async {
      final incoming = StreamController<Object>();
      final outgoing = StreamController<Object>();
      final server = WsServer(router: RpcRouter());
      final connection = server.attachHubSocket(
        frames: incoming.stream,
        send: outgoing.add,
        close: (code, reason) => incoming.close(),
        daemonId: 'daemon-1',
        scopes: const ['hub.execution.*'],
      );

      expect(connection.authenticated, isTrue);
      expect(connection.clientName, 'hub:daemon-1');
      expect(connection.scopes, ['hub.execution.*']);
      expect(server.connectionCount, 1);

      incoming.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'hub.management.daemon.get_status.request',
            'requestId': 'forbidden-1',
          },
        }),
      );
      final response =
          jsonDecode(await outgoing.stream.first as String)
              as Map<String, Object?>;
      final message = response['message'] as Map<String, Object?>;
      expect(message['type'], 'rpc_error');
      expect(
        (message['payload'] as Map<String, Object?>)['code'],
        'unauthorized',
      );

      await incoming.close();
      await Future<void>.delayed(Duration.zero);
      expect(server.connectionCount, 0);
      await outgoing.close();
    },
  );
}
