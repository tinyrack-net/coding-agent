import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/widgets/draft_feature_control.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('select feature exposes options, tooltip, and changes', (
    tester,
  ) async {
    Object? changed;
    await tester.pumpWidget(
      FluentApp(
        home: DraftFeatureControl(
          feature: const AgentFeatureSelect(
            id: 'effort',
            label: 'Effort',
            tooltip: 'Choose effort',
            value: 'medium',
            options: [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'high', label: 'High'),
            ],
          ),
          value: 'high',
          enabled: true,
          onChanged: (value) => changed = value,
        ),
      ),
    );

    expect(find.byType(Tooltip), findsOneWidget);
    final combo = tester.widget<ComboBox<String>>(
      find.byKey(const ValueKey('draft-feature-effort')),
    );
    expect(combo.value, 'high');
    expect(combo.items, hasLength(2));
    combo.onChanged?.call('low');
    expect(changed, 'low');
  });

  testWidgets('disabled select accepts a null effective value', (tester) async {
    await tester.pumpWidget(
      const FluentApp(
        home: DraftFeatureControl(
          feature: AgentFeatureSelect(
            id: 'profile',
            label: 'Profile',
            description: '',
            value: null,
            options: [ProviderSelectOption(id: 'safe', label: 'Safe')],
          ),
          value: false,
          enabled: false,
          onChanged: _ignoreFeatureValue,
        ),
      ),
    );

    final combo = tester.widget<ComboBox<String>>(
      find.byKey(const ValueKey('draft-feature-profile')),
    );
    expect(combo.value, isNull);
    expect(combo.onChanged, isNull);
    expect(find.byType(Tooltip), findsNothing);
  });
}

void _ignoreFeatureValue(Object? _) {}
