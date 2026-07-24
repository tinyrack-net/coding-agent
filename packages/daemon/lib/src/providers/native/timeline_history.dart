/// Reconstructs conversation history for a resumed [NativeSession].
///
/// Only user/assistant text is replayed — the display-layer `ToolCallDetail`
/// doesn't retain full tool-result content (e.g. `ReadDetail` has no file
/// body), so tool-call transcripts can't be faithfully rebuilt from the
/// persisted timeline. The model still sees what was asked and answered,
/// which is enough to continue coherently; any side effects of prior tool
/// calls are already reflected on disk regardless.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'llm_backend.dart';

List<LlmMessage> historyFromTimeline(List<TimelineItem> items) {
  final messages = <LlmMessage>[];
  for (final item in items) {
    switch (item) {
      case UserMessageItem(:final text):
        messages.add(LlmUserMessage(text));
      case AssistantMessageItem(:final text, :final complete):
        if (complete && text.isNotEmpty) {
          messages.add(LlmAssistantMessage(text: text));
        }
      default:
        break;
    }
  }
  return messages;
}
