import 'dart:convert';

import '../composer/composer_draft_store.dart';

/// Paseo's web drag contract. Keep the MIME stable so a daemon-served Flutter
/// web client can exchange payloads with the frozen Paseo 0.2.0 client.
const workspaceFileDragMime = 'application/x-paseo-workspace-file+json';

final class WorkspaceFileDragPayload {
  const WorkspaceFileDragPayload({
    required this.serverId,
    required this.workspaceId,
    required this.attachment,
  });

  static const version = 1;

  final String serverId;
  final String workspaceId;
  final ComposerWorkspaceFileAttachment attachment;

  Map<String, Object?> toJson() => {
    'version': version,
    'serverId': serverId,
    'workspaceId': workspaceId,
    'attachment': {'kind': 'workspace_file', ...attachment.toJson()},
  };

  @override
  bool operator ==(Object other) =>
      other is WorkspaceFileDragPayload &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId &&
      other.attachment == attachment;

  @override
  int get hashCode => Object.hash(serverId, workspaceId, attachment);
}

String serializeWorkspaceFileDragPayload(WorkspaceFileDragPayload payload) =>
    jsonEncode(payload.toJson());

/// Parses the untrusted cross-widget/web drag boundary.
///
/// Invalid payloads are ignored instead of surfacing an error to the
/// composer, matching Paseo's drop listener.
WorkspaceFileDragPayload? parseWorkspaceFileDragPayload(String serialized) {
  final Object? decoded;
  try {
    decoded = jsonDecode(serialized);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final record = decoded.cast<Object?, Object?>();
  final serverId = record['serverId'];
  final workspaceId = record['workspaceId'];
  final rawAttachment = record['attachment'];
  if (record['version'] != WorkspaceFileDragPayload.version ||
      serverId is! String ||
      serverId.isEmpty ||
      workspaceId is! String ||
      workspaceId.isEmpty ||
      rawAttachment is! Map) {
    return null;
  }

  final attachment = rawAttachment.cast<Object?, Object?>();
  final path = attachment['path'];
  final selection = attachment['selection'];
  if (attachment['kind'] != 'workspace_file' ||
      path is! String ||
      path.trim().isEmpty ||
      !_isValidSelection(selection)) {
    return null;
  }

  try {
    return WorkspaceFileDragPayload(
      serverId: serverId,
      workspaceId: workspaceId,
      attachment: ComposerWorkspaceFileAttachment.fromJson(
        attachment.cast<String, Object?>(),
      ),
    );
  } catch (_) {
    return null;
  }
}

ComposerWorkspaceFileAttachment? resolveWorkspaceFileDrop({
  required WorkspaceFileDragPayload payload,
  required String serverId,
  required String workspaceId,
}) {
  if (payload.serverId != serverId || payload.workspaceId != workspaceId) {
    return null;
  }
  return payload.attachment;
}

bool _isValidSelection(Object? value) {
  if (value is! Map) return false;
  final selection = value.cast<Object?, Object?>();
  if (selection['kind'] == 'whole_file') return true;
  final startLine = selection['startLine'];
  final endLine = selection['endLine'];
  return selection['kind'] == 'line_range' &&
      startLine is int &&
      endLine is int &&
      startLine > 0 &&
      endLine >= startLine;
}
