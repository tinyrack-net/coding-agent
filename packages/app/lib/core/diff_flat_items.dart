import 'package:agent_protocol/agent_protocol.dart';

import 'diff_tree.dart';

sealed class DiffFlatItem {
  const DiffFlatItem({required this.depth});

  final int depth;
}

final class DiffFlatFolderItem extends DiffFlatItem {
  const DiffFlatFolderItem({
    required this.dirPath,
    required this.displayName,
    required super.depth,
    required this.collapsed,
    required this.additions,
    required this.deletions,
  });

  final String dirPath;
  final String displayName;
  final bool collapsed;
  final int additions;
  final int deletions;
}

sealed class DiffFlatFileItem extends DiffFlatItem {
  const DiffFlatFileItem({
    required this.file,
    required this.fileIndex,
    required super.depth,
  });

  final DiffFile file;
  final int fileIndex;
}

final class DiffFlatHeaderItem extends DiffFlatFileItem {
  const DiffFlatHeaderItem({
    required super.file,
    required super.fileIndex,
    required super.depth,
    required this.isExpanded,
  });

  final bool isExpanded;
}

final class DiffFlatBodyItem extends DiffFlatFileItem {
  const DiffFlatBodyItem({
    required super.file,
    required super.fileIndex,
    required super.depth,
  });
}

final class DiffFlatItemsResult {
  const DiffFlatItemsResult({
    required this.items,
    required this.stickyHeaderIndices,
  });

  final List<DiffFlatItem> items;
  final List<int> stickyHeaderIndices;
}

DiffFlatItemsResult buildDiffFlatItems({
  required List<DiffFile> files,
  required bool treeView,
  required Set<String> collapsedFolders,
  required Set<String> expandedPaths,
  DiffTreeDirNode? tree,
}) {
  final items = <DiffFlatItem>[];
  final stickyHeaderIndices = <int>[];

  void pushFile(DiffFile file, int fileIndex, int depth) {
    final isExpanded = expandedPaths.contains(file.path);
    items.add(
      DiffFlatHeaderItem(
        file: file,
        fileIndex: fileIndex,
        depth: depth,
        isExpanded: isExpanded,
      ),
    );
    if (!isExpanded) return;
    stickyHeaderIndices.add(items.length - 1);
    items.add(DiffFlatBodyItem(file: file, fileIndex: fileIndex, depth: depth));
  }

  if (!treeView) {
    for (var index = 0; index < files.length; index++) {
      pushFile(files[index], index, 0);
    }
    return DiffFlatItemsResult(
      items: items,
      stickyHeaderIndices: stickyHeaderIndices,
    );
  }

  final indexByPath = <String, int>{
    for (var index = 0; index < files.length; index++) files[index].path: index,
  };
  final compressedTree =
      tree ?? compressSingleChildChains(buildDiffTree(files));
  final rows = flattenDiffTree(compressedTree, collapsedFolders);
  for (final row in rows) {
    switch (row) {
      case final DiffTreeFolderRow folder:
        items.add(
          DiffFlatFolderItem(
            dirPath: folder.dirPath,
            displayName: folder.displayName,
            depth: folder.depth,
            collapsed: collapsedFolders.contains(folder.dirPath),
            additions: folder.additions,
            deletions: folder.deletions,
          ),
        );
      case final DiffTreeFileRow fileRow:
        final fileIndex = indexByPath[fileRow.file.path];
        if (fileIndex != null) {
          pushFile(fileRow.file, fileIndex, fileRow.depth);
        }
    }
  }
  return DiffFlatItemsResult(
    items: items,
    stickyHeaderIndices: stickyHeaderIndices,
  );
}

double sumDiffItemHeightsBefore(
  List<DiffFlatItem> items,
  int index,
  double Function(DiffFlatItem item) heightFor,
) {
  var offset = 0.0;
  final end = index.clamp(0, items.length);
  for (var itemIndex = 0; itemIndex < end; itemIndex++) {
    offset += heightFor(items[itemIndex]);
  }
  return offset < 0 ? 0 : offset;
}
