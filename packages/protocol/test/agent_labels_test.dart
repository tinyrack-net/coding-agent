import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes the frozen parent agent label', () {
    expect(
      parentAgentIdFromLabels({paseoParentAgentIdLabel: ' parent-agent \n'}),
      'parent-agent',
    );
    expect(parentAgentIdFromLabels({paseoParentAgentIdLabel: '  '}), isNull);
    expect(parentAgentIdFromLabels({paseoParentAgentIdLabel: 42}), isNull);
    expect(parentAgentIdFromLabels(null), isNull);
  });

  test('delegated state follows the normalized parent label', () {
    expect(
      isDelegatedAgentLabels({paseoParentAgentIdLabel: 'parent-agent'}),
      isTrue,
    );
    expect(isDelegatedAgentLabels({paseoParentAgentIdLabel: '   '}), isFalse);
  });
}
