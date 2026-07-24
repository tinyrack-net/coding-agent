import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('request round-trips and derives response type', () {
    const req = RpcRequest(
      type: 'agent.create.request',
      requestId: 'r1',
      payload: {'cwd': 'C:/repo'},
    );
    final decoded =
        RpcFrame.fromJson(jsonDecode(jsonEncode(req.toJson())) as Map<String, Object?>);
    expect(decoded, isA<RpcRequest>());
    expect((decoded as RpcRequest).responseType, 'agent.create.response');
    expect(decoded.payload['cwd'], 'C:/repo');
  });

  test('response with error decodes as error', () {
    const req = RpcRequest(type: 'agent.list.request', requestId: 'r2');
    final res = req.fail(const RpcError(code: 'not_found', message: 'nope'));
    final decoded = RpcFrame.fromJson(res.toJson()) as RpcResponse;
    expect(decoded.isError, isTrue);
    expect(decoded.error!.code, 'not_found');
  });

  test('event has no requestId', () {
    final decoded = RpcFrame.fromJson(
      const RpcEvent(type: 'agent.stream', payload: {'agentId': 'a1'}).toJson(),
    );
    expect(decoded, isA<RpcEvent>());
  });
}
