import 'package:fluent_ui/fluent_ui.dart';

import '../tool_call_icon.dart';
import 'tool_call_overview.dart';

const toolCallGroupMaxHeight = 400.0;

final class ToolCallOverviewGroupView extends StatefulWidget {
  const ToolCallOverviewGroupView({
    required this.group,
    required this.children,
    this.isLastInSequence = false,
    super.key,
  });

  final ToolCallOverviewGroup group;
  final List<Widget> children;
  final bool isLastInSequence;

  @override
  State<ToolCallOverviewGroupView> createState() =>
      _ToolCallOverviewGroupViewState();
}

class _ToolCallOverviewGroupViewState extends State<ToolCallOverviewGroupView> {
  final _scrollController = ScrollController();
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ToolCallOverviewGroupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expanded &&
        oldWidget.group.run.calls.length != widget.group.run.calls.length) {
      _scrollToLatest();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final summary = formatToolCallOverviewSummary(widget.group.summary);
    return Card(
      key: ValueKey('tool-call-group-${widget.group.run.id}'),
      margin: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 4,
        bottom: widget.isLastInSequence ? 0 : 4,
      ),
      child: Expander(
        headerBackgroundColor: WidgetStateColor.transparent,
        contentBackgroundColor: Colors.transparent,
        contentPadding: const EdgeInsets.only(
          top: 4,
          left: 13,
          right: 13,
          bottom: 8,
        ),
        leading: const ToolCallIconView(
          name: ToolCallIconName.wrench,
          size: 20,
        ),
        header: Row(
          children: [
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.group.isLoading) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 14,
                height: 14,
                child: ProgressRing(strokeWidth: 2),
              ),
            ],
          ],
        ),
        initiallyExpanded: _expanded,
        onStateChanged: (expanded) {
          setState(() => _expanded = expanded);
          if (expanded) _scrollToLatest();
        },
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: toolCallGroupMaxHeight),
          child: ListView(
            controller: _scrollController,
            shrinkWrap: true,
            children: widget.children,
          ),
        ),
      ),
    );
  }
}
