import 'package:agent_protocol/agent_protocol.dart';

import 'prompt_attachments.dart';

/// Builds Paseo's untrusted metadata-generation seed for the first agent.
///
/// Prompt and attachments are fenced separately so the metadata agent treats
/// them only as source material, never as instructions to execute.
String? buildAgentBranchNameSeed(Map<String, Object?>? firstAgentContext) {
  if (firstAgentContext == null) return null;
  final parts = <String>[];
  final prompt = (firstAgentContext['prompt'] as String?)?.trim();
  if (prompt != null && prompt.isNotEmpty) {
    parts.add('<user-prompt>\n$prompt\n</user-prompt>');
  }
  final renderedAttachments =
      AgentAttachment.normalizeList(firstAgentContext['attachments'])
          .map((attachment) => renderPromptAttachmentAsText(attachment).trim())
          .where((value) => value.isNotEmpty)
          .toList();
  if (renderedAttachments.isNotEmpty) {
    parts.add(
      '<attachments>\n${renderedAttachments.join('\n\n')}\n</attachments>',
    );
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}
