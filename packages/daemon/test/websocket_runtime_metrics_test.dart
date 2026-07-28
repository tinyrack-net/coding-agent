import 'package:agent_daemon/src/server/websocket_runtime_metrics.dart';
import 'package:test/test.dart';

void main() {
  late int now;
  late WebSocketRuntimeMetricsWindow metrics;

  setUp(() {
    now = 1000;
    metrics = WebSocketRuntimeMetricsWindow(clock: () => now);
  });

  test('records outbound message type counts', () {
    metrics
      ..recordOutboundMessage({
        'type': 'session',
        'message': {
          'type': 'agent_stream',
          'payload': {
            'agentId': 'agent-1',
            'event': {'type': 'turn_completed', 'provider': 'codex'},
          },
        },
      }, bufferedAmount: 0)
      ..recordOutboundMessage({
        'type': 'session',
        'message': {
          'type': 'status',
          'payload': {'status': 'ok'},
        },
      }, bufferedAmount: 0)
      ..recordOutboundMessage({'type': 'pong'}, bufferedAmount: 0);

    final snapshot = metrics.snapshotAndReset();
    expect(snapshot['outboundMessageTypesTop'], [
      ['session_message', 2],
      ['pong', 1],
    ]);
    expect(snapshot['outboundSessionMessageTypesTop'], [
      ['agent_stream', 1],
      ['status', 1],
    ]);
  });

  test('records agent stream subtypes and top agents', () {
    void record(String agentId, Map<String, Object?> event) {
      metrics.recordOutboundMessage({
        'type': 'session',
        'message': {
          'type': 'agent_stream',
          'payload': {'agentId': agentId, 'event': event},
        },
      });
    }

    record('agent-1', {
      'type': 'timeline',
      'item': {'type': 'assistant_message'},
    });
    record('agent-1', {
      'type': 'timeline',
      'item': {'type': 'reasoning'},
    });
    record('agent-1', {'type': 'turn_completed'});
    record('agent-2', {
      'type': 'timeline',
      'item': {'type': 'assistant_message'},
    });

    final snapshot = metrics.snapshotAndReset();
    expect(snapshot['outboundAgentStreamTypesTop'], [
      ['timeline:assistant_message', 2],
      ['timeline:reasoning', 1],
      ['turn_completed', 1],
    ]);
    expect(snapshot['outboundAgentStreamAgentsTop'], [
      ['agent-1', 3],
      ['agent-2', 1],
    ]);
  });

  test('records buffered amount p95, max, and binary frames', () {
    for (final amount in [0, 10, 50]) {
      metrics.recordOutboundMessage({'type': 'pong'}, bufferedAmount: amount);
    }
    metrics.recordOutboundBinaryFrame(bufferedAmount: 100);

    final snapshot = metrics.snapshotAndReset();
    expect(snapshot['bufferedAmount'], {'p95': 100, 'max': 100});
    expect(snapshot['outboundBinaryFrameTypesTop'], [
      ['binary', 1],
    ]);
  });

  test('snapshots counters, request latency, and resets the window', () {
    metrics
      ..incrementCounter('helloNew')
      ..recordInboundMessage('session')
      ..recordInboundSessionRequest('send')
      ..recordRequestLatency('send', 12.4);
    now += 250;

    final first = metrics.snapshotAndReset();
    final second = metrics.snapshotAndReset();
    expect(first['windowMs'], 250);
    expect((first['counters'] as Map)['helloNew'], 1);
    expect(first['inboundMessageTypesTop'], [
      ['session', 1],
    ]);
    expect(first['inboundSessionRequestTypesTop'], [
      ['send', 1],
    ]);
    expect(first['latency'], [
      {
        'type': 'send',
        'count': 1,
        'minMs': 12,
        'maxMs': 12,
        'p50Ms': 12,
        'totalMs': 12,
      },
    ]);
    expect(second['windowMs'], 0);
    expect((second['counters'] as Map)['helloNew'], 0);
    expect(second['latency'], isEmpty);
  });

  test('bounds top lists and sorts latency by total duration', () {
    for (var index = 0; index < 25; index += 1) {
      metrics
        ..recordInboundMessage('in-$index')
        ..recordInboundSessionRequest('request-$index')
        ..recordRequestLatency('request-$index', index.toDouble());
    }
    final snapshot = metrics.snapshotAndReset();
    expect(snapshot['inboundMessageTypesTop'], hasLength(12));
    expect(snapshot['inboundSessionRequestTypesTop'], hasLength(20));
    expect(snapshot['latency'], hasLength(15));
    expect(
      (snapshot['latency'] as List).first,
      containsPair('type', 'request-24'),
    );
  });

  test('rejects unknown counters and ignores malformed stream payloads', () {
    expect(() => metrics.incrementCounter('unknown'), throwsArgumentError);
    metrics
      ..recordOutboundMessage(const {'type': 42})
      ..recordOutboundMessage(const {
        'type': 'session',
        'message': {
          'type': 'agent_stream',
          'payload': {'agentId': 42},
        },
      })
      ..recordOutboundMessage(const {'type': 'session', 'message': 'bad'});
    expect(metrics.snapshotAndReset()['outboundAgentStreamTypesTop'], isEmpty);
  });

  test('event loop delay reports percentiles and resets', () {
    final delays = EventLoopDelayWindow()
      ..record(double.nan)
      ..record(-1)
      ..record(1.2)
      ..record(3.7)
      ..record(9.8);
    expect(delays.snapshotAndReset(), {'p50Ms': 4, 'p99Ms': 10, 'maxMs': 10});
    expect(delays.snapshotAndReset(), isNull);
  });
}
