/// Covers the shared `widgets/fluent/` primitives: the searchable picker
/// dialog, the toast overlay, the back button, and the segmented control.
/// These are used by several screens but their own branches (search filtering,
/// empty state, cancel, dismiss) were only exercised incidentally.
library;

import 'package:coding_agent_app/widgets/fluent/page_back_button.dart';
import 'package:coding_agent_app/widgets/fluent/search_picker_dialog.dart';
import 'package:coding_agent_app/widgets/fluent/segmented_control.dart';
import 'package:coding_agent_app/widgets/fluent/toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchPickerDialog', () {
    /// Opens the picker and returns a getter for whatever it popped.
    Future<String? Function()> open(
      WidgetTester tester, {
      List<String> items = const ['alpha', 'beta', 'gamma'],
      bool searchable = true,
      Widget Function(BuildContext)? footer,
    }) async {
      String? picked;
      var popped = false;
      await tester.pumpWidget(
        FluentApp(
          home: Builder(
            builder: (context) => Button(
              onPressed: () async {
                picked = await showDialog<String>(
                  context: context,
                  builder: (_) => SearchPickerDialog<String>(
                    title: 'Pick one',
                    items: items,
                    itemLabel: (s) => s,
                    itemIcon: (_) => FluentIcons.folder,
                    searchHint: 'Search…',
                    searchable: searchable,
                    footer: footer,
                  ),
                );
                popped = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () {
        expect(popped, isTrue, reason: 'dialog never closed');
        return picked;
      };
    }

    testWidgets('lists every item and pops the tapped one', (tester) async {
      final result = await open(tester);

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('gamma'), findsOneWidget);

      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(result(), 'beta');
    });

    testWidgets('typing filters case-insensitively', (tester) async {
      await open(tester);

      await tester.enterText(find.byType(TextBox), 'AM');
      await tester.pumpAndSettle();

      // 'gamma' contains "am"; the others don't.
      expect(find.text('gamma'), findsOneWidget);
      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsNothing);
    });

    testWidgets('a query matching nothing shows the empty text', (
      tester,
    ) async {
      await open(tester);

      await tester.enterText(find.byType(TextBox), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('No matches.'), findsOneWidget);
      expect(find.text('alpha'), findsNothing);
    });

    testWidgets('an empty item list shows the empty text immediately', (
      tester,
    ) async {
      await open(tester, items: const []);
      expect(find.text('No matches.'), findsOneWidget);
    });

    testWidgets('searchable: false hides the search box', (tester) async {
      await open(tester, searchable: false);
      expect(find.byType(TextBox), findsNothing);
      expect(find.text('alpha'), findsOneWidget);
    });

    testWidgets('renders a footer below a divider when given', (tester) async {
      await open(
        tester,
        footer: (context) => const Text('footer content'),
      );
      expect(find.text('footer content'), findsOneWidget);
      expect(find.byType(Divider), findsWidgets);
    });

    testWidgets('Cancel pops without a selection', (tester) async {
      final result = await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });
  });

  group('AppToast', () {
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        FluentApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('shows a message and auto-dismisses after the duration', (
      tester,
    ) async {
      final context = await pumpHost(tester);

      AppToast.show(context, 'saved', duration: const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('saved'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('saved'), findsNothing);
    });

    testWidgets('showing a second toast replaces the first', (tester) async {
      final context = await pumpHost(tester);

      AppToast.show(context, 'first');
      await tester.pump();
      AppToast.show(context, 'second');
      await tester.pump();

      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('dismissCurrent removes it early and is safe to repeat', (
      tester,
    ) async {
      final context = await pumpHost(tester);

      AppToast.show(context, 'transient');
      await tester.pump();
      expect(find.text('transient'), findsOneWidget);

      AppToast.dismissCurrent();
      await tester.pump();
      expect(find.text('transient'), findsNothing);

      // Idempotent — the reset flow calls it unconditionally.
      AppToast.dismissCurrent();
      await tester.pump();
    });

    testWidgets('carries the requested severity', (tester) async {
      final context = await pumpHost(tester);

      AppToast.show(context, 'boom', severity: InfoBarSeverity.error);
      await tester.pump();

      expect(
        tester.widget<InfoBar>(find.byType(InfoBar)).severity,
        InfoBarSeverity.error,
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('PageBackButton', () {
    testWidgets('pops the current route', (tester) async {
      await tester.pumpWidget(
        FluentApp(
          home: Builder(
            builder: (context) => Button(
              child: const Text('push'),
              onPressed: () => Navigator.of(context).push(
                FluentPageRoute<void>(
                  builder: (_) => const ScaffoldPage(
                    header: PageHeader(
                      title: Text('Second'),
                      leading: PageBackButton(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);

      await tester.tap(find.byType(PageBackButton));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsNothing);
      expect(find.text('push'), findsOneWidget);
    });
  });

  group('SegmentedControl', () {
    testWidgets('marks the selected segment and reports taps', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        FluentApp(
          home: ScaffoldPage(
            content: SegmentedControl<String>(
              segments: const [('a', 'Alpha'), ('b', 'Beta')],
              selected: 'a',
              onChanged: tapped.add,
            ),
          ),
        ),
      );

      final buttons = tester.widgetList<ToggleButton>(
        find.byType(ToggleButton),
      ).toList();
      expect(buttons, hasLength(2));
      expect(buttons[0].checked, isTrue);
      expect(buttons[1].checked, isFalse);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(tapped, ['b']);
    });
  });
}
