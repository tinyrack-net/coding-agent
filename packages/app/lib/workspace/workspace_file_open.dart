import '../core/path.dart';
import 'workspace_pane_layout.dart';

enum OpenFileDisposition { main, side }

enum WorkspaceSideFileOpenPlacementKind {
  openInSource,
  focusSidePane,
  splitSidePane,
}

final class WorkspaceSideFileOpenPlacement {
  const WorkspaceSideFileOpenPlacement(this.kind, {this.paneId});

  final WorkspaceSideFileOpenPlacementKind kind;
  final String? paneId;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceSideFileOpenPlacement &&
      other.kind == kind &&
      other.paneId == paneId;

  @override
  int get hashCode => Object.hash(kind, paneId);
}

final class WorkspaceFileLocation {
  const WorkspaceFileLocation({
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  final String path;
  final int? lineStart;
  final int? lineEnd;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceFileLocation &&
      other.path == path &&
      other.lineStart == lineStart &&
      other.lineEnd == lineEnd;

  @override
  int get hashCode => Object.hash(path, lineStart, lineEnd);
}

final class WorkspaceFileOpenRequest {
  const WorkspaceFileOpenRequest({
    required this.location,
    required this.disposition,
  });

  final WorkspaceFileLocation location;
  final OpenFileDisposition disposition;
}

WorkspaceSideFileOpenPlacement resolveWorkspaceSideFileOpenPlacement({
  required WorkspacePaneLayout? layout,
  required String? sourcePaneId,
  required bool targetAlreadyOpen,
}) {
  if (targetAlreadyOpen || layout == null || sourcePaneId == null) {
    return const WorkspaceSideFileOpenPlacement(
      WorkspaceSideFileOpenPlacementKind.openInSource,
    );
  }
  final normalizedSourcePaneId = sourcePaneId.trim();
  if (normalizedSourcePaneId.isEmpty ||
      findWorkspacePane(layout.root, normalizedSourcePaneId) == null) {
    return const WorkspaceSideFileOpenPlacement(
      WorkspaceSideFileOpenPlacementKind.openInSource,
    );
  }
  final sidePaneId = findAdjacentWorkspacePane(
    layout.root,
    normalizedSourcePaneId,
    WorkspacePaneDirection.right,
  );
  if (sidePaneId != null) {
    return WorkspaceSideFileOpenPlacement(
      WorkspaceSideFileOpenPlacementKind.focusSidePane,
      paneId: sidePaneId,
    );
  }
  return WorkspaceSideFileOpenPlacement(
    WorkspaceSideFileOpenPlacementKind.splitSidePane,
    paneId: normalizedSourcePaneId,
  );
}

WorkspaceFileLocation? normalizeWorkspaceFileLocation(
  WorkspaceFileLocation? location,
) {
  if (location == null) return null;
  final path = location.path.trim().replaceAll(r'\', '/');
  if (path.isEmpty) return null;
  final lineStart = _normalizeLineNumber(location.lineStart);
  final lineEnd = _normalizeLineNumber(location.lineEnd);
  return WorkspaceFileLocation(
    path: path,
    lineStart: lineStart,
    lineEnd: lineStart != null && lineEnd != null && lineEnd >= lineStart
        ? lineEnd
        : null,
  );
}

ResolvedWorkspaceFilePaths? resolveWorkspaceFilePaths({
  required String path,
  required String workspaceRoot,
}) {
  final filePath = path.trim().replaceAll(r'\', '/');
  final root = _normalizeAbsolutePath(
    workspaceRoot.trim().replaceAll(r'\', '/'),
  );
  if (filePath.isEmpty || root == null) return null;

  if (isAbsolutePath(filePath)) {
    final normalizedFile = _normalizeAbsolutePath(filePath);
    if (normalizedFile == null || _pathsEqual(normalizedFile, root)) {
      return null;
    }
    final prefix = '$root/';
    final relativePath = _startsWithPath(normalizedFile, prefix)
        ? normalizedFile.substring(prefix.length)
        : null;
    return ResolvedWorkspaceFilePaths(
      absolutePath: normalizedFile,
      relativePath: relativePath,
    );
  }

  if (filePath == '~' || filePath.startsWith('~/')) return null;
  final relativePath = _normalizePathSegments(filePath, rejectEscape: true);
  if (relativePath == null || relativePath.isEmpty) return null;
  return ResolvedWorkspaceFilePaths(
    absolutePath: '$root/$relativePath',
    relativePath: relativePath,
  );
}

final class ResolvedWorkspaceFilePaths {
  const ResolvedWorkspaceFilePaths({
    required this.absolutePath,
    required this.relativePath,
  });

  final String absolutePath;
  final String? relativePath;
}

int? _normalizeLineNumber(int? value) =>
    value != null && value > 0 ? value : null;

String _trimTrailingSlashes(String value) {
  if (RegExp(r'^/+$').hasMatch(value)) return '/';
  if (RegExp(r'^[A-Za-z]:/+$').hasMatch(value)) {
    return '${value.substring(0, 2)}/';
  }
  return value.replaceFirst(RegExp(r'/+$'), '');
}

String? _normalizeAbsolutePath(String value) {
  final input = _trimTrailingSlashes(value);
  if (!isAbsolutePath(input)) return null;
  final drive = RegExp(r'^([A-Za-z]:)/(.*)$').firstMatch(input);
  if (drive != null) {
    final body = _normalizePathSegments(drive.group(2)!, rejectEscape: false);
    return _trimTrailingSlashes('${drive.group(1)}/$body');
  }
  final prefix = input.startsWith('//') ? '//' : '/';
  final body = _normalizePathSegments(
    input.replaceFirst(RegExp(r'^/+'), ''),
    rejectEscape: false,
  );
  return _trimTrailingSlashes('$prefix$body');
}

String? _normalizePathSegments(String value, {required bool rejectEscape}) {
  final segments = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) {
        if (rejectEscape) return null;
        continue;
      }
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

bool _isWindowsPath(String value) => RegExp(r'^[A-Za-z]:/').hasMatch(value);

bool _pathsEqual(String left, String right) =>
    _isWindowsPath(left) || _isWindowsPath(right)
    ? left.toLowerCase() == right.toLowerCase()
    : left == right;

bool _startsWithPath(String value, String prefix) =>
    _isWindowsPath(value) || _isWindowsPath(prefix)
    ? value.toLowerCase().startsWith(prefix.toLowerCase())
    : value.startsWith(prefix);
