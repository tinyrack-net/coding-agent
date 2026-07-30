import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diff_flat_items.dart';
import '../../core/diff_highlight.dart';
import '../../core/diff_order.dart';
import '../../core/diff_rendering.dart';
import '../../core/diff_scroll.dart';
import '../../core/diff_tree.dart';
import '../../core/theme.dart';
import '../../state/changes_preferences_provider.dart';
import '../../state/review_draft_provider.dart';
import '../file_actions_menu.dart';
import '../code_insets.dart';
import '../shortcut_badge.dart';
import '../syntax_token_styles.dart';
import 'diff_scroll.dart';
import 'diff_stat.dart';

/// Color/icon/letter mapping for a diff file status.
(Color, IconData, String) diffStatusStyle(DiffFileStatus status) =>
    switch (status) {
      DiffFileStatus.added => (Colors.green, FluentIcons.add, 'A'),
      DiffFileStatus.modified => (Colors.yellow, FluentIcons.edit, 'M'),
      DiffFileStatus.deleted => (Colors.red, FluentIcons.delete, 'D'),
      DiffFileStatus.renamed => (
        Colors.purple,
        FluentIcons.move_to_folder,
        'R',
      ),
    };

class DiffViewController extends ChangeNotifier {
  final Set<String> _expandedPaths = {};
  final Set<String> _collapsedFolders = {};

  Set<String> get expandedPaths => Set.unmodifiable(_expandedPaths);
  Set<String> get collapsedFolders => Set.unmodifiable(_collapsedFolders);

  void reconcile(List<DiffFile> files) {
    final paths = files.map((file) => file.path).toSet();
    final folders = collectDirPaths(
      compressSingleChildChains(buildDiffTree(files)),
    ).toSet();
    _expandedPaths.retainAll(paths);
    _collapsedFolders.retainAll(folders);
  }

  void toggleFile(String path) {
    if (!_expandedPaths.remove(path)) _expandedPaths.add(path);
    notifyListeners();
  }

  void toggleFolder(String path) {
    if (!_collapsedFolders.remove(path)) _collapsedFolders.add(path);
    notifyListeners();
  }

  void enterTreeView() {
    if (_collapsedFolders.isEmpty) return;
    _collapsedFolders.clear();
    notifyListeners();
  }

  bool allExpanded(List<DiffFile> files, ChangesViewMode viewMode) {
    if (files.isEmpty) return false;
    final everyFile = files.every((file) => _expandedPaths.contains(file.path));
    if (!everyFile || viewMode != ChangesViewMode.tree) return everyFile;
    final folders = collectDirPaths(
      compressSingleChildChains(buildDiffTree(files)),
    ).toSet();
    return _collapsedFolders.every((path) => !folders.contains(path));
  }

  void toggleExpandAll(List<DiffFile> files, ChangesViewMode viewMode) {
    reconcile(files);
    if (allExpanded(files, viewMode)) {
      _expandedPaths.clear();
      if (viewMode == ChangesViewMode.tree) {
        _collapsedFolders.addAll(
          collectDirPaths(compressSingleChildChains(buildDiffTree(files))),
        );
      }
    } else {
      _expandedPaths
        ..clear()
        ..addAll(files.map((file) => file.path));
      if (viewMode == ChangesViewMode.tree) _collapsedFolders.clear();
    }
    notifyListeners();
  }
}

/// Paseo-compatible expandable file diff list.
class DiffView extends ConsumerStatefulWidget {
  const DiffView({
    super.key,
    required this.diff,
    this.reviewDraftKey,
    this.layout = ChangesLayout.unified,
    this.viewMode = ChangesViewMode.flat,
    this.wrapLines = false,
    this.codeFontSize = 12,
    this.monoFontFamily = '',
    this.controller,
    this.focusPath,
    this.focusRequestId,
    this.onOpenFile,
    this.onCopyPath,
    this.onDownload,
    this.onAddToChat,
  });

  final DiffResponse diff;
  final String? reviewDraftKey;
  final ChangesLayout layout;
  final ChangesViewMode viewMode;
  final bool wrapLines;
  final double codeFontSize;
  final String monoFontFamily;
  final DiffViewController? controller;
  final String? focusPath;
  final int? focusRequestId;
  final ValueChanged<String>? onOpenFile;
  final ValueChanged<String>? onCopyPath;
  final ValueChanged<String>? onDownload;
  final ValueChanged<String>? onAddToChat;

  @override
  ConsumerState<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends ConsumerState<DiffView> {
  late DiffViewController _controller;
  late bool _ownsController;
  final _scrollController = ScrollController();
  final _headerKeys = <String, GlobalKey>{};
  final _folderKeys = <String, GlobalKey>{};
  DiffResponse? _highlightSource;
  DiffResponse? _highlightedDiff;
  String? _consumedFocusRequest;
  String? _pendingFocusRequest;
  _ReviewEditorTarget? _reviewEditor;

  @override
  void initState() {
    super.initState();
    _attachController(widget.controller);
  }

  void _attachController(DiffViewController? controller) {
    _controller = controller ?? DiffViewController();
    _ownsController = controller == null;
    _controller.addListener(_handleControllerChanged);
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_handleControllerChanged);
      if (_ownsController) _controller.dispose();
      _attachController(widget.controller);
    }
    if (oldWidget.reviewDraftKey != widget.reviewDraftKey) {
      _reviewEditor = null;
    }
    if (oldWidget.focusPath != widget.focusPath ||
        oldWidget.focusRequestId != widget.focusRequestId) {
      _pendingFocusRequest = null;
    }
    _controller.reconcile(widget.diff.files);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    if (_ownsController) _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _headerKey(String path) =>
      _headerKeys.putIfAbsent(path, GlobalKey.new);

  GlobalKey _folderKey(String path) =>
      _folderKeys.putIfAbsent(path, GlobalKey.new);

  void _toggleFile(String path) {
    final isExpanded = _controller.expandedPaths.contains(path);
    if (isExpanded) _anchorBeforeCollapse(_headerKey(path));
    _controller.toggleFile(path);
  }

  void _toggleFolder(String path) {
    final isCollapsed = _controller.collapsedFolders.contains(path);
    if (!isCollapsed) _anchorBeforeCollapse(_folderKey(path));
    _controller.toggleFolder(path);
  }

  void _anchorBeforeCollapse(GlobalKey itemKey) {
    if (!_scrollController.hasClients) return;
    final renderObject = itemKey.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return;
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0).offset;
    final itemHeight = renderObject.paintBounds.height;
    final position = _scrollController.position;
    final shouldAnchor = shouldAnchorHeaderBeforeCollapse(
      AnchorVisibilityInput(
        headerOffset: targetOffset,
        headerHeight: itemHeight,
        viewportOffset: position.pixels,
        viewportHeight: position.viewportDimension,
      ),
    );
    if (!shouldAnchor) return;
    _scrollController.jumpTo(
      targetOffset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  DiffResponse _resolveHighlightedDiff() {
    if (identical(_highlightSource, widget.diff)) return _highlightedDiff!;
    _highlightSource = widget.diff;
    return _highlightedDiff = highlightLegacyDiff(widget.diff);
  }

  void _scheduleFocusRequest(List<DiffFlatItem> items) {
    final path = widget.focusPath;
    if (path == null || path.isEmpty) return;
    final requestKey = '${widget.focusRequestId ?? 'initial'}:$path';
    if (_consumedFocusRequest == requestKey ||
        _pendingFocusRequest == requestKey) {
      return;
    }
    final hasTarget = items.any(
      (item) => item is DiffFlatHeaderItem && item.file.path == path,
    );
    if (!hasTarget) return;

    _pendingFocusRequest = requestKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _pendingFocusRequest != requestKey ||
          widget.focusPath != path ||
          '${widget.focusRequestId ?? 'initial'}:${widget.focusPath}' !=
              requestKey) {
        return;
      }
      final renderObject = _headerKey(path).currentContext?.findRenderObject();
      if (!_scrollController.hasClients ||
          renderObject == null ||
          !renderObject.attached) {
        _pendingFocusRequest = null;
        return;
      }
      final viewport = RenderAbstractViewport.maybeOf(renderObject);
      if (viewport == null) {
        _pendingFocusRequest = null;
        return;
      }
      final position = _scrollController.position;
      final offset = viewport.getOffsetToReveal(renderObject, 0).offset;
      _scrollController.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _consumedFocusRequest = requestKey;
      _pendingFocusRequest = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final files = orderLegacyDiffFiles(_resolveHighlightedDiff().files);
    if (files.isEmpty) return const _NoChanges();
    _controller.reconcile(files);
    final reviewKey = widget.reviewDraftKey;
    final comments = reviewKey == null
        ? const <ReviewDraftComment>[]
        : ref.watch(
            reviewDraftProvider.select(
              (state) => state.drafts[reviewKey] ?? const [],
            ),
          );
    final review = reviewKey == null
        ? null
        : _ReviewViewModel(
            comments: comments,
            editor: _reviewEditor,
            onStart: (target) => setState(
              () => _reviewEditor = _ReviewEditorTarget(target: target),
            ),
            onEdit: (target, comment) => setState(
              () => _reviewEditor = _ReviewEditorTarget(
                target: target,
                commentId: comment.id,
                initialBody: comment.body,
              ),
            ),
            onCancel: () => setState(() => _reviewEditor = null),
            onSave: (body) {
              final editor = _reviewEditor;
              if (editor == null || body.trim().isEmpty) return;
              final notifier = ref.read(reviewDraftProvider.notifier);
              if (editor.commentId == null) {
                notifier.add(
                  key: reviewKey,
                  filePath: editor.target.filePath,
                  side: editor.target.side,
                  lineNumber: editor.target.lineNumber,
                  body: body,
                );
              } else {
                notifier.updateComment(
                  key: reviewKey,
                  id: editor.commentId!,
                  body: body,
                );
              }
              setState(() => _reviewEditor = null);
            },
            onDelete: (id) {
              ref
                  .read(reviewDraftProvider.notifier)
                  .delete(key: reviewKey, id: id);
              if (_reviewEditor?.commentId == id) {
                setState(() => _reviewEditor = null);
              }
            },
          );

    return _DiffMetricsScope(
      metrics: _DiffMetrics(
        fontSize: widget.codeFontSize,
        monoFontFamily: widget.monoFontFamily,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout =
              widget.layout == ChangesLayout.split &&
                  constraints.maxWidth >= 840 &&
                  (kIsWeb ||
                      defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux)
              ? ChangesLayout.split
              : ChangesLayout.unified;
          final result = buildDiffFlatItems(
            files: files,
            treeView: widget.viewMode == ChangesViewMode.tree,
            collapsedFolders: _controller.collapsedFolders,
            expandedPaths: _controller.expandedPaths,
          );
          _scheduleFocusRequest(result.items);
          final stickyIndices = result.stickyHeaderIndices.toSet();
          return CustomScrollView(
            key: const ValueKey('git-diff-scroll'),
            controller: _scrollController,
            slivers: [
              for (var index = 0; index < result.items.length; index++)
                switch (result.items[index]) {
                  final DiffFlatFolderItem folder => SliverToBoxAdapter(
                    child: KeyedSubtree(
                      key: _folderKey(folder.dirPath),
                      child: _DiffFolderRow(
                        folder: folder,
                        onToggle: () => _toggleFolder(folder.dirPath),
                      ),
                    ),
                  ),
                  final DiffFlatHeaderItem header
                      when stickyIndices.contains(index) =>
                    PinnedHeaderSliver(
                      child: KeyedSubtree(
                        key: _headerKey(header.file.path),
                        child: ColoredBox(
                          color: context.paseoPalette.surface1,
                          child: _DiffFileHeader(
                            item: header,
                            showDirectory:
                                widget.viewMode == ChangesViewMode.flat,
                            onToggle: () => _toggleFile(header.file.path),
                            onOpenFile: widget.onOpenFile,
                            onCopyPath: widget.onCopyPath,
                            onDownload: widget.onDownload,
                            onAddToChat: widget.onAddToChat,
                          ),
                        ),
                      ),
                    ),
                  final DiffFlatHeaderItem header => SliverToBoxAdapter(
                    child: KeyedSubtree(
                      key: _headerKey(header.file.path),
                      child: _DiffFileHeader(
                        item: header,
                        showDirectory: widget.viewMode == ChangesViewMode.flat,
                        onToggle: () => _toggleFile(header.file.path),
                        onOpenFile: widget.onOpenFile,
                        onCopyPath: widget.onCopyPath,
                        onDownload: widget.onDownload,
                        onAddToChat: widget.onAddToChat,
                      ),
                    ),
                  ),
                  final DiffFlatBodyItem body => SliverToBoxAdapter(
                    child: Padding(
                      key: ValueKey('diff-file-${body.fileIndex}-body'),
                      padding: EdgeInsets.only(left: body.depth * 16.0),
                      child: _FileDiffBody(
                        file: body.file,
                        review: review,
                        layout: layout,
                        wrapLines: widget.wrapLines,
                      ),
                    ),
                  ),
                },
            ],
          );
        },
      ),
    );
  }
}

final class _DiffMetrics {
  _DiffMetrics({required double fontSize, required String monoFontFamily})
    : fontSize = fontSize.floorToDouble().clamp(9, 22),
      fontFamily = monoFontFamily.trim().isEmpty
          ? 'monospace'
          : monoFontFamily.trim();

  final double fontSize;
  final String fontFamily;

  double get lineHeight => (fontSize * 1.5).roundToDouble();

  TextStyle get textStyle => TextStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    height: lineHeight / fontSize,
  );
}

class _DiffMetricsScope extends InheritedWidget {
  const _DiffMetricsScope({required this.metrics, required super.child});

  final _DiffMetrics metrics;

  static _DiffMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DiffMetricsScope>()!.metrics;

  @override
  bool updateShouldNotify(_DiffMetricsScope oldWidget) =>
      metrics.fontSize != oldWidget.metrics.fontSize ||
      metrics.fontFamily != oldWidget.metrics.fontFamily;
}

class _FileDiffMetricsScope extends InheritedWidget {
  const _FileDiffMetricsScope({
    required this.gutterWidth,
    required super.child,
  });

  final double gutterWidth;

  static double of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FileDiffMetricsScope>()!
      .gutterWidth;

  @override
  bool updateShouldNotify(_FileDiffMetricsScope oldWidget) =>
      gutterWidth != oldWidget.gutterWidth;
}

class _NoChanges extends StatelessWidget {
  const _NoChanges();

  @override
  Widget build(BuildContext context) {
    final outline = context.tokens.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.completed_solid, size: 48, color: outline),
          const SizedBox(height: 12),
          Text('No changes', style: TextStyle(color: outline)),
          const SizedBox(height: 4),
          Text(
            'The working tree is clean.',
            style: context.textStyles.bodySmall?.copyWith(color: outline),
          ),
        ],
      ),
    );
  }
}

class _DiffFolderRow extends StatelessWidget {
  const _DiffFolderRow({required this.folder, required this.onToggle});

  final DiffFlatFolderItem folder;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('diff-folder-${folder.dirPath}'),
      padding: EdgeInsets.only(left: folder.depth * 16.0),
      child: ListTile(
        onPressed: onToggle,
        leading: Icon(
          folder.collapsed
              ? FluentIcons.chevron_right
              : FluentIcons.chevron_down,
          size: 12,
        ),
        title: Row(
          children: [
            const Icon(FluentIcons.folder, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                folder.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            DiffStat(additions: folder.additions, deletions: folder.deletions),
          ],
        ),
      ),
    );
  }
}

class _DiffFileHeader extends StatefulWidget {
  const _DiffFileHeader({
    required this.item,
    required this.showDirectory,
    required this.onToggle,
    this.onOpenFile,
    this.onCopyPath,
    this.onDownload,
    this.onAddToChat,
  });

  final DiffFlatHeaderItem item;
  final bool showDirectory;
  final VoidCallback onToggle;
  final ValueChanged<String>? onOpenFile;
  final ValueChanged<String>? onCopyPath;
  final ValueChanged<String>? onDownload;
  final ValueChanged<String>? onAddToChat;

  @override
  State<_DiffFileHeader> createState() => _DiffFileHeaderState();
}

class _DiffFileHeaderState extends State<_DiffFileHeader> {
  final _actionsKey = GlobalKey<FileActionsMenuState>();

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('diff-file-${widget.item.fileIndex}'),
      padding: EdgeInsets.only(left: widget.item.depth * 16.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTap: () => unawaited(_actionsKey.currentState?.show()),
        child: ListTile(
          onPressed: widget.onToggle,
          leading: Icon(
            widget.item.isExpanded
                ? FluentIcons.chevron_down
                : FluentIcons.chevron_right,
            size: 12,
          ),
          title: _FileRowLabel(
            file: widget.item.file,
            pathLabel: widget.showDirectory
                ? null
                : _treeFileLabel(widget.item.file),
            actions: FileActionsMenu(
              key: _actionsKey,
              path: widget.item.file.path,
              fileExists: widget.item.file.status != DiffFileStatus.deleted,
              testIdPrefix: 'diff-file-${widget.item.fileIndex}',
              onOpenFile: widget.onOpenFile,
              onCopyPath: widget.onCopyPath,
              onDownload: widget.onDownload,
              onAddToChat: widget.onAddToChat,
            ),
          ),
        ),
      ),
    );
  }
}

/// Status icon + path + add/del counts; shared by both layouts.
class _FileRowLabel extends StatelessWidget {
  const _FileRowLabel({required this.file, this.pathLabel, this.actions});

  final DiffFile file;
  final String? pathLabel;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final (color, icon, _) = diffStatusStyle(file.status);
    final path =
        pathLabel ??
        (file.status == DiffFileStatus.renamed && file.oldPath != null
            ? '${file.oldPath} → ${file.path}'
            : file.path);
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textStyles.bodyMedium,
          ),
        ),
        const SizedBox(width: 8),
        DiffStat(additions: file.additions, deletions: file.deletions),
        if (actions != null) ...[const SizedBox(width: 4), actions!],
      ],
    );
  }
}

String _treeFileLabel(DiffFile file) {
  String basename(String path) => path.split('/').last;
  if (file.status == DiffFileStatus.renamed && file.oldPath != null) {
    return '${basename(file.oldPath!)} → ${basename(file.path)}';
  }
  return basename(file.path);
}

/// Unified diff for a single file: hunk headers + numbered, tinted lines.
class _FileDiffBody extends StatelessWidget {
  const _FileDiffBody({
    required this.file,
    required this.layout,
    required this.wrapLines,
    this.review,
  });

  final DiffFile file;
  final ChangesLayout layout;
  final bool wrapLines;
  final _ReviewViewModel? review;

  @override
  Widget build(BuildContext context) {
    final outline = context.tokens.outline;
    if (file.tooLarge) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FluentIcons.warning, size: 18, color: outline),
            const SizedBox(width: 8),
            Text('Diff too large to display', style: TextStyle(color: outline)),
          ],
        ),
      );
    }
    if (file.binary) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FluentIcons.document, size: 18, color: outline),
            const SizedBox(width: 8),
            Text('Binary file', style: TextStyle(color: outline)),
          ],
        ),
      );
    }
    if (file.hunks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('No textual changes', style: TextStyle(color: outline)),
        ),
      );
    }
    final metrics = _DiffMetricsScope.of(context);
    final maxLineNumber = file.hunks
        .expand((hunk) => hunk.lines)
        .fold<int>(
          0,
          (maximum, line) => [
            maximum,
            line.oldLineNo ?? 0,
            line.newLineNo ?? 0,
          ].reduce((left, right) => left > right ? left : right),
        );
    final gutterWidth = lineNumberGutterWidth(maxLineNumber, metrics.fontSize);
    final Widget contents;
    if (layout == ChangesLayout.split) {
      contents = _SplitFileDiffBody(
        file: file,
        review: review,
        wrapLines: wrapLines,
      );
    } else {
      final unified = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final hunk in file.hunks) ...[
            _HunkHeader(header: hunk.header),
            for (final line in hunk.lines)
              _ReviewableDiffLine(
                filePath: file.path,
                line: line,
                review: review,
                wrapLines: wrapLines,
              ),
          ],
        ],
      );
      contents = wrapLines
          ? unified
          : _ScrollableUnifiedDiffBody(file: file, review: review);
    }
    return _FileDiffMetricsScope(gutterWidth: gutterWidth, child: contents);
  }
}

_ReviewTarget? _reviewTargetForLine(String filePath, DiffLine line) =>
    switch (line.type) {
      DiffLineType.del when line.oldLineNo != null => _ReviewTarget(
        filePath: filePath,
        side: ReviewAttachmentSide.old,
        lineNumber: line.oldLineNo!,
      ),
      DiffLineType.add when line.newLineNo != null => _ReviewTarget(
        filePath: filePath,
        side: ReviewAttachmentSide.newLine,
        lineNumber: line.newLineNo!,
      ),
      DiffLineType.context when line.newLineNo != null => _ReviewTarget(
        filePath: filePath,
        side: ReviewAttachmentSide.newLine,
        lineNumber: line.newLineNo!,
      ),
      _ => null,
    };

int? _unifiedLineNumber(DiffLine line) =>
    line.type == DiffLineType.del ? line.oldLineNo : line.newLineNo;

class _ScrollableUnifiedDiffBody extends StatefulWidget {
  const _ScrollableUnifiedDiffBody({required this.file, required this.review});

  final DiffFile file;
  final _ReviewViewModel? review;

  @override
  State<_ScrollableUnifiedDiffBody> createState() =>
      _ScrollableUnifiedDiffBodyState();
}

class _ScrollableUnifiedDiffBodyState
    extends State<_ScrollableUnifiedDiffBody> {
  String? _hoveredTargetKey;
  String? _dismissedTargetKey;

  bool get _isPointerFirstPlatform =>
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  void _startReview(_ReviewTarget target) {
    final review = widget.review;
    if (review == null) return;
    setState(() => _dismissedTargetKey = target.key);
    review.onStart(target);
  }

  void _setHoveredTarget(String? key) {
    setState(() {
      _hoveredTargetKey = key;
      if (key == null) _dismissedTargetKey = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final gutterWidth = _FileDiffMetricsScope.of(context);
    final pinnedReviews = _unifiedPinnedReviewEntries(
      widget.file,
      widget.review,
      metrics.lineHeight,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          key: const ValueKey('diff-fixed-gutter'),
          width: gutterWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final hunk in widget.file.hunks) ...[
                const _FixedGutterHeader(),
                for (final line in hunk.lines)
                  _UnifiedGutterBlock(
                    key: ValueKey(
                      'diff-gutter-block-'
                      '${_reviewTargetForLine(widget.file.path, line)?.key ?? line.text}',
                    ),
                    line: line,
                    target: _reviewTargetForLine(widget.file.path, line),
                    review: widget.review,
                    hoveredTargetKey: _hoveredTargetKey,
                    dismissedTargetKey: _dismissedTargetKey,
                    onStartReview: _startReview,
                  ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Stack(
            key: const ValueKey('diff-code-viewport'),
            clipBehavior: Clip.hardEdge,
            children: [
              DiffScroll(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final hunk in widget.file.hunks) ...[
                      _HunkHeader(header: hunk.header),
                      for (final line in hunk.lines)
                        _UnifiedCodeBlock(
                          key: ValueKey(
                            'diff-code-block-'
                            '${_reviewTargetForLine(widget.file.path, line)?.key ?? line.text}',
                          ),
                          filePath: widget.file.path,
                          line: line,
                          review: widget.review,
                          pointerFirst: _isPointerFirstPlatform,
                          onHoverTargetChanged: _setHoveredTarget,
                          onStartReview: _startReview,
                        ),
                    ],
                  ],
                ),
              ),
              for (final entry in pinnedReviews)
                Positioned(
                  key: ValueKey('pinned-review-slot-${entry.target.key}'),
                  top: entry.top,
                  left: 0,
                  right: 0,
                  height: entry.height,
                  child: _InlineReviewThread(
                    target: entry.target,
                    comments: entry.state.comments,
                    editor: entry.state.editor,
                    review: widget.review!,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FixedGutterHeader extends StatelessWidget {
  const _FixedGutterHeader();

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    return Container(
      height: metrics.lineHeight,
      decoration: BoxDecoration(
        color: context.tokens.surfaceContainerHighest,
        border: Border(
          right: BorderSide(color: context.paseoPalette.borderAccent),
        ),
      ),
    );
  }
}

class _UnifiedGutterBlock extends StatelessWidget {
  const _UnifiedGutterBlock({
    super.key,
    required this.line,
    required this.target,
    required this.review,
    required this.hoveredTargetKey,
    required this.dismissedTargetKey,
    required this.onStartReview,
  });

  final DiffLine line;
  final _ReviewTarget? target;
  final _ReviewViewModel? review;
  final String? hoveredTargetKey;
  final String? dismissedTargetKey;
  final ValueChanged<_ReviewTarget> onStartReview;

  @override
  Widget build(BuildContext context) {
    final threadState = _reviewThreadState(target, review);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FixedUnifiedGutterRow(
          line: line,
          target: target,
          hasComments: threadState?.comments.isNotEmpty ?? false,
          showReviewAction:
              target != null &&
              review != null &&
              hoveredTargetKey == target!.key &&
              dismissedTargetKey != target!.key,
          onAddReview: target == null ? null : () => onStartReview(target!),
        ),
        if ((threadState?.height ?? 0) > 0)
          SizedBox(
            height: threadState!.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.paseoPalette.surface1,
                border: Border(
                  right: BorderSide(color: context.paseoPalette.borderAccent),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FixedUnifiedGutterRow extends StatelessWidget {
  const _FixedUnifiedGutterRow({
    required this.line,
    required this.target,
    required this.hasComments,
    required this.showReviewAction,
    required this.onAddReview,
  });

  final DiffLine line;
  final _ReviewTarget? target;
  final bool hasComments;
  final bool showReviewAction;
  final VoidCallback? onAddReview;

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final background = switch (line.type) {
      DiffLineType.add => Colors.green.withValues(alpha: 0.12),
      DiffLineType.del => Colors.red.withValues(alpha: 0.12),
      DiffLineType.context => null,
    };
    final outline = context.tokens.outline;
    return Container(
      height: metrics.lineHeight,
      decoration: BoxDecoration(
        color: background,
        border: Border(
          right: BorderSide(color: context.paseoPalette.borderAccent),
        ),
      ),
      child: _ReviewGutterContent(
        lineNumber: _unifiedLineNumber(line),
        textStyle: metrics.textStyle.copyWith(color: outline),
        hasComments: hasComments,
        showReviewAction: showReviewAction,
        reviewTarget: target,
        onAddReview: onAddReview,
      ),
    );
  }
}

class _ReviewGutterContent extends StatelessWidget {
  const _ReviewGutterContent({
    required this.lineNumber,
    required this.textStyle,
    required this.hasComments,
    required this.showReviewAction,
    required this.reviewTarget,
    required this.onAddReview,
  });

  final int? lineNumber;
  final TextStyle textStyle;
  final bool hasComments;
  final bool showReviewAction;
  final _ReviewTarget? reviewTarget;
  final VoidCallback? onAddReview;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: hasComments ? context.paseoPalette.surface2 : Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                formatDiffGutterText(lineNumber),
                maxLines: 1,
                style: textStyle,
              ),
            ),
          ),
          if (showReviewAction)
            Tooltip(
              message: 'Add review comment',
              child: GestureDetector(
                key: ValueKey('review-add-${reviewTarget!.key}'),
                behavior: HitTestBehavior.opaque,
                onTap: onAddReview,
                child: Icon(
                  FluentIcons.add,
                  size: 16,
                  color: context.paseoPalette.accentBright,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnifiedCodeBlock extends StatelessWidget {
  const _UnifiedCodeBlock({
    super.key,
    required this.filePath,
    required this.line,
    required this.review,
    required this.pointerFirst,
    required this.onHoverTargetChanged,
    required this.onStartReview,
  });

  final String filePath;
  final DiffLine line;
  final _ReviewViewModel? review;
  final bool pointerFirst;
  final ValueChanged<String?> onHoverTargetChanged;
  final ValueChanged<_ReviewTarget> onStartReview;

  @override
  Widget build(BuildContext context) {
    final target = _reviewTargetForLine(filePath, line);
    final threadState = _reviewThreadState(target, review);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScrollableCodeLine(
          key: ValueKey('diff-code-${target?.key ?? line.text}'),
          line: line,
          target: target,
          canReview: target != null && review != null,
          onHoverTargetChanged: onHoverTargetChanged,
          onTap: !pointerFirst && target != null && review != null
              ? () => onStartReview(target)
              : null,
        ),
        if (target != null &&
            review != null &&
            threadState != null &&
            threadState.height > 0)
          SizedBox(height: threadState.height),
      ],
    );
  }
}

class _ScrollableCodeLine extends StatelessWidget {
  const _ScrollableCodeLine({
    super.key,
    required this.line,
    required this.target,
    required this.canReview,
    required this.onHoverTargetChanged,
    required this.onTap,
  });

  final DiffLine line;
  final _ReviewTarget? target;
  final bool canReview;
  final ValueChanged<String?> onHoverTargetChanged;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final dark = FluentTheme.of(context).brightness == Brightness.dark;
    final (background, marker, textColor) = switch (line.type) {
      DiffLineType.add => (
        Colors.green.withValues(alpha: 0.12),
        '+',
        dark ? Colors.green.light : Colors.green.dark,
      ),
      DiffLineType.del => (
        Colors.red.withValues(alpha: 0.12),
        '-',
        dark ? Colors.red.light : Colors.red.dark,
      ),
      DiffLineType.context => (null, ' ', null),
    };
    return Semantics(
      button: canReview,
      label: target == null ? null : 'Add review comment',
      child: MouseRegion(
        onEnter: (_) => onHoverTargetChanged(target?.key),
        onExit: (_) => onHoverTargetChanged(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: metrics.lineHeight,
            color: background,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  child: Text(
                    marker,
                    style: metrics.textStyle.copyWith(color: textColor),
                  ),
                ),
                _DiffContentText(
                  line: line,
                  softWrap: false,
                  style: metrics.textStyle.copyWith(color: textColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

sealed class _SplitDiffRow {
  const _SplitDiffRow();
}

final class _SplitDiffHeaderRow extends _SplitDiffRow {
  const _SplitDiffHeaderRow(this.header);

  final String header;
}

final class _SplitDiffCell {
  const _SplitDiffCell({required this.line, required this.target});

  final DiffLine line;
  final _ReviewTarget target;
}

final class _SplitDiffPairRow extends _SplitDiffRow {
  const _SplitDiffPairRow({required this.left, required this.right});

  final _SplitDiffCell? left;
  final _SplitDiffCell? right;
}

List<_SplitDiffRow> _buildSplitDiffRows(DiffFile file) {
  final rows = <_SplitDiffRow>[];
  for (final hunk in file.hunks) {
    rows.add(_SplitDiffHeaderRow(hunk.header));
    var removals = <_SplitDiffCell>[];
    var additions = <_SplitDiffCell>[];

    void flushPending() {
      final count = removals.length > additions.length
          ? removals.length
          : additions.length;
      for (var index = 0; index < count; index++) {
        rows.add(
          _SplitDiffPairRow(
            left: index < removals.length ? removals[index] : null,
            right: index < additions.length ? additions[index] : null,
          ),
        );
      }
      removals = [];
      additions = [];
    }

    for (final line in hunk.lines) {
      switch (line.type) {
        case DiffLineType.del:
          if (line.oldLineNo case final lineNumber?) {
            removals.add(
              _SplitDiffCell(
                line: line,
                target: _ReviewTarget(
                  filePath: file.path,
                  side: ReviewAttachmentSide.old,
                  lineNumber: lineNumber,
                ),
              ),
            );
          }
        case DiffLineType.add:
          if (line.newLineNo case final lineNumber?) {
            additions.add(
              _SplitDiffCell(
                line: line,
                target: _ReviewTarget(
                  filePath: file.path,
                  side: ReviewAttachmentSide.newLine,
                  lineNumber: lineNumber,
                ),
              ),
            );
          }
        case DiffLineType.context:
          flushPending();
          final oldNumber = line.oldLineNo;
          final newNumber = line.newLineNo;
          rows.add(
            _SplitDiffPairRow(
              left: oldNumber == null
                  ? null
                  : _SplitDiffCell(
                      line: line,
                      target: _ReviewTarget(
                        filePath: file.path,
                        side: ReviewAttachmentSide.old,
                        lineNumber: oldNumber,
                      ),
                    ),
              right: newNumber == null
                  ? null
                  : _SplitDiffCell(
                      line: line,
                      target: _ReviewTarget(
                        filePath: file.path,
                        side: ReviewAttachmentSide.newLine,
                        lineNumber: newNumber,
                      ),
                    ),
            ),
          );
      }
    }
    flushPending();
  }
  return rows;
}

typedef _ReviewThreadState = ({
  List<ReviewDraftComment> comments,
  _ReviewEditorTarget? editor,
  double height,
});

typedef _PinnedReviewEntry = ({
  double top,
  double height,
  _ReviewTarget target,
  _ReviewThreadState state,
});

_ReviewThreadState? _reviewThreadState(
  _ReviewTarget? target,
  _ReviewViewModel? review,
) {
  if (target == null || review == null) return null;
  final comments = review.comments
      .where(
        (comment) =>
            comment.filePath == target.filePath &&
            comment.side == target.side &&
            comment.lineNumber == target.lineNumber,
      )
      .toList(growable: false);
  final editor = review.editor?.target.key == target.key ? review.editor : null;
  final editingExisting =
      editor?.commentId != null &&
      comments.any((comment) => comment.id == editor!.commentId);
  final visibleComments = comments.length - (editingExisting ? 1 : 0);
  final blockCount = visibleComments + (editor == null ? 0 : 1);
  if (blockCount == 0) {
    return (comments: comments, editor: editor, height: 0);
  }
  final contentHeight = visibleComments * 72.0 + (editor == null ? 0 : 132.0);
  return (
    comments: comments,
    editor: editor,
    height: 16 + contentHeight + (blockCount - 1) * 6,
  );
}

List<_PinnedReviewEntry> _unifiedPinnedReviewEntries(
  DiffFile file,
  _ReviewViewModel? review,
  double lineHeight,
) {
  var top = 0.0;
  final entries = <_PinnedReviewEntry>[];
  for (final hunk in file.hunks) {
    top += lineHeight;
    for (final line in hunk.lines) {
      final target = _reviewTargetForLine(file.path, line);
      final state = _reviewThreadState(target, review);
      top += lineHeight;
      if (target != null && state != null && state.height > 0) {
        entries.add((
          top: top,
          height: state.height,
          target: target,
          state: state,
        ));
        top += state.height;
      }
    }
  }
  return entries;
}

List<_PinnedReviewEntry> _splitPinnedReviewEntries(
  List<_SplitDiffRow> rows,
  ReviewAttachmentSide side,
  _ReviewViewModel? review,
  double lineHeight,
) {
  var top = 0.0;
  final entries = <_PinnedReviewEntry>[];
  for (final row in rows) {
    switch (row) {
      case _SplitDiffHeaderRow():
        top += lineHeight;
      case final _SplitDiffPairRow pair:
        final cell = side == ReviewAttachmentSide.old ? pair.left : pair.right;
        final pairedCell = side == ReviewAttachmentSide.old
            ? pair.right
            : pair.left;
        final state = _reviewThreadState(cell?.target, review);
        final pairedState = _reviewThreadState(pairedCell?.target, review);
        final reservedHeight = (state?.height ?? 0) > (pairedState?.height ?? 0)
            ? state?.height ?? 0
            : pairedState?.height ?? 0;
        top += lineHeight;
        if (cell != null && state != null && state.height > 0) {
          entries.add((
            top: top,
            height: reservedHeight,
            target: cell.target,
            state: state,
          ));
        }
        top += reservedHeight;
    }
  }
  return entries;
}

class _SplitFileDiffBody extends StatelessWidget {
  const _SplitFileDiffBody({
    required this.file,
    required this.review,
    required this.wrapLines,
  });

  final DiffFile file;
  final _ReviewViewModel? review;
  final bool wrapLines;

  @override
  Widget build(BuildContext context) {
    final rows = _buildSplitDiffRows(file);
    if (wrapLines) {
      return _WrappedSplitDiffBody(rows: rows, review: review);
    }
    return Row(
      key: const ValueKey('split-diff'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _ScrollableSplitColumn(
            rows: rows,
            side: ReviewAttachmentSide.old,
            review: review,
          ),
        ),
        Container(width: 1, color: context.paseoPalette.borderAccent),
        Expanded(
          child: _ScrollableSplitColumn(
            rows: rows,
            side: ReviewAttachmentSide.newLine,
            review: review,
          ),
        ),
      ],
    );
  }
}

class _WrappedSplitDiffBody extends StatelessWidget {
  const _WrappedSplitDiffBody({required this.rows, required this.review});

  final List<_SplitDiffRow> rows;
  final _ReviewViewModel? review;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('split-diff'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < rows.length; index++)
          switch (rows[index]) {
            final _SplitDiffHeaderRow header => IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _HunkHeader(
                      key: ValueKey('split-left-header-$index'),
                      header: header.header,
                    ),
                  ),
                  Container(width: 1, color: context.paseoPalette.borderAccent),
                  Expanded(
                    child: _HunkHeader(
                      key: ValueKey('split-right-header-$index'),
                      header: header.header,
                    ),
                  ),
                ],
              ),
            ),
            final _SplitDiffPairRow pair => _WrappedSplitPairRow(
              index: index,
              pair: pair,
              review: review,
            ),
          },
      ],
    );
  }
}

class _WrappedSplitPairRow extends StatelessWidget {
  const _WrappedSplitPairRow({
    required this.index,
    required this.pair,
    required this.review,
  });

  final int index;
  final _SplitDiffPairRow pair;
  final _ReviewViewModel? review;

  @override
  Widget build(BuildContext context) {
    final leftState = _reviewThreadState(pair.left?.target, review);
    final rightState = _reviewThreadState(pair.right?.target, review);
    final reservedHeight = (leftState?.height ?? 0) > (rightState?.height ?? 0)
        ? leftState?.height ?? 0
        : rightState?.height ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _WrappedSplitLineCell(
                  key: ValueKey('split-wrapped-left-row-$index'),
                  cell: pair.left,
                  side: ReviewAttachmentSide.old,
                  review: review,
                ),
              ),
              Container(width: 1, color: context.paseoPalette.borderAccent),
              Expanded(
                child: _WrappedSplitLineCell(
                  key: ValueKey('split-wrapped-right-row-$index'),
                  cell: pair.right,
                  side: ReviewAttachmentSide.newLine,
                  review: review,
                ),
              ),
            ],
          ),
        ),
        if (reservedHeight > 0)
          SizedBox(
            height: reservedHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _SplitReviewSlot(
                    cell: pair.left,
                    state: leftState,
                    review: review,
                  ),
                ),
                Container(width: 1, color: context.paseoPalette.borderAccent),
                Expanded(
                  child: _SplitReviewSlot(
                    cell: pair.right,
                    state: rightState,
                    review: review,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _WrappedSplitLineCell extends StatelessWidget {
  const _WrappedSplitLineCell({
    super.key,
    required this.cell,
    required this.side,
    required this.review,
  });

  final _SplitDiffCell? cell;
  final ReviewAttachmentSide side;
  final _ReviewViewModel? review;

  @override
  Widget build(BuildContext context) {
    final value = cell;
    if (value == null) {
      final metrics = _DiffMetricsScope.of(context);
      return Container(
        constraints: BoxConstraints(minHeight: metrics.lineHeight),
        color: context.paseoPalette.surface1,
      );
    }
    return _ReviewableDiffLine(
      filePath: value.target.filePath,
      line: value.line,
      review: review,
      reviewTarget: value.target,
      splitSide: side,
      showThread: false,
      wrapLines: true,
    );
  }
}

class _SplitReviewSlot extends StatelessWidget {
  const _SplitReviewSlot({
    required this.cell,
    required this.state,
    required this.review,
  });

  final _SplitDiffCell? cell;
  final _ReviewThreadState? state;
  final _ReviewViewModel? review;

  @override
  Widget build(BuildContext context) {
    if (cell == null || state == null || state!.height == 0 || review == null) {
      return const SizedBox.expand();
    }
    return _InlineReviewThread(
      target: cell!.target,
      comments: state!.comments,
      editor: state!.editor,
      review: review!,
      split: true,
    );
  }
}

class _ScrollableSplitColumn extends StatefulWidget {
  const _ScrollableSplitColumn({
    required this.rows,
    required this.side,
    required this.review,
  });

  final List<_SplitDiffRow> rows;
  final ReviewAttachmentSide side;
  final _ReviewViewModel? review;

  @override
  State<_ScrollableSplitColumn> createState() => _ScrollableSplitColumnState();
}

class _ScrollableSplitColumnState extends State<_ScrollableSplitColumn> {
  String? _hoveredTargetKey;
  String? _dismissedTargetKey;

  bool get _isPointerFirstPlatform =>
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  void _startReview(_ReviewTarget target) {
    final review = widget.review;
    if (review == null) return;
    setState(() => _dismissedTargetKey = target.key);
    review.onStart(target);
  }

  void _setHoveredTarget(String? key) {
    setState(() {
      _hoveredTargetKey = key;
      if (key == null) _dismissedTargetKey = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLeft = widget.side == ReviewAttachmentSide.old;
    final metrics = _DiffMetricsScope.of(context);
    final gutterWidth = _FileDiffMetricsScope.of(context);
    final pinnedReviews = _splitPinnedReviewEntries(
      widget.rows,
      widget.side,
      widget.review,
      metrics.lineHeight,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          key: ValueKey('split-${isLeft ? 'left' : 'right'}-fixed-gutter'),
          width: gutterWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < widget.rows.length; index++)
                switch (widget.rows[index]) {
                  _SplitDiffHeaderRow() => const _FixedGutterHeader(),
                  final _SplitDiffPairRow pair => _SplitGutterBlock(
                    key: ValueKey(
                      'split-${isLeft ? 'left' : 'right'}-gutter-row-$index',
                    ),
                    pair: pair,
                    cell: isLeft ? pair.left : pair.right,
                    review: widget.review,
                    hoveredTargetKey: _hoveredTargetKey,
                    dismissedTargetKey: _dismissedTargetKey,
                    onStartReview: _startReview,
                  ),
                },
            ],
          ),
        ),
        Expanded(
          child: Stack(
            key: ValueKey('split-${isLeft ? 'left' : 'right'}-code-viewport'),
            clipBehavior: Clip.hardEdge,
            children: [
              DiffScroll(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < widget.rows.length; index++)
                      switch (widget.rows[index]) {
                        final _SplitDiffHeaderRow header => _HunkHeader(
                          key: ValueKey(
                            'split-${isLeft ? 'left' : 'right'}-header-$index',
                          ),
                          header: header.header,
                        ),
                        final _SplitDiffPairRow pair => _SplitCodeBlock(
                          key: ValueKey(
                            'split-${isLeft ? 'left' : 'right'}-row-$index',
                          ),
                          pair: pair,
                          cell: isLeft ? pair.left : pair.right,
                          side: widget.side,
                          review: widget.review,
                          pointerFirst: _isPointerFirstPlatform,
                          onHoverTargetChanged: _setHoveredTarget,
                          onStartReview: _startReview,
                        ),
                      },
                  ],
                ),
              ),
              for (final entry in pinnedReviews)
                Positioned(
                  key: ValueKey('pinned-review-slot-${entry.target.key}'),
                  top: entry.top,
                  left: 0,
                  right: 0,
                  height: entry.height,
                  child: _InlineReviewThread(
                    target: entry.target,
                    comments: entry.state.comments,
                    editor: entry.state.editor,
                    review: widget.review!,
                    split: true,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SplitGutterBlock extends StatelessWidget {
  const _SplitGutterBlock({
    super.key,
    required this.pair,
    required this.cell,
    required this.review,
    required this.hoveredTargetKey,
    required this.dismissedTargetKey,
    required this.onStartReview,
  });

  final _SplitDiffPairRow pair;
  final _SplitDiffCell? cell;
  final _ReviewViewModel? review;
  final String? hoveredTargetKey;
  final String? dismissedTargetKey;
  final ValueChanged<_ReviewTarget> onStartReview;

  @override
  Widget build(BuildContext context) {
    final ownState = _reviewThreadState(cell?.target, review);
    final pairedCell = identical(cell, pair.left) ? pair.right : pair.left;
    final pairedState = _reviewThreadState(pairedCell?.target, review);
    final reservedHeight = (ownState?.height ?? 0) > (pairedState?.height ?? 0)
        ? ownState?.height ?? 0
        : pairedState?.height ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FixedSplitGutterRow(
          cell: cell,
          hasComments: ownState?.comments.isNotEmpty ?? false,
          showReviewAction:
              cell != null &&
              review != null &&
              hoveredTargetKey == cell!.target.key &&
              dismissedTargetKey != cell!.target.key,
          onAddReview: cell == null ? null : () => onStartReview(cell!.target),
        ),
        if (reservedHeight > 0)
          SizedBox(
            height: reservedHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.paseoPalette.surface1,
                border: Border(
                  right: BorderSide(color: context.paseoPalette.borderAccent),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FixedSplitGutterRow extends StatelessWidget {
  const _FixedSplitGutterRow({
    required this.cell,
    required this.hasComments,
    required this.showReviewAction,
    required this.onAddReview,
  });

  final _SplitDiffCell? cell;
  final bool hasComments;
  final bool showReviewAction;
  final VoidCallback? onAddReview;

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final line = cell?.line;
    final background = switch (line?.type) {
      DiffLineType.add => Colors.green.withValues(alpha: 0.12),
      DiffLineType.del => Colors.red.withValues(alpha: 0.12),
      _ => null,
    };
    return Container(
      height: metrics.lineHeight,
      decoration: BoxDecoration(
        color: background ?? context.paseoPalette.surface1,
        border: Border(
          right: BorderSide(color: context.paseoPalette.borderAccent),
        ),
      ),
      child: _ReviewGutterContent(
        lineNumber: cell?.target.lineNumber,
        textStyle: metrics.textStyle.copyWith(color: context.tokens.outline),
        hasComments: hasComments,
        showReviewAction: showReviewAction,
        reviewTarget: cell?.target,
        onAddReview: onAddReview,
      ),
    );
  }
}

class _SplitCodeBlock extends StatelessWidget {
  const _SplitCodeBlock({
    super.key,
    required this.pair,
    required this.cell,
    required this.side,
    required this.review,
    required this.pointerFirst,
    required this.onHoverTargetChanged,
    required this.onStartReview,
  });

  final _SplitDiffPairRow pair;
  final _SplitDiffCell? cell;
  final ReviewAttachmentSide side;
  final _ReviewViewModel? review;
  final bool pointerFirst;
  final ValueChanged<String?> onHoverTargetChanged;
  final ValueChanged<_ReviewTarget> onStartReview;

  @override
  Widget build(BuildContext context) {
    final ownState = _reviewThreadState(cell?.target, review);
    final pairedCell = identical(cell, pair.left) ? pair.right : pair.left;
    final pairedState = _reviewThreadState(pairedCell?.target, review);
    final reservedHeight = (ownState?.height ?? 0) > (pairedState?.height ?? 0)
        ? ownState?.height ?? 0
        : pairedState?.height ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScrollableSplitCodeLine(
          cell: cell,
          side: side,
          canReview: cell != null && review != null,
          onHoverTargetChanged: onHoverTargetChanged,
          onTap: !pointerFirst && cell != null && review != null
              ? () => onStartReview(cell!.target)
              : null,
        ),
        if (reservedHeight > 0) SizedBox(height: reservedHeight),
      ],
    );
  }
}

class _ScrollableSplitCodeLine extends StatelessWidget {
  const _ScrollableSplitCodeLine({
    required this.cell,
    required this.side,
    required this.canReview,
    required this.onHoverTargetChanged,
    required this.onTap,
  });

  final _SplitDiffCell? cell;
  final ReviewAttachmentSide side;
  final bool canReview;
  final ValueChanged<String?> onHoverTargetChanged;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final value = cell;
    if (value == null) {
      return Container(
        key: ValueKey(
          'split-empty-${side == ReviewAttachmentSide.old ? 'left' : 'right'}',
        ),
        height: metrics.lineHeight,
        color: context.paseoPalette.surface1,
      );
    }
    final dark = FluentTheme.of(context).brightness == Brightness.dark;
    final (background, marker, textColor) = switch (value.line.type) {
      DiffLineType.add => (
        Colors.green.withValues(alpha: 0.12),
        '+',
        dark ? Colors.green.light : Colors.green.dark,
      ),
      DiffLineType.del => (
        Colors.red.withValues(alpha: 0.12),
        '-',
        dark ? Colors.red.light : Colors.red.dark,
      ),
      DiffLineType.context => (null, ' ', null),
    };
    return Semantics(
      button: canReview,
      label: 'Add review comment',
      child: MouseRegion(
        onEnter: (_) => onHoverTargetChanged(value.target.key),
        onExit: (_) => onHoverTargetChanged(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            key: ValueKey(
              'split-line-'
              '${side == ReviewAttachmentSide.old ? 'left' : 'right'}-'
              '${value.target.key}',
            ),
            height: metrics.lineHeight,
            color: background,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  child: Text(
                    marker,
                    style: metrics.textStyle.copyWith(color: textColor),
                  ),
                ),
                _DiffContentText(
                  line: value.line,
                  softWrap: false,
                  style: metrics.textStyle.copyWith(color: textColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ReviewTarget {
  const _ReviewTarget({
    required this.filePath,
    required this.side,
    required this.lineNumber,
  });

  final String filePath;
  final ReviewAttachmentSide side;
  final int lineNumber;

  String get key =>
      '$filePath:${side == ReviewAttachmentSide.old ? 'old' : 'new'}:'
      '$lineNumber';
}

final class _ReviewEditorTarget {
  const _ReviewEditorTarget({
    required this.target,
    this.commentId,
    this.initialBody = '',
  });

  final _ReviewTarget target;
  final String? commentId;
  final String initialBody;
}

final class _ReviewViewModel {
  const _ReviewViewModel({
    required this.comments,
    required this.editor,
    required this.onStart,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    required this.onDelete,
  });

  final List<ReviewDraftComment> comments;
  final _ReviewEditorTarget? editor;
  final ValueChanged<_ReviewTarget> onStart;
  final void Function(_ReviewTarget, ReviewDraftComment) onEdit;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;
  final ValueChanged<String> onDelete;
}

class _ReviewableDiffLine extends StatefulWidget {
  const _ReviewableDiffLine({
    required this.filePath,
    required this.line,
    required this.review,
    this.reviewTarget,
    this.splitSide,
    this.showThread = true,
    this.wrapLines = false,
  });

  final String filePath;
  final DiffLine line;
  final _ReviewViewModel? review;
  final _ReviewTarget? reviewTarget;
  final ReviewAttachmentSide? splitSide;
  final bool showThread;
  final bool wrapLines;

  @override
  State<_ReviewableDiffLine> createState() => _ReviewableDiffLineState();
}

class _ReviewableDiffLineState extends State<_ReviewableDiffLine> {
  bool _hovered = false;
  bool _dismissedAfterPress = false;

  bool get _isPointerFirstPlatform =>
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final derivedTarget = switch (widget.line.type) {
      DiffLineType.del when widget.line.oldLineNo != null => _ReviewTarget(
        filePath: widget.filePath,
        side: ReviewAttachmentSide.old,
        lineNumber: widget.line.oldLineNo!,
      ),
      DiffLineType.add when widget.line.newLineNo != null => _ReviewTarget(
        filePath: widget.filePath,
        side: ReviewAttachmentSide.newLine,
        lineNumber: widget.line.newLineNo!,
      ),
      DiffLineType.context when widget.line.newLineNo != null => _ReviewTarget(
        filePath: widget.filePath,
        side: ReviewAttachmentSide.newLine,
        lineNumber: widget.line.newLineNo!,
      ),
      _ => null,
    };
    final target = widget.reviewTarget ?? derivedTarget;
    final viewModel = widget.review;
    final threadState = _reviewThreadState(target, viewModel);
    final comments = threadState?.comments ?? const <ReviewDraftComment>[];
    final editor = threadState?.editor;

    final onStart = target == null || viewModel == null
        ? null
        : () {
            setState(() => _dismissedAfterPress = true);
            viewModel.onStart(target);
          };
    final line = Semantics(
      button: onStart != null,
      label: onStart == null ? null : 'Add review comment',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: !_isPointerFirstPlatform ? onStart : null,
        child: widget.splitSide == null
            ? _DiffLineRow(
                line: widget.line,
                reviewTarget: target,
                hasComments: comments.isNotEmpty,
                showReviewAction:
                    onStart != null && _hovered && !_dismissedAfterPress,
                onAddReview: onStart,
                wrapLines: widget.wrapLines,
              )
            : _SplitDiffLineRow(
                line: widget.line,
                side: widget.splitSide!,
                reviewTarget: target,
                hasComments: comments.isNotEmpty,
                showReviewAction:
                    onStart != null && _hovered && !_dismissedAfterPress,
                onAddReview: onStart,
                wrapLines: widget.wrapLines,
              ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _dismissedAfterPress = false;
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line,
          if (widget.showThread &&
              viewModel != null &&
              target != null &&
              (comments.isNotEmpty || editor != null))
            _InlineReviewThread(
              target: target,
              comments: comments,
              editor: editor,
              review: viewModel,
            ),
        ],
      ),
    );
  }
}

class _InlineReviewCommentRow extends StatelessWidget {
  const _InlineReviewCommentRow({
    required this.target,
    required this.comment,
    required this.review,
  });

  final _ReviewTarget target;
  final ReviewDraftComment comment;
  final _ReviewViewModel review;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return Container(
      key: ValueKey('review-comment-${comment.id}'),
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.borderAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              comment.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox.square(
            dimension: 26,
            child: Tooltip(
              message: 'Edit review comment',
              child: IconButton(
                key: ValueKey('review-edit-${comment.id}'),
                icon: Icon(
                  FluentIcons.edit,
                  size: 14,
                  color: palette.foregroundMuted,
                ),
                onPressed: () => review.onEdit(target, comment),
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox.square(
            dimension: 26,
            child: Tooltip(
              message: 'Delete review comment',
              child: IconButton(
                key: ValueKey('review-delete-${comment.id}'),
                icon: Icon(
                  FluentIcons.delete,
                  size: 14,
                  color: palette.statusDanger,
                ),
                onPressed: () => review.onDelete(comment.id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineReviewThread extends StatelessWidget {
  const _InlineReviewThread({
    required this.target,
    required this.comments,
    required this.editor,
    required this.review,
    this.split = false,
  });

  final _ReviewTarget target;
  final List<ReviewDraftComment> comments;
  final _ReviewEditorTarget? editor;
  final _ReviewViewModel review;
  final bool split;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('review-thread-${target.key}'),
      padding: split
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
          : const EdgeInsets.fromLTRB(32, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final comment in comments)
            if (editor?.commentId != comment.id)
              Padding(
                padding: EdgeInsets.only(
                  bottom: comment != comments.last || editor != null ? 6 : 0,
                ),
                child: _InlineReviewCommentRow(
                  target: target,
                  comment: comment,
                  review: review,
                ),
              ),
          if (editor != null)
            _InlineReviewEditor(
              key: ValueKey(
                'review-editor-${target.key}-${editor!.commentId ?? 'new'}',
              ),
              initialBody: editor!.initialBody,
              onCancel: review.onCancel,
              onSave: review.onSave,
            ),
        ],
      ),
    );
  }
}

class _InlineReviewEditor extends StatefulWidget {
  const _InlineReviewEditor({
    super.key,
    required this.initialBody,
    required this.onCancel,
    required this.onSave,
  });

  final String initialBody;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;

  @override
  State<_InlineReviewEditor> createState() => _InlineReviewEditorState();
}

class _InlineReviewEditorState extends State<_InlineReviewEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  FocusNode? _previousFocus;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialBody);
    _focusNode = FocusNode(debugLabel: 'inline-review-editor');
    _scrollController = ScrollController(keepScrollOffset: false);
    _focusNode.addListener(_handleFocusChange);
    _previousFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    final previousFocus = _previousFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (previousFocus?.context != null && previousFocus!.canRequestFocus) {
        previousFocus.requestFocus();
      }
    });
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    _setFocused(_focusNode.hasFocus);
  }

  void _setFocused(bool focused) {
    if (mounted && _focused != focused) setState(() => _focused = focused);
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final keyboard = HardwareKeyboard.instance;
    if (!isEnter ||
        keyboard.isShiftPressed ||
        (!keyboard.isControlPressed && !keyboard.isMetaPressed)) {
      return KeyEventResult.ignored;
    }
    final body = _controller.text.trim();
    if (body.isNotEmpty) widget.onSave(body);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final showHints =
        _focused &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    return Container(
      height: 132,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.borderAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Focus(
        onKeyEvent: _onKeyEvent,
        onFocusChange: _setFocused,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Semantics(
                label: 'Review comment',
                textField: true,
                child: TextBox(
                  key: const ValueKey('inline-review-editor-input'),
                  controller: _controller,
                  focusNode: _focusNode,
                  scrollController: _scrollController,
                  minLines: 2,
                  maxLines: 6,
                  placeholder: 'Leave a review comment',
                  onChanged: (_) => setState(() {}),
                  onEditingComplete: () {},
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Button(
                  key: const ValueKey('inline-review-editor-cancel'),
                  onPressed: widget.onCancel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Cancel'),
                      if (showHints) ...[
                        const SizedBox(width: 6),
                        ShortcutBadge(keys: const ['Esc'], isMac: isMac),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('inline-review-editor-save'),
                  onPressed: _controller.text.trim().isEmpty
                      ? null
                      : () => widget.onSave(_controller.text.trim()),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Save'),
                      if (showHints) ...[
                        const SizedBox(width: 6),
                        ShortcutBadge(
                          keys: const ['mod', 'Enter'],
                          isMac: isMac,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HunkHeader extends StatelessWidget {
  const _HunkHeader({super.key, required this.header});

  final String header;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final metrics = _DiffMetricsScope.of(context);
    return Container(
      height: metrics.lineHeight,
      alignment: Alignment.centerLeft,
      color: tokens.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        header,
        maxLines: 1,
        style: metrics.textStyle.copyWith(color: tokens.onSurfaceVariant),
      ),
    );
  }
}

class _SplitDiffLineRow extends StatelessWidget {
  const _SplitDiffLineRow({
    required this.line,
    required this.side,
    required this.reviewTarget,
    required this.hasComments,
    required this.showReviewAction,
    required this.onAddReview,
    required this.wrapLines,
  });

  final DiffLine line;
  final ReviewAttachmentSide side;
  final _ReviewTarget? reviewTarget;
  final bool hasComments;
  final bool showReviewAction;
  final VoidCallback? onAddReview;
  final bool wrapLines;

  @override
  Widget build(BuildContext context) {
    final metrics = _DiffMetricsScope.of(context);
    final gutterWidth = _FileDiffMetricsScope.of(context);
    final dark = FluentTheme.of(context).brightness == Brightness.dark;
    final (background, marker, textColor) = switch (line.type) {
      DiffLineType.add => (
        Colors.green.withValues(alpha: 0.12),
        '+',
        dark ? Colors.green.light : Colors.green.dark,
      ),
      DiffLineType.del => (
        Colors.red.withValues(alpha: 0.12),
        '-',
        dark ? Colors.red.light : Colors.red.dark,
      ),
      DiffLineType.context => (null, ' ', null),
    };
    final lineNumber = side == ReviewAttachmentSide.old
        ? line.oldLineNo
        : line.newLineNo;
    return Container(
      key: ValueKey(
        'split-line-${side == ReviewAttachmentSide.old ? 'left' : 'right'}-'
        '${reviewTarget?.key ?? 'empty'}',
      ),
      height: wrapLines ? null : metrics.lineHeight,
      constraints: BoxConstraints(minHeight: metrics.lineHeight),
      color: background,
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutterWidth,
            height: metrics.lineHeight,
            child: _ReviewGutterContent(
              lineNumber: lineNumber,
              textStyle: metrics.textStyle.copyWith(
                color: context.tokens.outline,
              ),
              hasComments: hasComments,
              showReviewAction: showReviewAction,
              reviewTarget: reviewTarget,
              onAddReview: onAddReview,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(
              marker,
              style: metrics.textStyle.copyWith(color: textColor),
            ),
          ),
          if (wrapLines)
            Expanded(
              child: _DiffContentText(
                line: line,
                softWrap: true,
                overflow: TextOverflow.visible,
                style: metrics.textStyle.copyWith(color: textColor),
              ),
            )
          else
            _DiffContentText(
              line: line,
              softWrap: false,
              style: metrics.textStyle.copyWith(color: textColor),
            ),
        ],
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({
    required this.line,
    this.reviewTarget,
    this.hasComments = false,
    this.showReviewAction = false,
    this.onAddReview,
    this.wrapLines = false,
  });

  final DiffLine line;
  final _ReviewTarget? reviewTarget;
  final bool hasComments;
  final bool showReviewAction;
  final VoidCallback? onAddReview;
  final bool wrapLines;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final metrics = _DiffMetricsScope.of(context);
    final gutterWidth = _FileDiffMetricsScope.of(context);
    final outline = context.tokens.outline;
    final dark = theme.brightness == Brightness.dark;
    final (background, marker, textColor) = switch (line.type) {
      DiffLineType.add => (
        Colors.green.withValues(alpha: 0.12),
        '+',
        dark ? Colors.green.light : Colors.green.dark,
      ),
      DiffLineType.del => (
        Colors.red.withValues(alpha: 0.12),
        '-',
        dark ? Colors.red.light : Colors.red.dark,
      ),
      DiffLineType.context => (null, ' ', null),
    };
    return Container(
      color: background,
      constraints: BoxConstraints(minHeight: metrics.lineHeight),
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutterWidth,
            height: metrics.lineHeight,
            child: _ReviewGutterContent(
              lineNumber: _unifiedLineNumber(line),
              textStyle: metrics.textStyle.copyWith(color: outline),
              hasComments: hasComments,
              showReviewAction: showReviewAction,
              reviewTarget: reviewTarget,
              onAddReview: onAddReview,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(
              marker,
              style: metrics.textStyle.copyWith(color: textColor),
            ),
          ),
          if (wrapLines)
            Expanded(
              child: _DiffContentText(
                line: line,
                softWrap: true,
                overflow: TextOverflow.visible,
                style: metrics.textStyle.copyWith(color: textColor),
              ),
            )
          else
            _DiffContentText(
              line: line,
              softWrap: false,
              style: metrics.textStyle.copyWith(color: textColor),
            ),
        ],
      ),
    );
  }
}

class _DiffContentText extends StatelessWidget {
  const _DiffContentText({
    required this.line,
    required this.softWrap,
    required this.style,
    this.overflow,
  });

  final DiffLine line;
  final bool softWrap;
  final TextStyle style;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final tokens = line.tokens;
    if (tokens == null || !tokens.any((token) => token.text.isNotEmpty)) {
      return Text(
        formatDiffContentText(line.text),
        softWrap: softWrap,
        overflow: overflow,
        style: style,
      );
    }
    final brightness = FluentTheme.of(context).brightness;
    final baseColor = context.paseoPalette.foreground;
    return Text.rich(
      TextSpan(
        children: [
          for (final token in tokens)
            TextSpan(
              text: token.text,
              style: TextStyle(
                color: syntaxTokenColorFor(
                  token.style,
                  brightness: brightness,
                  baseColor: baseColor,
                ),
              ),
            ),
        ],
      ),
      style: style.copyWith(color: baseColor),
      softWrap: softWrap,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}
