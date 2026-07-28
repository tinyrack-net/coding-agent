import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('matches the frozen Paseo 0.2.0 provider icon-name contract', () {
    expect(builtinProviderIconNames, const [
      'claude',
      'codex',
      'copilot',
      'kiro',
      'minimax',
      'omp',
      'opencode',
      'pi',
    ]);
    expect(acpProviderIconNames, const [
      'agoragentic-acp',
      'amp-acp',
      'auggie',
      'autohand',
      'cline',
      'codebuddy-code',
      'codewhale',
      'cortex-code',
      'corust-agent',
      'crow-cli',
      'cursor',
      'deepagents',
      'dimcode',
      'dirac',
      'factory-droid',
      'fast-agent',
      'gemini',
      'glm-acp-agent',
      'goose',
      'grok',
      'junie',
      'kilo',
      'kimi',
      'minion-code',
      'mistral-vibe',
      'nova',
      'poolside',
      'qoder',
      'qwen-code',
      'sigit',
      'stakpak',
      'traecli',
      'vtcode',
    ]);
    expect(terminalProfileIconNames, const ['agy']);
    expect(knownProviderIconNames, [
      ...builtinProviderIconNames,
      ...acpProviderIconNames,
      ...terminalProfileIconNames,
    ]);
    expect(knownProviderIconNames.toSet(), hasLength(42));
  });
}
