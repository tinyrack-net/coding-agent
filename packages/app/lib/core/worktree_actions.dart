import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_client.dart';
import '../state/agents_provider.dart';
import '../state/workspace_providers.dart';
import '../widgets/fluent/toast.dart';

/// Archives [agent], then — if it runs in an isolated worktree and was the
/// *last* agent sharing that worktree's cwd (several can now coexist) —
/// asks whether to also delete the worktree/branch (mirrors Paseo's
/// keep/remove-on-exit worktree flow). Shared by the worktree tab strip's
/// close-tab handler and the sidebar's per-row kebab menu.
Future<void> archiveAgentWithWorktreeConfirm(
  BuildContext context,
  WidgetRef ref,
  AgentSummary agent,
) async {
  final actions = ref.read(agentActionsProvider);
  try {
    await actions.archive(agent.agentId);
  } catch (e) {
    if (!context.mounted) return;
    AppToast.show(
      context,
      'Failed to archive: $e',
      severity: InfoBarSeverity.error,
    );
    return;
  }

  if (!agent.isWorktree || agent.projectPath == null) return;
  final worktreePath = resolveWorktreeKey(agent);
  final remaining = ref
      .read(agentsProvider)
      .values
      .where((a) => resolveWorktreeKey(a) == worktreePath);
  if (remaining.isNotEmpty) return;
  if (!context.mounted) return;
  final remove = await showDialog<bool>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Delete worktree?'),
      content: Text(
        'This agent ran on branch "${agent.branch}" in an isolated '
        'worktree. Keep it to resume later, or remove it now.',
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (remove != true) return;
  if (!context.mounted) return;
  await archiveWorktreeWithConfirm(context, ref, agent.projectPath!, agent.cwd);
}

/// Archives the worktree at [path] (project [projectPath]); on a
/// dirty-worktree conflict, confirms discarding the uncommitted changes and
/// retries with `force: true` — mirrors Paseo's `ExitWorktree`
/// `discard_changes` flow.
Future<void> archiveWorktreeWithConfirm(
  BuildContext context,
  WidgetRef ref,
  String projectPath,
  String path,
) async {
  final notifier = ref.read(worktreesProvider(projectPath).notifier);
  try {
    await notifier.archive(path);
  } on DaemonRpcException catch (e) {
    if (e.error.code != RpcErrorCodes.conflict) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Failed to remove worktree: ${e.error.message}',
        severity: InfoBarSeverity.error,
      );
      return;
    }
    if (!context.mounted) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Uncommitted changes'),
        content: Text(
          '${e.error.message}\n\nDiscard these changes and remove the worktree?',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard and remove'),
          ),
        ],
      ),
    );
    if (discard != true) return;
    try {
      await notifier.archive(path, force: true);
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Failed to remove worktree: $e',
        severity: InfoBarSeverity.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    AppToast.show(
      context,
      'Failed to remove worktree: $e',
      severity: InfoBarSeverity.error,
    );
  }
}
