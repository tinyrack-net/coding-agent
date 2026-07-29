import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';

import '../core/theme.dart';

enum SidebarResizeEdge { left, right }

class SidebarResizeHandle extends StatefulWidget {
  const SidebarResizeHandle({
    super.key,
    required this.edge,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.testId,
  });

  final SidebarResizeEdge edge;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final GestureDragCancelCallback onDragCancel;
  final String testId;

  @override
  State<SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<SidebarResizeHandle> {
  Timer? _highlightTimer;
  var _highlighted = false;

  void _cancelHighlightTimer() {
    _highlightTimer?.cancel();
    _highlightTimer = null;
  }

  void _handleHoverIn(PointerEnterEvent _) {
    _cancelHighlightTimer();
    _highlightTimer = Timer(const Duration(milliseconds: 100), () {
      _highlightTimer = null;
      if (mounted) setState(() => _highlighted = true);
    });
  }

  void _handleHoverOut(PointerExitEvent _) {
    _cancelHighlightTimer();
    if (_highlighted) setState(() => _highlighted = false);
  }

  @override
  void dispose() {
    _cancelHighlightTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    bottom: 0,
    left: widget.edge == SidebarResizeEdge.left ? 0 : null,
    right: widget.edge == SidebarResizeEdge.right ? 0 : null,
    width: 10,
    child: MouseRegion(
      key: ValueKey(widget.testId),
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: _handleHoverIn,
      onExit: _handleHoverOut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.onDragStart,
        onHorizontalDragUpdate: widget.onDragUpdate,
        onHorizontalDragEnd: widget.onDragEnd,
        onHorizontalDragCancel: widget.onDragCancel,
        child: Stack(
          children: [
            if (_highlighted)
              Positioned(
                key: ValueKey('${widget.testId}-highlight'),
                top: 0,
                bottom: 0,
                left: 5,
                width: 1,
                child: ColoredBox(
                  color: context.paseoPalette.foreground.withValues(
                    alpha: 0.25,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
