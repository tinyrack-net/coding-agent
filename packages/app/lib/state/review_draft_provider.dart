import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'working_diff_provider.dart';

const reviewAttachmentContextRadius = 3;

final class ReviewDraftComment {
  const ReviewDraftComment({
    required this.id,
    required this.filePath,
    required this.side,
    required this.lineNumber,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String filePath;
  final ReviewAttachmentSide side;
  final int lineNumber;
  final String body;
  final String createdAt;
  final String updatedAt;

  static ReviewDraftComment? tryFromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['filePath'] is! String ||
        value['side'] is! String ||
        value['lineNumber'] is! int ||
        (value['lineNumber']! as int) <= 0 ||
        value['body'] is! String ||
        value['createdAt'] is! String ||
        value['updatedAt'] is! String) {
      return null;
    }
    final side = switch (value['side']) {
      'old' => ReviewAttachmentSide.old,
      'new' => ReviewAttachmentSide.newLine,
      _ => null,
    };
    if (side == null) return null;
    return ReviewDraftComment(
      id: value['id']! as String,
      filePath: value['filePath']! as String,
      side: side,
      lineNumber: value['lineNumber']! as int,
      body: value['body']! as String,
      createdAt: value['createdAt']! as String,
      updatedAt: value['updatedAt']! as String,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'filePath': filePath,
    'side': side == ReviewAttachmentSide.old ? 'old' : 'new',
    'lineNumber': lineNumber,
    'body': body,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

final class ReviewDraftState {
  const ReviewDraftState({this.drafts = const {}});

  final Map<String, List<ReviewDraftComment>> drafts;
}

abstract interface class ReviewDraftStorage {
  Future<String?> read();
  Future<void> write(String value);
}

final class SharedPreferencesReviewDraftStorage implements ReviewDraftStorage {
  const SharedPreferencesReviewDraftStorage();

  static const key = '@tinyrack:review-draft-store';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }
}

final reviewDraftStorageProvider = Provider<ReviewDraftStorage>(
  (_) => const SharedPreferencesReviewDraftStorage(),
);

final class ReviewDraftNotifier extends Notifier<ReviewDraftState> {
  int _revision = 0;
  Future<void> _writeQueue = Future.value();

  @override
  ReviewDraftState build() {
    unawaited(_hydrate());
    return const ReviewDraftState();
  }

  ReviewDraftComment add({
    required String key,
    required String filePath,
    required ReviewAttachmentSide side,
    required int lineNumber,
    required String body,
    String? id,
    String? createdAt,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty || lineNumber <= 0) {
      throw ArgumentError('Review comments require a positive line and body');
    }
    final timestamp = createdAt ?? DateTime.now().toUtc().toIso8601String();
    final comment = ReviewDraftComment(
      id: id ?? const Uuid().v4(),
      filePath: filePath,
      side: side,
      lineNumber: lineNumber,
      body: trimmed,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _replace(key, [...?state.drafts[key], comment]);
    return comment;
  }

  void updateComment({
    required String key,
    required String id,
    required String body,
    String? updatedAt,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    final current = state.drafts[key] ?? const [];
    if (!current.any((comment) => comment.id == id)) return;
    _replace(key, [
      for (final comment in current)
        if (comment.id == id)
          ReviewDraftComment(
            id: comment.id,
            filePath: comment.filePath,
            side: comment.side,
            lineNumber: comment.lineNumber,
            body: trimmed,
            createdAt: comment.createdAt,
            updatedAt: updatedAt ?? DateTime.now().toUtc().toIso8601String(),
          )
        else
          comment,
    ]);
  }

  void delete({required String key, required String id}) {
    final current = state.drafts[key] ?? const [];
    if (!current.any((comment) => comment.id == id)) return;
    _replace(
      key,
      current.where((comment) => comment.id != id).toList(growable: false),
    );
  }

  void clear(String key) {
    if (!state.drafts.containsKey(key)) return;
    _replace(key, const []);
  }

  void _replace(String key, List<ReviewDraftComment> comments) {
    _revision++;
    final next = Map<String, List<ReviewDraftComment>>.from(state.drafts);
    if (comments.isEmpty) {
      next.remove(key);
    } else {
      next[key] = List.unmodifiable(comments);
    }
    state = ReviewDraftState(drafts: Map.unmodifiable(next));
    _persist();
  }

  Future<void> _hydrate() async {
    final revisionAtStart = _revision;
    final encoded = await ref.read(reviewDraftStorageProvider).read();
    if (encoded == null || revisionAtStart != _revision) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return;
      final rawDrafts = decoded['drafts'];
      if (rawDrafts is! Map) return;
      final drafts = <String, List<ReviewDraftComment>>{};
      for (final entry in rawDrafts.entries) {
        if (entry.key is! String || entry.value is! List) continue;
        final comments = (entry.value! as List)
            .map(ReviewDraftComment.tryFromJson)
            .whereType<ReviewDraftComment>()
            .toList(growable: false);
        if (comments.isNotEmpty) drafts[entry.key! as String] = comments;
      }
      if (revisionAtStart == _revision) {
        state = ReviewDraftState(drafts: Map.unmodifiable(drafts));
      }
    } on FormatException {
      // Invalid persisted state normalizes to the empty store.
    }
  }

  void _persist() {
    final encoded = jsonEncode({
      'drafts': {
        for (final entry in state.drafts.entries)
          entry.key: [for (final comment in entry.value) comment.toJson()],
      },
    });
    _writeQueue = _writeQueue.then(
      (_) => ref.read(reviewDraftStorageProvider).write(encoded),
    );
  }
}

final reviewDraftProvider =
    NotifierProvider<ReviewDraftNotifier, ReviewDraftState>(
      ReviewDraftNotifier.new,
    );

String buildReviewDraftKey({
  required String serverId,
  required String cwd,
  String? workspaceId,
  String? baseRef,
  required bool ignoreWhitespace,
  required CheckoutDiffMode mode,
}) {
  final scope = buildWorkingDiffScopeKey(
    serverId: serverId,
    cwd: cwd,
    workspaceId: workspaceId,
    baseRef: baseRef,
    ignoreWhitespace: ignoreWhitespace,
  );
  final parts = scope.split(':');
  return [...parts.take(3), 'mode=${mode.name}', ...parts.skip(3)].join(':');
}

ReviewAgentAttachment? buildReviewAttachment({
  required String cwd,
  required CheckoutDiffMode mode,
  required String? baseRef,
  required List<ReviewDraftComment> comments,
  required DiffResponse diff,
}) {
  final attached = <ReviewAttachmentComment>[];
  for (final comment in comments) {
    final target = _findReviewTarget(comment, diff);
    if (target == null) continue;
    final start = (target.index - reviewAttachmentContextRadius)
        .clamp(0, target.hunk.lines.length)
        .toInt();
    final end = (target.index + reviewAttachmentContextRadius + 1)
        .clamp(0, target.hunk.lines.length)
        .toInt();
    attached.add(
      ReviewAttachmentComment(
        filePath: comment.filePath,
        side: comment.side,
        lineNumber: comment.lineNumber,
        body: comment.body,
        context: ReviewAttachmentContext(
          hunkHeader: target.hunk.header,
          targetLine: _contextLine(target.line),
          lines: [
            for (final line in target.hunk.lines.sublist(start, end))
              _contextLine(line),
          ],
        ),
      ),
    );
  }
  if (attached.isEmpty) return null;
  return ReviewAgentAttachment(
    cwd: cwd,
    mode: mode == CheckoutDiffMode.base
        ? ReviewAttachmentMode.base
        : ReviewAttachmentMode.uncommitted,
    baseRef: switch (baseRef?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => null,
    },
    comments: List.unmodifiable(attached),
  );
}

({DiffHunk hunk, DiffLine line, int index})? _findReviewTarget(
  ReviewDraftComment comment,
  DiffResponse diff,
) {
  for (final file in diff.files) {
    if (file.path != comment.filePath) continue;
    for (final hunk in file.hunks) {
      for (var index = 0; index < hunk.lines.length; index++) {
        final line = hunk.lines[index];
        final lineNumber = comment.side == ReviewAttachmentSide.old
            ? line.oldLineNo
            : line.newLineNo;
        if (lineNumber == comment.lineNumber) {
          return (hunk: hunk, line: line, index: index);
        }
      }
    }
  }
  return null;
}

ReviewAttachmentContextLine _contextLine(DiffLine line) =>
    ReviewAttachmentContextLine(
      oldLineNumber: line.oldLineNo,
      newLineNumber: line.newLineNo,
      type: switch (line.type) {
        DiffLineType.add => ReviewAttachmentLineType.add,
        DiffLineType.del => ReviewAttachmentLineType.remove,
        DiffLineType.context => ReviewAttachmentLineType.context,
      },
      content: line.text,
    );
