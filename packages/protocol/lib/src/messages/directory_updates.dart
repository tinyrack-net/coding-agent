/// Frozen Paseo 0.2.0 directory update messages.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent.dart';
import 'workspace_v2.dart';

sealed class DirectoryUpdateEvent {
  const DirectoryUpdateEvent();

  factory DirectoryUpdateEvent.fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      'agent_update' => _decodeAgentUpdate(json),
      'agent_deleted' => AgentDeletedDirectoryEvent(
        agentId: _requiredString(_requiredMap(json, 'payload'), 'agentId'),
        requestId: _requiredString(_requiredMap(json, 'payload'), 'requestId'),
      ),
      'agent_archived' => AgentArchivedDirectoryEvent(
        agentId: _requiredString(_requiredMap(json, 'payload'), 'agentId'),
        archivedAt: _requiredString(
          _requiredMap(json, 'payload'),
          'archivedAt',
        ),
        requestId: _requiredString(_requiredMap(json, 'payload'), 'requestId'),
      ),
      'workspace_update' => WorkspaceDirectoryEvent(
        WorkspaceUpdate.fromJson(json),
      ),
      'project.update' => ProjectDirectoryEvent(ProjectUpdate.fromJson(json)),
      final type => throw FormatException('Unknown directory update: $type'),
    };
  }
}

final class AgentUpsertDirectoryEvent extends DirectoryUpdateEvent {
  const AgentUpsertDirectoryEvent({required this.agent, this.project});

  final AgentSummary agent;
  final Map<String, Object?>? project;
}

final class AgentRemoveDirectoryEvent extends DirectoryUpdateEvent {
  const AgentRemoveDirectoryEvent(this.agentId);

  final String agentId;
}

final class AgentDeletedDirectoryEvent extends DirectoryUpdateEvent {
  const AgentDeletedDirectoryEvent({
    required this.agentId,
    required this.requestId,
  });

  final String agentId;
  final String requestId;
}

final class AgentArchivedDirectoryEvent extends DirectoryUpdateEvent {
  const AgentArchivedDirectoryEvent({
    required this.agentId,
    required this.archivedAt,
    required this.requestId,
  });

  final String agentId;
  final String archivedAt;
  final String requestId;
}

final class WorkspaceDirectoryEvent extends DirectoryUpdateEvent {
  const WorkspaceDirectoryEvent(this.update);

  final WorkspaceUpdate update;
}

final class ProjectDirectoryEvent extends DirectoryUpdateEvent {
  const ProjectDirectoryEvent(this.update);

  final ProjectUpdate update;
}

DirectoryUpdateEvent _decodeAgentUpdate(Map<String, Object?> json) {
  final payload = _requiredMap(json, 'payload');
  return switch (payload['kind']) {
    'upsert' => AgentUpsertDirectoryEvent(
      agent: PaseoAgentSnapshotCodec.decode(_requiredMap(payload, 'agent')),
      project: payload['project'] == null
          ? null
          : Map<String, Object?>.unmodifiable(_requiredMap(payload, 'project')),
    ),
    'remove' => AgentRemoveDirectoryEvent(_requiredString(payload, 'agentId')),
    final kind => throw FormatException('Unknown agent update: $kind'),
  };
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$key must be an object');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}
