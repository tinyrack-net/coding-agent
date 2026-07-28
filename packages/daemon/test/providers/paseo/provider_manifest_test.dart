import 'package:agent_daemon/src/providers/paseo/provider_manifest.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('matches the Paseo 0.2 built-in provider manifest', () {
    final definitions = PaseoProviderManifest.definitions;

    expect(definitions.map((entry) => entry.id), [
      'claude',
      'codex',
      'copilot',
      'opencode',
      'pi',
      'omp',
    ]);
    expect(definitions.map((entry) => entry.command), [
      'claude',
      'codex',
      'copilot',
      'opencode',
      'pi',
      'omp',
    ]);
    expect(PaseoProviderManifest.find('claude')?.defaultModeId, 'auto');
    expect(PaseoProviderManifest.find('codex')?.defaultModeId, 'auto-review');
    expect(PaseoProviderManifest.find('opencode')?.defaultModeId, isNull);
    expect(PaseoProviderManifest.find('pi')?.modes, isEmpty);
    expect(PaseoProviderManifest.find('omp')?.enabledByDefault, isFalse);
    expect(PaseoProviderManifest.find('missing'), isNull);
  });

  test('preserves mode ids, visuals, and unattended semantics', () {
    final claude = PaseoProviderManifest.find('claude')!;
    final codex = PaseoProviderManifest.find('codex')!;
    final copilot = PaseoProviderManifest.find('copilot')!;
    final opencode = PaseoProviderManifest.find('opencode')!;
    final omp = PaseoProviderManifest.find('omp')!;

    expect(claude.modes.map((entry) => entry.mode.id), [
      'plan',
      'default',
      'acceptEdits',
      'auto',
      'bypassPermissions',
    ]);
    expect(
      claude.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'bypassPermissions',
    );
    expect(
      codex.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'full-access',
    );
    expect(
      copilot.modes.singleWhere((entry) => entry.isUnattended).mode.id,
      'allow-all',
    );
    expect(opencode.modes.last.mode.colorTier, 'planning');
    expect(omp.modes.first.isUnattended, isTrue);
    expect(copilot.commandArgs, ['--acp']);
  });

  test('matches frozen provider capability differences', () {
    final claude = PaseoProviderManifest.find('claude')!;
    final codex = PaseoProviderManifest.find('codex')!;
    final openCode = PaseoProviderManifest.find('opencode')!;
    final pi = PaseoProviderManifest.find('pi')!;
    final omp = PaseoProviderManifest.find('omp')!;

    expect(claude.capabilities['supportsRewindBoth'], isTrue);
    expect(codex.capabilities['supportsDynamicModes'], isFalse);
    expect(codex.capabilities['supportsRewindConversation'], isTrue);
    expect(openCode.capabilities['supportsRewindBoth'], isTrue);
    expect(pi.capabilities['supportsMcpServers'], isFalse);
    expect(omp.capabilities['supportsNativePaseoTools'], isTrue);
  });

  test('projects only frozen provider features supported by the model', () {
    AgentSummary agent({
      required String provider,
      required String model,
      Map<String, Object?> featureValues = const {},
    }) => AgentSummary(
      agentId: 'agent-1',
      title: '',
      cwd: r'C:\repo',
      provider: provider,
      model: model,
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 0,
      featureValues: featureValues,
    );

    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'codex',
          model: 'gpt-5.4',
          featureValues: const {'fast_mode': true, 'plan_mode': true},
        ),
      ),
      [containsPair('id', 'fast_mode'), containsPair('id', 'plan_mode')],
    );
    expect(
      paseoProviderFeaturesFor(
        agent(provider: 'codex', model: 'unknown-model'),
      ).map((feature) => feature['id']),
      ['plan_mode'],
    );
    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'claude',
          model: 'claude-opus-4-8',
          featureValues: const {'fast_mode': true},
        ),
      ).single,
      containsPair('value', true),
    );
    expect(
      paseoProviderFeaturesFor(
        agent(provider: 'claude', model: 'claude-sonnet-5'),
      ),
      isEmpty,
    );
    expect(
      paseoProviderFeaturesFor(
        agent(
          provider: 'opencode',
          model: '',
          featureValues: const {'auto_accept': true},
        ),
      ).single,
      allOf(containsPair('id', 'auto_accept'), containsPair('value', true)),
    );
    expect(paseoProviderFeaturesFor(agent(provider: 'pi', model: '')), isEmpty);
  });
}
