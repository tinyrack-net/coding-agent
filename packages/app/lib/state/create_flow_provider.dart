import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_store.dart';

enum CreateFlowLifecycle { active, abandoned, sent }

class PendingCreateAttempt {
  const PendingCreateAttempt({
    required this.draftId,
    required this.serverId,
    required this.workspaceId,
    required this.agentId,
    required this.clientMessageId,
    required this.text,
    required this.timestamp,
    required this.lifecycle,
    this.images = const [],
    this.attachments = const [],
  });

  final String draftId;
  final String serverId;
  final String? workspaceId;
  final String? agentId;
  final String clientMessageId;
  final String text;
  final int timestamp;
  final CreateFlowLifecycle lifecycle;
  final List<AttachmentMetadata> images;
  final List<AgentAttachment> attachments;

  PendingCreateAttempt copyWith({
    String? draftId,
    String? agentId,
    CreateFlowLifecycle? lifecycle,
  }) => PendingCreateAttempt(
    draftId: draftId ?? this.draftId,
    serverId: serverId,
    workspaceId: workspaceId,
    agentId: agentId ?? this.agentId,
    clientMessageId: clientMessageId,
    text: text,
    timestamp: timestamp,
    lifecycle: lifecycle ?? this.lifecycle,
    images: images,
    attachments: attachments,
  );
}

bool isActiveCreateFlowForDraft({
  required PendingCreateAttempt? pending,
  required String serverId,
  required String? draftId,
}) {
  final normalizedDraftId = draftId?.trim();
  return normalizedDraftId != null &&
      normalizedDraftId.isNotEmpty &&
      pending?.draftId == normalizedDraftId &&
      pending?.serverId == serverId &&
      pending?.lifecycle == CreateFlowLifecycle.active;
}

class CreateFlowNotifier extends Notifier<Map<String, PendingCreateAttempt>> {
  @override
  Map<String, PendingCreateAttempt> build() => const {};

  void setPending(PendingCreateAttempt pending) {
    state = {
      ...state,
      pending.draftId: pending.copyWith(lifecycle: CreateFlowLifecycle.active),
    };
  }

  void updateAgentId({required String draftId, required String agentId}) {
    final current = state[draftId];
    if (current == null || current.agentId == agentId) return;
    state = {...state, draftId: current.copyWith(agentId: agentId)};
  }

  void markLifecycle({
    required String draftId,
    required CreateFlowLifecycle lifecycle,
  }) {
    final current = state[draftId];
    if (current == null || current.lifecycle == lifecycle) return;
    state = {...state, draftId: current.copyWith(lifecycle: lifecycle)};
  }

  void rekeyDraft({required String fromDraftId, required String toDraftId}) {
    final current = state[fromDraftId];
    if (current == null || fromDraftId == toDraftId) return;
    final next = Map<String, PendingCreateAttempt>.of(state)
      ..remove(fromDraftId)
      ..[toDraftId] = current.copyWith(draftId: toDraftId);
    state = Map.unmodifiable(next);
  }

  void clear(String draftId) {
    if (!state.containsKey(draftId)) return;
    final next = Map<String, PendingCreateAttempt>.of(state)..remove(draftId);
    state = Map.unmodifiable(next);
  }

  void clearByAgent({required String serverId, required String agentId}) {
    final next = Map<String, PendingCreateAttempt>.of(state)
      ..removeWhere(
        (_, pending) =>
            pending.serverId == serverId && pending.agentId == agentId,
      );
    if (next.length == state.length) return;
    state = Map.unmodifiable(next);
  }

  void clearAll() => state = const {};

  Set<String> activeAttachmentIds() => {
    for (final pending in state.values)
      if (pending.lifecycle == CreateFlowLifecycle.active)
        for (final image in pending.images) image.id,
  };
}

final createFlowProvider =
    NotifierProvider<CreateFlowNotifier, Map<String, PendingCreateAttempt>>(
      CreateFlowNotifier.new,
    );

class PendingWorkspaceDraftSubmission {
  const PendingWorkspaceDraftSubmission({
    required this.serverId,
    required this.workspaceId,
    required this.workspaceDirectory,
    required this.draftId,
    required this.text,
    required this.images,
    required this.cwd,
    required this.provider,
    required this.model,
    required this.modeId,
    required this.clientMessageId,
    required this.timestamp,
    this.thinkingOptionId,
    this.featureValues = const {},
    this.attachments = const [],
    this.allowEmptyText = false,
  });

  final String serverId;
  final String workspaceId;
  final String workspaceDirectory;
  final String draftId;
  final String text;
  final List<AttachmentMetadata> images;
  final List<AgentAttachment> attachments;
  final String cwd;
  final String provider;
  final String model;
  final String modeId;
  final String? thinkingOptionId;
  final Map<String, Object?> featureValues;
  final String clientMessageId;
  final int timestamp;
  final bool allowEmptyText;
}

class WorkspaceDraftSubmissionNotifier
    extends Notifier<Map<String, PendingWorkspaceDraftSubmission>> {
  @override
  Map<String, PendingWorkspaceDraftSubmission> build() => const {};

  void setPending(PendingWorkspaceDraftSubmission submission) {
    state = {...state, submission.draftId: submission};
  }

  PendingWorkspaceDraftSubmission? consume({
    required String serverId,
    required String workspaceId,
    required String draftId,
  }) {
    final pending = state[draftId];
    if (pending == null ||
        pending.serverId != serverId ||
        pending.workspaceId != workspaceId ||
        pending.draftId != draftId) {
      return null;
    }
    final next = Map<String, PendingWorkspaceDraftSubmission>.of(state)
      ..remove(draftId);
    state = Map.unmodifiable(next);
    return pending;
  }

  void clear(String draftId) {
    if (!state.containsKey(draftId)) return;
    final next = Map<String, PendingWorkspaceDraftSubmission>.of(state)
      ..remove(draftId);
    state = Map.unmodifiable(next);
  }
}

final workspaceDraftSubmissionProvider =
    NotifierProvider<
      WorkspaceDraftSubmissionNotifier,
      Map<String, PendingWorkspaceDraftSubmission>
    >(WorkspaceDraftSubmissionNotifier.new);
