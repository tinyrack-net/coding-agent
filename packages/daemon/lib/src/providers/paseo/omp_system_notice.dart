import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:crypto/crypto.dart';

const ompSystemNoticeOpenTag = '<system-notice>';
const ompSystemNoticeCloseTag = '</system-notice>';

final _taskResultPattern = RegExp(
  r'<task-result\b([^>]*)>',
  caseSensitive: false,
);
final _attributePattern = RegExp(r'''([\w-]+)=["'“‘]([^"'“”‘’]*)["'”’]''');

final class OmpSystemNotice {
  const OmpSystemNotice({
    required this.callId,
    required this.status,
    required this.label,
    required this.text,
    required this.errorMessage,
    required this.metadata,
  });

  final String callId;
  final ToolCallStatus status;
  final String label;
  final String text;
  final String? errorMessage;
  final Map<String, Object?> metadata;
}

OmpSystemNotice? parseOmpSystemNotice(String text) {
  if (!text.trimLeft().startsWith(ompSystemNoticeOpenTag)) return null;

  final attributes = <String, String>{};
  final taskResult = _taskResultPattern.firstMatch(text);
  if (taskResult?.group(1) case final source?) {
    for (final match in _attributePattern.allMatches(source)) {
      final name = match.group(1);
      final value = match.group(2);
      if (name != null && value != null) attributes[name] = value.trim();
    }
  }

  final taskId = _nonEmpty(attributes['id']);
  final taskStatus = _nonEmpty(attributes['status']);
  final normalizedStatus = taskStatus?.toLowerCase();
  final label = taskId == null
      ? (_noticeFirstLine(text) ?? 'System notice')
      : 'Background job $taskId ${taskStatus ?? 'completed'}';
  final status = switch (normalizedStatus) {
    'failed' || 'error' => ToolCallStatus.error,
    'canceled' || 'cancelled' || 'stopped' => ToolCallStatus.canceled,
    _ => ToolCallStatus.success,
  };
  final digest = sha1
      .convert(utf8.encode(text.trim()))
      .toString()
      .substring(0, 12);

  return OmpSystemNotice(
    callId: 'omp-notice:${taskId ?? digest}',
    status: status,
    label: label,
    text: text,
    errorMessage: status == ToolCallStatus.error ? label : null,
    metadata: Map.unmodifiable({
      'synthetic': true,
      'source': 'omp_system_notice',
      if (taskId != null) 'taskId': taskId,
      if (_nonEmpty(attributes['agent']) case final agent?)
        'subagentType': agent,
      if (taskStatus != null) 'status': taskStatus,
    }),
  );
}

String? _noticeFirstLine(String text) {
  final openIndex = text.indexOf(ompSystemNoticeOpenTag);
  final closeIndex = text.indexOf(ompSystemNoticeCloseTag);
  final body = text.substring(
    openIndex + ompSystemNoticeOpenTag.length,
    closeIndex == -1 ? null : closeIndex,
  );
  for (final line in const LineSplitter().convert(body)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('<')) return trimmed;
  }
  return null;
}

String? _nonEmpty(String? value) =>
    value?.trim().isNotEmpty == true ? value!.trim() : null;
