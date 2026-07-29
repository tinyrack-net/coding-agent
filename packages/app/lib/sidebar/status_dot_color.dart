import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

const agentStatusNeedsInputColor = Color(0xFFF59E0B);
const agentStatusFailedColor = Color(0xFFEF4444);
const agentStatusRunningColor = Color(0xFF3B82F6);
const agentStatusAttentionColor = Color(0xFF22C55E);

Color? getStatusDotColor({
  required PaseoPalette palette,
  required WorkspaceStateBucket bucket,
  bool showDoneAsInactive = false,
}) => switch (bucket) {
  WorkspaceStateBucket.needsInput => agentStatusNeedsInputColor,
  WorkspaceStateBucket.failed => agentStatusFailedColor,
  WorkspaceStateBucket.running => agentStatusRunningColor,
  WorkspaceStateBucket.attention => agentStatusAttentionColor,
  WorkspaceStateBucket.done => showDoneAsInactive ? palette.border : null,
};

bool isEmphasizedStatusDotBucket(WorkspaceStateBucket? bucket) =>
    bucket == WorkspaceStateBucket.needsInput ||
    bucket == WorkspaceStateBucket.attention;
