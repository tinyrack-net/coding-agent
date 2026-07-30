import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('daemon update request matches the Paseo wire contract', () {
    expect(const DaemonUpdateRequest(requestId: 'update-1').toJson(), {
      'type': 'daemon.update.request',
      'requestId': 'update-1',
    });
  });

  test('daemon update progress parses every Paseo phase', () {
    for (final phase in DaemonUpdatePhase.values) {
      final progress = DaemonUpdateProgress.fromJson({
        'type': 'daemon.update.progress',
        'payload': {'requestId': 'update-1', 'phase': phase.name},
      });
      expect(progress.requestId, 'update-1');
      expect(progress.phase, phase);
    }
  });

  test('daemon update response preserves recovery diagnostics', () {
    final response = DaemonUpdateResponse.fromJson({
      'type': 'daemon.update.response',
      'payload': {
        'requestId': 'update-1',
        'success': false,
        'error': 'npm install failed',
        'previousVersion': '0.1.9',
        'newVersion': null,
      },
    });
    expect(response.success, isFalse);
    expect(response.error, 'npm install failed');
    expect(response.previousVersion, '0.1.9');
    expect(response.newVersion, isNull);
  });
}
