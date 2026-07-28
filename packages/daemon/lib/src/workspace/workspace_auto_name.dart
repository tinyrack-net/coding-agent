import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent/create_agent_title.dart';
import '../agent/first_agent_context.dart';
import '../git/git_service.dart';
import '../git/worktree_metadata.dart';
import 'workspace_registry.dart';

final class GeneratedWorkspaceName {
  const GeneratedWorkspaceName({required this.title, required this.branch});

  final String title;
  final String branch;
}

typedef WorkspaceAutoNameGenerator =
    Future<GeneratedWorkspaceName?> Function(String seed, String cwd);

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
    DateTime Function()? now,
  }) : _generate = generate,
       _now = now ?? DateTime.now;

  final FileBackedWorkspaceRegistry workspaces;
  final GitService git;
  final WorkspaceAutoNameGenerator _generate;
  final DateTime Function() _now;

  void schedule(
    PersistedWorkspaceRecord workspace,
    Map<String, Object?>? firstAgentContext,
  ) {
    unawaited(
      Future<void>(() async {
        try {
          await run(workspace, firstAgentContext);
        } catch (_) {
          // Metadata generation is best effort and must never fail creation.
        }
      }),
    );
  }

  Future<void> run(
    PersistedWorkspaceRecord workspace,
    Map<String, Object?>? firstAgentContext,
  ) async {
    final seed = buildAgentBranchNameSeed(firstAgentContext);
    if (seed == null) return;
    GeneratedWorkspaceName? generated;
    final isWorktree =
        workspace.isPaseoOwnedWorktree && workspace.worktreeRoot != null;
    FirstAgentBranchAutoNameResult? branchResult;
    if (isWorktree) {
      branchResult = await attemptFirstAgentBranchAutoName(
        workspace.worktreeRoot!,
        seed,
        generate: () async =>
            generated ??= await _generate(seed, workspace.cwd),
      );
    }
    generated ??= await _generate(seed, workspace.cwd);
    final name = generated;
    if (name == null) return;
    final current = await workspaces.get(workspace.workspaceId);
    if (current == null) return;
    final provisionalTitle = resolveFirstAgentPromptTitle(firstAgentContext);
    final mayReplaceTitle =
        current.title == null || current.title == provisionalTitle;
    final renamedBranch = branchResult?.renamed == true
        ? branchResult!.branch
        : null;
    if (!mayReplaceTitle && renamedBranch == null) return;
    await workspaces.upsert(
      current.copyWith(
        title: mayReplaceTitle ? name.title : current.title,
        branch: renamedBranch ?? current.branch,
        displayName: renamedBranch ?? current.displayName,
        updatedAt: _now().toUtc().toIso8601String(),
      ),
    );
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
    final desired = generated?.branch.trim();
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
