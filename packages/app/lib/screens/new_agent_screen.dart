import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/workspace_providers.dart';

/// Shows the "New Agent" form as a dialog; on success the new agent is
/// selected in the shell.
Future<void> showNewAgentDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: const SingleChildScrollView(child: NewAgentForm()),
      ),
    ),
  );
}

String _defaultCwd() {
  final env = Platform.environment;
  return env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
}

/// Sentinel dropdown values for the non-project choices.
const _kCustomPath = '::custom::';
const _kAddProject = '::add::';

class NewAgentForm extends ConsumerStatefulWidget {
  const NewAgentForm({super.key});

  @override
  ConsumerState<NewAgentForm> createState() => _NewAgentFormState();
}

class _NewAgentFormState extends ConsumerState<NewAgentForm> {
  late final _cwdController = TextEditingController(text: _defaultCwd());
  final _titleController = TextEditingController();
  final _branchController = TextEditingController();
  ProviderId? _provider;
  String? _model;
  AgentMode _mode = AgentMode.normal;
  bool _submitting = false;

  /// Selected project path, or [_kCustomPath] for a manually entered cwd.
  String? _projectChoice;
  bool _useWorktree = false;

  @override
  void dispose() {
    _cwdController.dispose();
    _titleController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  Future<void> _promptAddProject() async {
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
      if (mounted) setState(() => _projectChoice = project.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add project: $e')));
    }
  }

  Future<void> _submit() async {
    final provider = _provider;
    final model = _model;
    final projectChoice = _projectChoice;
    if (provider == null || model == null || projectChoice == null) return;
    final branch = _branchController.text.trim();
    final useWorktree =
        _useWorktree && projectChoice != _kCustomPath && branch.isNotEmpty;
    setState(() => _submitting = true);
    try {
      String cwd;
      if (projectChoice == _kCustomPath) {
        cwd = _cwdController.text.trim();
        if (cwd.isEmpty) {
          setState(() => _submitting = false);
          return;
        }
      } else if (useWorktree) {
        final worktree = await ref
            .read(worktreesProvider(projectChoice).notifier)
            .create(branch);
        cwd = worktree.path;
      } else {
        cwd = projectChoice;
      }
      final agent = await ref
          .read(agentActionsProvider)
          .create(
            cwd: cwd,
            provider: provider.name,
            model: model,
            mode: _mode,
            title: _titleController.text.trim(),
          );
      ref.read(selectedAgentProvider.notifier).select(agent.agentId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to create agent: $e')));
    }
  }

  Widget _buildWorkspaceFields(BuildContext context) {
    final projects = ref.watch(projectsProvider).value ?? const <ProjectInfo>[];
    // Keep the choice valid if the project list changed under us.
    final choice =
        _projectChoice != null &&
            (_projectChoice == _kCustomPath ||
                projects.any((p) => p.path == _projectChoice))
        ? _projectChoice
        : (projects.isEmpty ? _kCustomPath : projects.first.path);
    _projectChoice = choice;
    final selectedProject = projects.where((p) => p.path == choice).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('project-$choice'),
          initialValue: choice,
          decoration: const InputDecoration(
            labelText: 'Project',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final p in projects)
              DropdownMenuItem(
                value: p.path,
                child: Text(
                  p.name.isEmpty ? p.path : p.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem(
              value: _kCustomPath,
              child: Text('Custom path…'),
            ),
            const DropdownMenuItem(
              value: _kAddProject,
              child: Text('Add project…'),
            ),
          ],
          onChanged: (value) {
            if (value == _kAddProject) {
              _promptAddProject();
              return;
            }
            setState(() {
              _projectChoice = value;
              if (value == _kCustomPath) _useWorktree = false;
            });
          },
        ),
        if (choice == _kCustomPath) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _cwdController,
            decoration: const InputDecoration(
              labelText: 'Working directory',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        if (selectedProject != null && selectedProject.isGitRepo) ...[
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _useWorktree,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Run in new worktree'),
            onChanged: (value) => setState(() => _useWorktree = value ?? false),
          ),
          if (_useWorktree)
            TextField(
              controller: _branchController,
              decoration: const InputDecoration(
                labelText: 'Branch name',
                hintText: 'feature/my-change',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(providerListProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: providersAsync.when(
        loading: () => const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Text('Failed to load providers: $e'),
        data: (all) {
          final providers = all.where((p) => p.available).toList();
          if (providers.isEmpty) {
            return const Text(
              'No providers are available on this machine. '
              'Install the Claude CLI and restart the daemon.',
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

          final worktreeBlocked =
              _useWorktree &&
              _projectChoice != _kCustomPath &&
              _branchController.text.trim().isEmpty;

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New Agent', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              _buildWorkspaceFields(context),
              const SizedBox(height: 12),
              DropdownButtonFormField<ProviderId>(
                initialValue: selectedProvider.id,
                decoration: const InputDecoration(
                  labelText: 'Provider',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final p in providers)
                    DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                ],
                onChanged: (value) => setState(() {
                  _provider = value;
                  _model = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
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
              const SizedBox(height: 12),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitting || _model == null || worktreeBlocked
                        ? null
                        : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
