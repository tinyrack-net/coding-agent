import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../attachments/attachment_store.dart';
import '../composer/composer_image_attachment_service.dart';
import '../composer/composer_image_attachments.dart';
import '../core/diff_highlight.dart';
import '../core/theme.dart';
import '../core/tool_call_parsers.dart';
import '../state/timeline_provider.dart';
import '../tool_calls/tool_call_presentation.dart';
import '../tool_calls/tool_call_icon.dart';
import 'diff/diff_viewer.dart';

/// Pure presentation of a single [TimelineItem]. Kept free of providers so it
/// is trivially widget-testable; permission responses are surfaced via
/// [onPermissionDecision].
class TimelineItemTile extends StatelessWidget {
  const TimelineItemTile({
    super.key,
    required this.item,
    this.onPermissionDecision,
    this.providerLabel,
    this.userMessage,
    this.imageAttachmentService,
    this.cwd,
    this.onOpenFilePath,
  });

  final TimelineItem item;
  final void Function(String permissionId, String decision)?
  onPermissionDecision;

  /// Friendly provider name shown on permission cards (e.g. "Codex wants to
  /// use bash"); defaults to "The agent" when not supplied.
  final String? providerLabel;
  final OptimisticUserMessage? userMessage;
  final ComposerImageAttachmentService? imageAttachmentService;
  final String? cwd;
  final void Function(String path)? onOpenFilePath;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserMessageItem(:final text, :final attachments) => _UserBubble(
        text: userMessage?.text ?? text,
        images: userMessage?.images ?? const [],
        attachments: userMessage?.attachments ?? attachments,
        optimistic: userMessage != null && item.id == userMessage!.id,
        imageAttachmentService: imageAttachmentService,
      ),
      AssistantMessageItem(:final text, :final complete) => _AssistantMessage(
        text: text,
        complete: complete,
      ),
      ReasoningItem(:final text) => _ReasoningTile(text: text),
      final ToolCallItem tool => _ToolCallCard(
        item: tool,
        cwd: cwd,
        onOpenFilePath: onOpenFilePath,
      ),
      final PermissionItem permission => _PermissionCard(
        item: permission,
        onDecision: onPermissionDecision,
        providerLabel: providerLabel,
        cwd: cwd,
      ),
      final TodoItem todo => _TodoTile(item: todo),
      TurnItem(:final phase, :final errorMessage) => _TurnDivider(
        phase: phase,
        errorMessage: errorMessage,
      ),
      final CompactionItem compaction => _CompactionTile(item: compaction),
      ErrorItem(:final message) => _ErrorBanner(message: message),
    };
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.item});

  final TodoItem item;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tasks', style: context.textStyles.labelLarge),
          const SizedBox(height: 8),
          for (final entry in item.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    entry.completed
                        ? FluentIcons.completed_solid
                        : FluentIcons.circle_ring,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(entry.text)),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _CompactionTile extends StatelessWidget {
  const _CompactionTile({required this.item});

  final CompactionItem item;

  @override
  Widget build(BuildContext context) {
    final loading = item.status == CompactionStatus.loading;
    final trigger = switch (item.trigger) {
      CompactionTrigger.auto => 'Automatically compacting context',
      CompactionTrigger.manual => 'Compacting context',
      null => loading ? 'Compacting context' : 'Context compacted',
    };
    return Semantics(
      label: trigger,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            Expanded(child: Divider(style: DividerThemeData())),
            const SizedBox(width: 10),
            if (loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: ProgressRing(strokeWidth: 2),
              )
            else
              Icon(
                FluentIcons.processing,
                size: 14,
                color: context.tokens.outline,
              ),
            const SizedBox(width: 6),
            Text(
              trigger,
              style: context.textStyles.bodySmall?.copyWith(
                color: context.tokens.outline,
              ),
            ),
            if (item.preTokens case final tokens?) ...[
              const SizedBox(width: 6),
              Text(
                '($tokens tokens)',
                style: context.textStyles.bodySmall?.copyWith(
                  color: context.tokens.outline,
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(child: Divider(style: DividerThemeData())),
          ],
        ),
      ),
    );
  }
}

class _UserBubble extends StatefulWidget {
  const _UserBubble({
    required this.text,
    required this.images,
    required this.attachments,
    required this.optimistic,
    this.imageAttachmentService,
  });

  final String text;
  final List<AttachmentMetadata> images;
  final List<AgentAttachment> attachments;
  final bool optimistic;
  final ComposerImageAttachmentService? imageAttachmentService;

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  late ComposerImageAttachmentService _imageAttachmentService;
  late Future<List<PendingComposerImage>> _images;

  @override
  void initState() {
    super.initState();
    _resetImages();
  }

  @override
  void didUpdateWidget(covariant _UserBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageAttachmentService != widget.imageAttachmentService ||
        _imageIds(oldWidget.images) != _imageIds(widget.images)) {
      _resetImages();
    }
  }

  String _imageIds(List<AttachmentMetadata> images) =>
      images.map((image) => image.id).join('\u0000');

  void _resetImages() {
    _imageAttachmentService =
        widget.imageAttachmentService ?? ComposerImageAttachmentService();
    _images = _imageAttachmentService.restore(widget.images);
  }

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
        child: Semantics(
          label: widget.optimistic ? 'Sending message' : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.images.isNotEmpty)
                FutureBuilder<List<PendingComposerImage>>(
                  future: _images,
                  builder: (context, snapshot) {
                    final images = snapshot.data ?? const [];
                    if (images.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom:
                            widget.text.isEmpty && widget.attachments.isEmpty
                            ? 0
                            : 8,
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final image in images)
                            ClipRRect(
                              key: ValueKey('timeline-image-${image.id}'),
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(
                                image.bytes,
                                width: 160,
                                height: 120,
                                fit: BoxFit.cover,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              if (widget.text.isNotEmpty)
                SelectableText(
                  widget.text,
                  style: TextStyle(color: tokens.onPrimaryContainer),
                ),
              if (widget.attachments.isNotEmpty) ...[
                if (widget.text.isNotEmpty) const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final attachment in widget.attachments)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          attachment is TextAgentAttachment
                              ? attachment.title ?? 'Attachment'
                              : 'Attachment',
                          style: TextStyle(
                            fontSize: 11,
                            color: tokens.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
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
      child: Container(width: 8, height: 16, color: context.tokens.primary),
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

class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard({required this.item, this.cwd, this.onOpenFilePath});

  final ToolCallItem item;
  final String? cwd;
  final void Function(String path)? onOpenFilePath;

  @override
  Widget build(BuildContext context) {
    final presentation = buildToolCallPresentation(
      toolName: item.toolName,
      status: item.status,
      error: item.errorMessage,
      detail: item.detail,
      metadata: item.metadata,
      cwd: cwd,
      resolveIcon: resolveToolCallIconName,
    );
    if (presentation.isPlan && item.detail is PlanDetail) {
      final text = (item.detail as PlanDetail).text;
      return _PlanToolCard(text: text);
    }
    final detailBody = _toolBody(context, item.detail);
    final Widget? body = switch ((
      detailBody,
      presentation.errorText,
      presentation.isLoadingDetails,
    )) {
      (_, _, true) => const _ToolLoadingBlock(),
      (null, final String message, _) when message.isNotEmpty =>
        _ToolErrorBlock(message),
      (final Widget detail, final String message, _) when message.isNotEmpty =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            detail,
            const SizedBox(height: 8),
            _ToolErrorBlock(message),
          ],
        ),
      (final Widget detail, _, _) => detail,
      _ => null,
    };
    final openFile = presentation.openFilePath == null || onOpenFilePath == null
        ? null
        : () => onOpenFilePath!(presentation.openFilePath!);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: !presentation.canOpenDetails || body == null
          ? ListTile(
              leading: ToolCallIconView(name: presentation.icon),
              title: _ToolTitle(
                toolName: presentation.displayName,
                summary: presentation.summary,
                statusChip: _ToolStatusChip(status: item.status),
                onOpenFile: openFile,
                openFileKey: ValueKey('tool-open-file-${item.id}'),
              ),
            )
          : Expander(
              headerBackgroundColor: WidgetStateColor.transparent,
              contentBackgroundColor: Colors.transparent,
              leading: ToolCallIconView(name: presentation.icon),
              header: _ToolTitle(
                toolName: presentation.displayName,
                summary: presentation.summary,
                statusChip: _ToolStatusChip(status: item.status),
                onOpenFile: openFile,
                openFileKey: ValueKey('tool-open-file-${item.id}'),
              ),
              content: body,
            ),
    );
  }

  Widget? _toolBody(BuildContext context, ToolCallDetail detail) {
    return switch (detail) {
      ShellDetail(:final output) when output != null && output.isNotEmpty =>
        _MonoBlock(text: output),
      ShellDetail(:final command) => _MonoBlock(text: command),
      ReadDetail(:final content) when content != null && content.isNotEmpty =>
        _MonoBlock(text: content),
      ReadDetail(:final path) => _MonoBlock(text: path),
      EditDetail(
        :final path,
        :final diff,
        :final oldString,
        :final newString,
      ) =>
        DiffViewer(
          diffLines: highlightDiffLines(
            diff != null && diff.isNotEmpty
                ? parseUnifiedDiff(diff)
                : buildLineDiff(oldString ?? '', newString ?? ''),
            path,
          ),
          maxHeight: 300,
        ),
      WriteDetail(:final contentPreview)
          when contentPreview != null && contentPreview.isNotEmpty =>
        _MonoBlock(text: contentPreview),
      WriteDetail(:final path) => _MonoBlock(text: path),
      GenericDetail(:final input) when input.isNotEmpty => _MonoBlock(
        text: input.toString(),
      ),
      GenericDetail(:final output) when output != null => _MonoBlock(
        text: output.toString(),
      ),
      WorktreeSetupToolDetail(:final log) when log.isNotEmpty => _MonoBlock(
        text: log,
      ),
      FetchDetail(:final result) when result != null && result.isNotEmpty =>
        _MonoBlock(text: result),
      FetchDetail(:final codeText)
          when codeText != null && codeText.isNotEmpty =>
        _MonoBlock(text: codeText),
      FetchDetail(:final url) => _MonoBlock(text: url),
      SubAgentDetail(:final log) when log.isNotEmpty => _MonoBlock(text: log),
      SubAgentDetail(:final description)
          when description != null && description.isNotEmpty =>
        _MonoBlock(text: description),
      PlainTextDetail(:final text) when text != null && text.isNotEmpty => Text(
        text,
      ),
      SearchDetail(:final content) when content != null && content.isNotEmpty =>
        _MonoBlock(text: content),
      SearchDetail(:final filePaths) when filePaths.isNotEmpty => _MonoBlock(
        text: filePaths.join('\n'),
      ),
      SearchDetail(:final query) => _MonoBlock(text: query),
      PlanDetail(:final text) when text.isNotEmpty => _MonoBlock(text: text),
      _ => null,
    };
  }
}

class _ToolErrorBlock extends StatelessWidget {
  const _ToolErrorBlock(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: context.textStyles.bodySmall?.copyWith(
      color: context.statusColors.danger,
    ),
  );
}

class _ToolTitle extends StatelessWidget {
  const _ToolTitle({
    required this.toolName,
    required this.summary,
    required this.statusChip,
    this.onOpenFile,
    this.openFileKey,
  });

  final String toolName;
  final String? summary;
  final Widget statusChip;
  final VoidCallback? onOpenFile;
  final Key? openFileKey;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final textStyles = context.textStyles;
    return Row(
      children: [
        Text(toolName, style: textStyles.labelLarge),
        if (summary != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyles.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: tokens.onSurfaceVariant,
              ),
            ),
          ),
        ] else
          const Spacer(),
        if (onOpenFile != null)
          Tooltip(
            message: 'Open file',
            child: IconButton(
              key: openFileKey,
              icon: const Icon(FluentIcons.open_file, size: 16),
              onPressed: onOpenFile,
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
    final loading =
        status == ToolCallStatus.pending || status == ToolCallStatus.running;
    final (label, color) = switch (status) {
      ToolCallStatus.pending => ('pending', status_.neutral),
      ToolCallStatus.running => ('running', status_.running),
      ToolCallStatus.success => ('success', status_.success),
      ToolCallStatus.error => ('error', status_.danger),
      ToolCallStatus.canceled => ('canceled', status_.neutral),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: ProgressRing(
                strokeWidth: 1.5,
                activeColor: color,
                semanticLabel: 'Loading tool call',
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
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

class _ToolLoadingBlock extends StatelessWidget {
  const _ToolLoadingBlock();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading tool details',
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(width: 18, height: 18, child: ProgressRing()),
      ),
    ),
  );
}

class _PlanToolCard extends StatelessWidget {
  const _PlanToolCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Plan', style: context.textStyles.labelLarge),
          const SizedBox(height: 8),
          MarkdownBody(data: text),
        ],
      ),
    ),
  );
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.item,
    this.onDecision,
    this.providerLabel,
    this.cwd,
  });

  final PermissionItem item;
  final void Function(String permissionId, String decision)? onDecision;
  final String? providerLabel;
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final textStyles = context.textStyles;
    final pending = item.status == PermissionStatus.pending;
    final display = buildToolCallDisplayModel(
      ToolCallDisplayInput(
        name: item.toolName,
        status: ToolCallStatus.pending,
        detail: item.detail,
        cwd: cwd,
      ),
    );
    final displayName = tinyrackToolCallDisplayName(
      item.toolName,
      display.displayName,
    );
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
                    '${providerLabel ?? 'The agent'} wants to use $displayName',
                    style: textStyles.titleSmall,
                  ),
                ),
              ],
            ),
            if (display.summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  display.summary!,
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
      TurnPhase.failed =>
        'turn failed${errorMessage == null ? '' : ': $errorMessage'}',
      TurnPhase.canceled => 'turn canceled',
      TurnPhase.started => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              style: DividerThemeData(
                decoration: BoxDecoration(color: color.withValues(alpha: 0.4)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: TextStyle(fontSize: 11, color: color)),
          ),
          Expanded(
            child: Divider(
              style: DividerThemeData(
                decoration: BoxDecoration(color: color.withValues(alpha: 0.4)),
              ),
            ),
          ),
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
