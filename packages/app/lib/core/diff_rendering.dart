import 'tool_call_parsers.dart';

String formatDiffGutterText(int? lineNumber) =>
    lineNumber == null ? '\u00a0' : '$lineNumber';

String formatDiffContentText(String? content) =>
    content != null && content.isNotEmpty ? content : ' ';

bool hasVisibleDiffTokens(List<ToolDiffToken>? tokens) =>
    tokens?.any((token) => token.text.isNotEmpty) ?? false;
