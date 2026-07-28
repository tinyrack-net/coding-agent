import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/terminal_activity_route.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/terminal/pty/pty.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final class _FakePty implements Pty {
  final _output = StreamController<Uint8List>();
  final _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  String get shell => 'fake';

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_output.isClosed) unawaited(_output.close());
  }

  @override
  void resize(int cols, int rows) {}

  @override
  void write(Uint8List data) {}
}

void main() {
  late TerminalManager terminals;
  late WsServer server;
  late String terminalId;
  late int now;

  setUp(() async {
    now = 100;
    terminals = TerminalManager(
      spawn:
          ({
            required String cwd,
            int cols = 80,
            int rows = 24,
            String? shell,
            List<String>? arguments,
            Map<String, String>? environment,
          }) => _FakePty(),
      sendBinary: (_, __) {},
      onExited: (_, __) {},
      activityTokenFactory: () => 'secret-token',
      activityClock: () => now,
    );
    terminalId = terminals.create(cwd: 'C:/workspace')['terminalId']! as String;
    server = WsServer(
      router: RpcRouter(),
      terminalActivityHandler: TerminalActivityRoute(terminals).call,
    );
    await server.start(host: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await server.stop();
    await terminals.dispose();
  });

  Uri endpoint() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/terminal-activity');

  Future<http.Response> report(Object? body, {String method = 'POST'}) {
    final request = http.Request(method, endpoint())
      ..headers['content-type'] = 'application/json'
      ..body = body is String ? body : jsonEncode(body);
    return http.Client().send(request).then(http.Response.fromStream);
  }

  test(
    'authenticated loopback reports drive Paseo activity transitions',
    () async {
      final running = await report({
        'terminalId': terminalId,
        'token': 'secret-token',
        'state': 'running',
      });
      expect(running.statusCode, 204);
      expect(terminals.list().single['activity'], {
        'state': 'working',
        'changedAt': 100,
      });

      now = 200;
      final idle = await report({
        'terminalId': terminalId,
        'token': 'secret-token',
        'state': 'idle',
      });
      expect(idle.statusCode, 204);
      expect(terminals.list().single['activity'], {
        'state': 'idle',
        'attentionReason': 'finished',
        'changedAt': 200,
      });

      terminals.clearAttention(terminalId);
      now = 300;
      final needsInput = await report({
        'terminalId': terminalId,
        'token': 'secret-token',
        'state': 'needs-input',
      });
      expect(needsInput.statusCode, 204);
      expect(
        (terminals.listActivityContributions().single.activity)
            ?.attentionReason,
        TerminalActivityAttentionReason.needsInput,
      );
    },
  );

  test(
    'rejects malformed reports, wrong tokens, and unsupported methods',
    () async {
      expect((await report('{bad json')).statusCode, 400);
      expect(
        (await report({
          'terminalId': terminalId,
          'token': 'secret-token',
          'state': 'future',
        })).statusCode,
        400,
      );
      expect(
        (await report({
          'terminalId': terminalId,
          'token': 'wrong',
          'state': 'running',
        })).statusCode,
        403,
      );
      expect(
        (await report({
          'terminalId': 'missing',
          'token': 'secret-token',
          'state': 'running',
        })).statusCode,
        403,
      );
      expect((await report('', method: 'GET')).statusCode, 404);
      expect(terminals.list().single['activity'], isNull);
    },
  );
}
