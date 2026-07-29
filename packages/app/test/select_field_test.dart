import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/widgets/fluent/select_field.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop trigger uses frozen small geometry and anchor flyout', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    String? selected;
    await _pump(tester, value: null, onChanged: (value, _) => selected = value);

    final trigger = find.byKey(const ValueKey('project-trigger'));
    expect(tester.getSize(trigger).height, 34);
    expect(find.text('Select project'), findsOneWidget);

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('project-trigger-search')),
      findsOneWidget,
    );
    expect(find.text('Project one'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('project-trigger-option-one')));
    await tester.pumpAndSettle();
    expect(selected, 'one');
  });

  testWidgets(
    'compact trigger uses frozen 46px browser geometry and adaptive sheet',
    (tester) async {
      await _setViewport(tester, const Size(500, 800));
      await _pump(
        tester,
        value: null,
        size: PaseoFieldControlSize.md,
        onChanged: (_, _) {},
      );

      final trigger = find.byKey(const ValueKey('project-trigger'));
      expect(tester.getSize(trigger).height, 46);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('adaptive-modal-sheet-card')),
        findsOneWidget,
      );
      final card = tester.getRect(
        find.byKey(const ValueKey('adaptive-modal-sheet-card')),
      );
      expect(card.height, 800 * .6);
      expect(card.bottom, 800);
    },
  );

  testWidgets('search filters labels and descriptions and reports empty', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await _pump(tester, value: null, onChanged: (_, _) {});
    await tester.tap(find.byKey(const ValueKey('project-trigger')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('project-trigger-search')),
      'secondary',
    );
    await tester.pump();
    expect(find.text('Project two'), findsOneWidget);
    expect(find.text('Project one'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('project-trigger-search')),
      'missing',
    );
    await tester.pump();
    expect(find.text('No projects found'), findsOneWidget);
  });

  testWidgets('loading preserves previous options and selected display', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: _Harness(key: key),
      ),
    );
    key.currentState!.setLoading();
    await tester.pump();

    expect(find.byType(ProgressRing), findsOneWidget);
    expect(find.text('Project one'), findsOneWidget);
  });

  testWidgets('disabled trigger exposes semantics and does not open', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await _pump(tester, value: 'one', disabled: true, onChanged: (_, _) {});

    await tester.tap(find.byKey(const ValueKey('project-trigger')));
    await tester.pumpAndSettle();
    expect(find.byType(FlyoutContent), findsNothing);
    expect(find.text('Project one'), findsOneWidget);
  });

  testWidgets('desktop flyout uses the trigger width as its minimum', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await _pump(tester, value: null, onChanged: (_, _) {});

    await tester.tap(find.byKey(const ValueKey('project-trigger')));
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byType(FlyoutContent)).width;
    expect(width, greaterThanOrEqualTo(360));
    expect(width, lessThanOrEqualTo(400));
  });

  testWidgets('value keys and custom rows receive selected and active state', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    _Choice? selected;
    final options = [
      SelectFieldOption(
        id: 'one',
        value: _Choice('one'),
        label: 'Choice one',
        optionKey: const ValueKey('stable-one'),
      ),
      SelectFieldOption(id: 'two', value: _Choice('two'), label: 'Choice two'),
    ];
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: Center(
          child: SizedBox(
            width: 360,
            child: PaseoSelectField<_Choice>(
              label: 'Choice',
              value: _Choice('two'),
              selectedDisplay: const SelectFieldDisplay(label: 'Choice two'),
              options: options,
              onChanged: (value, _) => selected = value,
              placeholder: 'Select choice',
              emptyText: 'No choices',
              size: PaseoFieldControlSize.sm,
              field: false,
              triggerKey: const ValueKey('choice-trigger'),
              getValueKey: (value) => value.id,
              renderOption: (input) => Button(
                key: ValueKey(
                  'custom-${input.option.id}-${input.selected}-${input.active}',
                ),
                onPressed: input.onPressed,
                child: Text(input.option.label),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('choice-trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stable-one')), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-two-true-true')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('custom-one-false-false')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'one');
  });

  testWidgets('default matching preserves Object.is signed-zero semantics', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: Center(
          child: SizedBox(
            width: 360,
            child: PaseoSelectField<double>(
              label: 'Number',
              value: -0.0,
              selectedDisplay: const SelectFieldDisplay(label: 'Negative zero'),
              options: const [
                SelectFieldOption(id: 'positive', value: 0.0, label: 'Zero'),
                SelectFieldOption(
                  id: 'negative',
                  value: -0.0,
                  label: 'Negative zero',
                ),
              ],
              onChanged: (_, _) {},
              placeholder: 'Select number',
              emptyText: 'No numbers',
              size: PaseoFieldControlSize.sm,
              field: false,
              triggerKey: const ValueKey('number-trigger'),
              renderOption: (input) => Text(
                input.option.label,
                key: ValueKey(
                  'number-${input.option.id}-selected-${input.selected}',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('number-trigger')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('number-positive-selected-false')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('number-negative-selected-true')),
      findsOneWidget,
    );
  });

  testWidgets('option kinds render frozen folder and file affordances', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: Center(
          child: SizedBox(
            width: 360,
            child: PaseoSelectField<String>(
              label: 'Path',
              value: null,
              options: const [
                SelectFieldOption(
                  id: 'directory',
                  value: 'directory',
                  label: 'Directory',
                  kind: SelectFieldOptionKind.directory,
                ),
                SelectFieldOption(
                  id: 'file',
                  value: 'file',
                  label: 'File',
                  kind: SelectFieldOptionKind.file,
                ),
              ],
              onChanged: (_, _) {},
              placeholder: 'Select path',
              emptyText: 'No paths',
              size: PaseoFieldControlSize.sm,
              field: false,
              triggerKey: const ValueKey('path-trigger'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('path-trigger')));
    await tester.pumpAndSettle();

    expect(find.byIcon(FluentIcons.folder), findsOneWidget);
    expect(find.byIcon(FluentIcons.page), findsOneWidget);
  });

  testWidgets('keyboard opens, wraps the active row, selects, and escapes', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    String? selected;
    await _pump(
      tester,
      value: 'one',
      searchable: false,
      onChanged: (value, _) => selected = value,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(FlyoutContent), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'two');
    expect(find.byType(FlyoutContent), findsNothing);

    await tester.tap(find.byKey(const ValueKey('project-trigger')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FlyoutContent), findsNothing);
  });
}

final _options = <SelectFieldOption<String>>[
  const SelectFieldOption(
    id: 'one',
    value: 'one',
    label: 'Project one',
    description: 'Primary repository',
    leading: Icon(FluentIcons.folder, size: 16),
  ),
  const SelectFieldOption(
    id: 'two',
    value: 'two',
    label: 'Project two',
    description: 'Secondary repository',
    leading: Icon(FluentIcons.folder, size: 16),
  ),
];

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  required String? value,
  required SelectFieldChanged<String> onChanged,
  bool disabled = false,
  bool searchable = true,
  PaseoFieldControlSize size = PaseoFieldControlSize.sm,
}) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(),
    home: Center(
      child: SizedBox(
        width: 360,
        child: PaseoSelectField<String>(
          label: 'Project',
          value: value,
          options: _options,
          onChanged: onChanged,
          placeholder: 'Select project',
          emptyText: 'No projects found',
          searchable: searchable,
          searchPlaceholder: 'Search projects...',
          disabled: disabled,
          size: size,
          field: false,
          triggerKey: const ValueKey('project-trigger'),
        ),
      ),
    ),
  ),
);

final class _Choice {
  _Choice(this.id);

  final String id;
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  var loading = false;
  var options = _options;

  void setLoading() => setState(() {
    loading = true;
    options = const [];
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 360,
      child: PaseoSelectField<String>(
        label: 'Project',
        value: 'one',
        options: options,
        onChanged: (_, _) {},
        placeholder: 'Select project',
        emptyText: 'No projects found',
        loading: loading,
        searchable: true,
        field: false,
        triggerKey: const ValueKey('project-trigger'),
      ),
    ),
  );
}
