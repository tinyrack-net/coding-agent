import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('text attachment round-trips the frozen Paseo wire shape', () {
    const attachment = TextAgentAttachment(
      title: 'Review comment',
      text: 'Please fix this.',
      contextKind: 'chat_history',
    );

    expect(attachment.toJson(), {
      'type': 'text',
      'mimeType': 'text/plain',
      'title': 'Review comment',
      'contextKind': 'chat_history',
      'text': 'Please fix this.',
    });
    final decoded = AgentAttachment.tryFromJson(attachment.toJson());
    expect(decoded, isA<TextAgentAttachment>());
    expect((decoded! as TextAgentAttachment).text, 'Please fix this.');
  });

  test('normalization drops malformed and unknown attachments', () {
    final attachments = AgentAttachment.normalizeList([
      {
        'type': 'text',
        'mimeType': 'text/plain',
        'title': null,
        'text': 'valid',
      },
      {'type': 'text', 'mimeType': 'text/html', 'text': 'invalid'},
      {'type': 'future_type', 'value': true},
      'invalid',
    ]);

    expect(attachments, hasLength(1));
    expect((attachments.single as TextAgentAttachment).text, 'valid');
  });

  test('prompt images round-trip the frozen send-message wire shape', () {
    const image = AgentPromptImage(
      data: 'base64-payload',
      mimeType: 'image/png',
    );

    expect(image.toJson(), {'data': 'base64-payload', 'mimeType': 'image/png'});
    expect(AgentPromptImage.normalizeList([image.toJson(), 'invalid']), [
      isA<AgentPromptImage>()
          .having((value) => value.data, 'data', 'base64-payload')
          .having((value) => value.mimeType, 'mimeType', 'image/png'),
    ]);
  });
}
