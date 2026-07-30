import 'package:agent_protocol/agent_protocol.dart';

/// Renders semantic prompt attachments using Paseo's provider-facing format.
String renderPromptAttachmentAsText(AgentAttachment attachment) =>
    switch (attachment) {
      TextAgentAttachment(:final text) => text,
      ReviewAgentAttachment() => _renderReviewAttachment(attachment),
    };

bool isChatHistoryAttachment(AgentAttachment attachment) =>
    attachment is TextAgentAttachment &&
    attachment.contextKind == 'chat_history';

String _renderReviewAttachment(ReviewAgentAttachment attachment) {
  final lines = <String>[
    'Paseo review attachment (${attachment.mode.name})',
    'CWD: ${attachment.cwd}',
    if (attachment.baseRef case final baseRef?) 'Base: $baseRef',
  ];
  for (var index = 0; index < attachment.comments.length; index++) {
    final comment = attachment.comments[index];
    lines.addAll([
      '',
      'Comment ${index + 1}: ${comment.filePath}:'
          '${comment.side == ReviewAttachmentSide.old ? 'old' : 'new'}:'
          '${comment.lineNumber}',
      comment.body,
      comment.context.hunkHeader,
    ]);
    final target = comment.context.targetLine;
    for (final line in comment.context.lines) {
      final isTarget =
          line.oldLineNumber == target.oldLineNumber &&
          line.newLineNumber == target.newLineNumber &&
          line.type == target.type &&
          line.content == target.content;
      final oldLine = _padLineNumber(line.oldLineNumber);
      final newLine = _padLineNumber(line.newLineNumber);
      final marker = switch (line.type) {
        ReviewAttachmentLineType.add => '+',
        ReviewAttachmentLineType.remove => '-',
        ReviewAttachmentLineType.context => ' ',
      };
      lines.add(
        '${isTarget ? '> ' : '  '}$oldLine $newLine '
        '$marker${line.content}',
      );
    }
  }
  return lines.join('\n');
}

String _padLineNumber(int? lineNumber) =>
    (lineNumber?.toString() ?? '-').padLeft(2);
