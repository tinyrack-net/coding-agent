import 'package:fluent_ui/fluent_ui.dart';

import '../../core/theme.dart';
import '../../core/tool_call_parsers.dart';
import '../code_insets.dart';
import '../syntax_token_styles.dart';
import 'diff_scroll.dart';

class DiffViewer extends StatefulWidget {
  const DiffViewer({
    super.key,
    required this.diffLines,
    this.maxHeight,
    this.emptyLabel,
    this.fillAvailableHeight = false,
  });

  final List<ToolDiffLine> diffLines;
  final double? maxHeight;
  final String? emptyLabel;
  final bool fillAvailableHeight;

  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  final _verticalController = ScrollController();

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diffLines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            widget.emptyLabel ?? 'No changes to display',
            style: TextStyle(
              fontSize: 14,
              color: context.paseoPalette.foregroundMuted,
            ),
          ),
        ),
      );
    }

    Widget content = Scrollbar(
      controller: _verticalController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        key: const ValueKey('diff-viewer-vertical-scroll'),
        controller: _verticalController,
        child: Padding(
          padding: EdgeInsets.only(bottom: paseoCodeInsets.extraBottom),
          child: DiffScroll(
            child: Padding(
              padding: EdgeInsets.only(
                left: paseoCodeInsets.padding,
                top: paseoCodeInsets.padding,
                right: paseoCodeInsets.padding + paseoCodeInsets.extraRight,
                bottom: paseoCodeInsets.padding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < widget.diffLines.length; index++)
                    _ToolDiffLineRow(
                      key: ValueKey('diff-viewer-line-$index'),
                      line: widget.diffLines[index],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.maxHeight case final maxHeight?) {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: content,
      );
    }
    if (!widget.fillAvailableHeight) return content;
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : widget.maxHeight,
        child: content,
      ),
    );
  }
}

class _ToolDiffLineRow extends StatelessWidget {
  const _ToolDiffLineRow({super.key, required this.line});

  final ToolDiffLine line;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final background = switch (line.type) {
      ToolDiffLineType.header || ToolDiffLineType.context => palette.surface1,
      ToolDiffLineType.add => const Color(0x262EA043),
      ToolDiffLineType.remove => const Color(0x1AF85149),
    };
    final foreground =
        line.type == ToolDiffLineType.header ||
            line.type == ToolDiffLineType.context
        ? palette.foregroundMuted
        : palette.foreground;
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RichText(
        softWrap: false,
        text: TextSpan(
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: foreground,
          ),
          children: _spans(context, foreground),
        ),
      ),
    );
  }

  List<InlineSpan> _spans(BuildContext context, Color foreground) {
    final tokens = line.tokens;
    if (tokens != null) {
      return [
        TextSpan(
          text: diffLinePrefix(line),
          style: TextStyle(color: foreground),
        ),
        for (final token in tokens)
          TextSpan(
            text: token.text,
            style: TextStyle(
              color: syntaxTokenColorFor(
                token.style,
                brightness: FluentTheme.of(context).brightness,
                baseColor: context.paseoPalette.foreground,
              ),
            ),
          ),
      ];
    }
    final segments = line.segments;
    if (segments != null) {
      return [
        TextSpan(text: line.content.isEmpty ? '' : line.content[0]),
        for (final segment in segments)
          TextSpan(
            text: segment.text,
            style: segment.changed
                ? TextStyle(
                    backgroundColor: line.type == ToolDiffLineType.add
                        ? const Color(0x662EA043)
                        : const Color(0x59F85149),
                  )
                : null,
          ),
      ];
    }
    return [TextSpan(text: line.content)];
  }
}
