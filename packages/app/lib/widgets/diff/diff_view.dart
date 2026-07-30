import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diff_rendering.dart';
import '../../core/diff_tree.dart';
import '../../core/theme.dart';
import '../../state/review_draft_provider.dart';
import '../shortcut_badge.dart';
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

/// Structured diff review: file list + unified per-file view.
///
/// Wide layouts show a file list on the left and the selected file's hunks on
/// the right; narrow layouts fall back to collapsible per-file sections.
class DiffView extends ConsumerStatefulWidget {
  const DiffView({super.key, required this.diff, this.reviewDraftKey});

  final DiffResponse diff;
  final String? reviewDraftKey;

  @override
  ConsumerState<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends ConsumerState<DiffView> {
  int _selectedIndex = 0;
  final Set<String> _collapsedFolders = {};
  _ReviewEditorTarget? _reviewEditor;

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reviewDraftKey != widget.reviewDraftKey) {
      _reviewEditor = null;
    }
    if (_selectedIndex >= widget.diff.files.length) {
      _selectedIndex = 0;
    }
    final directoryPaths = collectDirPaths(
      compressSingleChildChains(buildDiffTree(widget.diff.files)),
    );
    _collapsedFolders.retainAll(directoryPaths);
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.diff.files;
    if (files.isEmpty) return const _NoChanges();
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

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          // Narrow: collapsible section per file.
          return ListView(
            children: [
              for (final file in files)
                Padding(
                  key: PageStorageKey('diff-${file.path}'),
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Expander(
                    header: _FileRowLabel(file: file),
                    content: _FileDiffBody(file: file, review: review),
                  ),
                ),
            ],
          );
        }
        final selected = files[_selectedIndex.clamp(0, files.length - 1)];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 280,
              child: _DiffTreeFileList(
                files: files,
                selected: selected,
                collapsedFolders: _collapsedFolders,
                onToggleFolder: (dirPath) => setState(() {
                  if (!_collapsedFolders.remove(dirPath)) {
                    _collapsedFolders.add(dirPath);
                  }
                }),
                onSelectFile: (file) =>
                    setState(() => _selectedIndex = files.indexOf(file)),
              ),
            ),
            const Divider(direction: Axis.vertical),
            Expanded(
              child: ListView(
                key: ValueKey('diff-body-${selected.path}'),
                children: [_FileDiffBody(file: selected, review: review)],
              ),
            ),
          ],
        );
      },
    );
  }
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

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.file,
    required this.selected,
    required this.onTap,
    this.pathLabel,
  });

  final DiffFile file;
  final bool selected;
  final VoidCallback onTap;
  final String? pathLabel;

  @override
  Widget build(BuildContext context) {
    return ListTile.selectable(
      selected: selected,
      onPressed: onTap,
      title: _FileRowLabel(file: file, pathLabel: pathLabel),
    );
  }
}

class _DiffTreeFileList extends StatelessWidget {
  const _DiffTreeFileList({
    required this.files,
    required this.selected,
    required this.collapsedFolders,
    required this.onToggleFolder,
    required this.onSelectFile,
  });

  final List<DiffFile> files;
  final DiffFile selected;
  final Set<String> collapsedFolders;
  final ValueChanged<String> onToggleFolder;
  final ValueChanged<DiffFile> onSelectFile;

  @override
  Widget build(BuildContext context) {
    final tree = compressSingleChildChains(buildDiffTree(files));
    final rows = flattenDiffTree(tree, collapsedFolders);
    return ListView(
      key: const ValueKey('diff-file-tree'),
      children: [
        for (final row in rows)
          switch (row) {
            final DiffTreeFolderRow folder => Padding(
              key: ValueKey('diff-folder-${folder.dirPath}'),
              padding: EdgeInsets.only(left: folder.depth * 16.0),
              child: ListTile(
                onPressed: () => onToggleFolder(folder.dirPath),
                leading: Icon(
                  collapsedFolders.contains(folder.dirPath)
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
                    DiffStat(
                      additions: folder.additions,
                      deletions: folder.deletions,
                    ),
                  ],
                ),
              ),
            ),
            final DiffTreeFileRow fileRow => Padding(
              key: ValueKey('diff-tree-file-${fileRow.file.path}'),
              padding: EdgeInsets.only(left: fileRow.depth * 16.0),
              child: _FileListTile(
                file: fileRow.file,
                pathLabel: _treeFileLabel(fileRow.file),
                selected: identical(fileRow.file, selected),
                onTap: () => onSelectFile(fileRow.file),
              ),
            ),
          },
      ],
    );
  }
}

/// Status icon + path + add/del counts; shared by both layouts.
class _FileRowLabel extends StatelessWidget {
  const _FileRowLabel({required this.file, this.pathLabel});

  final DiffFile file;
  final String? pathLabel;

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
  const _FileDiffBody({required this.file, this.review});

  final DiffFile file;
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
            Text('Diff too large', style: TextStyle(color: outline)),
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
    return DiffScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final hunk in file.hunks) ...[
            _HunkHeader(header: hunk.header),
            for (final line in hunk.lines)
              _ReviewableDiffLine(
                filePath: file.path,
                line: line,
                review: review,
              ),
          ],
        ],
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
  });

  final String filePath;
  final DiffLine line;
  final _ReviewViewModel? review;

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
    final target = switch (widget.line.type) {
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
    final viewModel = widget.review;
    final comments = target == null || viewModel == null
        ? const <ReviewDraftComment>[]
        : viewModel.comments
              .where(
                (comment) =>
                    comment.filePath == target.filePath &&
                    comment.side == target.side &&
                    comment.lineNumber == target.lineNumber,
              )
              .toList(growable: false);
    final editor = target != null && viewModel?.editor?.target.key == target.key
        ? viewModel!.editor
        : null;

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
        child: _DiffLineRow(
          line: widget.line,
          reviewTarget: target,
          hasComments: comments.isNotEmpty,
          showReviewAction:
              onStart != null && _hovered && !_dismissedAfterPress,
          onAddReview: onStart,
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
          if (viewModel != null &&
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
  });

  final _ReviewTarget target;
  final List<ReviewDraftComment> comments;
  final _ReviewEditorTarget? editor;
  final _ReviewViewModel review;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('review-thread-${target.key}'),
      padding: const EdgeInsets.fromLTRB(32, 8, 12, 8),
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
  const _HunkHeader({required this.header});

  final String header;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      color: tokens.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        header,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: tokens.onSurfaceVariant,
        ),
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
  });

  final DiffLine line;
  final _ReviewTarget? reviewTarget;
  final bool hasComments;
  final bool showReviewAction;
  final VoidCallback? onAddReview;

  static const _monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 12.5);

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
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
    final numberStyle = _monoStyle.copyWith(color: outline);
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            height: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hasComments ? context.paseoPalette.surface2 : null,
              ),
              child: showReviewAction
                  ? Tooltip(
                      message: 'Add review comment',
                      child: IconButton(
                        key: ValueKey('review-add-${reviewTarget!.key}'),
                        icon: const Icon(FluentIcons.add, size: 16),
                        onPressed: onAddReview,
                      ),
                    )
                  : null,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              formatDiffGutterText(line.oldLineNo),
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              formatDiffGutterText(line.newLineNo),
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(marker, style: _monoStyle.copyWith(color: textColor)),
          ),
          Text(
            formatDiffContentText(line.text),
            softWrap: false,
            style: _monoStyle.copyWith(color: textColor),
          ),
        ],
      ),
    );
  }
}
