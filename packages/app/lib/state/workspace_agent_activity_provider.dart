import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sidebar/workspace_agent_activity.dart';
import 'agents_provider.dart';

final _workspaceAgentActivityControllerProvider =
    Provider<WorkspaceAgentActivityIndexController>(
      (_) => WorkspaceAgentActivityIndexController(),
    );

final workspaceAgentActivityIndexProvider =
    Provider<Map<String, WorkspaceAgentActivity>>((ref) {
      final controller = ref.watch(_workspaceAgentActivityControllerProvider);
      return controller.update(ref.watch(agentsProvider));
    });
