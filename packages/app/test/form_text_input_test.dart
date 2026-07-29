import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/widgets/fluent/form_text_input.dart';
import 'package:coding_agent_app/widgets/fluent/select_field.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses frozen field geometry for both control sizes', (
    tester,
  ) async {
    final controllers = List.generate(3, (_) => TextEditingController());
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
    });

    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: ScaffoldPage(
          content: Column(
            children: [
              PaseoFormTextInput(
                key: const ValueKey('small'),
                controller: controllers[0],
                size: PaseoFieldControlSize.sm,
              ),
              PaseoFormTextInput(
                key: const ValueKey('medium'),
                controller: controllers[1],
                size: PaseoFieldControlSize.md,
              ),
              PaseoFormTextInput(
                key: const ValueKey('multiline'),
                controller: controllers[2],
                size: PaseoFieldControlSize.sm,
                maxLines: 4,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const ValueKey('small'))).height, 32);
    expect(tester.getSize(find.byKey(const ValueKey('medium'))).height, 44);
    expect(tester.getSize(find.byKey(const ValueKey('multiline'))).height, 96);
  });

  testWidgets('read-only field shares adaptive control geometry', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: const ScaffoldPage(
          content: Column(
            children: [
              PaseoReadOnlyField(
                key: ValueKey('small'),
                value: 'Small',
                size: PaseoFieldControlSize.sm,
              ),
              PaseoReadOnlyField(
                key: ValueKey('medium'),
                value: 'Medium',
                size: PaseoFieldControlSize.md,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const ValueKey('small'))).height, 32);
    expect(tester.getSize(find.byKey(const ValueKey('medium'))).height, 44);
  });
}
