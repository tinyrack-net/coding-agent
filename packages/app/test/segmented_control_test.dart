import 'package:coding_agent_app/widgets/fluent/segmented_control.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selecting a segment reports its value', (tester) async {
    var selected = 'first';

    await tester.pumpWidget(
      FluentApp(
        home: SegmentedControl<String>(
          segments: const [('first', 'First'), ('second', 'Second')],
          selected: selected,
          onChanged: (value) => selected = value,
        ),
      ),
    );

    await tester.tap(find.text('Second'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(selected, 'second');
  });
}
