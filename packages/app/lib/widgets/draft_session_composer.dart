import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/worktree_tabs_provider.dart';
import 'fluent/segmented_control.dart';

/// Inline composer for a `draft`-kind [WorktreeTab]: pick provider/model/mode
/// and an optional first prompt, then create the agent and convert this tab
/// to it in place. The worktree's cwd (and, for worktree-isolation agents,
/// its owning project/branch) are already fixed by the surrounding tab —
/// unlike [NewWorkspaceScreen], there is no project/isolation/base-ref
/// picker here.
class DraftSessionComposer extends ConsumerStatefulWidget {
  const DraftSessionComposer({
    super.key,
    required this.worktreePath,
    required this.tabId,
    this.projectPath,
    this.branch,
    this.isWorktree = false,
  });

  /// The agent's `cwd` once created — always this worktree's path.
  final String worktreePath;

  /// The draft tab converting to an agent tab on submit.
  final String tabId;

  /// Set when [isWorktree] is true: the owning repo the worktree was
  /// created from.
  final String? projectPath;

  /// Set when [isWorktree] is true: the worktree's branch.
  final String? branch;

  final bool isWorktree;

  @override
  ConsumerState<DraftSessionComposer> createState() =>
      _DraftSessionComposerState();
}

class _DraftSessionComposerState extends ConsumerState<DraftSessionComposer> {
  final _promptController = TextEditingController();

  String? _provider;
  String? _model;
  AgentMode _mode = AgentMode.normal;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final provider = _provider;
    final model = _model;
    if (provider == null || model == null) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final agent = await ref.read(agentActionsProvider).create(
            cwd: widget.worktreePath,
            provider: provider,
            model: model,
            mode: _mode,
            projectPath: widget.projectPath,
            branch: widget.branch,
            isWorktree: widget.isWorktree,
          );

      final prompt = _promptController.text.trim();
      if (prompt.isNotEmpty) {
        await ref.read(agentActionsProvider).prompt(agent.agentId, prompt);
      }

      if (!mounted) return;
      ref
          .read(worktreeTabsProvider(widget.worktreePath).notifier)
          .retarget(widget.tabId, agent.agentId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Failed to create agent: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(providerListProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: providersAsync.when(
          loading: () => const Center(child: ProgressRing()),
          error: (e, _) => Text('Failed to load providers: $e'),
          data: (all) {
            final providers = all.where((p) => p.configured).toList();
            if (providers.isEmpty) {
              return const Text(
                'No providers are configured yet. '
                'Add an API key in Settings and try again.',
              );
            }
            final selectedProvider = providers.firstWhere(
              (p) => p.id == _provider,
              orElse: () => providers.first,
            );
            if (_provider != selectedProvider.id) {
              _provider = selectedProvider.id;
              _model = null;
            }
            final models = selectedProvider.models;
            final selectedModel =
                models.any((m) => m.id == _model) || models.isEmpty
                ? _model
                : models.first.id;
            _model = selectedModel ?? (models.isEmpty ? null : models.first.id);

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ComboBox<String>(
                          value: selectedProvider.id,
                          items: [
                            for (final p in providers)
                              ComboBoxItem(
                                value: p.id,
                                child: Text(p.displayName),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _provider = value;
                            _model = null;
                          }),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ComboBox<String>(
                          key: ValueKey('model-${selectedProvider.id}'),
                          value: _model,
                          items: [
                            for (final m in models)
                              ComboBoxItem(value: m.id, child: Text(m.displayName)),
                          ],
                          onChanged: (value) => setState(() => _model = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedControl<AgentMode>(
                    segments: const [
                      (AgentMode.plan, 'Plan'),
                      (AgentMode.normal, 'Normal'),
                      (AgentMode.fullAccess, 'Full access'),
                    ],
                    selected: _mode,
                    onChanged: (mode) => setState(() => _mode = mode),
                  ),
                  const SizedBox(height: 20),
                  TextBox(
                    controller: _promptController,
                    minLines: 3,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    placeholder: 'What do you want to do? (optional)',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FilledButton(
                        onPressed: _submitting || _model == null ? null : _submit,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: ProgressRing(strokeWidth: 2),
                                  )
                                : const Icon(FluentIcons.return_key, size: 16),
                            const SizedBox(width: 6),
                            const Text('Create'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage!,
                      style: TextStyle(color: context.tokens.error),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
