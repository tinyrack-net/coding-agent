import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../composer/composer_image_attachments.dart';
import 'workspace_attachments_provider.dart';

final class QueuedComposerMessage {
  QueuedComposerMessage({
    required this.id,
    required this.text,
    required List<PendingComposerImage> images,
    required List<WorkspaceContextAttachment> attachments,
  }) : images = List.unmodifiable(images),
       attachments = List.unmodifiable(attachments);

  final String id;
  final String text;
  final List<PendingComposerImage> images;
  final List<WorkspaceContextAttachment> attachments;

  Set<String> get attachmentIds => {
    for (final image in images)
      if (image.metadata case final metadata?) metadata.id,
    for (final attachment in attachments)
      if (attachment.kind == 'browser_element' && attachment.screenshot != null)
        attachment.screenshot!.id,
  };
}

class QueuedMessagesNotifier
    extends Notifier<Map<String, Map<String, List<QueuedComposerMessage>>>> {
  QueuedMessagesNotifier({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  @override
  Map<String, Map<String, List<QueuedComposerMessage>>> build() => const {};

  QueuedComposerMessage? enqueue({
    required String serverId,
    required String agentId,
    required String text,
    List<PendingComposerImage> images = const [],
    List<WorkspaceContextAttachment> attachments = const [],
    String? messageId,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty && attachments.isEmpty) return null;
    final message = QueuedComposerMessage(
      id: messageId ?? _uuid.v4(),
      text: trimmed,
      images: images,
      attachments: attachments,
    );
    final session = state[serverId] ?? const {};
    state = {
      ...state,
      serverId: {
        ...session,
        agentId: [...(session[agentId] ?? const []), message],
      },
    };
    return message;
  }

  QueuedComposerMessage? take({
    required String serverId,
    required String agentId,
    required String messageId,
  }) {
    final queue = state[serverId]?[agentId];
    if (queue == null) return null;
    QueuedComposerMessage? found;
    final nextQueue = <QueuedComposerMessage>[];
    for (final message in queue) {
      if (found == null && message.id == messageId) {
        found = message;
      } else {
        nextQueue.add(message);
      }
    }
    if (found == null) return null;
    _replaceAgentQueue(serverId, agentId, nextQueue);
    return found;
  }

  QueuedComposerMessage? takeFirst({
    required String serverId,
    required String agentId,
  }) {
    final queue = state[serverId]?[agentId];
    if (queue == null || queue.isEmpty) return null;
    final message = queue.first;
    _replaceAgentQueue(
      serverId,
      agentId,
      queue.skip(1).toList(growable: false),
    );
    return message;
  }

  void restoreFirst({
    required String serverId,
    required String agentId,
    required QueuedComposerMessage message,
  }) {
    final session = state[serverId] ?? const {};
    state = {
      ...state,
      serverId: {
        ...session,
        agentId: [message, ...(session[agentId] ?? const [])],
      },
    };
  }

  void clearAgent({required String serverId, required String agentId}) {
    if (state[serverId]?[agentId] == null) return;
    _replaceAgentQueue(serverId, agentId, const []);
  }

  Set<String> attachmentIds() => {
    for (final session in state.values)
      for (final queue in session.values)
        for (final message in queue) ...message.attachmentIds,
  };

  void _replaceAgentQueue(
    String serverId,
    String agentId,
    List<QueuedComposerMessage> queue,
  ) {
    final session = Map<String, List<QueuedComposerMessage>>.of(
      state[serverId] ?? const {},
    );
    if (queue.isEmpty) {
      session.remove(agentId);
    } else {
      session[agentId] = List.unmodifiable(queue);
    }
    final next = Map<String, Map<String, List<QueuedComposerMessage>>>.of(
      state,
    );
    if (session.isEmpty) {
      next.remove(serverId);
    } else {
      next[serverId] = Map.unmodifiable(session);
    }
    state = Map.unmodifiable(next);
  }
}

final queuedMessagesProvider =
    NotifierProvider<
      QueuedMessagesNotifier,
      Map<String, Map<String, List<QueuedComposerMessage>>>
    >(QueuedMessagesNotifier.new);
