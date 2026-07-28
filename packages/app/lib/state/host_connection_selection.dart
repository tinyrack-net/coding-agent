import 'package:agent_protocol/agent_protocol.dart';

sealed class ConnectionProbeState {
  const ConnectionProbeState();
}

final class ConnectionProbePending extends ConnectionProbeState {
  const ConnectionProbePending();
}

final class ConnectionProbeUnavailable extends ConnectionProbeState {
  const ConnectionProbeUnavailable();
}

final class ConnectionProbeAvailable extends ConnectionProbeState {
  const ConnectionProbeAvailable(this.latencyMs);

  final double latencyMs;
}

String? selectBestConnection({
  required List<HostConnection> candidates,
  required Map<String, ConnectionProbeState> probes,
}) {
  String? bestConnectionId;
  double? bestLatency;
  for (final connection in candidates) {
    final probe = probes[connection.id];
    if (probe is! ConnectionProbeAvailable) continue;
    if (bestLatency == null || probe.latencyMs < bestLatency) {
      bestConnectionId = connection.id;
      bestLatency = probe.latencyMs;
    }
  }
  return bestConnectionId;
}
