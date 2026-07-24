import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/workspace_slug.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/workspace_providers.dart';

/// How the new workspace's working directory is provisioned. Mirrors
/// Paseo's "Isolation" picker (`Local` / `New worktree`).
enum WorkspaceIsolation { local, worktree }

/// Full-screen "New workspace" flow (Paseo parity): pick a project, an
/// isolation mode, and — for worktree isolation — a branch/PR to start from;
/// type an optional first message; submitting creates the agent (and its
/// worktree, if any) and navigates straight into its chat.
class NewWorkspaceScreen extends ConsumerStatefulWidget {
  const NewWorkspaceScreen({super.key});

  @override
  ConsumerState<NewWorkspaceScreen> createState() =>
      _NewWorkspaceScreenState();
}

class _NewWorkspaceScreenState extends ConsumerState<NewWorkspaceScreen> {
  final _promptController = TextEditingController();

  String? _projectChoice;
  WorkspaceIsolation _isolation = WorkspaceIsolation.local;
  String? _baseRef;
  ProviderId? _provider;
  String? _model;
  AgentMode _mode = AgentMode.normal;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _addProject() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Project path',
            hintText: r'C:\path\to\repo',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path == null || path.isEmpty) return;
    try {
      final project = await ref.read(projectsProvider.notifier).add(path);
      if (!mounted) return;
      setState(() {
        _projectChoice = project.path;
        _isolation = WorkspaceIsolation.local;
        _baseRef = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add project: $e')));
    }
  }

  Future<void> _pickProject() async {
    final projects = ref.read(projectsProvider).value ?? const <ProjectInfo>[];
    final chosen = await showDialog<Object?>(
      context: context,
      builder: (context) => _SearchPickerDialog<ProjectInfo>(
        title: 'Project',
        searchHint: 'Search projects',
        emptyText: 'No projects available.',
        items: projects,
        itemLabel: (p) => p.name.isEmpty ? p.path : p.name,
        itemIcon: (p) => p.isGitRepo ? Icons.folder_special_outlined : Icons.folder_outlined,
        footer: (dialogContext) => ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('Add project'),
          onTap: () => Navigator.of(dialogContext).pop(const _AddProjectSentinel()),
        ),
      ),
    );
    if (chosen is _AddProjectSentinel) {
      await _addProject();
      return;
    }
    if (chosen is ProjectInfo) {
      setState(() {
        _projectChoice = chosen.path;
        _isolation = WorkspaceIsolation.local;
        _baseRef = null;
      });
    }
  }

  Future<void> _pickIsolation() async {
    final chosen = await showDialog<WorkspaceIsolation>(
      context: context,
      builder: (context) => _SearchPickerDialog<WorkspaceIsolation>(
        title: 'Isolation',
        searchable: false,
        items: WorkspaceIsolation.values,
        itemLabel: (v) => v == WorkspaceIsolation.local ? 'Local' : 'New worktree',
        itemIcon: (v) => v == WorkspaceIsolation.local ? Icons.folder_outlined : Icons.call_split,
      ),
    );
    if (chosen != null) {
      setState(() {
        _isolation = chosen;
        _baseRef = null;
      });
    }
  }

  Future<void> _pickBaseRef(String projectPath) async {
    // Ensure the branch list has been fetched before opening the picker.
    ref.read(branchesProvider(projectPath));
    final branches = await ref.read(branchesProvider(projectPath).future);
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _SearchPickerDialog<String>(
        title: 'Start from',
        searchHint: 'Search branches',
        emptyText: 'No matching refs.',
        items: branches.branches,
        itemLabel: (b) => b,
        itemIcon: (_) => Icons.call_split,
      ),
    );
    if (chosen != null) setState(() => _baseRef = chosen);
  }

  Future<void> _submit() async {
    final provider = _provider;
    final model = _model;
    final projectPath = _projectChoice;
    if (provider == null || model == null || projectPath == null) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      String cwd;
      String? worktreeProjectPath;
      String? worktreeBranch;
      final isWorktree = _isolation == WorkspaceIsolation.worktree;

      if (isWorktree) {
        final branches = ref.read(branchesProvider(projectPath)).value;
        final baseRef = _baseRef ??
            (branches != null && branches.currentBranch.isNotEmpty
                ? branches.currentBranch
                : 'main');
        final slug = generateWorkspaceSlug();
        final worktree = await ref
            .read(worktreesProvider(projectPath).notifier)
            .create(slug, baseRef: baseRef);
        cwd = worktree.path;
        worktreeProjectPath = projectPath;
        worktreeBranch = slug;
      } else {
        cwd = projectPath;
      }

      final agent = await ref.read(agentActionsProvider).create(
            cwd: cwd,
            provider: provider.name,
            model: model,
            mode: _mode,
            projectPath: worktreeProjectPath,
            branch: worktreeBranch,
            isWorktree: isWorktree,
          );

      final prompt = _promptController.text.trim();
      if (prompt.isNotEmpty) {
        await ref.read(agentActionsProvider).prompt(agent.agentId, prompt);
      }

      ref.read(selectedAgentProvider.notifier).select(agent.agentId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Failed to create worktree: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(providerListProvider);
    final projects = ref.watch(projectsProvider).value ?? const <ProjectInfo>[];

    // Keep the choice valid if the project list changed under us; default to
    // the first available project (Paseo: route project -> last active ->
    // first available).
    final choice =
        _projectChoice != null && projects.any((p) => p.path == _projectChoice)
        ? _projectChoice
        : (projects.isEmpty ? null : projects.first.path);
    _projectChoice = choice;
    final selectedProject = projects.where((p) => p.path == choice).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('New workspace')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: providersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _PickerBadge(
                            icon: selectedProject?.isGitRepo == true
                                ? Icons.folder_special_outlined
                                : Icons.folder_outlined,
                            label: selectedProject == null
                                ? 'Choose project'
                                : (selectedProject.name.isEmpty
                                    ? selectedProject.path
                                    : selectedProject.name),
                            tooltip: 'Choose project',
                            onTap: _pickProject,
                          ),
                          if (selectedProject != null && selectedProject.isGitRepo) ...[
                            _PickerBadge(
                              icon: _isolation == WorkspaceIsolation.local
                                  ? Icons.folder_outlined
                                  : Icons.call_split,
                              label: _isolation == WorkspaceIsolation.local
                                  ? 'Local'
                                  : 'New worktree',
                              tooltip: 'Isolation',
                              onTap: _pickIsolation,
                            ),
                            if (_isolation == WorkspaceIsolation.worktree)
                              _BaseRefBadge(
                                projectPath: selectedProject.path,
                                baseRef: _baseRef,
                                onTap: () => _pickBaseRef(selectedProject.path),
                              ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<ProviderId>(
                              initialValue: selectedProvider.id,
                              decoration: const InputDecoration(
                                labelText: 'Provider',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                for (final p in providers)
                                  DropdownMenuItem(
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
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('model-${selectedProvider.id.name}'),
                              initialValue: _model,
                              decoration: const InputDecoration(
                                labelText: 'Model',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                for (final m in models)
                                  DropdownMenuItem(value: m.id, child: Text(m.displayName)),
                              ],
                              onChanged: (value) => setState(() => _model = value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<AgentMode>(
                        segments: const [
                          ButtonSegment(value: AgentMode.plan, label: Text('Plan')),
                          ButtonSegment(value: AgentMode.normal, label: Text('Normal')),
                          ButtonSegment(
                            value: AgentMode.fullAccess,
                            label: Text('Full access'),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (selection) =>
                            setState(() => _mode = selection.first),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _promptController,
                        minLines: 3,
                        maxLines: 8,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'What do you want to do? (optional)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FilledButton.icon(
                            onPressed: _submitting || _model == null || choice == null
                                ? null
                                : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.keyboard_return),
                            label: const Text('Create'),
                          ),
                        ],
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Sentinel returned by the project picker's "Add project" footer row.
class _AddProjectSentinel {
  const _AddProjectSentinel();
}

class _PickerBadge extends StatelessWidget {
  const _PickerBadge({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// The "Start from" badge: shows the chosen base ref, or the project's
/// current branch (falling back to the literal `"main"`) while none has
/// been explicitly picked yet.
class _BaseRefBadge extends ConsumerWidget {
  const _BaseRefBadge({
    required this.projectPath,
    required this.baseRef,
    required this.onTap,
  });

  final String projectPath;
  final String? baseRef;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branchesAsync = ref.watch(branchesProvider(projectPath));
    final currentBranch = branchesAsync.maybeWhen<String>(
      data: (b) => b.currentBranch.isNotEmpty ? b.currentBranch : 'main',
      orElse: () => 'main',
    );
    final label = baseRef ?? currentBranch;
    return _PickerBadge(
      icon: Icons.call_split,
      label: label,
      tooltip: 'Choose where to start from',
      onTap: onTap,
    );
  }
}

/// A searchable (or plain-list) picker dialog, used for the Project,
/// Isolation, and "Start from" comboboxes.
class _SearchPickerDialog<T> extends StatefulWidget {
  const _SearchPickerDialog({
    required this.title,
    required this.items,
    required this.itemLabel,
    this.itemIcon,
    this.searchHint,
    this.emptyText = 'No matches.',
    this.searchable = true,
    this.footer,
    super.key,
  });

  final String title;
  final List<T> items;
  final String Function(T) itemLabel;
  final IconData Function(T)? itemIcon;
  final String? searchHint;
  final String emptyText;
  final bool searchable;
  final Widget Function(BuildContext context)? footer;

  @override
  State<_SearchPickerDialog<T>> createState() => _SearchPickerDialogState<T>();
}

class _SearchPickerDialogState<T> extends State<_SearchPickerDialog<T>> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.items
        : widget.items
            .where((item) =>
                widget.itemLabel(item).toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.searchable) ...[
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
            ],
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(widget.emptyText),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return ListTile(
                          leading: widget.itemIcon == null
                              ? null
                              : Icon(widget.itemIcon!(item)),
                          title: Text(widget.itemLabel(item)),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
            ),
            if (widget.footer != null) ...[
              const Divider(height: 1),
              widget.footer!(context),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
