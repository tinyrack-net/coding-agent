import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/agents_provider.dart';
import '../state/timeline_provider.dart';
import '../state/workspace_providers.dart';
import '../widgets/composer.dart';
import '../widgets/diff/diff_view.dart';
import '../widgets/terminal_pane.dart';
import '../widgets/timeline_item_tile.dart';

/// Tabs of the agent pane.
enum AgentPaneTab { chat, diff, terminal }

/// Chat view for one agent: timeline list (auto-stick to bottom) + composer.
class AgentChatScreen extends ConsumerStatefulWidget {
  const AgentChatScreen({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  final _scrollController = ScrollController();
  bool _stickToBottom = true;
  AgentPaneTab _tab = AgentPaneTab.chat;

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
        Material(
          elevation: 1,
          child: ListTile(
            dense: true,
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
                    '${agent.provider} · ${agent.model} · ${agent.mode.name} · ${agent.cwd}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: IconButton(
              tooltip: 'Archive agent',
              icon: const Icon(Icons.archive_outlined),
              onPressed: () async {
                final actions = ref.read(agentActionsProvider);
                final selected = ref.read(selectedAgentProvider.notifier);
                try {
                  await actions.archive(widget.agentId);
                  selected.select(null);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to archive: $e')),
                  );
                }
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<AgentPaneTab>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: AgentPaneTab.chat, label: Text('Chat')),
                ButtonSegment(value: AgentPaneTab.diff, label: Text('Diff')),
                ButtonSegment(
                  value: AgentPaneTab.terminal,
                  label: Text('Terminal'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) =>
                  setState(() => _tab = selection.first),
            ),
          ),
        ),
        const Divider(height: 1),
        ...switch (_tab) {
          AgentPaneTab.diff => [
            Expanded(
              child: agent == null
                  ? const SizedBox.shrink()
                  : _DiffPane(cwd: agent.cwd),
            ),
          ],
          AgentPaneTab.terminal => [
            Expanded(child: TerminalPane(agentId: widget.agentId)),
          ],
          AgentPaneTab.chat => _chatChildren(context, count, loading),
        },
      ],
    );
  }

  List<Widget> _chatChildren(BuildContext context, int count, bool loading) {
    return [
      Expanded(
        child: loading && count == 0
            ? const Center(child: CircularProgressIndicator())
            : count == 0
            ? Center(
                child: Text(
                  'No messages yet. Say something below.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
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
            child: FloatingActionButton.small(
              tooltip: 'Jump to latest',
              onPressed: () {
                setState(() => _stickToBottom = true);
                _scrollToBottom();
              },
              child: const Icon(Icons.arrow_downward),
            ),
          ),
        ),
      const Divider(height: 1),
      Composer(agentId: widget.agentId),
    ];
  }
}

/// Diff of the agent's working directory with a manual refresh action.
class _DiffPane extends ConsumerWidget {
  const _DiffPane({required this.cwd});

  final String cwd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diffAsync = ref.watch(diffProvider(cwd));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh diff',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => ref.read(diffProvider(cwd).notifier).refresh(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Failed to load diff: $e')),
            data: (diff) => DiffView(diff: diff),
          ),
        ),
      ],
    );
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
    return TimelineItemTile(
      key: ValueKey(item.id),
      item: item,
      onPermissionDecision: (permissionId, decision) async {
        try {
          await ref
              .read(agentActionsProvider)
              .respondPermission(permissionId, decision);
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to respond: $e')));
        }
      },
    );
  }
}
