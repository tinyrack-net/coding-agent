typedef RuntimeMetricsClock = int Function();

const websocketRuntimeCounterNames = <String>[
  'connectedAwaitingHello',
  'helloResumed',
  'helloNew',
  'pendingDisconnected',
  'sessionDisconnectedWaitingReconnect',
  'sessionSocketDisconnectedAttached',
  'sessionCleanup',
  'validationFailed',
  'binaryBeforeHelloRejected',
  'pendingMessageRejectedBeforeHello',
  'missingConnectionForMessage',
  'unexpectedHelloOnActiveConnection',
  'sessionHandlerFailed',
  'relayExternalSocketAttached',
  'originRejected',
  'hostRejected',
];

/// Accumulates the same bounded WebSocket runtime window emitted by Paseo.
class WebSocketRuntimeMetricsWindow {
  WebSocketRuntimeMetricsWindow({RuntimeMetricsClock? clock})
    : _clock = clock ?? _systemClock,
      _windowStartedAt = (clock ?? _systemClock)();

  final RuntimeMetricsClock _clock;
  int _windowStartedAt;
  final Map<String, int> _counters = {
    for (final name in websocketRuntimeCounterNames) name: 0,
  };
  final Map<String, int> _inboundMessageCounts = {};
  final Map<String, int> _inboundSessionRequestCounts = {};
  final Map<String, int> _outboundMessageCounts = {};
  final Map<String, int> _outboundSessionMessageCounts = {};
  final Map<String, int> _outboundAgentStreamCounts = {};
  final Map<String, int> _outboundAgentStreamByAgentCounts = {};
  final Map<String, int> _outboundBinaryFrameCounts = {};
  final List<int> _bufferedAmountSamples = [];
  final Map<String, List<double>> _requestLatencies = {};

  void incrementCounter(String counter) {
    if (!_counters.containsKey(counter)) {
      throw ArgumentError.value(counter, 'counter', 'unknown counter');
    }
    _counters[counter] = _counters[counter]! + 1;
  }

  void recordInboundMessage(String type) {
    _incrementCount(_inboundMessageCounts, type);
  }

  void recordInboundSessionRequest(String type) {
    _incrementCount(_inboundSessionRequestCounts, type);
  }

  void recordOutboundMessage(
    Map<String, Object?> message, {
    int? bufferedAmount,
  }) {
    if (message['type'] != 'session') {
      final type = message['type'];
      if (type is String) _incrementCount(_outboundMessageCounts, type);
      _recordBufferedAmount(bufferedAmount);
      return;
    }

    _incrementCount(_outboundMessageCounts, 'session_message');
    final sessionMessage = message['message'];
    if (sessionMessage is Map<String, Object?>) {
      final type = sessionMessage['type'];
      if (type is String) {
        _incrementCount(_outboundSessionMessageCounts, type);
        if (type == 'agent_stream') {
          _recordOutboundAgentStreamMessage(sessionMessage['payload']);
        }
      }
    }
    _recordBufferedAmount(bufferedAmount);
  }

  void recordOutboundBinaryFrame({int? bufferedAmount}) {
    _incrementCount(_outboundBinaryFrameCounts, 'binary');
    _recordBufferedAmount(bufferedAmount);
  }

  void recordRequestLatency(String type, double durationMs) {
    (_requestLatencies[type] ??= []).add(durationMs);
  }

  Map<String, Object?> snapshotAndReset() {
    final now = _clock();
    final elapsed = now - _windowStartedAt;
    final snapshot = <String, Object?>{
      'windowMs': elapsed < 0 ? 0 : elapsed,
      'counters': Map<String, int>.unmodifiable(_counters),
      'inboundMessageTypesTop': _topCounts(_inboundMessageCounts, 12),
      'inboundSessionRequestTypesTop': _topCounts(
        _inboundSessionRequestCounts,
        20,
      ),
      'outboundMessageTypesTop': _topCounts(_outboundMessageCounts, 12),
      'outboundSessionMessageTypesTop': _topCounts(
        _outboundSessionMessageCounts,
        20,
      ),
      'outboundAgentStreamTypesTop': _topCounts(_outboundAgentStreamCounts, 20),
      'outboundAgentStreamAgentsTop': _topCounts(
        _outboundAgentStreamByAgentCounts,
        20,
      ),
      'outboundBinaryFrameTypesTop': _topCounts(_outboundBinaryFrameCounts, 12),
      'bufferedAmount': _bufferedAmountStats(),
      'latency': _latencyStats(),
    };
    _reset(now);
    return snapshot;
  }

  void _recordOutboundAgentStreamMessage(Object? payload) {
    if (payload is! Map<String, Object?>) return;
    final agentId = payload['agentId'];
    final event = payload['event'];
    if (agentId is! String || event is! Map<String, Object?>) return;
    final eventType = event['type'];
    if (eventType is! String) return;
    var normalizedType = eventType;
    if (eventType == 'timeline') {
      final item = event['item'];
      if (item is Map<String, Object?> && item['type'] is String) {
        normalizedType = 'timeline:${item['type']}';
      }
    }
    _incrementCount(_outboundAgentStreamCounts, normalizedType);
    _incrementCount(_outboundAgentStreamByAgentCounts, agentId);
  }

  void _recordBufferedAmount(int? bufferedAmount) {
    if (bufferedAmount != null) _bufferedAmountSamples.add(bufferedAmount);
  }

  List<Map<String, Object?>> _latencyStats() {
    final stats = <Map<String, Object?>>[];
    for (final entry in _requestLatencies.entries) {
      if (entry.value.isEmpty) continue;
      final sorted = [...entry.value]..sort();
      stats.add({
        'type': entry.key,
        'count': sorted.length,
        'minMs': sorted.first.round(),
        'maxMs': sorted.last.round(),
        'p50Ms': sorted[sorted.length ~/ 2].round(),
        'totalMs': sorted.fold<double>(0, (sum, value) => sum + value).round(),
      });
    }
    stats.sort(
      (a, b) => (b['totalMs']! as int).compareTo(a['totalMs']! as int),
    );
    return stats.take(15).toList(growable: false);
  }

  Map<String, int> _bufferedAmountStats() {
    if (_bufferedAmountSamples.isEmpty) return const {'p95': 0, 'max': 0};
    final samples = [..._bufferedAmountSamples]..sort();
    final p95Index = (samples.length * .95).ceil() - 1;
    return {'p95': samples[p95Index], 'max': samples.last};
  }

  void _reset(int now) {
    for (final name in _counters.keys) {
      _counters[name] = 0;
    }
    _inboundMessageCounts.clear();
    _inboundSessionRequestCounts.clear();
    _outboundMessageCounts.clear();
    _outboundSessionMessageCounts.clear();
    _outboundAgentStreamCounts.clear();
    _outboundAgentStreamByAgentCounts.clear();
    _outboundBinaryFrameCounts.clear();
    _bufferedAmountSamples.clear();
    _requestLatencies.clear();
    _windowStartedAt = now;
  }
}

class EventLoopDelayWindow {
  final List<double> _samples = [];

  void record(double delayMs) {
    if (delayMs.isFinite && delayMs >= 0) _samples.add(delayMs);
  }

  Map<String, int>? snapshotAndReset() {
    if (_samples.isEmpty) return null;
    final sorted = [..._samples]..sort();
    final p99Index = (sorted.length * .99).ceil() - 1;
    final snapshot = {
      'p50Ms': sorted[sorted.length ~/ 2].round(),
      'p99Ms': sorted[p99Index].round(),
      'maxMs': sorted.last.round(),
    };
    _samples.clear();
    return snapshot;
  }
}

int _systemClock() => DateTime.now().millisecondsSinceEpoch;

void _incrementCount(Map<String, int> counts, String key) {
  counts[key] = (counts[key] ?? 0) + 1;
}

List<List<Object>> _topCounts(Map<String, int> counts, int limit) {
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [
    for (final entry in entries.take(limit)) <Object>[entry.key, entry.value],
  ];
}
