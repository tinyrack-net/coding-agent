import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import '../sidebar/sidebar_agent_state.dart';
import '../sidebar/status_dot_color.dart';

class AgentStatusDot extends StatelessWidget {
  const AgentStatusDot({
    super.key,
    required this.status,
    required this.requiresAttention,
    this.attentionReason,
    this.pendingPermissionCount = 0,
    this.showInactive = false,
  });

  final AgentRunState? status;
  final bool? requiresAttention;
  final AgentAttentionReason? attentionReason;
  final int pendingPermissionCount;
  final bool showInactive;

  @override
  Widget build(BuildContext context) {
    final lifecycleStatus = status;
    if (lifecycleStatus == null) return const SizedBox.shrink();

    final bucket = deriveSidebarStateBucket(
      status: lifecycleStatus,
      requiresAttention: requiresAttention ?? false,
      attentionReason: attentionReason,
      pendingPermissionCount: pendingPermissionCount,
    );
    final color = getStatusDotColor(
      palette: context.paseoPalette,
      bucket: bucket,
      showDoneAsInactive: showInactive,
    );
    if (color == null) return const SizedBox.shrink();

    return DecoratedBox(
      key: ValueKey('agent-status-dot-${bucket.name}'),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 8),
    );
  }
}
