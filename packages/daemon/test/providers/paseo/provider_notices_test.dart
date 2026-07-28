import 'package:agent_daemon/src/providers/paseo/provider_notices.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('matches Paseo next-turn provider notices exactly', () {
    expect(modeAppliesNextTurnNotice.type, AgentProviderNoticeType.warning);
    expect(
      modeAppliesNextTurnNotice.message,
      'Permission mode applies next turn',
    );
    expect(thinkingAppliesNextTurnNotice.type, AgentProviderNoticeType.warning);
    expect(
      thinkingAppliesNextTurnNotice.message,
      'Thinking level applies next turn',
    );
  });
}
