import 'package:agent_protocol/agent_protocol.dart';

import 'model.dart';

const directorySearchMethodId = 'directory-search';
const browseMethodId = 'browse';
const githubMethodId = 'github';
const newDirectoryMethodId = 'new-directory';

final class AddProjectMethodOption {
  const AddProjectMethodOption({
    required this.id,
    required this.label,
    required this.description,
    this.disabled = false,
  });

  final String id;
  final String label;
  final String description;
  final bool disabled;
}

final class AddProjectPathOption {
  const AddProjectPathOption({
    required this.id,
    required this.path,
    required this.displayPath,
    required this.secondaryText,
    required this.disabled,
  });

  final String id;
  final String path;
  final String displayPath;
  final String? secondaryText;
  final bool disabled;
}

List<AddProjectHost> filterAddProjectHosts(
  List<AddProjectHost> hosts,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return hosts;
  return hosts
      .where(
        (host) =>
            host.label.toLowerCase().contains(normalized) ||
            host.serverId.toLowerCase().contains(normalized),
      )
      .toList(growable: false);
}

List<AddProjectMethodOption> buildAddProjectMethods(AddProjectHost host) {
  if (!host.canAddProject) return const [];
  return [
    AddProjectMethodOption(
      id: directorySearchMethodId,
      label: 'Search for directory',
      description: 'Find a directory on ${host.label}',
    ),
    if (host.canBrowse)
      const AddProjectMethodOption(
        id: browseMethodId,
        label: 'Browse',
        description: 'Choose or create a directory in Finder',
      ),
    AddProjectMethodOption(
      id: githubMethodId,
      label: 'Clone from GitHub',
      description: _githubMethodDescription(host),
      disabled: !host.canCloneGithubRepositories,
    ),
    AddProjectMethodOption(
      id: newDirectoryMethodId,
      label: 'New directory',
      description: host.canCreateDirectory
          ? 'Create an empty directory on ${host.label}'
          : 'Update this host to create directories',
      disabled: !host.canCreateDirectory,
    ),
  ];
}

String addProjectMethodEmptyText(AddProjectHost? host) =>
    host?.canAddProject == false
    ? 'Update the host to use Add Project.'
    : 'No matching options';

String _githubMethodDescription(AddProjectHost host) {
  if (!host.canCloneGithubRepositories) {
    return 'Update this host to clone GitHub repositories';
  }
  if (host.canSearchGithubRepositories) {
    return 'Search projects available to your GitHub account';
  }
  return 'Enter a GitHub URL or owner/repo';
}

String pathBaseName(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final parts = trimmed.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? trimmed : parts.last;
}

List<GithubRepositoryChoice> buildManualGithubRepositoryChoices(String query) {
  final repo = query.trim();
  if (repo.isEmpty) return const [];
  if (isCompleteGitRemote(repo)) {
    final identity = parseGitHubRemoteUrl(repo);
    final location = parseGitRemoteLocation(repo);
    final remoteName = location == null
        ? repo
        : pathBaseName(location.path).replaceFirst(RegExp(r'\.git$'), '');
    return [
      GithubRepositoryChoice(
        id: 'manual:$repo',
        nameWithOwner: identity?.repo ?? remoteName,
        cloneUrl: repo,
        description: 'Clone this repository URL',
        visibility: null,
        updatedAt: null,
      ),
    ];
  }

  final shorthand = RegExp(r'^([^\s/]+)/([^\s/]+)$').firstMatch(repo);
  if (shorthand == null) return const [];
  final nameWithOwner = '${shorthand.group(1)}/${shorthand.group(2)}';
  return GithubCloneProtocol.values
      .map(
        (protocol) => GithubRepositoryChoice(
          id: 'manual:${protocol.name}:$nameWithOwner',
          nameWithOwner: nameWithOwner,
          cloneUrl: nameWithOwner,
          cloneProtocol: protocol,
          description: 'Clone owner/repo via ${protocol.name.toUpperCase()}',
          visibility: null,
          updatedAt: null,
        ),
      )
      .toList(growable: false);
}

String? parentDirectory(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final index = [
    trimmed.lastIndexOf('/'),
    trimmed.lastIndexOf('\\'),
  ].reduce((left, right) => left > right ? left : right);
  if (index < 0) return null;
  if (index == 0) return trimmed.substring(0, 1);
  return trimmed.substring(0, index);
}

String joinDirectoryPath(String parent, String name) {
  final trimmedParent = parent.replaceAll(RegExp(r'[\\/]+$'), '');
  final separator = trimmedParent.contains('\\') && !trimmedParent.contains('/')
      ? '\\'
      : '/';
  return '$trimmedParent$separator$name';
}

List<String> buildSuggestedParentDirectories(List<String> projectPaths) {
  final values = <String>[
    for (final path in projectPaths) ?parentDirectory(path),
    '~/dev',
    '~/Developer',
    '~/src',
    '~/projects',
    '~/workspace',
    '~',
  ];
  return values.toSet().toList(growable: false);
}

List<AddProjectPathOption> buildCloneLocationOptions({
  required List<String> parents,
  required String repositoryName,
  required List<String> existingPaths,
}) {
  final existing = existingPaths.map(_pathIdentity).toSet();
  final seen = <String>{};
  final result = <AddProjectPathOption>[];
  for (final parent in parents) {
    final path = joinDirectoryPath(parent, repositoryName);
    final identity = _pathIdentity(path);
    if (!seen.add(identity)) continue;
    final pathExists = existing.contains(identity);
    result.add(
      AddProjectPathOption(
        id: parent,
        path: parent,
        displayPath: path,
        secondaryText: pathExists
            ? 'Already exists'
            : 'Parent directory: $parent',
        disabled: pathExists,
      ),
    );
  }
  return result;
}

String _pathIdentity(String path) {
  final normalized = _shortenPath(
    path.trim(),
  ).replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  return RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
          normalized.startsWith('//')
      ? normalized.toLowerCase()
      : normalized;
}

String _shortenPath(String path) =>
    path.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+'), '~');
