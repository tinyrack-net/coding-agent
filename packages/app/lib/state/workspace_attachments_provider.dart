import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_store.dart';

final class WorkspaceContextAttachment {
  const WorkspaceContextAttachment({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.text,
    required this.url,
    this.screenshot,
    this.semanticAttachment,
    this.reviewDraftKey,
  });

  final String kind;
  final String id;
  final String title;
  final String subtitle;
  final String text;
  final String? url;
  final AttachmentMetadata? screenshot;
  final AgentAttachment? semanticAttachment;
  final String? reviewDraftKey;

  AgentAttachment toAgentAttachment() =>
      semanticAttachment ?? TextAgentAttachment(title: title, text: text);
}

class WorkspaceAttachmentsNotifier
    extends Notifier<List<WorkspaceContextAttachment>> {
  WorkspaceAttachmentsNotifier(this.cwd);

  final String cwd;

  @override
  List<WorkspaceContextAttachment> build() => const [];

  void add(WorkspaceContextAttachment attachment) {
    final existing = state
        .where(
          (current) =>
              current.kind == attachment.kind && current.id == attachment.id,
        )
        .firstOrNull;
    if (existing != null &&
        existing.title == attachment.title &&
        existing.subtitle == attachment.subtitle &&
        existing.text == attachment.text &&
        existing.url == attachment.url &&
        jsonEncode(existing.semanticAttachment?.toJson()) ==
            jsonEncode(attachment.semanticAttachment?.toJson())) {
      return;
    }
    state = [
      for (final current in state)
        if (current.kind != attachment.kind || current.id != attachment.id)
          current,
      attachment,
    ];
    _syncScreenshotOwners();
  }

  void remove(String kind, String id) {
    state = [
      for (final attachment in state)
        if (attachment.kind != kind || attachment.id != id) attachment,
    ];
    _syncScreenshotOwners();
  }

  void clear() {
    state = const [];
    _syncScreenshotOwners();
  }

  void _syncScreenshotOwners() {
    ref
        .read(workspaceScreenshotOwnersProvider.notifier)
        .replaceScope(cwd, state);
  }
}

final workspaceAttachmentsProvider =
    NotifierProvider.family<
      WorkspaceAttachmentsNotifier,
      List<WorkspaceContextAttachment>,
      String
    >(WorkspaceAttachmentsNotifier.new);

class WorkspaceScreenshotOwnersNotifier
    extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  void replaceScope(
    String scope,
    Iterable<WorkspaceContextAttachment> attachments,
  ) {
    final ids = {
      for (final attachment in attachments)
        if (attachment.kind == 'browser_element' &&
            attachment.screenshot != null)
          attachment.screenshot!.id,
    };
    final next = Map<String, Set<String>>.of(state);
    if (ids.isEmpty) {
      next.remove(scope);
    } else {
      next[scope] = Set.unmodifiable(ids);
    }
    state = Map.unmodifiable(next);
  }

  Set<String> attachmentIds() => {for (final ids in state.values) ...ids};
}

final workspaceScreenshotOwnersProvider =
    NotifierProvider<
      WorkspaceScreenshotOwnersNotifier,
      Map<String, Set<String>>
    >(WorkspaceScreenshotOwnersNotifier.new);
