/// Tests pinning the frozen contract of the Paseo 0.2.0 draggable-list +
/// material-file-icon cluster.
///
/// Upstream ships no `.test.ts(x)` for any of the six files, so every case here
/// is written against the frozen sources themselves:
///
/// * the icon tables are asserted **entry-for-entry** (both maps are compared
///   against a literal transcription, not sampled), together with the
///   `getFileIconSvg` / `getExtension` fallback rules;
/// * the list is asserted on its reorder behaviour — which must come out
///   identical to dnd-kit's `arrayMove` — and on its visual contract: the
///   dragged row's opacity and scale, the activation thresholds, and the
///   conditional rendering of header/footer/empty/refresh.
library;

import 'package:coding_agent_app/drag_reorder/drag_reorder.dart';
import 'package:coding_agent_app/widgets/paseo_draggable_list.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const double _rowHeight = 48;

/// Long enough to clear the frozen 180 ms `touchHoldDelayMs`.
const Duration _pastHoldDelay = Duration(milliseconds: 250);

/// Mounts [child] in the smallest tree the widget needs, sized so a fixed
/// number of rows are laid out and hit-testable.
Future<void> pumpList(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    FluentApp(home: SizedBox(width: 400, height: 400, child: child)),
  );
}

/// A list of `['a', 'b', 'c', 'd']` rows keyed by their own text.
PaseoDraggableList<String> buildList({
  required List<String> data,
  required ValueChanged<List<String>> onDragEnd,
  bool useDragHandle = false,
  Widget? header,
  Widget? footer,
  Widget? empty,
  VoidCallback? onDragBegin,
  VoidCallback? onDragIntent,
  VoidCallback? onDragRelease,
  PaseoDraggableListTranslator? translate,
  void Function(PaseoDraggableRenderItemInfo<String> info)? onRender,
}) => PaseoDraggableList<String>(
  data: data,
  keyExtractor: (item, index) => item,
  onDragEnd: onDragEnd,
  useDragHandle: useDragHandle,
  header: header,
  footer: footer,
  empty: empty,
  onDragBegin: onDragBegin,
  onDragIntent: onDragIntent,
  onDragRelease: onDragRelease,
  translate: translate,
  renderItem: (context, info) {
    onRender?.call(info);
    final row = SizedBox(
      height: _rowHeight,
      child: Text(info.item, key: ValueKey<String>('row-${info.item}')),
    );
    final handle = info.dragHandleProps;
    return handle == null ? row : handle.wrap(row);
  },
);

/// Drags [gesture] by [dy] logical pixels in small increments.
///
/// `SliverReorderableList` re-evaluates which row the proxy overlaps once per
/// pointer-move, so a single 96px jump would only ever swap one slot. Stepping
/// mirrors how a real finger moves and is the only way the multi-slot cases
/// below exercise the real drop target.
Future<void> dragBy(WidgetTester tester, TestGesture gesture, double dy) async {
  const double step = 8;
  final int steps = (dy.abs() / step).ceil();
  for (var i = 0; i < steps; i += 1) {
    final double remaining = dy - (dy.sign * step * i);
    final double delta = remaining.abs() < step ? remaining : dy.sign * step;
    await gesture.moveBy(Offset(0, delta));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Presses row [from], drags it by [dy] logical pixels, and releases.
Future<void> dragRow(WidgetTester tester, String from, double dy) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(ValueKey<String>('row-$from'))),
  );
  await tester.pump(_pastHoldDelay);
  await dragBy(tester, gesture, dy);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('material-file-icons.ts — SVG_ICONS', () {
    test('carries every entry, and the count is pinned', () {
      expect(materialFileIconSvgs, hasLength(materialFileIconSvgCount));
      expect(materialFileIconSvgCount, 54);
    });

    test('key set matches the frozen table exactly', () {
      expect(materialFileIconSvgs.keys.toList(), <String>[
        '_default',
        'astro',
        'c',
        'clojure',
        'console',
        'cpp',
        'csharp',
        'css',
        'dart',
        'database',
        'document',
        'elixir',
        'erlang',
        'go',
        'gradle',
        'graphql',
        'groovy',
        'h',
        'haskell',
        'hcl',
        'hpp',
        'html',
        'image',
        'java',
        'javascript',
        'json',
        'kotlin',
        'less',
        'lock',
        'lua',
        'markdown',
        'nix',
        'ocaml',
        'php',
        'python',
        'r',
        'react',
        'react_ts',
        'ruby',
        'rust',
        'sass',
        'scala',
        'settings',
        'svelte',
        'svg',
        'swift',
        'terraform',
        'toml',
        'typescript',
        'vue',
        'webassembly',
        'xml',
        'yaml',
        'zig',
      ]);
    });

    test('every payload is a self-contained svg document', () {
      for (final MapEntry<String, String> entry
          in materialFileIconSvgs.entries) {
        expect(
          entry.value,
          startsWith('<svg'),
          reason: '${entry.key} must be inline svg',
        );
        expect(entry.value, endsWith('</svg>'), reason: entry.key);
        expect(entry.value, contains('<path'), reason: entry.key);
      }
    });

    test('the default glyph is present under its documented key', () {
      expect(materialFileIconDefaultName, '_default');
      expect(
        materialFileIconSvgs.containsKey(materialFileIconDefaultName),
        isTrue,
      );
    });
  });

  group('material-file-icons.ts — EXTENSION_TO_ICON', () {
    test('is carried over entry-for-entry', () {
      expect(materialFileIconNameByExtension, <String, String>{
        'astro': 'astro',
        'bash': 'console',
        'c': 'c',
        'cfg': 'settings',
        'clj': 'clojure',
        'conf': 'settings',
        'cpp': 'cpp',
        'cs': 'csharp',
        'css': 'css',
        'dart': 'dart',
        'erl': 'erlang',
        'ex': 'elixir',
        'exs': 'elixir',
        'gif': 'image',
        'go': 'go',
        'gql': 'graphql',
        'gradle': 'gradle',
        'graphql': 'graphql',
        'groovy': 'groovy',
        'h': 'h',
        'hcl': 'hcl',
        'hpp': 'hpp',
        'hs': 'haskell',
        'html': 'html',
        'ico': 'image',
        'ini': 'settings',
        'java': 'java',
        'jpeg': 'image',
        'jpg': 'image',
        'js': 'javascript',
        'json': 'json',
        'jsx': 'react',
        'kt': 'kotlin',
        'less': 'less',
        'lock': 'lock',
        'lua': 'lua',
        'markdown': 'markdown',
        'md': 'markdown',
        'ml': 'ocaml',
        'nix': 'nix',
        'php': 'php',
        'png': 'image',
        'py': 'python',
        'r': 'r',
        'rb': 'ruby',
        'rs': 'rust',
        'scala': 'scala',
        'scss': 'sass',
        'sh': 'console',
        'sql': 'database',
        'svelte': 'svelte',
        'svg': 'svg',
        'swift': 'swift',
        'tf': 'terraform',
        'toml': 'toml',
        'ts': 'typescript',
        'tsx': 'react_ts',
        'txt': 'document',
        'vue': 'vue',
        'wasm': 'webassembly',
        'webp': 'image',
        'xml': 'xml',
        'yaml': 'yaml',
        'yml': 'yaml',
        'zig': 'zig',
      });
    });

    test('count is pinned and larger than the glyph table', () {
      expect(
        materialFileIconNameByExtension,
        hasLength(materialFileIconExtensionCount),
      );
      expect(materialFileIconExtensionCount, 65);
      expect(
        materialFileIconExtensionCount,
        greaterThan(materialFileIconSvgCount),
      );
    });

    test('every mapped glyph exists', () {
      for (final String name in materialFileIconNameByExtension.values) {
        expect(
          materialFileIconSvgs.containsKey(name),
          isTrue,
          reason: 'missing glyph "$name"',
        );
      }
    });

    test('no glyph other than the default is unreachable', () {
      final reachable = materialFileIconNameByExtension.values.toSet();
      final orphans = materialFileIconSvgs.keys
          .where(
            (k) => k != materialFileIconDefaultName && !reachable.contains(k),
          )
          .toList();
      expect(orphans, isEmpty);
    });

    test('extensions are stored lowercase and without a leading dot', () {
      for (final String extension in materialFileIconNameByExtension.keys) {
        expect(extension, extension.toLowerCase());
        expect(extension.startsWith('.'), isFalse);
      }
    });
  });

  group('materialFileIconExtension', () {
    test('returns the lowercased text after the final dot', () {
      expect(materialFileIconExtension('main.dart'), 'dart');
      expect(materialFileIconExtension('README.MD'), 'md');
      expect(materialFileIconExtension('component.test.tsx'), 'tsx');
    });

    test('returns null when there is no extension to read', () {
      expect(materialFileIconExtension('Makefile'), isNull);
      expect(materialFileIconExtension(''), isNull);
    });

    test('rejects a trailing dot rather than yielding an empty extension', () {
      expect(materialFileIconExtension('archive.'), isNull);
      expect(materialFileIconExtension('.'), isNull);
    });

    test('treats a dotfile name as an extension, matching lastIndexOf', () {
      // ".gitignore" has its dot at index 0, so upstream reads "gitignore" as
      // the extension; it is simply not in the table and falls back.
      expect(materialFileIconExtension('.gitignore'), 'gitignore');
    });
  });

  group('getFileIconSvg', () {
    test('resolves every mapped extension to its glyph', () {
      for (final MapEntry<String, String> entry
          in materialFileIconNameByExtension.entries) {
        expect(
          getFileIconSvg('file.${entry.key}'),
          materialFileIconSvgs[entry.value],
          reason: entry.key,
        );
      }
    });

    test('is case-insensitive on the extension', () {
      expect(getFileIconSvg('App.TSX'), materialFileIconSvgs['react_ts']);
      expect(getFileIconSvg('Main.Dart'), materialFileIconSvgs['dart']);
    });

    test('uses only the final extension of a multi-dot name', () {
      expect(getFileIconSvg('a.dart.ts'), materialFileIconSvgs['typescript']);
    });

    test('falls back to the default glyph', () {
      final fallback = materialFileIconSvgs[materialFileIconDefaultName];
      expect(getFileIconSvg('Makefile'), fallback);
      expect(getFileIconSvg('archive.'), fallback);
      expect(getFileIconSvg('notes.unknownext'), fallback);
      expect(getFileIconSvg('.gitignore'), fallback);
      expect(getFileIconSvg(''), fallback);
    });

    test('never returns an empty string', () {
      for (final String name in <String>['a.ts', 'b', 'c.', '.d', '']) {
        expect(getFileIconSvg(name), isNotEmpty);
      }
    });
  });

  group('MaterialFileIcon', () {
    testWidgets('renders the mapped svg at the requested size', (tester) async {
      await pumpList(
        tester,
        const Center(child: MaterialFileIcon(fileName: 'main.dart', size: 20)),
      );
      final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(picture.width, 20);
      expect(picture.height, 20);
      // No tint: the material-icon-theme payloads carry their own fills.
      expect(picture.colorFilter, isNull);
    });

    testWidgets('an unknown file still renders the default glyph', (
      tester,
    ) async {
      await pumpList(
        tester,
        const Center(child: MaterialFileIcon(fileName: 'Makefile', size: 16)),
      );
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('createMaterialFileIcon binds the file name', (tester) async {
      final builder = createMaterialFileIcon('app.tsx');
      await pumpList(tester, Center(child: builder(24)));
      final icon = tester.widget<MaterialFileIcon>(
        find.byType(MaterialFileIcon),
      );
      expect(icon.fileName, 'app.tsx');
      expect(icon.size, 24);
    });
  });

  group('frozen constants', () {
    test('activation config matches DRAG_ACTIVATION_CONFIG', () {
      expect(paseoDraggableListActivationConfig.movementDistance, 6);
      expect(paseoDraggableListActivationConfig.touchHoldDelayMs, 180);
      expect(paseoDraggableListActivationConfig.touchHoldTolerance, 8);
    });

    test('drag styling matches the web inline style', () {
      expect(paseoDraggableListDragOpacity, 0.9);
      expect(paseoDraggableListDragScale, 1.02);
    });

    test('without a handle both pointers activate on the frozen distance', () {
      final constraints = getDragActivationConstraints(
        false,
        paseoDraggableListActivationConfig,
      );
      expect(
        constraints.mouse,
        const DistanceActivationConstraint(distance: 6),
      );
      expect(
        constraints.touch,
        const DistanceActivationConstraint(distance: 6),
      );
    });

    test('with a handle touch becomes a 180ms press-and-hold', () {
      final constraints = getDragActivationConstraints(
        true,
        paseoDraggableListActivationConfig,
      );
      expect(
        constraints.mouse,
        const DistanceActivationConstraint(distance: 6),
      );
      expect(
        constraints.touch,
        const DelayActivationConstraint(delayMs: 180, tolerance: 8),
      );
    });
  });

  group('paseoDraggableListProxyDecorator', () {
    testWidgets('applies the frozen lift to the dragged row', (tester) async {
      const marker = ValueKey<String>('proxy');
      await pumpList(
        tester,
        Center(
          child: KeyedSubtree(
            key: marker,
            child: paseoDraggableListProxyDecorator(
              const SizedBox(width: 10, height: 10),
              0,
              const AlwaysStoppedAnimation<double>(1),
            ),
          ),
        ),
      );
      Finder within(Type type) =>
          find.descendant(of: find.byKey(marker), matching: find.byType(type));
      expect(
        tester.widget<Opacity>(within(Opacity)).opacity,
        paseoDraggableListDragOpacity,
      );
      expect(
        tester
            .widget<Transform>(within(Transform))
            .transform
            .getMaxScaleOnAxis(),
        closeTo(paseoDraggableListDragScale, 1e-9),
      );
    });
  });

  group('paseoDraggableListShowsRefreshControl', () {
    bool shows({
      bool hasOnRefresh = true,
      bool isDragging = false,
      bool refreshing = false,
      bool nestable = false,
    }) => paseoDraggableListShowsRefreshControl(
      hasOnRefresh: hasOnRefresh,
      isDragging: isDragging,
      refreshing: refreshing,
      nestable: nestable,
    );

    test('requires a refresh handler', () {
      expect(shows(hasOnRefresh: false), isFalse);
      expect(shows(), isTrue);
    });

    test('hides while dragging so the pull cannot steal the gesture', () {
      expect(shows(isDragging: true), isFalse);
    });

    test('stays visible if a refresh was already running', () {
      expect(shows(isDragging: true, refreshing: true), isTrue);
    });

    test('is always off for a nestable list', () {
      expect(shows(nestable: true), isFalse);
      expect(shows(refreshing: true, nestable: true), isFalse);
    });
  });

  group('paseoDraggableListOverKey', () {
    const items = <String>['a', 'b', 'c', 'd'];
    String keyOf(String item, int index) => item;

    String? overKey(int destinationIndex) => paseoDraggableListOverKey<String>(
      items: items,
      destinationIndex: destinationIndex,
      keyExtractor: keyOf,
    );

    test('names the row at the destination index', () {
      expect(overKey(0), 'a');
      expect(overKey(2), 'c');
      expect(overKey(3), 'd');
    });

    test('returns null for an index outside the list', () {
      expect(overKey(-1), isNull);
      expect(overKey(4), isNull);
    });

    test('feeds reorderItemsOnDragEnd to reproduce arrayMove downward', () {
      // Drag "a" below "c": destination index 2 names "c".
      expect(
        reorderItemsOnDragEnd<String>(
          items: items,
          activeId: 'a',
          overId: overKey(2),
          keyExtractor: keyOf,
        ),
        <String>['b', 'c', 'a', 'd'],
      );
    });

    test('feeds reorderItemsOnDragEnd to reproduce arrayMove upward', () {
      // Drag "d" above "b": destination index 1 names "b".
      expect(
        reorderItemsOnDragEnd<String>(
          items: items,
          activeId: 'd',
          overId: overKey(1),
          keyExtractor: keyOf,
        ),
        <String>['a', 'd', 'b', 'c'],
      );
    });
  });

  group('PaseoDraggableList — rendering', () {
    testWidgets('renders every row in order', (tester) async {
      await pumpList(
        tester,
        buildList(data: const <String>['a', 'b', 'c'], onDragEnd: (_) {}),
      );
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      expect(find.text('c'), findsOneWidget);
    });

    testWidgets('renders header and footer around the rows', (tester) async {
      await pumpList(
        tester,
        buildList(
          data: const <String>['a'],
          onDragEnd: (_) {},
          header: const Text('HEAD'),
          footer: const Text('FOOT'),
        ),
      );
      expect(find.text('HEAD'), findsOneWidget);
      expect(find.text('FOOT'), findsOneWidget);
      final head = tester.getTopLeft(find.text('HEAD')).dy;
      final row = tester.getTopLeft(find.text('a')).dy;
      final foot = tester.getTopLeft(find.text('FOOT')).dy;
      expect(head, lessThan(row));
      expect(row, lessThan(foot));
    });

    testWidgets('shows the empty slot only when there is no data', (
      tester,
    ) async {
      await pumpList(
        tester,
        buildList(
          data: const <String>[],
          onDragEnd: (_) {},
          empty: const Text('EMPTY'),
        ),
      );
      expect(find.text('EMPTY'), findsOneWidget);

      await pumpList(
        tester,
        buildList(
          data: const <String>['a'],
          onDragEnd: (_) {},
          empty: const Text('EMPTY'),
        ),
      );
      expect(find.text('EMPTY'), findsNothing);
    });

    testWidgets('rows start idle, with no drag handle by default', (
      tester,
    ) async {
      final seen = <PaseoDraggableRenderItemInfo<String>>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b'],
          onDragEnd: (_) {},
          onRender: seen.add,
        ),
      );
      expect(seen.every((info) => !info.isActive), isTrue);
      expect(seen.every((info) => info.dragHandleProps == null), isTrue);
      expect(seen.map((info) => info.index), containsAll(<int>[0, 1]));
    });

    testWidgets('useDragHandle hands each row its own handle props', (
      tester,
    ) async {
      final seen = <PaseoDraggableRenderItemInfo<String>>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b'],
          onDragEnd: (_) {},
          useDragHandle: true,
          onRender: seen.add,
        ),
      );
      final props = seen.map((info) => info.dragHandleProps).toList();
      expect(props.every((p) => p != null), isTrue);
      expect(props.first!.index, 0);
      expect(
        props.first!.constraint,
        const DelayActivationConstraint(delayMs: 180, tolerance: 8),
      );
    });

    testWidgets('drag() reports intent without starting a drag', (
      tester,
    ) async {
      var intents = 0;
      var ends = 0;
      final seen = <PaseoDraggableRenderItemInfo<String>>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b'],
          onDragEnd: (_) => ends += 1,
          onDragIntent: () => intents += 1,
          onRender: seen.add,
        ),
      );
      seen.first.drag();
      expect(intents, 1);
      expect(ends, 0);
    });
  });

  group('PaseoDraggableList — translation', () {
    testWidgets('falls back to the frozen English handle label', (
      tester,
    ) async {
      final seen = <PaseoDraggableRenderItemInfo<String>>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a'],
          onDragEnd: (_) {},
          useDragHandle: true,
          onRender: seen.add,
        ),
      );
      expect(seen.first.dragHandleProps!.semanticsLabel, 'Drag to reorder');
    });

    testWidgets('uses the injected translator when it resolves', (
      tester,
    ) async {
      final seen = <PaseoDraggableRenderItemInfo<String>>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a'],
          onDragEnd: (_) {},
          useDragHandle: true,
          translate: (key) => '<$key>',
          onRender: seen.add,
        ),
      );
      expect(
        seen.first.dragHandleProps!.semanticsLabel,
        '<draggableList.dragHandle>',
      );
    });

    test('a translator that echoes the key falls back to English', () {
      expect(
        paseoDraggableListString(
          'draggableList.dragHandle',
          translate: (key) => key,
        ),
        'Drag to reorder',
      );
      expect(
        paseoDraggableListString(
          'draggableList.dragHandle',
          translate: (key) => '',
        ),
        'Drag to reorder',
      );
    });

    test('an unknown key degrades to the key itself', () {
      expect(paseoDraggableListString('nope.missing'), 'nope.missing');
    });
  });

  group('PaseoDraggableList — reorder', () {
    testWidgets('dragging a row down produces the dnd-kit arrayMove result', (
      tester,
    ) async {
      List<String>? result;
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b', 'c', 'd'],
          onDragEnd: (next) => result = next,
        ),
      );
      await dragRow(tester, 'a', _rowHeight * 2);
      expect(result, <String>['b', 'c', 'a', 'd']);
    });

    testWidgets('dragging a row up produces the dnd-kit arrayMove result', (
      tester,
    ) async {
      List<String>? result;
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b', 'c', 'd'],
          onDragEnd: (next) => result = next,
        ),
      );
      await dragRow(tester, 'd', -_rowHeight * 2);
      expect(result, <String>['a', 'd', 'b', 'c']);
    });

    testWidgets('a drop back onto the same slot is a no-op', (tester) async {
      var calls = 0;
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b', 'c'],
          onDragEnd: (_) => calls += 1,
        ),
      );
      await dragRow(tester, 'b', 2);
      expect(calls, 0);
    });

    // Upstream's native list fires `onRelease` the moment the finger lifts and
    // `onDragEnd` only once the row has settled into its slot, so release
    // genuinely precedes the reordered payload. Flutter's
    // onReorderEnd/onReorderItem pair lands in the same order.
    testWidgets('a drag reports begin, then release, then the new order', (
      tester,
    ) async {
      final events = <String>[];
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b', 'c'],
          onDragEnd: (_) => events.add('end'),
          onDragBegin: () => events.add('begin'),
          onDragRelease: () => events.add('release'),
        ),
      );
      await dragRow(tester, 'a', _rowHeight);
      expect(events, <String>['begin', 'release', 'end']);
    });

    testWidgets('the active row is reported to renderItem while dragging', (
      tester,
    ) async {
      final active = <String>{};
      await pumpList(
        tester,
        buildList(
          data: const <String>['a', 'b', 'c'],
          onDragEnd: (_) {},
          onRender: (info) {
            if (info.isActive) active.add(info.item);
          },
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('row-a'))),
      );
      await tester.pump(_pastHoldDelay);
      await dragBy(tester, gesture, _rowHeight);
      await tester.pumpAndSettle();
      expect(active, <String>{'a'});
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('with a handle, only the handle starts a drag', (tester) async {
      List<String>? result;
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a', 'b', 'c'],
          keyExtractor: (item, index) => item,
          onDragEnd: (next) => result = next,
          useDragHandle: true,
          renderItem: (context, info) => SizedBox(
            height: _rowHeight,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    info.item,
                    key: ValueKey<String>('body-${info.item}'),
                  ),
                ),
                info.dragHandleProps!.wrap(
                  SizedBox(
                    key: ValueKey<String>('handle-${info.item}'),
                    width: 40,
                    height: _rowHeight,
                    child: const Icon(FluentIcons.more),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Dragging the body does nothing.
      await tester.drag(
        find.byKey(const ValueKey<String>('body-a')),
        const Offset(0, _rowHeight),
      );
      await tester.pumpAndSettle();
      expect(result, isNull);

      // Dragging the handle, after the frozen 180ms hold, reorders.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('handle-a'))),
      );
      await tester.pump(_pastHoldDelay);
      await dragBy(tester, gesture, _rowHeight);
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(result, <String>['b', 'a', 'c']);
    });

    testWidgets('a handle press shorter than 180ms never becomes a drag', (
      tester,
    ) async {
      List<String>? result;
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a', 'b', 'c'],
          keyExtractor: (item, index) => item,
          onDragEnd: (next) => result = next,
          useDragHandle: true,
          renderItem: (context, info) => info.dragHandleProps!.wrap(
            SizedBox(
              key: ValueKey<String>('handle-${info.item}'),
              height: _rowHeight,
              child: Text(info.item),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('handle-a'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await dragBy(tester, gesture, _rowHeight);
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('PaseoDraggableList — drag snapshot', () {
    testWidgets('keeps rendering the list as it looked at drag start', (
      tester,
    ) async {
      final data = ValueNotifier<List<String>>(const <String>['a', 'b', 'c']);
      addTearDown(data.dispose);
      await pumpList(
        tester,
        ValueListenableBuilder<List<String>>(
          valueListenable: data,
          builder: (context, value, _) => PaseoDraggableList<String>(
            data: value,
            keyExtractor: (item, index) => item,
            onDragEnd: (_) {},
            renderItem: (context, info) => SizedBox(
              height: _rowHeight,
              child: Text(info.item, key: ValueKey<String>('row-${info.item}')),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('row-a'))),
      );
      await tester.pump(_pastHoldDelay);
      await dragBy(tester, gesture, _rowHeight);
      await tester.pumpAndSettle();

      // A refetch lands mid-gesture; the snapshot held by dragStateReducer is
      // what keeps the rows from teleporting under the pointer.
      data.value = const <String>['x', 'y'];
      await tester.pump();
      expect(find.text('a'), findsOneWidget);
      expect(find.text('c'), findsOneWidget);
      expect(find.text('x'), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      // Once the drag clears, the live data takes over again.
      expect(find.text('x'), findsOneWidget);
      expect(find.text('a'), findsNothing);
    });
  });

  group('PaseoDraggableList — scrolling', () {
    testWidgets('scrollEnabled false disables the internal scroll', (
      tester,
    ) async {
      await pumpList(
        tester,
        SingleChildScrollView(
          child: PaseoDraggableList<String>(
            data: List<String>.generate(20, (i) => 'item$i'),
            keyExtractor: (item, index) => item,
            scrollEnabled: false,
            onDragEnd: (_) {},
            renderItem: (context, info) =>
                SizedBox(height: _rowHeight, child: Text(info.item)),
          ),
        ),
      );
      final scrollable = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollable.shrinkWrap, isTrue);
      expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('scrollEnabled true keeps the list its own scroll owner', (
      tester,
    ) async {
      await pumpList(
        tester,
        buildList(data: const <String>['a', 'b'], onDragEnd: (_) {}),
      );
      final scrollable = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollable.shrinkWrap, isFalse);
      // [ScrollView] substitutes its own default when none is supplied; the
      // contract here is only that it is *not* the disabled physics.
      expect(scrollable.physics, isNot(isA<NeverScrollableScrollPhysics>()));
    });

    testWidgets('listKey addresses the scroll view, not the widget', (
      tester,
    ) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          listKey: const ValueKey<String>('project-list'),
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('project-list')),
        findsOneWidget,
      );
      expect(
        tester.widget(find.byKey(const ValueKey<String>('project-list'))),
        isA<CustomScrollView>(),
      );
    });

    testWidgets('contentContainerFlexGrow fills the remaining viewport', (
      tester,
    ) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          contentContainerFlexGrow: true,
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(find.byType(SliverFillRemaining), findsOneWidget);
    });

    testWidgets('a non-scrolling list has nothing to fill', (tester) async {
      await pumpList(
        tester,
        SingleChildScrollView(
          child: PaseoDraggableList<String>(
            data: const <String>['a'],
            keyExtractor: (item, index) => item,
            onDragEnd: (_) {},
            scrollEnabled: false,
            contentContainerFlexGrow: true,
            renderItem: (context, info) =>
                SizedBox(height: _rowHeight, child: Text(info.item)),
          ),
        ),
      );
      expect(find.byType(SliverFillRemaining), findsNothing);
    });

    testWidgets('showsVerticalScrollIndicator toggles the scrollbar', (
      tester,
    ) async {
      // Pinned to a desktop platform because that is the only family whose
      // default [ScrollBehavior] paints a scrollbar at all; on the test
      // default (android) both branches would look identical.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        for (final bool shows in <bool>[true, false]) {
          await pumpList(
            tester,
            PaseoDraggableList<String>(
              data: const <String>['a'],
              keyExtractor: (item, index) => item,
              onDragEnd: (_) {},
              showsVerticalScrollIndicator: shows,
              renderItem: (context, info) =>
                  SizedBox(height: _rowHeight, child: Text(info.item)),
            ),
          );
          const child = Placeholder();
          final element = tester.element(find.byType(CustomScrollView));
          final decorated = ScrollConfiguration.of(element).buildScrollbar(
            element,
            child,
            const ScrollableDetails(direction: AxisDirection.down),
          );
          expect(
            identical(decorated, child),
            shows ? isFalse : isTrue,
            reason: 'showsVerticalScrollIndicator: $shows',
          );
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('padding wraps the slivers', (tester) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          padding: const EdgeInsets.all(12),
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(
        tester.widget<SliverPadding>(find.byType(SliverPadding)).padding,
        const EdgeInsets.all(12),
      );
      expect(tester.getTopLeft(find.text('a')).dx, 12);
    });
  });

  group('PaseoDraggableList — refresh', () {
    testWidgets('shows a progress bar while refreshing', (tester) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          refreshing: true,
          onRefresh: () {},
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(find.byType(ProgressBar), findsOneWidget);
    });

    testWidgets('a nestable list never shows one', (tester) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          refreshing: true,
          nestable: true,
          onRefresh: () {},
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(find.byType(ProgressBar), findsNothing);
    });

    testWidgets('no handler means no progress bar', (tester) async {
      await pumpList(
        tester,
        PaseoDraggableList<String>(
          data: const <String>['a'],
          keyExtractor: (item, index) => item,
          onDragEnd: (_) {},
          refreshing: true,
          renderItem: (context, info) =>
              SizedBox(height: _rowHeight, child: Text(info.item)),
        ),
      );
      expect(find.byType(ProgressBar), findsNothing);
    });
  });
}
