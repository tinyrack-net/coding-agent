import 'package:coding_agent_app/screens/keyboard_shortcuts_settings_section.dart';
import 'package:coding_agent_app/state/keyboard_shortcut_overrides_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _commandCenterBindingId = 'command-center-toggle-ctrl-k-non-mac';

Future<ProviderContainer> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const FluentApp(home: KeyboardShortcutsSettingsSection()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _startCommandCenterCapture(WidgetTester tester) async {
  final edit = find.byKey(
    const ValueKey('shortcut-edit-toggle-command-center'),
  );
  await tester.scrollUntilVisible(
    edit,
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(edit);
  await tester.pump();
}

Future<void> _sendControlCombo(
  WidgetTester tester,
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(logical, physicalKey: physical);
  await tester.sendKeyUpEvent(logical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('renders the Paseo shortcut catalog by section', (tester) async {
    await _pumpSettings(tester);

    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Tabs & Panes'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shortcut-setting-toggle-command-center')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('shortcut-setting-toggle-command-center')),
      findsOneWidget,
    );
    expect(find.text('Ctrl+K'), findsOneWidget);
  });

  testWidgets('captures, persists, and resets a replacement shortcut', (
    tester,
  ) async {
    final container = await _pumpSettings(tester);
    await _startCommandCenterCapture(tester);

    expect(find.text('Press a key combination'), findsOneWidget);
    await _sendControlCombo(
      tester,
      LogicalKeyboardKey.keyJ,
      PhysicalKeyboardKey.keyJ,
    );
    expect(
      find.byKey(const ValueKey('shortcut-capture-preview')),
      findsOneWidget,
    );
    expect(find.text('Ctrl+J'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shortcut-capture-done')));
    await tester.pumpAndSettle();
    expect(container.read(keyboardShortcutOverridesProvider), {
      _commandCenterBindingId: 'Ctrl+J',
    });

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(KeyboardShortcutOverridesNotifier.storageKey),
      contains('Ctrl+J'),
    );

    final reset = find.byKey(
      const ValueKey('shortcut-reset-toggle-command-center'),
    );
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(container.read(keyboardShortcutOverridesProvider), isEmpty);
  });

  testWidgets('captures chords and Backspace removes the last combination', (
    tester,
  ) async {
    final container = await _pumpSettings(tester);
    await _startCommandCenterCapture(tester);
    await _sendControlCombo(
      tester,
      LogicalKeyboardKey.keyJ,
      PhysicalKeyboardKey.keyJ,
    );
    await _sendControlCombo(
      tester,
      LogicalKeyboardKey.keyC,
      PhysicalKeyboardKey.keyC,
    );
    expect(find.text('Ctrl+J  Ctrl+C'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('Ctrl+J'), findsOneWidget);
    expect(find.text('Ctrl+J  Ctrl+C'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shortcut-capture-done')));
    await tester.pumpAndSettle();
    expect(container.read(keyboardShortcutOverridesProvider), {
      _commandCenterBindingId: 'Ctrl+J',
    });
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('Escape cancels capture without changing the override', (
    tester,
  ) async {
    final container = await _pumpSettings(tester);
    await container
        .read(keyboardShortcutOverridesProvider.notifier)
        .setOverride(_commandCenterBindingId, 'Ctrl+J');
    await tester.pump();
    await _startCommandCenterCapture(tester);
    await _sendControlCombo(
      tester,
      LogicalKeyboardKey.keyC,
      PhysicalKeyboardKey.keyC,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('shortcut-capture-preview')),
      findsNothing,
    );
    expect(container.read(keyboardShortcutOverridesProvider), {
      _commandCenterBindingId: 'Ctrl+J',
    });
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('Reset all removes every customized binding', (tester) async {
    final container = await _pumpSettings(tester);
    final notifier = container.read(keyboardShortcutOverridesProvider.notifier);
    await notifier.setOverride(_commandCenterBindingId, 'Ctrl+J');
    await notifier.setOverride('workspace-tab-new-ctrl-t-non-mac', 'Ctrl+Y');
    await tester.pump();

    final resetAll = find.byKey(const ValueKey('shortcut-reset-all'));
    await tester.scrollUntilVisible(
      resetAll,
      -500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(resetAll);
    await tester.pumpAndSettle();

    expect(container.read(keyboardShortcutOverridesProvider), isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(KeyboardShortcutOverridesNotifier.storageKey),
      isNull,
    );
  });
}
