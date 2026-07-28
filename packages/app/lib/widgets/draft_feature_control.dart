import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

class DraftFeatureControl extends StatelessWidget {
  const DraftFeatureControl({
    super.key,
    required this.feature,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.keyPrefix = 'draft-feature',
  });

  final AgentFeature feature;
  final Object? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final control = switch (feature) {
      AgentFeatureToggle() => ToggleSwitch(
        key: ValueKey('$keyPrefix-${feature.id}'),
        checked: value == true,
        onChanged: enabled ? (checked) => onChanged(checked) : null,
        content: Text(feature.label),
      ),
      AgentFeatureSelect(:final options) => SizedBox(
        width: 190,
        child: ComboBox<String>(
          key: ValueKey('$keyPrefix-${feature.id}'),
          value: value is String ? value as String : null,
          placeholder: Text(feature.label),
          items: [
            for (final option in options)
              ComboBoxItem(value: option.id, child: Text(option.label)),
          ],
          onChanged: enabled ? onChanged : null,
        ),
      ),
    };
    final tooltip = feature.tooltip ?? feature.description;
    if (tooltip == null || tooltip.isEmpty) return control;
    return Tooltip(message: tooltip, child: control);
  }
}
