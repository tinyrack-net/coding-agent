import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('real daemon history failures reject the Flutter client and timeline '
      'without waiting for the request timeout', () async {
    final server = WsServer(router: RpcRouter());
    server.onV2SessionMessage = (_, message) {
      if (message['type'] != FetchAgentTimelineRequest.type) return null;
      return _historyResponse(message);
    };
    await server.start(host: '127.0.0.1', port: 0);
    addTearDown(server.stop);

    final client = DaemonClient(
      uri: Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    addTearDown(client.dispose);
    await client.connect();

    await _expectImmediateFailure(
      () => client.fetchAgentTimeline(
        agentId: 'missing-field-history',
        timeout: const Duration(seconds: 30),
      ),
      isA<DaemonProtocolException>()
          .having((error) => error.code, 'code', 'invalid_response')
          .having(
            (error) => error.responseType,
            'responseType',
            AgentTimelinePage.responseType,
          ),
    );
    await _expectImmediateFailure(
      () => client.fetchAgentTimeline(
        agentId: 'corrupt-history',
        timeout: const Duration(seconds: 30),
      ),
      isA<DaemonProtocolException>()
          .having((error) => error.code, 'code', 'invalid_response')
          .having(
            (error) => error.responseType,
            'responseType',
            AgentTimelinePage.responseType,
          ),
    );
    await _expectImmediateFailure(
      () => client.fetchAgentTimeline(
        agentId: 'missing-agent-history',
        timeout: const Duration(seconds: 30),
      ),
      isA<DaemonRpcException>()
          .having((error) => error.error.code, 'code', 'timeline_fetch')
          .having(
            (error) => error.error.message,
            'message',
            contains('Agent not found: missing-agent-history'),
          ),
    );

    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    container.read(timelineProvider('missing-agent-history'));
    await _waitUntil(
      () => !container.read(timelineProvider('missing-agent-history')).loading,
    );
    final timeline = container.read(timelineProvider('missing-agent-history'));
    expect(timeline.epoch, isNull);
    expect(timeline.error, contains('Agent not found: missing-agent-history'));
  }, timeout: const Timeout(Duration(seconds: 10)));
}

Map<String, Object?> _historyResponse(Map<String, Object?> request) {
  final agentId = request['agentId']! as String;
  final payload = <String, Object?>{
    'requestId': request['requestId'],
    'agentId': agentId,
    'agent': null,
    'direction': request['direction'] ?? 'tail',
    'projection': request['projection'] ?? 'projected',
    'epoch': '',
    'reset': false,
    'staleCursor': false,
    'gap': false,
    'window': const {'minSeq': 0, 'maxSeq': 0, 'nextSeq': 0},
    'startCursor': null,
    'endCursor': null,
    'hasOlder': false,
    'hasNewer': false,
    'entries': const <Object?>[],
    'error': agentId == 'missing-agent-history'
        ? 'Agent not found: missing-agent-history'
        : null,
  };
  if (agentId == 'missing-field-history') {
    payload.remove('window');
  } else if (agentId == 'corrupt-history') {
    payload['entries'] = [
      {
        'provider': 'test',
        'item': {'kind': 'tool_call', 'id': 42},
        'timestamp': 0,
        'seqStart': 1,
        'seqEnd': 1,
        'sourceSeqRanges': const <Object?>[],
        'collapsed': const <Object?>[],
      },
    ];
  }
  return {'type': AgentTimelinePage.responseType, 'payload': payload};
}

Future<void> _expectImmediateFailure(
  Future<Object?> Function() action,
  Matcher matcher,
) async {
  final stopwatch = Stopwatch()..start();
  await expectLater(action(), throwsA(matcher));
  stopwatch.stop();
  expect(
    stopwatch.elapsed,
    lessThan(const Duration(seconds: 2)),
    reason: 'a correlated response must not fall through to the 30s timeout',
  );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed >= timeout) {
      fail('condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
