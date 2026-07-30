import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_store.dart';
import '../composer/composer_draft_store.dart';

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

WorkspaceContextAttachment workspaceFileContextAttachment(String path) {
  final attachment = ComposerWorkspaceFileAttachment(path: path);
  final title = attachment.path.split('/').last;
  return WorkspaceContextAttachment(
    kind: 'file',
    id: attachment.path,
    title: title,
    subtitle: attachment.path,
    text: 'Workspace file: ${attachment.path}',
    url: null,
    semanticAttachment: TextAgentAttachment(
      title: title,
      text: 'Workspace file: ${attachment.path}',
    ),
  );
}

List<WorkspaceContextAttachment> mergeWorkspaceContextAttachments(
  Iterable<WorkspaceContextAttachment> first,
  Iterable<WorkspaceContextAttachment> second,
) {
  final result = <WorkspaceContextAttachment>[];
  final indices = <String, int>{};
  for (final attachment in [...first, ...second]) {
    final key = '${attachment.kind}\u0000${attachment.id}';
    final existing = indices[key];
    if (existing == null) {
      indices[key] = result.length;
      result.add(attachment);
    } else {
      result[existing] = attachment;
    }
  }
  return List.unmodifiable(result);
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

class ComposerAttachmentFocusRequestNotifier extends Notifier<int> {
  ComposerAttachmentFocusRequestNotifier(this.draftKey);

  final String draftKey;

  @override
  int build() => 0;

  void request() => state += 1;
}

final composerAttachmentFocusRequestProvider =
    NotifierProvider.family<
      ComposerAttachmentFocusRequestNotifier,
      int,
      String
    >(ComposerAttachmentFocusRequestNotifier.new);

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
