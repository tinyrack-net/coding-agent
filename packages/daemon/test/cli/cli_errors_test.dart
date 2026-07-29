import 'package:agent_daemon/src/cli/cli_errors.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('returns the message from Dart errors and exceptions', () {
    expect(getErrorMessage(StateError('broken state')), 'broken state');
    expect(
      getErrorMessage(const FormatException('invalid value')),
      'invalid value',
    );
    expect(
      getErrorMessage(
        DaemonSpawnException('spawn failed', logTail: 'private log tail'),
      ),
      'spawn failed',
    );
  });

  test('stringifies arbitrary thrown values without rewriting them', () {
    expect(getErrorMessage('plain failure'), 'plain failure');
    expect(getErrorMessage(42), '42');
    expect(getErrorMessage(null), 'null');
    expect(getErrorMessage(_OpaqueFailure()), 'opaque: failure');
  });
}

final class _OpaqueFailure {
  @override
  String toString() => 'opaque: failure';
}
