import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_service.dart';
import '../workspace/workspace_registry.dart';
import '../workspace/workspace_v2_service.dart';
import 'agent_manager.dart';
import 'create_agent_title.dart';

typedef AgentLifecycleSubscribe =
    void Function() Function(
      AgentStreamSubscriber subscriber, {
      String? agentId,
    });

final class LifecycleRegistration {
  const LifecycleRegistration(this._cancel);

  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

final class CreateAgentLifecycleDispatch {
  CreateAgentLifecycleDispatch({
    required this.manager,
    required this.workspaces,
    required this.git,
    required this.archiveWorkspace,
    this.log,
  });

  final AgentManager manager;
  final WorkspaceV2Service workspaces;
  final GitService git;
  final Future<void> Function(String workspaceId) archiveWorkspace;
  final void Function(String message)? log;
  final Set<String> _autoArchiveAgentIds = {};

  Future<PersistedWorkspaceRecord?> createWorktreeForRequest({
    required String cwd,
    required CreateAgentWorktreeTarget? target,
    required String initialPrompt,
    required GitSetupOptions? legacyGitOptions,
    String? legacyWorktreeName,
  }) async {
    if (target != null && legacyGitOptions != null) {
      throw StateError(
        'create_agent_request worktree cannot be combined with git options',
      );
    }
    PersistedWorkspaceRecord? currentWorktree;
    if (target != null) {
      final source = switch (target) {
        BranchOffCreateAgentWorktreeTarget(:final newBranch, :final base) =>
          WorktreeWorkspaceCreateSource(
            cwd: cwd,
            action: WorktreeCreateAction.branchOff,
            branchName: newBranch,
            refName: base,
            worktreeSlug: newBranch,
          ),
        CheckoutBranchCreateAgentWorktreeTarget(:final branch) =>
          WorktreeWorkspaceCreateSource(
            cwd: cwd,
            action: WorktreeCreateAction.checkout,
            refName: branch,
          ),
        CheckoutPrCreateAgentWorktreeTarget(:final prNumber) =>
          WorktreeWorkspaceCreateSource(
            cwd: cwd,
            action: WorktreeCreateAction.checkout,
            githubPrNumber: prNumber,
          ),
      };
      currentWorktree = await _createWorktree(source, initialPrompt);
    }

    final options = legacyGitOptions ?? _legacyWorktree(legacyWorktreeName);
    if (options == null) return currentWorktree;
    final setupCwd = currentWorktree?.cwd ?? cwd;
    final baseBranch = _trimmed(options.baseBranch);
    final createNewBranch = options.createNewBranch == true;
    final newBranchName = options.newBranchName == null
        ? null
        : slugify(options.newBranchName!);
    final requestedSlug = options.worktreeSlug == null
        ? null
        : slugify(options.worktreeSlug!);
    final worktreeSlug = requestedSlug ?? newBranchName;

    if (createNewBranch && (newBranchName == null || newBranchName.isEmpty)) {
      throw StateError('New branch name is required');
    }
    if (options.createWorktree == true) {
      return _createWorktree(
        WorktreeWorkspaceCreateSource(
          cwd: setupCwd,
          action: switch (options.action) {
            GitSetupAction.branchOff => WorktreeCreateAction.branchOff,
            GitSetupAction.checkout => WorktreeCreateAction.checkout,
            null => null,
          },
          refName: _trimmed(options.refName),
          baseBranch: baseBranch,
          branchName: createNewBranch ? newBranchName : null,
          checkoutSource: options.checkoutSource?.toJson(),
          githubPrNumber: options.githubPrNumber,
          worktreeSlug: worktreeSlug,
        ),
        initialPrompt,
      );
    }
    if (createNewBranch) {
      await git.createBranchFromBase(
        cwd: setupCwd,
        baseBranch: baseBranch ?? await git.resolveDefaultBranch(setupCwd),
        newBranchName: newBranchName!,
      );
    } else if (baseBranch != null) {
      await git.checkoutExistingBranch(setupCwd, baseBranch);
    }
    return currentWorktree;
  }

  Future<PersistedWorkspaceRecord> _createWorktree(
    WorktreeWorkspaceCreateSource source,
    String initialPrompt,
  ) => workspaces.createAutomationWorkspace(
    source,
    title: resolveFirstAgentPromptTitle({'prompt': initialPrompt}),
    firstAgentContext: {'prompt': initialPrompt},
  );

  GitSetupOptions? _legacyWorktree(String? name) {
    if (name == null || name.isEmpty) return null;
    return GitSetupOptions(
      createWorktree: true,
      createNewBranch: true,
      newBranchName: name,
      worktreeSlug: name,
    );
  }

  String? _trimmed(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  LifecycleRegistration registerAutoArchiveIfRequested({
    required bool? autoArchive,
    required String agentId,
    String? createdWorkspaceId,
  }) {
    if (autoArchive != true) {
      return LifecycleRegistration(() async {});
    }
    return registerAgentAutoArchive(
      subscribe: manager.subscribeStream,
      agentId: agentId,
      archive: () => _autoArchiveOnce(
        agentId: agentId,
        createdWorkspaceId: createdWorkspaceId,
      ),
    );
  }

  Future<void> cleanupCreatedWorktreeAfterFailedAgentCreate({
    required String? createdWorkspaceId,
    required String? createdAgentId,
  }) async {
    if (createdWorkspaceId == null || createdAgentId != null) return;
    try {
      if (await workspaces.cancelAgentContinuation(createdWorkspaceId)) {
        return;
      }
      await archiveWorkspace(createdWorkspaceId);
    } catch (error) {
      log?.call(
        'Failed to clean up worktree after create_agent_request failed: '
        '$error',
      );
    }
  }

  Future<void> _autoArchiveOnce({
    required String agentId,
    required String? createdWorkspaceId,
  }) async {
    if (!_autoArchiveAgentIds.add(agentId)) return;
    try {
      if (createdWorkspaceId != null) {
        await archiveWorkspace(createdWorkspaceId);
      } else {
        await manager.archive(agentId);
      }
    } catch (error) {
      log?.call('Failed to auto-archive agent $agentId: $error');
    }
  }
}

LifecycleRegistration registerAgentAutoArchive({
  required AgentLifecycleSubscribe subscribe,
  required String agentId,
  required Future<void> Function() archive,
}) {
  void Function()? unsubscribe;
  Future<void>? archiveTask;
  void release() {
    final subscribed = unsubscribe;
    if (subscribed == null) return;
    unsubscribe = null;
    subscribed();
  }

  final registration = LifecycleRegistration(() async {
    release();
    await archiveTask;
  });
  unsubscribe = subscribe((payload) {
    final item = payload.item;
    if (item is! TurnItem ||
        !const {
          TurnPhase.completed,
          TurnPhase.failed,
          TurnPhase.canceled,
        }.contains(item.phase)) {
      return;
    }
    release();
    archiveTask = Future<void>.sync(archive);
  }, agentId: agentId);
  return registration;
}
