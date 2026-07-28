import 'package:agent_protocol/agent_protocol.dart';

const modeAppliesNextTurnNotice = AgentProviderNotice(
  type: AgentProviderNoticeType.warning,
  message: 'Permission mode applies next turn',
);

const thinkingAppliesNextTurnNotice = AgentProviderNotice(
  type: AgentProviderNoticeType.warning,
  message: 'Thinking level applies next turn',
);
