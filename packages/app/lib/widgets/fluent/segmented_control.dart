import 'package:fluent_ui/fluent_ui.dart';

/// A row of mutually-exclusive [ToggleButton]s, replacing Material's
/// `SegmentedButton` (fluent_ui has no direct equivalent).
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  /// `(value, label)` pairs, in display order.
  final List<(T value, String label)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (value, label) in segments)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: ToggleButton(
              checked: value == selected,
              onChanged: (_) => onChanged(value),
              child: Text(label),
            ),
          ),
      ],
    );
  }
}
