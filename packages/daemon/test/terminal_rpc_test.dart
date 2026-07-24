/// Tests `registerTerminalHandlers` end-to-end over a live WebSocket
/// connection, following `ws_server_test.dart`'s pattern. `terminal_manager_test.dart`
/// already covers [TerminalManager] behavior directly (PTY plumbing,
/// scrollback, fanout); these tests focus on the RPC layer: payload
/// validation and StateError -> RpcException(notFound) mapping.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/terminal/pty/pty.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/terminal/terminal_rpc.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakePty implements Pty {
  FakePty({this.shell = 'fake-shell'});

  @override
  final String shell;

  final outputController = StreamController<Uint8List>();
  final exitCompleter = Completer<int>();

  @override
  Stream<Uint8List> get output => outputController.stream;

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  void kill() {
    if (!exitCompleter.isCompleted) exitCompleter.complete(0);
    outputController.close();
  }
}

void main() {
  late WsServer server;
  late TerminalManager manager;
  late WebSocketChannel channel;
  late Stream<Map<String, Object?>> frames;
  var nextRequestId = 0;

  setUp(() async {
    manager = TerminalManager(
      spawn: ({required String cwd, int cols = 80, int rows = 24, String? shell}) =>
          FakePty(),
      sendBinary: (_, __) {},
      onExited: (_, __) {},
    );
    final router = RpcRouter();
    registerTerminalHandlers(router, terminals: manager);
    server = WsServer(router: router);
    await server.start(host: '127.0.0.1', port: 0);

    channel =
        WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await channel.ready;
    frames = channel.stream
        .map((f) => jsonDecode(f as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'hello',
      payload: {'clientName': 'test', 'clientVersion': '0.0.1'},
    ).toJson()));
    await frames.first;
  });

  tearDown(() async {
    await manager.dispose();
    await channel.sink.close();
    await server.stop();
  });

  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload,
  ) async {
    final id = 'req-${nextRequestId++}';
    channel.sink.add(jsonEncode(
        RpcRequest(type: type, requestId: id, payload: payload).toJson()));
    return frames.firstWhere((f) => f['requestId'] == id);
  }

  test('terminal.create requires a non-empty cwd', () async {
    final response = await request(MessageTypes.terminalCreateRequest, const {});
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });

  test('terminal.create returns terminal info; terminal.list reflects it',
      () async {
    final createResponse = await request(
      MessageTypes.terminalCreateRequest,
      {'cwd': 'C:/work', 'cols': 100, 'rows': 30},
    );
    expect(createResponse['error'], isNull);
    final terminal = (createResponse['payload'] as Map)['terminal'] as Map;
    expect(terminal['cwd'], 'C:/work');
    expect(terminal['shell'], 'fake-shell');
    expect(terminal['terminalId'], isA<String>());

    final listResponse =
        await request(MessageTypes.terminalListRequest, const {});
    final list = (listResponse['payload'] as Map)['terminals'] as List;
    expect(list, hasLength(1));
    expect(list.single, terminal);
  });

  test('terminal.subscribe returns a slotId for a known terminal', () async {
    final createResponse = await request(
      MessageTypes.terminalCreateRequest,
      {'cwd': 'C:/work'},
    );
    final terminalId =
        ((createResponse['payload'] as Map)['terminal'] as Map)['terminalId']
            as String;

    final subscribeResponse = await request(
      MessageTypes.terminalSubscribeRequest,
      {'terminalId': terminalId},
    );
    expect(subscribeResponse['error'], isNull);
    expect((subscribeResponse['payload'] as Map)['slotId'], isA<int>());
  });

  test('terminal.subscribe on an unknown terminal returns not_found',
      () async {
    final response = await request(
      MessageTypes.terminalSubscribeRequest,
      {'terminalId': 'nonexistent'},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('terminal.subscribe requires a non-empty terminalId', () async {
    final response =
        await request(MessageTypes.terminalSubscribeRequest, const {});
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });

  test('terminal.unsubscribe on a known terminal succeeds with an empty '
      'payload', () async {
    final createResponse = await request(
      MessageTypes.terminalCreateRequest,
      {'cwd': 'C:/work'},
    );
    final terminalId =
        ((createResponse['payload'] as Map)['terminal'] as Map)['terminalId']
            as String;
    await request(
        MessageTypes.terminalSubscribeRequest, {'terminalId': terminalId});

    final response = await request(
      MessageTypes.terminalUnsubscribeRequest,
      {'terminalId': terminalId},
    );
    expect(response['error'], isNull);
    expect(response['payload'], isEmpty);
  });

  test('terminal.unsubscribe on an unknown terminal returns not_found',
      () async {
    final response = await request(
      MessageTypes.terminalUnsubscribeRequest,
      {'terminalId': 'nope'},
    );
    expect((response['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('terminal.kill removes it from terminal.list; killing again fails '
      'with not_found', () async {
    final createResponse = await request(
      MessageTypes.terminalCreateRequest,
      {'cwd': 'C:/work'},
    );
    final terminalId =
        ((createResponse['payload'] as Map)['terminal'] as Map)['terminalId']
            as String;

    final killResponse = await request(
      MessageTypes.terminalKillRequest,
      {'terminalId': terminalId},
    );
    expect(killResponse['error'], isNull);
    await Future<void>.delayed(Duration.zero);

    final listResponse =
        await request(MessageTypes.terminalListRequest, const {});
    expect((listResponse['payload'] as Map)['terminals'], isEmpty);

    final secondKill = await request(
      MessageTypes.terminalKillRequest,
      {'terminalId': terminalId},
    );
    expect((secondKill['error'] as Map)['code'], RpcErrorCodes.notFound);
  });

  test('terminal.kill requires a non-empty terminalId', () async {
    final response =
        await request(MessageTypes.terminalKillRequest, const {});
    expect((response['error'] as Map)['code'], RpcErrorCodes.invalidPayload);
  });
}
