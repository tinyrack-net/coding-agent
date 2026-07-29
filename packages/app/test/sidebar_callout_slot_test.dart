import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/sidebar_callout_provider.dart';
import 'package:coding_agent_app/state/sidebar_callout_state.dart';
import 'package:coding_agent_app/widgets/sidebar_callout_slot.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('native slot renders the active callout at full width', (
    tester,
  ) async {
    final container = await _pumpSlot(tester, web: false);
    addTearDown(container.dispose);

    expect(find.byKey(const ValueKey('sidebar-callout-slot')), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('sidebar-callout-slot'))).width,
      280,
    );
  });

  testWidgets('web slot stays empty even when a callout is active', (
    tester,
  ) async {
    final container = await _pumpSlot(tester, web: true);
    addTearDown(container.dispose);

    expect(find.byKey(const ValueKey('sidebar-callout-slot')), findsNothing);
    expect(find.text('Update available'), findsNothing);
  });
}

Future<ProviderContainer> _pumpSlot(
  WidgetTester tester, {
  required bool web,
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  container
      .read(sidebarCalloutProvider.notifier)
      .show(
        const SidebarCalloutOptions(id: 'update', title: 'Update available'),
      );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        theme: buildAppTheme(),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 280,
            child: SidebarCalloutSlot(webOverride: web),
          ),
        ),
      ),
    ),
  );
  return container;
}
