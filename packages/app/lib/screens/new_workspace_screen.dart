import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/workspace_slug.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../widgets/fluent/page_back_button.dart';
import '../widgets/fluent/search_picker_dialog.dart';
import '../widgets/fluent/segmented_control.dart';
import '../widgets/fluent/toast.dart';

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
      builder: (context) => ContentDialog(
        title: const Text('Add project'),
        // Without this, TextBox greedily fills ContentDialog's unconstrained
        // body height instead of sizing to its single line of text.
        content: IntrinsicHeight(
          child: InfoLabel(
            label: 'Project path',
            child: TextBox(
              controller: controller,
              autofocus: true,
              placeholder: r'C:\path\to\repo',
              onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
            ),
          ),
        ),
        actions: [
          Button(
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
      AppToast.show(context, 'Failed to add project: $e',
          severity: InfoBarSeverity.error);
    }
  }

  Future<void> _pickProject() async {
    final projects = ref.read(projectsProvider).value ?? const <ProjectInfo>[];
    final chosen = await showDialog<Object?>(
      context: context,
      builder: (context) => SearchPickerDialog<ProjectInfo>(
        title: 'Project',
        searchHint: 'Search projects',
        emptyText: 'No projects available.',
        items: projects,
        itemLabel: (p) => p.name.isEmpty ? p.path : p.name,
        itemIcon: (p) => p.isGitRepo ? FluentIcons.folder_horizontal : FluentIcons.folder,
        footer: (dialogContext) => ListTile(
          leading: const Icon(FluentIcons.add),
          title: const Text('Add project'),
          onPressed: () => Navigator.of(dialogContext).pop(const _AddProjectSentinel()),
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
      builder: (context) => SearchPickerDialog<WorkspaceIsolation>(
        title: 'Isolation',
        searchable: false,
        items: WorkspaceIsolation.values,
        itemLabel: (v) => v == WorkspaceIsolation.local ? 'Local' : 'New worktree',
        itemIcon: (v) => v == WorkspaceIsolation.local ? FluentIcons.folder : FluentIcons.branch_fork2,
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
      builder: (context) => SearchPickerDialog<String>(
        title: 'Start from',
        searchHint: 'Search branches',
        emptyText: 'No matching refs.',
        items: branches.branches,
        itemLabel: (b) => b,
        itemIcon: (_) => FluentIcons.branch_fork2,
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

      ref.read(worktreeTabsProvider(cwd).notifier).focusAgent(agent.agentId);
      ref.read(selectedWorktreeProvider.notifier).select(cwd);
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

    return ScaffoldPage(
      header: const PageHeader(
        leading: PageBackButton(),
        title: Text('New workspace'),
      ),
      content: Center(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PickerBadge(
                          icon: selectedProject?.isGitRepo == true
                              ? FluentIcons.folder_horizontal
                              : FluentIcons.folder,
                          label: selectedProject == null
                              ? 'Choose project'
                              : (selectedProject.name.isEmpty
                                  ? selectedProject.path
                                  : selectedProject.name),
                          tooltip: 'Choose project',
                          onTap: _pickProject,
                        ),
                        if (selectedProject != null && selectedProject.isGitRepo) ...[
                          PickerBadge(
                            icon: _isolation == WorkspaceIsolation.local
                                ? FluentIcons.folder
                                : FluentIcons.branch_fork2,
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
                          child: ComboBox<ProviderId>(
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
                            key: ValueKey('model-${selectedProvider.id.name}'),
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
                          onPressed: _submitting || _model == null || choice == null
                              ? null
                              : _submit,
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
      ),
    );
  }
}

/// Sentinel returned by the project picker's "Add project" footer row.
class _AddProjectSentinel {
  const _AddProjectSentinel();
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
    return PickerBadge(
      icon: FluentIcons.branch_fork2,
      label: label,
      tooltip: 'Choose where to start from',
      onTap: onTap,
    );
  }
}
