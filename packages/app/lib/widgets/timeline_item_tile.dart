import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/theme.dart';

/// Pure presentation of a single [TimelineItem]. Kept free of providers so it
/// is trivially widget-testable; permission responses are surfaced via
/// [onPermissionDecision].
class TimelineItemTile extends StatelessWidget {
  const TimelineItemTile({
    super.key,
    required this.item,
    this.onPermissionDecision,
    this.providerLabel,
  });

  final TimelineItem item;
  final void Function(String permissionId, String decision)?
      onPermissionDecision;

  /// Friendly provider name shown on permission cards (e.g. "Codex wants to
  /// use bash"); defaults to "The agent" when not supplied.
  final String? providerLabel;

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
          providerLabel: providerLabel,
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
    final tokens = context.tokens;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: tokens.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(2),
          ),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: tokens.onPrimaryContainer),
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
        color: context.tokens.primary,
      ),
    );
  }
}

class _ReasoningTile extends StatelessWidget {
  const _ReasoningTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final dim = context.textStyles.bodySmall?.copyWith(color: tokens.outline);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Expander(
        headerBackgroundColor: WidgetStateColor.transparent,
        contentBackgroundColor: Colors.transparent,
        leading: Icon(FluentIcons.lightbulb, size: 18, color: tokens.outline),
        header: Text('Thinking…', style: dim),
        content: Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(text, style: dim),
        ),
      ),
    );
  }
}

(IconData, String) _toolIconAndSummary(String toolName, ToolCallDetail detail) {
  return switch (detail) {
    ShellDetail(:final command) => (FluentIcons.command_prompt, command),
    ReadDetail(:final path) => (FluentIcons.open_file, path),
    EditDetail(:final path) => (FluentIcons.edit, path),
    WriteDetail(:final path) => (FluentIcons.save, path),
    SearchDetail(:final query, :final path) => (
        FluentIcons.search,
        path == null ? query : '$query in $path',
      ),
    GenericDetail() => (FluentIcons.build, toolName),
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
              leading: Icon(icon, size: 20),
              title: _ToolTitle(
                toolName: item.toolName,
                summary: summary,
                statusChip: _ToolStatusChip(status: item.status),
              ),
            )
          : Expander(
              headerBackgroundColor: WidgetStateColor.transparent,
              contentBackgroundColor: Colors.transparent,
              leading: Icon(icon, size: 20),
              header: _ToolTitle(
                toolName: item.toolName,
                summary: summary,
                statusChip: _ToolStatusChip(status: item.status),
              ),
              content: body,
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
    final tokens = context.tokens;
    final textStyles = context.textStyles;
    return Row(
      children: [
        Text(toolName, style: textStyles.labelLarge),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyles.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: tokens.onSurfaceVariant,
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
    final status_ = context.statusColors;
    final (label, color) = switch (status) {
      ToolCallStatus.pending => ('pending', status_.neutral),
      ToolCallStatus.running => ('running', status_.running),
      ToolCallStatus.success => ('success', status_.success),
      ToolCallStatus.error => ('error', status_.danger),
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
        color: context.tokens.surfaceContainerHighest,
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
        color: context.tokens.surfaceContainerHighest,
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
                      ? Colors.green
                      : line.startsWith('-')
                          ? Colors.red
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
  const _PermissionCard({required this.item, this.onDecision, this.providerLabel});

  final PermissionItem item;
  final void Function(String permissionId, String decision)? onDecision;
  final String? providerLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final textStyles = context.textStyles;
    final pending = item.status == PermissionStatus.pending;
    final (_, summary) = _toolIconAndSummary(item.toolName, item.detail);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      backgroundColor: tokens.tertiaryContainer.withValues(alpha: 0.5),
      borderColor: pending ? tokens.tertiary : tokens.outlineVariant,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(FluentIcons.shield, size: 18, color: tokens.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${providerLabel ?? 'The agent'} wants to use ${item.toolName}',
                    style: textStyles.titleSmall,
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
                  Button(
                    onPressed: onDecision == null
                        ? null
                        : () => onDecision!(item.permissionId, 'allow_always'),
                    child: const Text('Always allow'),
                  ),
                  const SizedBox(width: 8),
                  HyperlinkButton(
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
                        ? FluentIcons.completed_solid
                        : FluentIcons.blocked,
                    size: 16,
                    color: item.status == PermissionStatus.allowed
                        ? context.statusColors.success
                        : context.statusColors.danger,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    item.status == PermissionStatus.allowed
                        ? 'Allowed'
                        : 'Denied',
                    style: textStyles.bodySmall,
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
    final tokens = context.tokens;
    final status = context.statusColors;
    final color = switch (phase) {
      TurnPhase.failed => status.danger,
      TurnPhase.canceled => status.warning,
      _ => tokens.outline,
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
          Expanded(child: Divider(style: DividerThemeData(decoration: BoxDecoration(color: color.withValues(alpha: 0.4))))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
          Expanded(child: Divider(style: DividerThemeData(decoration: BoxDecoration(color: color.withValues(alpha: 0.4))))),
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
    final tokens = context.tokens;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(FluentIcons.error_badge, color: tokens.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: tokens.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
