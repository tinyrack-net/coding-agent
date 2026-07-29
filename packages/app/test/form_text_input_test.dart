import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/widgets/fluent/form_text_input.dart';
import 'package:coding_agent_app/widgets/fluent/select_field.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('field gives errors precedence and preserves frozen spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: const ScaffoldPage(
          content: PaseoField(
            testId: 'project',
            label: 'Project',
            hint: 'Choose a project',
            error: 'Project is required',
            child: SizedBox(key: ValueKey('control'), height: 32),
          ),
        ),
      ),
    );

    expect(find.text('Choose a project'), findsNothing);
    expect(find.text('Project is required'), findsOneWidget);
    expect(find.byKey(const ValueKey('project')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-error')), findsOneWidget);
    final labelRect = tester.getRect(find.text('Project'));
    final controlRect = tester.getRect(find.byKey(const ValueKey('control')));
    final errorRect = tester.getRect(
      find.byKey(const ValueKey('project-error')),
    );
    expect(controlRect.top - labelRect.bottom, 8);
    expect(errorRect.top - controlRect.bottom, 8);
  });

  testWidgets('field falls back to its hint for an empty error', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: const ScaffoldPage(
          content: PaseoField(
            testId: 'project',
            label: 'Project',
            hint: 'Choose a project',
            error: '',
            child: SizedBox(height: 32),
          ),
        ),
      ),
    );

    expect(find.text('Choose a project'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-error')), findsNothing);
  });

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

    expect(tester.getSize(find.byKey(const ValueKey('small'))).height, 34);
    expect(tester.getSize(find.byKey(const ValueKey('medium'))).height, 46);
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

    expect(tester.getSize(find.byKey(const ValueKey('small'))).height, 34);
    expect(tester.getSize(find.byKey(const ValueKey('medium'))).height, 46);
  });
}
