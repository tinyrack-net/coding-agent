import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Pure presentation of a single [TimelineItem]. Kept free of providers so it
/// is trivially widget-testable; permission responses are surfaced via
/// [onPermissionDecision].
class TimelineItemTile extends StatelessWidget {
  const TimelineItemTile({
    super.key,
    required this.item,
    this.onPermissionDecision,
  });

  final TimelineItem item;
  final void Function(String permissionId, String decision)?
      onPermissionDecision;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserMessageItem(:final text) => _UserBubble(text: text),
      AssistantMessageItem(:final text, :final complete) =>
        _AssistantMessage(text: text, complete: complete),
      ReasoningItem(:final text) => _ReasoningTile(text: text),
      final ToolCallItem tool => _ToolCallCard(item: tool),
      final PermissionItem permission => _PermissionCard(
          item: permission,
          onDecision: onPermissionDecision,
        ),
      TurnItem(:final phase, :final errorMessage) =>
        _TurnDivider(phase: phase, errorMessage: errorMessage),
      ErrorItem(:final message) => _ErrorBanner(message: message),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(2),
          ),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.text, required this.complete});

  final String text;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(data: text, selectable: true),
          if (!complete)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _StreamingCursor(),
            ),
        ],
      ),
    );
  }
}

class _StreamingCursor extends StatefulWidget {
  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _ReasoningTile extends StatelessWidget {
  const _ReasoningTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.outline);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(left: 24, bottom: 8),
          dense: true,
          initiallyExpanded: false,
          leading: Icon(
            Icons.psychology_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.outline,
          ),
          title: Text('Thinking…', style: dim),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [SelectableText(text, style: dim)],
        ),
      ),
    );
  }
}

(IconData, String) _toolIconAndSummary(String toolName, ToolCallDetail detail) {
  return switch (detail) {
    ShellDetail(:final command) => (Icons.terminal, command),
    ReadDetail(:final path) => (Icons.file_open_outlined, path),
    EditDetail(:final path) => (Icons.edit_outlined, path),
    WriteDetail(:final path) => (Icons.save_outlined, path),
    SearchDetail(:final query, :final path) => (
        Icons.search,
        path == null ? query : '$query in $path',
      ),
    GenericDetail() => (Icons.build_outlined, toolName),
  };
}

class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard({required this.item});

  final ToolCallItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, summary) = _toolIconAndSummary(item.toolName, item.detail);
    final body = _toolBody(context, item.detail);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: body == null
          ? ListTile(
              dense: true,
              leading: Icon(icon, size: 20),
              title: _ToolTitle(
                toolName: item.toolName,
                summary: summary,
                statusChip: _ToolStatusChip(status: item.status),
              ),
            )
          : Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                dense: true,
                leading: Icon(icon, size: 20),
                title: _ToolTitle(
                  toolName: item.toolName,
                  summary: summary,
                  statusChip: _ToolStatusChip(status: item.status),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [body],
              ),
            ),
    );
  }

  Widget? _toolBody(BuildContext context, ToolCallDetail detail) {
    return switch (detail) {
      ShellDetail(:final output) when output != null && output.isNotEmpty =>
        _MonoBlock(text: output),
      EditDetail(:final diff) when diff != null && diff.isNotEmpty =>
        _DiffView(diff: diff),
      WriteDetail(:final contentPreview)
          when contentPreview != null && contentPreview.isNotEmpty =>
        _MonoBlock(text: contentPreview),
      GenericDetail(:final input) when input.isNotEmpty =>
        _MonoBlock(text: input.toString()),
      _ => null,
    };
  }
}

class _ToolTitle extends StatelessWidget {
  const _ToolTitle({
    required this.toolName,
    required this.summary,
    required this.statusChip,
  });

  final String toolName;
  final String summary;
  final Widget statusChip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(toolName, style: theme.textTheme.labelLarge),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        statusChip,
      ],
    );
  }
}

class _ToolStatusChip extends StatelessWidget {
  const _ToolStatusChip({required this.status});

  final ToolCallStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ToolCallStatus.pending => ('pending', Colors.grey),
      ToolCallStatus.running => ('running', Colors.amber),
      ToolCallStatus.success => ('success', Colors.green),
      ToolCallStatus.error => ('error', Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}

class _MonoBlock extends StatelessWidget {
  const _MonoBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});

  final String diff;

  @override
  Widget build(BuildContext context) {
    final lines = diff.split('\n');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText.rich(
        TextSpan(
          children: [
            for (final line in lines)
              TextSpan(
                text: '$line\n',
                style: TextStyle(
                  color: line.startsWith('+')
                      ? Colors.greenAccent
                      : line.startsWith('-')
                          ? Colors.redAccent
                          : null,
                ),
              ),
          ],
        ),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.item, this.onDecision});

  final PermissionItem item;
  final void Function(String permissionId, String decision)? onDecision;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = item.status == PermissionStatus.pending;
    final (_, summary) = _toolIconAndSummary(item.toolName, item.detail);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      color: scheme.tertiaryContainer.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: pending ? scheme.tertiary : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 18, color: scheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Claude wants to use ${item.toolName}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  summary,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            if (pending)
              Row(
                children: [
                  FilledButton(
                    onPressed: onDecision == null
                        ? null
                        : () => onDecision!(item.permissionId, 'allow'),
                    child: const Text('Allow'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onDecision == null
                        ? null
                        : () => onDecision!(item.permissionId, 'allow_always'),
                    child: const Text('Always allow'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onDecision == null
                        ? null
                        : () => onDecision!(item.permissionId, 'deny'),
                    child: const Text('Deny'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Icon(
                    item.status == PermissionStatus.allowed
                        ? Icons.check_circle_outline
                        : Icons.block,
                    size: 16,
                    color: item.status == PermissionStatus.allowed
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    item.status == PermissionStatus.allowed
                        ? 'Allowed'
                        : 'Denied',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TurnDivider extends StatelessWidget {
  const _TurnDivider({required this.phase, this.errorMessage});

  final TurnPhase phase;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (phase == TurnPhase.started) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final color = switch (phase) {
      TurnPhase.failed => Colors.redAccent,
      TurnPhase.canceled => Colors.orangeAccent,
      _ => scheme.outline,
    };
    final label = switch (phase) {
      TurnPhase.completed => 'turn completed',
      TurnPhase.failed => 'turn failed${errorMessage == null ? '' : ': $errorMessage'}',
      TurnPhase.canceled => 'turn canceled',
      TurnPhase.started => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withValues(alpha: 0.4))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
          Expanded(child: Divider(color: color.withValues(alpha: 0.4))),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
