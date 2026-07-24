/// Project and git-worktree messages.
library;

final class ProjectInfo {
  const ProjectInfo({
    required this.path,
    required this.name,
    required this.isGitRepo,
  });

  final String path;
  final String name;
  final bool isGitRepo;

  static ProjectInfo fromJson(Map<String, Object?> json) => ProjectInfo(
        path: json['path'] as String,
        name: (json['name'] as String?) ?? '',
        isGitRepo: (json['isGitRepo'] as bool?) ?? false,
      );

  Map<String, Object?> toJson() =>
      {'path': path, 'name': name, 'isGitRepo': isGitRepo};
}

final class WorktreeInfo {
  const WorktreeInfo({
    required this.path,
    required this.branch,
    required this.projectPath,
    this.isMain = false,
  });

  final String path;
  final String branch;

  /// The repository this worktree belongs to (its main checkout path).
  final String projectPath;

  /// True for the primary checkout (cannot be archived).
  final bool isMain;

  static WorktreeInfo fromJson(Map<String, Object?> json) => WorktreeInfo(
        path: json['path'] as String,
        branch: (json['branch'] as String?) ?? '',
        projectPath: (json['projectPath'] as String?) ?? '',
        isMain: (json['isMain'] as bool?) ?? false,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'branch': branch,
        'projectPath': projectPath,
        'isMain': isMain,
      };
}

/// Response of `branch.list.request`: local branches of a project, most
/// recently committed first, plus the branch currently checked out.
final class BranchListResponse {
  const BranchListResponse({required this.branches, required this.currentBranch});

  final List<String> branches;
  final String currentBranch;

  static BranchListResponse fromJson(Map<String, Object?> json) =>
      BranchListResponse(
        branches:
            ((json['branches'] as List?) ?? const []).cast<String>(),
        currentBranch: (json['currentBranch'] as String?) ?? '',
      );

  Map<String, Object?> toJson() =>
      {'branches': branches, 'currentBranch': currentBranch};
}
