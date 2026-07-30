import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/diff_flat_items.dart';
import 'package:flutter_test/flutter_test.dart';

DiffFile file(String path, [int additions = 1, int deletions = 0]) => DiffFile(
  path: path,
  status: DiffFileStatus.modified,
  additions: additions,
  deletions: deletions,
);

List<String> summarize(List<DiffFlatItem> items) => [
  for (final item in items)
    switch (item) {
      final DiffFlatFolderItem folder =>
        '${'  ' * folder.depth}[${folder.displayName}]'
            '${folder.collapsed ? ' (collapsed)' : ''}',
      final DiffFlatHeaderItem header =>
        '${'  ' * header.depth}${header.file.path.split('/').last}',
      final DiffFlatBodyItem body =>
        '${'  ' * body.depth}body:${body.file.path.split('/').last}',
    },
];

void main() {
  final files = [file('src/app/a.ts'), file('src/app/nested/b.ts')];

  test('emits a body and sticky index for each expanded file', () {
    final result = buildDiffFlatItems(
      files: [file('a.ts'), file('b.ts')],
      treeView: true,
      collapsedFolders: {},
      expandedPaths: {'a.ts'},
    );

    expect(summarize(result.items), ['a.ts', 'body:a.ts', 'b.ts']);
    expect(result.stickyHeaderIndices, [0]);
    expect(result.items[0], isA<DiffFlatHeaderItem>());
  });

  test('flat view omits folders and indentation', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: false,
      collapsedFolders: {},
      expandedPaths: {'src/app/a.ts'},
    );

    expect(summarize(result.items), ['a.ts', 'body:a.ts', 'b.ts']);
    expect(result.stickyHeaderIndices, [0]);
    expect(result.items.whereType<DiffFlatFolderItem>(), isEmpty);
  });

  test('tree view groups files under compressed folders', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: true,
      collapsedFolders: {},
      expandedPaths: {},
    );

    expect(summarize(result.items), [
      '[src/app]',
      '  [nested]',
      '    b.ts',
      '  a.ts',
    ]);
  });

  test('collapsing a folder hides descendants but keeps its row', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: true,
      collapsedFolders: {'src/app/nested'},
      expandedPaths: {},
    );

    expect(summarize(result.items), [
      '[src/app]',
      '  [nested] (collapsed)',
      '  a.ts',
    ]);
  });

  test('collapsing an ancestor hides everything below it', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: true,
      collapsedFolders: {'src/app'},
      expandedPaths: {},
    );

    expect(summarize(result.items), ['[src/app] (collapsed)']);
  });

  test('sticky indices use the final post-collapse item list', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: true,
      collapsedFolders: {},
      expandedPaths: {'src/app/a.ts'},
    );

    expect(summarize(result.items), [
      '[src/app]',
      '  [nested]',
      '    b.ts',
      '  a.ts',
      '  body:a.ts',
    ]);
    expect(result.stickyHeaderIndices, [3]);
    expect(
      result.stickyHeaderIndices.map((index) => result.items[index]),
      everyElement(isA<DiffFlatHeaderItem>()),
    );
  });

  test('tree rows retain the original sorted-file index', () {
    final result = buildDiffFlatItems(
      files: files,
      treeView: true,
      collapsedFolders: {},
      expandedPaths: {},
    );

    expect(
      result.items.whereType<DiffFlatHeaderItem>().map(
        (item) => item.fileIndex,
      ),
      [1, 0],
    );
  });

  test('sums item heights before a clamped index', () {
    final items = buildDiffFlatItems(
      files: [file('src/a.ts'), file('src/b.ts')],
      treeView: true,
      collapsedFolders: {},
      expandedPaths: {},
    ).items;
    double heightFor(DiffFlatItem item) => item is DiffFlatFolderItem ? 10 : 20;

    expect(sumDiffItemHeightsBefore(items, 0, heightFor), 0);
    expect(sumDiffItemHeightsBefore(items, 1, heightFor), 10);
    expect(sumDiffItemHeightsBefore(items, 2, heightFor), 30);
    expect(sumDiffItemHeightsBefore(items, 999, heightFor), 50);
    expect(sumDiffItemHeightsBefore(items, -1, heightFor), 0);
  });
}
