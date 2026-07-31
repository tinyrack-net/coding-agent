import 'workspace_file_drag.dart';

/// Minimal HTML5 DataTransfer surface used by Paseo workspace-file drags.
///
/// Keeping the DOM object behind this interface makes the trust boundary
/// testable on every Flutter platform while the web implementation delegates
/// to the browser's real `DataTransfer`.
abstract interface class WorkspaceFileDataTransfer {
  Iterable<String> get types;

  String get effectAllowed;
  set effectAllowed(String value);

  String get dropEffect;
  set dropEffect(String value);

  String getData(String format);
  void setData(String format, String data);
}

bool hasWorkspaceFileDragData(WorkspaceFileDataTransfer dataTransfer) =>
    dataTransfer.types.contains(workspaceFileDragMime);

void writeWorkspaceFileDragData({
  required WorkspaceFileDataTransfer dataTransfer,
  required WorkspaceFileDragPayload payload,
}) {
  dataTransfer.effectAllowed = 'copy';
  dataTransfer.setData(
    workspaceFileDragMime,
    serializeWorkspaceFileDragPayload(payload),
  );
}

WorkspaceFileDragPayload? readWorkspaceFileDragData(
  WorkspaceFileDataTransfer dataTransfer,
) {
  if (!hasWorkspaceFileDragData(dataTransfer)) return null;
  final serialized = dataTransfer.getData(workspaceFileDragMime);
  if (serialized.isEmpty) return null;
  return parseWorkspaceFileDragPayload(serialized);
}

/// Mirrors Paseo's drag-over cursor contract for a workspace-file sink.
///
/// A browser must only advertise a copy when both the custom MIME is present
/// and the active sink can accept it. Otherwise the cursor advertises `none`.
void updateWorkspaceFileDropEffect({
  required WorkspaceFileDataTransfer dataTransfer,
  required bool canAccept,
}) {
  dataTransfer.dropEffect = canAccept && hasWorkspaceFileDragData(dataTransfer)
      ? 'copy'
      : 'none';
}
