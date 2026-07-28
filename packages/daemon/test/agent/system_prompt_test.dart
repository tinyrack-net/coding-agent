import 'package:agent_daemon/src/agent/system_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('trims and joins non-empty prompt parts with one blank line', () {
    expect(
      composeSystemPromptParts([
        '  Agent instructions.  ',
        null,
        '',
        ' \n ',
        'Daemon instructions.',
      ]),
      'Agent instructions.\n\nDaemon instructions.',
    );
  });

  test('returns null when every prompt part is absent or blank', () {
    expect(composeSystemPromptParts(const []), isNull);
    expect(composeSystemPromptParts(const [null, '', ' \n\t ']), isNull);
  });
}
