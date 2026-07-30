sealed class AgentAttachment {
  const AgentAttachment();

  String get type;

  Map<String, Object?> toJson();

  static AgentAttachment? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, Object?>.from(value);
    return switch (json['type']) {
      'text' => TextAgentAttachment.tryFromJson(json),
      'review' => ReviewAgentAttachment.tryFromJson(json),
      _ => null,
    };
  }

  static List<AgentAttachment> normalizeList(Object? value) {
    if (value is! List) return const [];
    return value
        .map(AgentAttachment.tryFromJson)
        .whereType<AgentAttachment>()
        .toList(growable: false);
  }
}

enum ReviewAttachmentSide { old, newLine }

ReviewAttachmentSide? _reviewSideFromWire(Object? value) => switch (value) {
  'old' => ReviewAttachmentSide.old,
  'new' => ReviewAttachmentSide.newLine,
  _ => null,
};

String _reviewSideToWire(ReviewAttachmentSide side) => switch (side) {
  ReviewAttachmentSide.old => 'old',
  ReviewAttachmentSide.newLine => 'new',
};

enum ReviewAttachmentMode { uncommitted, base }

enum ReviewAttachmentLineType { add, remove, context }

final class ReviewAttachmentContextLine {
  const ReviewAttachmentContextLine({
    required this.oldLineNumber,
    required this.newLineNumber,
    required this.type,
    required this.content,
  });

  final int? oldLineNumber;
  final int? newLineNumber;
  final ReviewAttachmentLineType type;
  final String content;

  static ReviewAttachmentContextLine? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final oldLineNumber = _positiveIntOrNull(value['oldLineNumber']);
    final newLineNumber = _positiveIntOrNull(value['newLineNumber']);
    if ((value['oldLineNumber'] != null && oldLineNumber == null) ||
        (value['newLineNumber'] != null && newLineNumber == null) ||
        value['type'] is! String ||
        value['content'] is! String) {
      return null;
    }
    try {
      return ReviewAttachmentContextLine(
        oldLineNumber: oldLineNumber,
        newLineNumber: newLineNumber,
        type: ReviewAttachmentLineType.values.byName(value['type']! as String),
        content: value['content']! as String,
      );
    } on ArgumentError {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'oldLineNumber': oldLineNumber,
    'newLineNumber': newLineNumber,
    'type': type.name,
    'content': content,
  };
}

final class ReviewAttachmentContext {
  const ReviewAttachmentContext({
    required this.hunkHeader,
    required this.targetLine,
    required this.lines,
  });

  final String hunkHeader;
  final ReviewAttachmentContextLine targetLine;
  final List<ReviewAttachmentContextLine> lines;

  static ReviewAttachmentContext? tryFromJson(Object? value) {
    if (value is! Map || value['hunkHeader'] is! String) return null;
    final targetLine = ReviewAttachmentContextLine.tryFromJson(
      value['targetLine'],
    );
    final rawLines = value['lines'];
    if (targetLine == null || rawLines is! List) return null;
    final lines = rawLines
        .map(ReviewAttachmentContextLine.tryFromJson)
        .whereType<ReviewAttachmentContextLine>()
        .toList(growable: false);
    if (lines.length != rawLines.length) return null;
    return ReviewAttachmentContext(
      hunkHeader: value['hunkHeader']! as String,
      targetLine: targetLine,
      lines: lines,
    );
  }

  Map<String, Object?> toJson() => {
    'hunkHeader': hunkHeader,
    'targetLine': targetLine.toJson(),
    'lines': [for (final line in lines) line.toJson()],
  };
}

final class ReviewAttachmentComment {
  const ReviewAttachmentComment({
    required this.filePath,
    required this.side,
    required this.lineNumber,
    required this.body,
    required this.context,
  });

  final String filePath;
  final ReviewAttachmentSide side;
  final int lineNumber;
  final String body;
  final ReviewAttachmentContext context;

  static ReviewAttachmentComment? tryFromJson(Object? value) {
    if (value is! Map ||
        value['filePath'] is! String ||
        value['side'] is! String ||
        value['body'] is! String) {
      return null;
    }
    final lineNumber = _positiveIntOrNull(value['lineNumber']);
    final context = ReviewAttachmentContext.tryFromJson(value['context']);
    if (lineNumber == null || context == null) return null;
    final side = _reviewSideFromWire(value['side']);
    if (side == null) return null;
    return ReviewAttachmentComment(
      filePath: value['filePath']! as String,
      side: side,
      lineNumber: lineNumber,
      body: value['body']! as String,
      context: context,
    );
  }

  Map<String, Object?> toJson() => {
    'filePath': filePath,
    'side': _reviewSideToWire(side),
    'lineNumber': lineNumber,
    'body': body,
    'context': context.toJson(),
  };
}

final class ReviewAgentAttachment extends AgentAttachment {
  const ReviewAgentAttachment({
    required this.cwd,
    required this.mode,
    required this.comments,
    this.baseRef,
  });

  @override
  String get type => 'review';

  final String cwd;
  final ReviewAttachmentMode mode;
  final String? baseRef;
  final List<ReviewAttachmentComment> comments;

  static ReviewAgentAttachment? tryFromJson(Map<String, Object?> json) {
    if (json['mimeType'] != 'application/paseo-review' ||
        json['cwd'] is! String ||
        json['mode'] is! String) {
      return null;
    }
    final baseRef = json['baseRef'];
    final rawComments = json['comments'];
    if ((baseRef != null && baseRef is! String) || rawComments is! List) {
      return null;
    }
    final comments = rawComments
        .map(ReviewAttachmentComment.tryFromJson)
        .whereType<ReviewAttachmentComment>()
        .toList(growable: false);
    if (comments.length != rawComments.length) return null;
    try {
      return ReviewAgentAttachment(
        cwd: json['cwd']! as String,
        mode: ReviewAttachmentMode.values.byName(json['mode']! as String),
        baseRef: baseRef as String?,
        comments: comments,
      );
    } on ArgumentError {
      return null;
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': 'application/paseo-review',
    'cwd': cwd,
    'mode': mode.name,
    'baseRef': baseRef,
    'comments': [for (final comment in comments) comment.toJson()],
  };
}

/// Base64 image payload carried separately from semantic prompt attachments.
///
/// This matches Paseo's `ImageAttachmentSchema` used by send/create/resume
/// agent messages. Claude receives supported image MIME types as native
/// Anthropic image blocks.
final class AgentPromptImage {
  const AgentPromptImage({required this.data, required this.mimeType});

  final String data;
  final String mimeType;

  static AgentPromptImage? tryFromJson(Object? value) {
    if (value is! Map ||
        value['data'] is! String ||
        value['mimeType'] is! String) {
      return null;
    }
    return AgentPromptImage(
      data: value['data']! as String,
      mimeType: value['mimeType']! as String,
    );
  }

  static List<AgentPromptImage> normalizeList(Object? value) {
    if (value is! List) return const [];
    return value
        .map(AgentPromptImage.tryFromJson)
        .whereType<AgentPromptImage>()
        .toList(growable: false);
  }

  Map<String, Object?> toJson() => {'data': data, 'mimeType': mimeType};
}

final class TextAgentAttachment extends AgentAttachment {
  const TextAgentAttachment({required this.text, this.title, this.contextKind});

  @override
  String get type => 'text';

  final String text;
  final String? title;
  final String? contextKind;

  static TextAgentAttachment? tryFromJson(Map<String, Object?> json) {
    if (json['mimeType'] != 'text/plain' || json['text'] is! String) {
      return null;
    }
    final title = json['title'];
    final contextKind = json['contextKind'];
    if (title != null && title is! String) return null;
    if (contextKind != null && contextKind is! String) return null;
    return TextAgentAttachment(
      text: json['text']! as String,
      title: title as String?,
      contextKind: contextKind == 'chat_history' ? contextKind as String : null,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': 'text/plain',
    if (title != null) 'title': title,
    if (contextKind == 'chat_history') 'contextKind': contextKind,
    'text': text,
  };
}

int? _positiveIntOrNull(Object? value) =>
    value is int && value > 0 ? value : null;
