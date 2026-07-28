import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../widgets/fluent/toast.dart';

void showProviderNoticeToast(
  BuildContext context,
  AgentProviderNotice? notice,
) {
  if (notice == null) return;
  AppToast.show(
    context,
    notice.message,
    severity: switch (notice.type) {
      AgentProviderNoticeType.info => InfoBarSeverity.info,
      AgentProviderNoticeType.warning => InfoBarSeverity.warning,
      AgentProviderNoticeType.error => InfoBarSeverity.error,
    },
    duration: notice.type == AgentProviderNoticeType.warning
        ? const Duration(seconds: 5)
        : const Duration(seconds: 4),
  );
}
