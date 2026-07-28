import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/host_connection_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const slow = DirectTcpHostConnection(
    id: 'slow',
    endpoint: 'slow.example:6767',
  );
  const fast = DirectTcpHostConnection(
    id: 'fast',
    endpoint: 'fast.example:6767',
  );

  test('selects the lowest latency available candidate', () {
    expect(
      selectBestConnection(
        candidates: const [slow, fast],
        probes: const {
          'slow': ConnectionProbeAvailable(80),
          'fast': ConnectionProbeAvailable(12),
        },
      ),
      'fast',
    );
  });

  test('ignores pending and unavailable candidates', () {
    expect(
      selectBestConnection(
        candidates: const [slow, fast],
        probes: const {
          'slow': ConnectionProbeUnavailable(),
          'fast': ConnectionProbePending(),
        },
      ),
      isNull,
    );
  });

  test('keeps candidate order when latency is tied', () {
    expect(
      selectBestConnection(
        candidates: const [slow, fast],
        probes: const {
          'slow': ConnectionProbeAvailable(20),
          'fast': ConnectionProbeAvailable(20),
        },
      ),
      'slow',
    );
  });
}
