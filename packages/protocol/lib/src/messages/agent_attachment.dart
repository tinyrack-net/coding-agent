sealed class AgentAttachment {
  const AgentAttachment();

  String get type;

  Map<String, Object?> toJson();

  static AgentAttachment? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, Object?>.from(value);
    return switch (json['type']) {
      'text' => TextAgentAttachment.tryFromJson(json),
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
