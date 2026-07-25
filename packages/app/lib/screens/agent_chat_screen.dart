import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/provider_display.dart';
import '../core/theme.dart';
import '../core/worktree_actions.dart';
import '../state/agents_provider.dart';
import '../state/timeline_provider.dart';
import '../widgets/composer.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/timeline_item_tile.dart';

/// Chat view for one agent: timeline list (auto-stick to bottom) + composer.
/// Chat-only — diff and terminal are sibling top-level tabs at the worktree
/// level (see `WorktreeTabbedPane`), not nested inside an agent's tab.
class AgentChatScreen extends ConsumerStatefulWidget {
  const AgentChatScreen({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  final _scrollController = ScrollController();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final nearBottom = position.pixels >= position.maxScrollExtent - 80;
    if (nearBottom != _stickToBottom) {
      setState(() => _stickToBottom = nearBottom);
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final agent = ref.watch(agentSummaryProvider(widget.agentId));
    final count = ref.watch(timelineCountProvider(widget.agentId));
    final loading = ref.watch(
      timelineProvider(widget.agentId).select((s) => s.loading),
    );

    // While stuck to bottom, follow new/updated content.
    ref.listen(timelineProvider(widget.agentId), (previous, next) {
      if (_stickToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });

    return Column(
      children: [
        Container(
          color: context.tokens.surfaceContainerHighest,
          child: ListTile(
            title: Text(
              agent == null || agent.title.isEmpty
                  ? widget.agentId
                  : agent.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: agent == null
                ? null
                : Text(
                    agent.isWorktree
                        ? '${agent.provider} · ${agent.model} · ${agent.mode.name} · ${agent.branch} · ${agent.cwd}'
                        : '${agent.provider} · ${agent.model} · ${agent.mode.name} · ${agent.cwd}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Tooltip(
              message: 'Archive agent',
              child: IconButton(
                icon: const Icon(FluentIcons.archive),
                onPressed: agent == null
                    ? null
                    : () => archiveAgentWithWorktreeConfirm(context, ref, agent),
              ),
            ),
          ),
        ),
        const Divider(),
        ..._chatChildren(context, count, loading),
      ],
    );
  }

  List<Widget> _chatChildren(BuildContext context, int count, bool loading) {
    return [
      Expanded(
        child: loading && count == 0
            ? const Center(child: ProgressRing())
            : count == 0
            ? Center(
                child: Text(
                  'No messages yet. Say something below.',
                  style: TextStyle(color: context.tokens.outline),
                ),
              )
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: count,
                itemBuilder: (context, index) =>
                    _TimelineRow(agentId: widget.agentId, index: index),
              ),
      ),
      if (!_stickToBottom)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 4),
            child: Tooltip(
              message: 'Jump to latest',
              child: SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  icon: const Icon(FluentIcons.down),
                  onPressed: () {
                    setState(() => _stickToBottom = true);
                    _scrollToBottom();
                  },
                ),
              ),
            ),
          ),
        ),
      const Divider(),
      Composer(agentId: widget.agentId),
    ];
  }
}

/// One timeline row: only rebuilds when its own item changes.
class _TimelineRow extends ConsumerWidget {
  const _TimelineRow({required this.agentId, required this.index});

  final String agentId;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      timelineProvider(
        agentId,
      ).select((s) => index < s.items.length ? s.items[index] : null),
    );
    if (item == null) return const SizedBox.shrink();
    final agent = ref.watch(agentSummaryProvider(agentId));
    return TimelineItemTile(
      key: ValueKey(item.id),
      item: item,
      providerLabel: providerDisplayName(agent?.provider),
      onPermissionDecision: (permissionId, decision) async {
        try {
          await ref
              .read(agentActionsProvider)
              .respondPermission(permissionId, decision);
        } catch (e) {
          if (!context.mounted) return;
          AppToast.show(context, 'Failed to respond: $e',
              severity: InfoBarSeverity.error);
        }
      },
    );
  }
}
