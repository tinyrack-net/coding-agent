// Port of Paseo's `composer/agent-controls/mode.test.ts` and
// `composer/agent-controls/model-loading.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/agent_controls_mode.dart';
import 'package:flutter_test/flutter_test.dart';

const _planMode = ProviderMode(id: 'plan', label: 'Plan');
const _modes = [
  _planMode,
  ProviderMode(id: 'build', label: 'Build'),
  ProviderMode(id: 'full-access', label: 'Full Access'),
];

void main() {
  group('resolveAgentControlsMode', () {
    test('uses ready mode without controlled agent controls', () {
      expect(
        resolveAgentControlsMode(hasAgentControls: false),
        AgentControlsMode.ready,
      );
    });

    test('uses draft mode with controlled agent controls', () {
      expect(
        resolveAgentControlsMode(hasAgentControls: true),
        AgentControlsMode.draft,
      );
    });
  });

  group('resolveNextAgentModeId', () {
    test('cycles from the selected mode to the next mode', () {
      expect(
        resolveNextAgentModeId(modeOptions: _modes, selectedMode: 'build'),
        'full-access',
      );
    });

    test('wraps from the last mode to the first mode', () {
      expect(
        resolveNextAgentModeId(
          modeOptions: _modes,
          selectedMode: 'full-access',
        ),
        'plan',
      );
    });

    test('treats an empty selection as the visible first mode', () {
      expect(
        resolveNextAgentModeId(modeOptions: _modes, selectedMode: ''),
        'build',
      );
      expect(resolveNextAgentModeId(modeOptions: _modes), 'build');
    });

    test('treats a stale selection as the visible first mode', () {
      expect(
        resolveNextAgentModeId(
          modeOptions: _modes,
          selectedMode: 'deleted-mode',
        ),
        'build',
      );
    });

    test('returns null when there are fewer than two modes', () {
      expect(
        resolveNextAgentModeId(modeOptions: const [], selectedMode: ''),
        isNull,
      );
      expect(
        resolveNextAgentModeId(
          modeOptions: const [_planMode],
          selectedMode: 'plan',
        ),
        isNull,
      );
    });
  });

  group('isProviderModelsQueryLoading', () {
    test('is loading during an initial load or a background refetch', () {
      expect(
        isProviderModelsQueryLoading(isLoading: true, isFetching: false),
        isTrue,
      );
      expect(
        isProviderModelsQueryLoading(isLoading: false, isFetching: true),
        isTrue,
      );
      expect(
        isProviderModelsQueryLoading(isLoading: true, isFetching: true),
        isTrue,
      );
    });

    test('is settled only when neither is in flight', () {
      expect(
        isProviderModelsQueryLoading(isLoading: false, isFetching: false),
        isFalse,
      );
    });
  });
}
