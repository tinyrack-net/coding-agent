import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/diff_tree.dart';
import 'package:flutter_test/flutter_test.dart';

DiffFile createFile(String path, {int additions = 1, int deletions = 0}) =>
    DiffFile(
      path: path,
      status: DiffFileStatus.modified,
      additions: additions,
      deletions: deletions,
    );

DiffTreeDirNode tree(List<DiffFile> files) => buildDiffTree(files);

DiffTreeDirNode compressed(List<DiffFile> files) =>
    compressSingleChildChains(tree(files));

List<String> rowLabels(List<DiffTreeRow> rows) => [
  for (final row in rows)
    switch (row) {
      DiffTreeFolderRow(:final displayName, :final depth) =>
        '${List.filled(depth, '  ').join()}[$displayName]',
      DiffTreeFileRow(:final file, :final depth) =>
        '${List.filled(depth, '  ').join()}${file.path.split('/').last}',
    },
];

void main() {
  group('buildDiffTree', () {
    test('returns an empty virtual root for no files', () {
      final root = tree(const []);
      expect(root.dirPath, '');
      expect(root.children, isEmpty);
    });

    test('places sorted root files directly under the root', () {
      final root = tree([createFile('package.json'), createFile('README.md')]);
      expect(root.children.map((node) => (node as DiffTreeFileNode).name), [
        'README.md',
        'package.json',
      ]);
    });

    test('nests directories under stable full-path identities', () {
      final root = tree([
        createFile('src/a.ts'),
        createFile('src/nested/b.ts'),
      ]);
      final src = root.children.single as DiffTreeDirNode;
      expect(src.dirPath, 'src');
      final nested = src.children.whereType<DiffTreeDirNode>().single;
      expect(nested.dirPath, 'src/nested');
    });

    test('sorts directories before files and each group by ASCII name', () {
      final root = tree([
        createFile('src/a.ts'),
        createFile('src/z/deep.ts'),
        createFile('src/m/mid.ts'),
      ]);
      final src = root.children.single as DiffTreeDirNode;
      expect(
        src.children.map(
          (node) => switch (node) {
            DiffTreeDirNode(:final name) => 'dir:$name',
            DiffTreeFileNode(:final name) => 'file:$name',
          },
        ),
        ['dir:m', 'dir:z', 'file:a.ts'],
      );
    });
  });

  group('compressSingleChildChains', () {
    test('compresses to the deepest stable directory identity', () {
      final rows = flattenDiffTree(
        compressed([createFile('packages/app/src/git/diff-pane.tsx')]),
        {},
      );
      expect(rowLabels(rows), ['[packages/app/src/git]', '  diff-pane.tsx']);
      expect((rows.first as DiffTreeFolderRow).dirPath, 'packages/app/src/git');
    });

    test('stops compression at a directory with multiple children', () {
      final rows = flattenDiffTree(
        compressed([
          createFile('packages/app/a.ts'),
          createFile('packages/server/b.ts'),
        ]),
        {},
      );
      expect(rowLabels(rows), [
        '[packages]',
        '  [app]',
        '    a.ts',
        '  [server]',
        '    b.ts',
      ]);
    });

    test('compresses a chain ending in a file-bearing directory', () {
      final rows = flattenDiffTree(
        compressed([createFile('a/b/c/one.ts'), createFile('a/b/c/two.ts')]),
        {},
      );
      expect(rowLabels(rows), ['[a/b/c]', '  one.ts', '  two.ts']);
    });

    test('never merges the virtual root into its child', () {
      final rows = flattenDiffTree(
        compressed([createFile('only/deep/file.ts')]),
        {},
      );
      expect((rows.first as DiffTreeFolderRow).displayName, 'only/deep');
    });
  });

  group('flattenDiffTree', () {
    test('expands all descendants when collapsed is empty', () {
      final rows = flattenDiffTree(
        compressed([createFile('src/a.ts'), createFile('src/b.ts')]),
        {},
      );
      expect(rowLabels(rows), ['[src]', '  a.ts', '  b.ts']);
    });

    test('keeps a collapsed folder and omits every descendant', () {
      final root = compressed([
        createFile('src/deep/a.ts'),
        createFile('src/top.ts'),
      ]);
      expect(rowLabels(flattenDiffTree(root, {'src'})), ['[src]']);
    });

    test('aggregates full descendant stats when expanded and collapsed', () {
      final root = compressed([
        createFile('src/a.ts', additions: 3, deletions: 1),
        createFile('src/nested/b.ts', additions: 5, deletions: 2),
      ]);
      final expanded = flattenDiffTree(root, {});
      final folder = expanded.whereType<DiffTreeFolderRow>().firstWhere(
        (row) => row.dirPath == 'src',
      );
      expect((folder.additions, folder.deletions), (8, 3));

      final collapsed = flattenDiffTree(root, {'src'});
      final collapsedFolder = collapsed.single as DiffTreeFolderRow;
      expect((collapsedFolder.additions, collapsedFolder.deletions), (8, 3));
    });
  });

  test('collectDirPaths returns every compressed logical directory path', () {
    final root = compressed([
      createFile('packages/app/a.ts'),
      createFile('packages/server/b.ts'),
    ]);
    expect(collectDirPaths(root)..sort(), [
      'packages',
      'packages/app',
      'packages/server',
    ]);
  });
}
