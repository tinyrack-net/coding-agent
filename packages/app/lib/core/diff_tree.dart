import 'package:agent_protocol/agent_protocol.dart';

sealed class DiffTreeNode {
  const DiffTreeNode();
}

final class DiffTreeFileNode extends DiffTreeNode {
  const DiffTreeFileNode({required this.file, required this.name});

  final DiffFile file;
  final String name;
}

final class DiffTreeDirNode extends DiffTreeNode {
  const DiffTreeDirNode({
    required this.dirPath,
    required this.name,
    required this.children,
  });

  final String dirPath;
  final String name;
  final List<DiffTreeNode> children;
}

sealed class DiffTreeRow {
  const DiffTreeRow({required this.depth});

  final int depth;
}

final class DiffTreeFolderRow extends DiffTreeRow {
  const DiffTreeFolderRow({
    required this.dirPath,
    required this.displayName,
    required super.depth,
    required this.additions,
    required this.deletions,
  });

  final String dirPath;
  final String displayName;
  final int additions;
  final int deletions;
}

final class DiffTreeFileRow extends DiffTreeRow {
  const DiffTreeFileRow({required this.file, required super.depth});

  final DiffFile file;
}

DiffTreeDirNode buildDiffTree(List<DiffFile> files) {
  final root = DiffTreeDirNode(dirPath: '', name: '', children: []);
  final directories = <String, DiffTreeDirNode>{'': root};

  DiffTreeDirNode ensureDirectory(String dirPath) {
    final existing = directories[dirPath];
    if (existing != null) return existing;
    final parts = dirPath.split('/');
    final name = parts.last;
    final parentPath = parts.take(parts.length - 1).join('/');
    final parent = ensureDirectory(parentPath);
    final node = DiffTreeDirNode(dirPath: dirPath, name: name, children: []);
    parent.children.add(node);
    directories[dirPath] = node;
    return node;
  }

  for (final file in files) {
    final parts = file.path.split('/');
    final name = parts.last;
    final dirPath = parts.take(parts.length - 1).join('/');
    ensureDirectory(
      dirPath,
    ).children.add(DiffTreeFileNode(file: file, name: name));
  }
  _sortTree(root);
  return root;
}

DiffTreeDirNode compressSingleChildChains(DiffTreeDirNode root) =>
    DiffTreeDirNode(
      dirPath: root.dirPath,
      name: root.name,
      children: [
        for (final child in root.children)
          child is DiffTreeDirNode ? _compressNode(child) : child,
      ],
    );

List<DiffTreeRow> flattenDiffTree(DiffTreeDirNode root, Set<String> collapsed) {
  final stats = _computeDirectoryStats(root);
  final rows = <DiffTreeRow>[];

  void walk(DiffTreeDirNode node, int depth) {
    for (final child in node.children) {
      if (child is DiffTreeFileNode) {
        rows.add(DiffTreeFileRow(file: child.file, depth: depth));
      } else if (child is DiffTreeDirNode) {
        final childStats = stats[child] ?? (additions: 0, deletions: 0);
        rows.add(
          DiffTreeFolderRow(
            dirPath: child.dirPath,
            displayName: child.name,
            depth: depth,
            additions: childStats.additions,
            deletions: childStats.deletions,
          ),
        );
        if (!collapsed.contains(child.dirPath)) walk(child, depth + 1);
      }
    }
  }

  walk(root, 0);
  return rows;
}

List<String> collectDirPaths(DiffTreeDirNode root) {
  final paths = <String>[];
  void walk(DiffTreeDirNode node) {
    for (final child in node.children) {
      if (child is DiffTreeDirNode) {
        paths.add(child.dirPath);
        walk(child);
      }
    }
  }

  walk(root);
  return paths;
}

void _sortTree(DiffTreeDirNode node) {
  node.children.sort((left, right) {
    if (left.runtimeType != right.runtimeType) {
      return left is DiffTreeDirNode ? -1 : 1;
    }
    final leftName = switch (left) {
      DiffTreeDirNode(:final name) || DiffTreeFileNode(:final name) => name,
    };
    final rightName = switch (right) {
      DiffTreeDirNode(:final name) || DiffTreeFileNode(:final name) => name,
    };
    return leftName.compareTo(rightName);
  });
  for (final child in node.children) {
    if (child is DiffTreeDirNode) _sortTree(child);
  }
}

DiffTreeDirNode _compressNode(DiffTreeDirNode node) {
  var name = node.name;
  var dirPath = node.dirPath;
  var children = [
    for (final child in node.children)
      child is DiffTreeDirNode ? _compressNode(child) : child,
  ];
  while (children.length == 1 && children.single is DiffTreeDirNode) {
    final only = children.single as DiffTreeDirNode;
    name = name.isEmpty ? only.name : '$name/${only.name}';
    dirPath = only.dirPath;
    children = only.children;
  }
  return DiffTreeDirNode(dirPath: dirPath, name: name, children: children);
}

Map<DiffTreeDirNode, ({int additions, int deletions})> _computeDirectoryStats(
  DiffTreeDirNode root,
) {
  final stats = <DiffTreeDirNode, ({int additions, int deletions})>{};
  ({int additions, int deletions}) visit(DiffTreeDirNode node) {
    var additions = 0;
    var deletions = 0;
    for (final child in node.children) {
      if (child is DiffTreeFileNode) {
        additions += child.file.additions;
        deletions += child.file.deletions;
      } else if (child is DiffTreeDirNode) {
        final childStats = visit(child);
        additions += childStats.additions;
        deletions += childStats.deletions;
      }
    }
    final result = (additions: additions, deletions: deletions);
    stats[node] = result;
    return result;
  }

  visit(root);
  return stats;
}
