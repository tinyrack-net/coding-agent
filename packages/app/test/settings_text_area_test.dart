import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/settings_text_area.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('card matches the frozen settings textarea geometry and tokens', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      SettingsTextAreaCard(
        key: const ValueKey('card'),
        inputKey: const ValueKey('input'),
        accessibilityLabel: 'Setup commands',
        controller: controller,
        placeholder: 'npm install',
      ),
    );

    final palette = paseoPaletteFor(AppThemeName.dark);
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('card')),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = card.decoration! as BoxDecoration;
    expect(card.clipBehavior, Clip.hardEdge);
    expect(decoration.color, palette.surface1);
    expect((decoration.border! as Border).top.color, palette.border);
    expect(decoration.borderRadius, BorderRadius.circular(8));
    expect(tester.getSize(find.byKey(const ValueKey('input'))).height, 96);

    final input = tester.widget<TextBox>(
      find.descendant(
        of: find.byKey(const ValueKey('input')),
        matching: find.byType(TextBox),
      ),
    );
    expect(
      input.padding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    expect(input.expands, isTrue);
    expect(input.minLines, isNull);
    expect(input.maxLines, isNull);
    expect(input.textAlignVertical, TextAlignVertical.top);
    expect(input.style?.fontSize, 14);
    expect(input.style?.color, palette.foreground);
    expect(input.placeholder, 'npm install');
    expect(input.placeholderStyle?.color, palette.foregroundMuted);
    expect(find.bySemanticsLabel('Setup commands'), findsOneWidget);
  });

  testWidgets('input preserves multiline edits and custom text overrides', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'first');
    addTearDown(controller.dispose);
    var changed = '';
    await _pump(
      tester,
      SettingsTextArea(
        key: const ValueKey('input'),
        accessibilityLabel: 'Teardown commands',
        controller: controller,
        onChanged: (value) => changed = value,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );

    await tester.enterText(find.byType(TextBox), 'first\nsecond');
    await tester.pump();

    expect(controller.text, 'first\nsecond');
    expect(changed, 'first\nsecond');
    final input = tester.widget<TextBox>(find.byType(TextBox));
    expect(input.style?.fontSize, 16);
    expect(input.style?.fontWeight, FontWeight.w600);
    expect(tester.getSize(find.byKey(const ValueKey('input'))).height, 96);
  });
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: Center(child: SizedBox(width: 420, child: child)),
  ),
);
