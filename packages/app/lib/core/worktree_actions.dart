import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_client.dart';
import '../state/workspace_providers.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove worktree: ${e.error.message}')),
      );
      return;
    }
    if (!context.mounted) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uncommitted changes'),
        content: Text(
          '${e.error.message}\n\nDiscard these changes and remove the worktree?',
        ),
        actions: [
          TextButton(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove worktree: $e')),
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Failed to remove worktree: $e')));
  }
}
