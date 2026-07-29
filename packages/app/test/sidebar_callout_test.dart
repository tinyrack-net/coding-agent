import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/sidebar_callout_state.dart';
import 'package:coding_agent_app/widgets/sidebar_callout.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders frozen content geometry and at most two actions', (
    tester,
  ) async {
    await _pump(
      tester,
      SidebarCallout(
        title: 'Update available',
        description: 'v1.2.3 is ready to install.',
        icon: const Icon(FluentIcons.sync, size: 14),
        testId: 'callout',
        actions: [
          SidebarCalloutAction(label: "What's new", onPressed: () {}),
          SidebarCalloutAction(
            label: 'Install & restart',
            onPressed: () {},
            variant: SidebarCalloutActionVariant.primary,
          ),
          SidebarCalloutAction(label: 'Ignored', onPressed: () {}),
        ],
      ),
    );

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('v1.2.3 is ready to install.'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Install & restart'), findsOneWidget);
    expect(find.text('Ignored'), findsNothing);
    expect(find.byKey(const ValueKey('callout-actions')), findsOneWidget);

    final container = tester.widget<Container>(
      find.byKey(const ValueKey('callout')),
    );
    expect(
      container.padding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(
      (decoration.border! as Border).top.color,
      paseoPaletteFor(AppThemeName.dark).border,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('callout-action-0'))).width,
      120,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('callout-action-1'))).width,
      120,
    );

    final primaryContainer = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('callout-action-1')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (primaryContainer.decoration! as BoxDecoration).color,
      paseoPaletteFor(AppThemeName.dark).foreground,
    );
  });

  testWidgets('actions honor disabled state and dismiss remains optional', (
    tester,
  ) async {
    var pressed = 0;
    var dismissed = 0;
    await _pump(
      tester,
      SidebarCallout(
        description: 'Saved.',
        testId: 'callout',
        onDismiss: () => dismissed++,
        actions: [
          SidebarCalloutAction(
            label: 'Disabled',
            disabled: true,
            onPressed: () => pressed++,
          ),
          SidebarCalloutAction(label: 'Undo', onPressed: () => pressed++),
        ],
      ),
    );

    final dismiss = find.byKey(const ValueKey('callout-dismiss'));
    expect(dismiss, findsOneWidget);
    expect(tester.getSize(dismiss), const Size(14, 14));
    expect(tester.getTopLeft(dismiss).dx, 16);
    await tester.tap(find.byKey(const ValueKey('callout-action-0')));
    await tester.tap(find.byKey(const ValueKey('callout-action-1')));
    final dismissCenter = tester.getCenter(dismiss);
    await tester.tapAt(Offset(dismissCenter.dx - 15, dismissCenter.dy));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pressed, 1);
    expect(dismissed, 1);
    await tester.tap(dismiss);
    await tester.pump(const Duration(milliseconds: 100));
    expect(dismissed, 2);

    final disabledOpacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byKey(const ValueKey('callout-action-0')),
        matching: find.byType(Opacity),
      ),
    );
    expect(disabledOpacity.opacity, 0.5);
  });

  testWidgets('error variant uses destructive border and announces content', (
    tester,
  ) async {
    await _pump(
      tester,
      const SidebarCallout(
        title: 'Update failed',
        description: 'Try again.',
        variant: SidebarCalloutVariant.error,
        testId: 'callout',
      ),
    );

    final container = tester.widget<Container>(
      find.byKey(const ValueKey('callout')),
    );
    expect(
      (container.decoration! as BoxDecoration).border!.top.color,
      buildAppTheme().resources.systemFillColorCritical,
    );
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('callout')),
    );
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
  });

  testWidgets('omits action row and dismiss button when absent', (
    tester,
  ) async {
    await _pump(
      tester,
      const SidebarCallout(
        description: SidebarCalloutDescriptionText('Copied'),
        testId: 'callout',
      ),
    );
    final description = tester.widget<Text>(find.text('Copied'));
    expect(description.style?.fontSize, 12);
    expect(
      description.style?.color,
      paseoPaletteFor(AppThemeName.dark).foregroundMuted,
    );
    expect(find.byKey(const ValueKey('callout-actions')), findsNothing);
    expect(find.byKey(const ValueKey('callout-dismiss')), findsNothing);
  });
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 280, child: child),
    ),
  ),
);
