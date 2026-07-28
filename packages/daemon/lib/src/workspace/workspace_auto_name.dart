import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent/create_agent_title.dart';
import '../agent/first_agent_context.dart';
import '../agent/structured_generation.dart';
import '../git/git_service.dart';
import '../git/worktree_metadata.dart';
import 'workspace_registry.dart';

final class GeneratedWorkspaceName {
  const GeneratedWorkspaceName({required this.title, required this.branch});

  final String? title;
  final String? branch;
}

typedef WorkspaceAutoNameGenerator =
    Future<GeneratedWorkspaceName?> Function(
      String seed,
      String cwd,
      StructuredGenerationSelection? currentSelection,
    );
typedef WorkspaceGitMutationNotifier =
    Future<void> Function(String cwd, String mutation);

final class FirstAgentBranchAutoNameResult {
  const FirstAgentBranchAutoNameResult({
    required this.attempted,
    required this.renamed,
    this.branch,
  });

  final bool attempted;
  final bool renamed;
  final String? branch;
}

/// Paseo-compatible first-agent title and worktree branch auto naming.
final class WorkspaceAutoName {
  WorkspaceAutoName({
    required this.workspaces,
    required this.git,
    required WorkspaceAutoNameGenerator generate,
    WorkspaceGitMutationNotifier? notifyGitMutation,
    DateTime Function()? now,
  }) : _generate = generate,
       _notifyGitMutation = notifyGitMutation,
       _now = now ?? DateTime.now;

  final FileBackedWorkspaceRegistry workspaces;
  final GitService git;
  final WorkspaceAutoNameGenerator _generate;
  final WorkspaceGitMutationNotifier? _notifyGitMutation;
  final DateTime Function() _now;

  void schedule(
    PersistedWorkspaceRecord workspace,
    Map<String, Object?>? firstAgentContext, {
    StructuredGenerationSelection? currentSelection,
  }) {
    unawaited(
      Future<void>(() async {
        try {
          await run(
            workspace,
            firstAgentContext,
            currentSelection: currentSelection,
          );
        } catch (_) {
          // Metadata generation is best effort and must never fail creation.
        }
      }),
    );
  }

  Future<void> run(
    PersistedWorkspaceRecord workspace,
    Map<String, Object?>? firstAgentContext, {
    StructuredGenerationSelection? currentSelection,
  }) async {
    final seed = buildAgentBranchNameSeed(firstAgentContext);
    if (seed == null) return;
    GeneratedWorkspaceName? generated;
    final isWorktree = workspace.kind == PersistedWorkspaceKind.worktree;
    final worktreeRoot = workspace.worktreeRoot ?? workspace.cwd;
    FirstAgentBranchAutoNameResult? branchResult;
    if (isWorktree) {
      branchResult = await attemptFirstAgentBranchAutoName(
        worktreeRoot,
        seed,
        generate: () async => generated ??= await _generate(
          seed,
          workspace.cwd,
          currentSelection,
        ),
      );
    }
    generated ??= await _generate(seed, workspace.cwd, currentSelection);
    final name = generated;
    final generatedTitle = name?.title?.trim();
    if (name == null || generatedTitle == null || generatedTitle.isEmpty) {
      return;
    }
    final current = await workspaces.get(workspace.workspaceId);
    if (current == null) return;
    final provisionalTitle = resolveFirstAgentPromptTitle(firstAgentContext);
    final mayReplaceTitle =
        current.title == null || current.title == provisionalTitle;
    final renamedBranch = branchResult?.renamed == true
        ? branchResult!.branch
        : null;
    await workspaces.upsert(
      current.copyWith(
        title: mayReplaceTitle ? generatedTitle : current.title,
        branch: renamedBranch ?? current.branch,
        updatedAt: _now().toUtc().toIso8601String(),
      ),
    );
    if (branchResult?.renamed == true) {
      await _notifyGitMutation?.call(worktreeRoot, 'rename-branch');
    }
  }

  Future<FirstAgentBranchAutoNameResult> attemptFirstAgentBranchAutoName(
    String worktreeRoot,
    String seed, {
    required Future<GeneratedWorkspaceName?> Function() generate,
  }) async {
    WorktreeMetadata? metadata;
    try {
      metadata = readWorktreeMetadata(worktreeRoot);
    } on Object {
      return const FirstAgentBranchAutoNameResult(
        attempted: false,
        renamed: false,
      );
    }
    final state = metadata?.firstAgentBranchAutoName;
    if (metadata?.version != 2 || state?['status'] != 'pending') {
      return const FirstAgentBranchAutoNameResult(
        attempted: false,
        renamed: false,
      );
    }
    final placeholder = state!['placeholderBranchName']! as String;
    if (await git.currentBranch(worktreeRoot) != placeholder) {
      markWorktreeFirstAgentBranchAutoNameAttempted(
        worktreeRoot,
        attemptedAt: _now(),
      );
      return const FirstAgentBranchAutoNameResult(
        attempted: true,
        renamed: false,
      );
    }
    markWorktreeFirstAgentBranchAutoNameAttempted(
      worktreeRoot,
      attemptedAt: _now(),
    );
    final generated = await generate();
    final desired = generated?.branch?.trim();
    if (desired == null ||
        desired == placeholder ||
        !validateBranchSlug(desired).valid) {
      return const FirstAgentBranchAutoNameResult(
        attempted: true,
        renamed: false,
      );
    }
    if (await git.currentBranch(worktreeRoot) != placeholder) {
      return const FirstAgentBranchAutoNameResult(
        attempted: true,
        renamed: false,
      );
    }
    String? available;
    for (var suffix = 1; suffix <= 50; suffix++) {
      final candidate = suffix == 1 ? desired : '$desired-$suffix';
      if (candidate == placeholder) continue;
      if (!await git.localBranchExists(worktreeRoot, candidate)) {
        available = candidate;
        break;
      }
    }
    if (available == null) {
      return const FirstAgentBranchAutoNameResult(
        attempted: true,
        renamed: false,
      );
    }
    final branch = await git.renameCurrentBranch(worktreeRoot, available);
    return FirstAgentBranchAutoNameResult(
      attempted: true,
      renamed: true,
      branch: branch,
    );
  }
}
