import 'package:agent_daemon/src/agent/create_agent_title.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('derives a provisional title from the first prompt content line', () {
    final resolved = resolveCreateAgentTitles(
      initialPrompt:
          '\n  Implement   auth retries with backoff  \r\n\r\ninclude tests',
    );

    expect(resolved.explicitTitle, isNull);
    expect(resolved.provisionalTitle, 'Implement auth retries with backoff');
  });

  test('preserves a trimmed explicit title over the prompt', () {
    final resolved = resolveCreateAgentTitles(
      configTitle: '  Keep This Title  ',
      initialPrompt: 'Ignored prompt title',
    );

    expect(resolved.explicitTitle, 'Keep This Title');
    expect(resolved.provisionalTitle, 'Keep This Title');
  });

  test('returns null values for empty title and prompt', () {
    final resolved = resolveCreateAgentTitles(
      configTitle: '   ',
      initialPrompt: ' \r\n\t ',
    );

    expect(resolved.explicitTitle, isNull);
    expect(resolved.provisionalTitle, isNull);
  });

  test('clamps provisional titles without an ellipsis', () {
    final longTitle = List.filled(maxInitialAgentTitleChars + 10, 'x').join();
    final title = resolveCreateAgentTitles(
      initialPrompt: longTitle,
    ).provisionalTitle;

    expect(maxExplicitAgentTitleChars, 200);
    expect(title, List.filled(60, 'x').join());
  });

  test('resolves a first-agent context prompt defensively', () {
    expect(
      resolveFirstAgentPromptTitle(const {'prompt': '  Fix startup\nlater  '}),
      'Fix startup',
    );
    expect(resolveFirstAgentPromptTitle(const {'prompt': 1}), isNull);
    expect(resolveFirstAgentPromptTitle(null), isNull);
  });
}
