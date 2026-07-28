import 'package:agent_daemon/src/agent/first_agent_context.dart';
import 'package:test/test.dart';

void main() {
  test('builds the frozen prompt and attachment seed', () {
    expect(
      buildAgentBranchNameSeed({
        'prompt': '  Fix the race  ',
        'attachments': [
          {
            'type': 'text',
            'mimeType': 'text/plain',
            'title': 'notes.txt',
            'text': '  first note  ',
          },
          {'type': 'text', 'mimeType': 'text/plain', 'text': '\nsecond note\n'},
        ],
      }),
      '<user-prompt>\nFix the race\n</user-prompt>\n\n'
      '<attachments>\nfirst note\n\nsecond note\n</attachments>',
    );
  });

  test('returns null when no semantic source material exists', () {
    expect(buildAgentBranchNameSeed(null), isNull);
    expect(buildAgentBranchNameSeed({'prompt': '  '}), isNull);
  });
}
