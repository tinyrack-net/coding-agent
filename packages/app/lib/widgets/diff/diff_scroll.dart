import 'package:fluent_ui/fluent_ui.dart';

/// Horizontally scrolls diff code while reporting the laid-out viewport width.
///
/// This is the Flutter equivalent of Paseo's web `DiffScroll`: nested vertical
/// scrolling remains available to the surrounding diff list, horizontal
/// overflow uses clamping physics, and the horizontal indicator stays visible.
class DiffScroll extends StatefulWidget {
  const DiffScroll({
    super.key,
    required this.child,
    this.scrollViewWidth = 0,
    this.onScrollViewWidthChange,
    this.onScrollOffsetChange,
  });

  final Widget child;
  final double scrollViewWidth;
  final ValueChanged<double>? onScrollViewWidthChange;
  final ValueChanged<double>? onScrollOffsetChange;

  @override
  State<DiffScroll> createState() => _DiffScrollState();
}

class _DiffScrollState extends State<DiffScroll> {
  final _controller = ScrollController();
  double? _reportedWidth;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_reportOffset);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_reportOffset)
      ..dispose();
    super.dispose();
  }

  void _reportOffset() => widget.onScrollOffsetChange?.call(_controller.offset);

  void _reportWidthAfterLayout(double width) {
    if (_reportedWidth == width) return;
    _reportedWidth = width;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedWidth == width) {
        widget.onScrollViewWidthChange?.call(width);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        if (viewportWidth.isFinite) _reportWidthAfterLayout(viewportWidth);
        return Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            key: const ValueKey('diff-horizontal-scroll'),
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: viewportWidth.isFinite ? viewportWidth : 0,
              ),
              child: IntrinsicWidth(child: widget.child),
            ),
          ),
        );
      },
    );
  }
}
