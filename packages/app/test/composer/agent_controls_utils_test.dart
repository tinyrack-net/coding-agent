// Port of Paseo's `composer/agent-controls/utils.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/agent_controls_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const _translations = {
  'agentControls.thinking.extraHigh': 'Extra high',
  'agentControls.thinking.unknown': 'Unknown',
  'agentControls.model.unknown': 'Unknown model',
};

String t(String key) => _translations[key] ?? key;

ProviderModelDefinition model({
  required String id,
  required String label,
  String provider = 'codex',
  bool? isDefault,
  List<ProviderSelectOption>? thinkingOptions,
  String? defaultThinkingOptionId,
}) => ProviderModelDefinition(
  provider: provider,
  id: id,
  label: label,
  isDefault: isDefault,
  thinkingOptions: thinkingOptions,
  defaultThinkingOptionId: defaultThinkingOptionId,
);

void main() {
  test('returns translation keys for each editable agent control hint', () {
    expect(
      getAgentControlHintKey(ExplainedAgentControl.thinking),
      'agentControls.hints.thinking',
    );
    expect(
      getAgentControlHintKey(ExplainedAgentControl.model),
      'agentControls.hints.model',
    );
    expect(
      getAgentControlHintKey(ExplainedAgentControl.mode),
      'agentControls.hints.mode',
    );
  });

  group('feature metadata helpers', () {
    test('prefers explicit feature tooltip copy', () {
      expect(
        getFeatureTooltip(label: 'Fast mode', tooltip: 'Run faster'),
        'Run faster',
      );
    });

    test('falls back to the feature label when no tooltip is provided', () {
      expect(getFeatureTooltip(label: 'Fast mode'), 'Fast mode');
    });

    test('maps feature highlight colors by feature id', () {
      expect(
        getFeatureHighlightColor('fast_mode'),
        FeatureHighlightColor.yellow,
      );
      expect(
        getFeatureHighlightColor('auto_accept'),
        FeatureHighlightColor.green,
      );
      expect(getFeatureHighlightColor('plan_mode'), FeatureHighlightColor.blue);
      expect(
        getFeatureHighlightColor('anything-else'),
        FeatureHighlightColor.defaultColor,
      );
    });
  });

  group('normalizeModelId', () {
    test('treats empty values as unset', () {
      expect(normalizeModelId(null), isNull);
      expect(normalizeModelId(''), isNull);
      expect(normalizeModelId('   '), isNull);
    });

    test('returns trimmed model ids', () {
      expect(normalizeModelId('  gpt-5  '), 'gpt-5');
    });
  });

  group('formatAgentModeLabel', () {
    test('sentence-cases provider mode labels', () {
      expect(formatAgentModeLabel(id: 'plan', label: 'Plan'), 'Plan');
      expect(
        formatAgentModeLabel(id: 'full-access', label: 'Full Access'),
        'Full access',
      );
      expect(
        formatAgentModeLabel(id: 'auto-review', label: 'Auto-review'),
        'Auto-review',
      );
      expect(
        formatAgentModeLabel(id: 'read_only', label: 'read_only'),
        'Read only',
      );
      expect(
        formatAgentModeLabel(id: 'acceptEdits', label: 'acceptEdits'),
        'Accept edits',
      );
    });

    test('splits compact mode ids when no provider label is available', () {
      expect(formatAgentModeLabel(id: 'auto-review'), 'Auto review');
    });
  });

  group('formatThinkingOptionLabel', () {
    test('formats compact thinking option labels for display', () {
      expect(
        formatThinkingOptionLabel(id: 'none', label: 'none', t: t),
        'None',
      );
      expect(formatThinkingOptionLabel(id: 'low', label: 'low', t: t), 'Low');
      expect(
        formatThinkingOptionLabel(id: 'medium', label: 'medium', t: t),
        'Medium',
      );
      expect(
        formatThinkingOptionLabel(id: 'high', label: 'high', t: t),
        'High',
      );
      expect(
        formatThinkingOptionLabel(id: 'xhigh', label: 'xhigh', t: t),
        'Extra high',
      );
    });

    test('sentence-cases split provider labels', () {
      expect(
        formatThinkingOptionLabel(id: 'extra_high', label: 'extra_high', t: t),
        'Extra high',
      );
      expect(
        formatThinkingOptionLabel(id: 'think-hard', label: 'think-hard', t: t),
        'Think hard',
      );
      expect(
        formatThinkingOptionLabel(id: 'xhigh', label: 'XHigh', t: t),
        'Extra high',
      );
    });
  });

  group('resolveAgentModelSelection', () {
    test('prefers runtime model over configured model', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'a',
            label: 'Model A',
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
            ],
            defaultThinkingOptionId: 'low',
          ),
        ],
        runtimeModelId: 'a',
        configuredModelId: 'b',
        t: t,
      );

      expect(selection.activeModelId, 'a');
      expect(selection.displayModel, 'Model A');
      expect(selection.selectedThinkingId, 'low');
      expect(selection.displayThinking, 'Low');
    });

    test('uses an explicit thinking option when provided', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'a',
            label: 'Model A',
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'xhigh', label: 'xhigh'),
            ],
            defaultThinkingOptionId: 'low',
          ),
        ],
        runtimeModelId: 'a',
        explicitThinkingOptionId: 'xhigh',
        t: t,
      );

      expect(selection.selectedThinkingId, 'xhigh');
      expect(selection.displayThinking, 'Extra high');
    });

    test('treats the default sentinel as the model default', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'a',
            label: 'Model A',
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'high', label: 'High'),
            ],
            defaultThinkingOptionId: 'high',
          ),
        ],
        runtimeModelId: 'a',
        explicitThinkingOptionId: 'default',
        t: t,
      );

      expect(selection.selectedThinkingId, 'high');
      expect(selection.displayThinking, 'High');
    });

    test('falls back to the provider default model label', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'a',
            label: 'Model A',
            isDefault: true,
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
            ],
            defaultThinkingOptionId: 'low',
          ),
        ],
        t: t,
      );

      expect(selection.displayModel, 'Model A');
      expect(selection.displayThinking, 'Low');
    });

    test('prefers the configured model when the runtime model is not in the '
        'list', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'default',
            provider: 'claude',
            label: 'Default (Sonnet 4.6)',
            isDefault: true,
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'medium', label: 'Medium'),
            ],
          ),
        ],
        runtimeModelId: 'claude-sonnet-4-6-20260101',
        configuredModelId: 'default',
        t: t,
      );

      expect(selection.activeModelId, 'default');
      expect(selection.displayModel, 'Default (Sonnet 4.6)');
      expect(selection.selectedThinkingId, 'low');
      expect(selection.displayThinking, 'Low');
    });

    test('still displays a model id the catalog does not contain', () {
      final selection = resolveAgentModelSelection(
        models: const [],
        runtimeModelId: 'ghost-model',
        t: t,
      );

      expect(selection.selectedModel, isNull);
      expect(selection.activeModelId, 'ghost-model');
      expect(selection.displayModel, 'ghost-model');
      expect(selection.displayThinking, 'Unknown');
    });

    test('reports unknown model and thinking with nothing to go on', () {
      final selection = resolveAgentModelSelection(models: null, t: t);

      expect(selection.selectedModel, isNull);
      expect(selection.activeModelId, isNull);
      expect(selection.displayModel, 'Unknown model');
      expect(selection.thinkingOptions, isNull);
      expect(selection.selectedThinkingId, isNull);
      expect(selection.displayThinking, 'Unknown');
    });

    test('falls back to the first thinking option when the resolved id is '
        'stale', () {
      final selection = resolveAgentModelSelection(
        models: [
          model(
            id: 'a',
            label: 'Model A',
            thinkingOptions: const [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'high', label: 'High'),
            ],
            defaultThinkingOptionId: 'removed',
          ),
        ],
        runtimeModelId: 'a',
        t: t,
      );

      expect(selection.selectedThinkingId, 'low');
      expect(selection.displayThinking, 'Low');
    });
  });
}
