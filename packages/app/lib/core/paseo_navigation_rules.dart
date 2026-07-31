/// Ports of Paseo 0.2.0's navigation-intent rules — the small frozen
/// decisions that sit between a user gesture and the stores that mutate
/// layout state:
///
/// - `utils/workspace-navigation.ts`
/// - `utils/desktop-sidebar-toggle.ts`
/// - `utils/schedule-cadence-policy.ts`
///
/// Each rule is deliberately store-free so the decision can be tested
/// without standing up layout state; the caller supplies the mutations.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../workspace/prepare_workspace_tab.dart';
import '../workspace/workspace_tab_model.dart';

/// Opens a workspace tab through the layout mutations the caller supplies.
///
/// Upstream this reads `useWorkspaceLayoutStore.getState()` at call time so
/// navigation always hits the *current* store instance rather than a snapshot
/// captured when the module loaded. The Dart repo has no workspace layout
/// store port yet, so the two store actions arrive as plain parameters —
/// callers keep the same late-binding property by passing store getters.
void prepareWorkspaceTabWithLayout(
  PrepareWorkspaceTabInput input, {
  required String? Function(String workspaceKey, WorkspaceTabTarget target)
  openTabFocused,
  required void Function(String workspaceKey, String agentId) pinAgent,
}) {
  prepareWorkspaceTab(
    input,
    PrepareWorkspaceTabDependencies(
      openTabFocused: openTabFocused,
      pinAgent: pinAgent,
    ),
  );
}

/// Handles the desktop "toggle sidebars" gesture, returning whether the
/// gesture was consumed (always true — the desktop layout owns this key).
///
/// The gesture is a single collapse/expand switch over both rails: if either
/// rail is showing, the gesture clears the workspace; otherwise it restores
/// both. The right rail is only ever opened via [toggleFocusedFileExplorer]
/// because that handler carries the checkout intent (it knows which pane is
/// focused and whether a checkout is pending) — calling a plain open would
/// drop that context. Its return value is intentionally discarded: the
/// gesture is already decided by the time it runs.
bool toggleDesktopSidebarsWithCheckoutIntent({
  required bool isAgentListOpen,
  required bool isFileExplorerOpen,
  required void Function() openAgentList,
  required void Function() closeAgentList,
  required void Function() closeFileExplorer,
  required bool Function() toggleFocusedFileExplorer,
}) {
  if (isAgentListOpen || isFileExplorerOpen) {
    closeAgentList();
    closeFileExplorer();
    return true;
  }

  openAgentList();
  toggleFocusedFileExplorer();
  return true;
}

/// Resolves the cadence to store when a schedule's cron expression is edited
/// or when a schedule switches over to cron.
///
/// A schedule that is already on cron keeps its own timezone so editing the
/// expression never silently re-homes the schedule to wherever the editing
/// device happens to be. Legacy cron cadences persisted before timezones
/// existed are pinned to UTC, matching how the daemon interpreted them at the
/// time. Only a cadence arriving from a non-cron shape (interval) has no
/// timezone to preserve, so it adopts the device's.
CronScheduleCadence nextCronCadence({
  required ScheduleCadence current,
  required String expression,
  required String deviceTimeZone,
}) {
  if (current is CronScheduleCadence) {
    return CronScheduleCadence(
      expression: expression,
      timezone: current.timezone ?? 'UTC',
    );
  }
  return CronScheduleCadence(expression: expression, timezone: deviceTimeZone);
}
