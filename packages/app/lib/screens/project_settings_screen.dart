import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../projects/project_config_form.dart';
import '../projects/project_icon.dart';
import '../projects/projects.dart';
import '../state/daemon_providers.dart';
import '../state/project_summaries_provider.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/host_status_dot.dart';

const _worktreeDocsUrl = 'https://paseo.sh/docs/worktrees';

class ProjectSettingsScreen extends ConsumerStatefulWidget {
  const ProjectSettingsScreen({super.key, required this.projectKey});

  final String projectKey;

  @override
  ConsumerState<ProjectSettingsScreen> createState() =>
      _ProjectSettingsScreenState();
}

class _ProjectSettingsScreenState extends ConsumerState<ProjectSettingsScreen> {
  String? _selectedServerId;

  @override
  Widget build(BuildContext context) {
    final summaries = ref.watch(projectSummariesProvider);
    final clients = ref.watch(hostRuntimeClientsProvider);
    final data = summaries.value;
    if (summaries.isLoading && data == null) {
      return const ScaffoldPage(content: Center(child: ProgressRing()));
    }
    ProjectSummary? project;
    for (final candidate in data?.projects ?? const <ProjectSummary>[]) {
      if (candidate.projectKey == widget.projectKey) {
        project = candidate;
        break;
      }
    }
    final editableHosts =
        project?.hosts
            .where(
              (host) =>
                  host.isOnline &&
                  host.serverId.trim().isNotEmpty &&
                  host.repoRoot.trim().isNotEmpty &&
                  clients.containsKey(host.serverId),
            )
            .toList(growable: false) ??
        const <ProjectHostEntry>[];
    if (project == null || editableHosts.isEmpty) {
      return _NoEditableProject(
        loading: summaries.isLoading,
        message: summaries.hasError
            ? summaries.error.toString()
            : 'This project has no connected editable host.',
      );
    }
    final selected = editableHosts
        .where((host) => host.serverId == _selectedServerId)
        .firstOrNull;
    final host = selected ?? editableHosts.first;
    final client = clients[host.serverId]!;
    return ScaffoldPage.scrollable(
      key: ValueKey('project-settings-${project.projectKey}'),
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            button: true,
            label: 'Back to projects',
            child: HyperlinkButton(
              key: const Key('project-settings-back-link'),
              onPressed: () => context.go('/settings/projects'),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.back, size: 12),
                  SizedBox(width: 6),
                  Text('Back to projects'),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ProjectIconView(
              serverId: host.serverId,
              cwd: host.repoRoot,
              projectKey: project.projectKey,
              projectName: project.projectName,
              size: 28,
              borderRadius: 6,
              fontSize: 14,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ProjectNameEditor(project: project, client: client),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ProjectHostContext(
          hosts: editableHosts,
          selectedHost: host,
          onSelected: (value) => setState(() => _selectedServerId = value),
        ),
        const SizedBox(height: 16),
        _ProjectConfigPane(
          key: ValueKey('${host.serverId}:${host.repoRoot}'),
          client: client,
          repoRoot: host.repoRoot,
        ),
      ],
    );
  }
}

class _NoEditableProject extends StatelessWidget {
  const _NoEditableProject({required this.loading, required this.message});

  final bool loading;
  final String message;

  @override
  Widget build(BuildContext context) => ScaffoldPage(
    key: const Key('project-settings-no-target'),
    content: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HyperlinkButton(
            onPressed: () => context.go('/settings/projects'),
            child: const Text('Back to projects'),
          ),
          const SizedBox(height: 16),
          if (loading) const ProgressRing() else Text(message),
          const SizedBox(height: 12),
          Button(
            key: const Key('project-settings-back-button'),
            onPressed: () => context.go('/settings/projects'),
            child: const Text('Back to projects'),
          ),
        ],
      ),
    ),
  );
}

class _ProjectNameEditor extends ConsumerStatefulWidget {
  const _ProjectNameEditor({required this.project, required this.client});

  final ProjectSummary project;
  final DaemonClient client;

  @override
  ConsumerState<_ProjectNameEditor> createState() => _ProjectNameEditorState();
}

class _ProjectNameEditorState extends ConsumerState<_ProjectNameEditor> {
  late final TextEditingController _controller;
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.project.projectCustomName ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _ProjectNameEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing &&
        oldWidget.project.projectCustomName !=
            widget.project.projectCustomName) {
      _controller.text = widget.project.projectCustomName ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _rename(String? name) async {
    setState(() => _saving = true);
    try {
      await widget.client.renameProject(widget.project.projectKey, name);
      await ref.read(projectSummariesProvider.notifier).reload();
      if (!mounted) return;
      setState(() => _editing = false);
      AppToast.show(context, 'Project renamed.');
    } on Object catch (error) {
      if (mounted) AppToast.show(context, error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _save() {
    final value = _controller.text.trim();
    final next = value.isEmpty ? null : value;
    if (next == widget.project.projectCustomName) {
      setState(() => _editing = false);
      return;
    }
    _rename(next);
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return Row(
        children: [
          Expanded(
            child: Text(
              widget.project.projectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: 'Rename project',
            child: IconButton(
              key: const Key('project-name-edit-button'),
              icon: const Icon(FluentIcons.edit, size: 14),
              onPressed: () {
                _controller.text = widget.project.projectCustomName ?? '';
                setState(() => _editing = true);
              },
            ),
          ),
          if (widget.project.projectCustomName != null)
            HyperlinkButton(
              key: const Key('project-name-reset-button'),
              onPressed: _saving ? null : () => _rename(null),
              child: const Text('Reset'),
            ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextBox(
            key: const Key('project-name-input'),
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            onSubmitted: (_) => _save(),
            placeholder: widget.project.projectName,
          ),
        ),
        Tooltip(
          message: 'Save project name',
          child: IconButton(
            key: const Key('project-name-save-button'),
            icon: const Icon(FluentIcons.check_mark, size: 14),
            onPressed: _saving ? null : _save,
          ),
        ),
        Tooltip(
          message: 'Cancel project rename',
          child: IconButton(
            key: const Key('project-name-cancel-button'),
            icon: const Icon(FluentIcons.cancel, size: 14),
            onPressed: _saving
                ? null
                : () {
                    _controller.text = widget.project.projectCustomName ?? '';
                    setState(() => _editing = false);
                  },
          ),
        ),
      ],
    );
  }
}

class _ProjectHostContext extends StatelessWidget {
  const _ProjectHostContext({
    required this.hosts,
    required this.selectedHost,
    required this.onSelected,
  });

  final List<ProjectHostEntry> hosts;
  final ProjectHostEntry selectedHost;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (hosts.length == 1) {
      return Semantics(
        key: const Key('host-indicator'),
        label: 'Host ${selectedHost.serverName}',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HostStatusDot(serverId: selectedHost.serverId),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                selectedHost.serverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.tokens.outline),
              ),
            ),
          ],
        ),
      );
    }
    return Semantics(
      label: 'Switch host',
      child: SizedBox(
        width: 240,
        child: ComboBox<String>(
          key: const Key('project-settings-host-picker'),
          value: selectedHost.serverId,
          items: [
            for (final host in hosts)
              ComboBoxItem(
                key: ValueKey('host-picker-item-${host.serverId}'),
                value: host.serverId,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HostStatusDot(serverId: host.serverId),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        host.serverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: onSelected,
        ),
      ),
    );
  }
}

class _ProjectConfigPane extends StatefulWidget {
  const _ProjectConfigPane({
    super.key,
    required this.client,
    required this.repoRoot,
  });

  final DaemonClient client;
  final String repoRoot;

  @override
  State<_ProjectConfigPane> createState() => _ProjectConfigPaneState();
}

class _ProjectConfigPaneState extends State<_ProjectConfigPane> {
  Map<String, Object?>? _baseConfig;
  ProjectConfigRevision? _revision;
  ProjectConfigDraft? _draft;
  ProjectConfigRpcError? _readError;
  ProjectConfigRpcError? _writeError;
  Object? _transportError;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _readError = null;
      _writeError = null;
      _transportError = null;
    });
    try {
      final response = await widget.client.readProjectConfig(widget.repoRoot);
      if (!mounted) return;
      switch (response) {
        case ReadProjectConfigSuccess(:final config, :final revision):
          final loaded = config ?? <String, Object?>{};
          setState(() {
            _baseConfig = loaded;
            _revision = revision;
            _draft = configToDraft(loaded);
            _loading = false;
          });
        case ReadProjectConfigFailure(:final error):
          setState(() {
            _readError = error;
            _loading = false;
          });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _transportError = error;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving || _writeError is ProjectConfigStale) return;
    setState(() => _saving = true);
    try {
      final config = applyDraftToConfig(draft: draft, base: _baseConfig);
      final response = await widget.client.writeProjectConfig(
        repoRoot: widget.repoRoot,
        config: config,
        expectedRevision: _revision,
      );
      if (!mounted) return;
      switch (response) {
        case WriteProjectConfigSuccess(:final config, :final revision):
          setState(() {
            _baseConfig = config;
            _revision = revision;
            _writeError = null;
          });
          AppToast.show(context, 'Project settings saved.');
        case WriteProjectConfigFailure(:final error):
          setState(() => _writeError = error);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _transportError = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editScript(ProjectScriptDraft? existing) async {
    final draft = _draft;
    if (draft == null) return;
    final candidate = existing == null
        ? ProjectScriptDraft(
            id: 'script-draft-new-${DateTime.now().microsecondsSinceEpoch}',
            name: '',
            commandText: '',
            commandOriginalKind: LifecycleOriginalKind.missing,
            type: '',
            portText: '',
            rawEntry: const {},
          )
        : ProjectScriptDraft(
            id: existing.id,
            name: existing.name,
            commandText: existing.commandText,
            commandOriginalKind: existing.commandOriginalKind,
            type: existing.type,
            portText: existing.portText,
            rawEntry: existing.rawEntry,
          );
    final saved = await showDialog<ProjectScriptDraft>(
      context: context,
      builder: (context) => _ScriptEditDialog(script: candidate),
    );
    if (saved == null || !mounted) return;
    setState(() {
      if (existing == null) {
        draft.scripts = [...draft.scripts, saved];
      } else {
        draft.scripts = [
          for (final script in draft.scripts)
            if (script.id == existing.id) saved else script,
        ];
      }
    });
  }

  Future<void> _removeScript(ProjectScriptDraft script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Remove script?'),
        content: Text(
          'Remove ${script.name.isEmpty ? 'this script' : script.name}?',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _draft!.scripts = [
        for (final candidate in _draft!.scripts)
          if (candidate.id != script.id) candidate,
      ];
    });
  }

  bool get _hasInvalidScripts =>
      _draft?.scripts.any(
        (script) =>
            script.name.trim().isEmpty || script.commandText.trim().isEmpty,
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(32), child: ProgressRing()),
      );
    }
    if (_transportError != null) {
      return _FailureBar(
        key: const Key('read-transport-callout'),
        title: 'Could not read project settings',
        message: _transportError.toString(),
        onReload: _load,
      );
    }
    if (_readError != null) {
      final error = _readError!;
      return _FailureBar(
        key: ValueKey(
          error is ProjectConfigInvalid
              ? 'invalid-callout'
              : error is ProjectConfigProjectNotFound
              ? 'project-not-found-callout'
              : 'read-failed-callout',
        ),
        title: error is ProjectConfigInvalid
            ? 'Project config is invalid'
            : error is ProjectConfigProjectNotFound
            ? 'Project was not found'
            : 'Could not read project settings',
        message: error is ProjectConfigInvalid
            ? 'Fix the project config file, then reload.'
            : 'Reload the project or choose another connected host.',
        onReload: _load,
      );
    }
    final draft = _draft!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroup(
          key: const Key('worktree-group'),
          title: 'Worktree',
          description:
              'Configure commands run when isolated worktrees are created or removed.',
          trailing: HyperlinkButton(
            onPressed: () => launchUrl(Uri.parse(_worktreeDocsUrl)),
            child: const Text('Docs'),
          ),
          children: [
            _TextAreaSetting(
              key: const Key('worktree-setup-section'),
              label: 'Setup',
              fieldKey: const Key('worktree-setup-input'),
              value: draft.setupText,
              placeholder: 'npm install',
              onChanged: (value) => draft.setupText = value,
            ),
            _TextAreaSetting(
              key: const Key('worktree-teardown-section'),
              label: 'Teardown',
              fieldKey: const Key('worktree-teardown-input'),
              value: draft.teardownText,
              placeholder: 'docker compose down',
              onChanged: (value) => draft.teardownText = value,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsGroup(
          key: const Key('scripts-group'),
          title: 'Scripts',
          description:
              'Define project commands and long-running services available to workspaces.',
          trailing: Tooltip(
            message: 'Add script',
            child: IconButton(
              key: const Key('scripts-add-button'),
              icon: const Icon(FluentIcons.add, size: 14),
              onPressed: () => _editScript(null),
            ),
          ),
          children: [
            if (draft.scripts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No scripts configured.'),
              )
            else
              for (final script in draft.scripts)
                _ScriptRow(
                  script: script,
                  onEdit: () => _editScript(script),
                  onRemove: () => _removeScript(script),
                ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsGroup(
          key: const Key('metadata-group'),
          title: 'Generated metadata',
          description:
              'Add project-specific instructions for generated branches, commits, and pull requests.',
          children: [
            for (final entry in const [
              (
                'branchName',
                'Branch name',
                'Describe branch naming conventions.',
              ),
              (
                'commitMessage',
                'Commit message',
                'Describe commit message conventions.',
              ),
              (
                'pullRequest',
                'Pull request',
                'Describe pull request content and format.',
              ),
            ])
              _TextAreaSetting(
                key: ValueKey('metadata-prompt-${entry.$1}-section'),
                label: entry.$2,
                fieldKey: ValueKey('metadata-prompt-${entry.$1}-input'),
                value: draft.metadataPrompts[entry.$1] ?? '',
                placeholder: entry.$3,
                onChanged: (value) => draft.metadataPrompts[entry.$1] = value,
              ),
          ],
        ),
        if (_writeError case final error?) ...[
          const SizedBox(height: 16),
          InfoBar(
            key: ValueKey(
              error is ProjectConfigStale
                  ? 'stale-callout'
                  : 'write-failed-callout',
            ),
            title: Text(
              error is ProjectConfigStale
                  ? 'Project settings changed on disk'
                  : 'Could not save project settings',
            ),
            content: Text(
              error is ProjectConfigStale
                  ? 'Reload the latest file before editing again.'
                  : 'Try saving again or reload the file.',
            ),
            severity: InfoBarSeverity.error,
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error is! ProjectConfigStale)
                  Button(onPressed: _save, child: const Text('Try again')),
                const SizedBox(width: 8),
                Button(onPressed: _load, child: const Text('Reload')),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const Key('save-button'),
            onPressed:
                _saving ||
                    _hasInvalidScripts ||
                    _writeError is ProjectConfigStale
                ? null
                : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ),
      ],
    );
  }
}

class _FailureBar extends StatelessWidget {
  const _FailureBar({
    super.key,
    required this.title,
    required this.message,
    required this.onReload,
  });

  final String title;
  final String message;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) => InfoBar(
    title: Text(title),
    content: Text(message),
    severity: InfoBarSeverity.error,
    action: Button(onPressed: onReload, child: const Text('Reload')),
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.trailing,
  });

  final String title;
  final String description;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.textStyles.titleSmall),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(color: context.tokens.outline),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 8),
      Card(
        padding: EdgeInsets.zero,
        child: Column(children: children),
      ),
    ],
  );
}

class _TextAreaSetting extends StatefulWidget {
  const _TextAreaSetting({
    super.key,
    required this.label,
    required this.fieldKey,
    required this.value,
    required this.placeholder,
    required this.onChanged,
  });

  final String label;
  final Key fieldKey;
  final String value;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  State<_TextAreaSetting> createState() => _TextAreaSettingState();
}

class _TextAreaSettingState extends State<_TextAreaSetting> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label),
        const SizedBox(height: 8),
        TextBox(
          key: widget.fieldKey,
          controller: _controller,
          minLines: 2,
          maxLines: 5,
          placeholder: widget.placeholder,
          onChanged: widget.onChanged,
        ),
      ],
    ),
  );
}

class _ScriptRow extends StatelessWidget {
  const _ScriptRow({
    required this.script,
    required this.onEdit,
    required this.onRemove,
  });

  final ProjectScriptDraft script;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hints = [
      if (script.type.isNotEmpty) script.type,
      if (script.portText.isNotEmpty) 'Port ${script.portText}',
      if (script.commandText.isNotEmpty) script.commandText.split('\n').first,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(script.name.isEmpty ? 'Untitled script' : script.name),
                if (hints.isNotEmpty)
                  Text(
                    hints.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.tokens.outline),
                  ),
              ],
            ),
          ),
          Tooltip(
            message: 'Edit ${script.name}',
            child: IconButton(
              key: ValueKey('script-edit-${script.id}'),
              icon: const Icon(FluentIcons.edit, size: 14),
              onPressed: onEdit,
            ),
          ),
          Tooltip(
            message: 'Remove ${script.name}',
            child: IconButton(
              key: ValueKey('script-remove-${script.id}'),
              icon: const Icon(FluentIcons.delete, size: 14),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScriptEditDialog extends StatefulWidget {
  const _ScriptEditDialog({required this.script});

  final ProjectScriptDraft script;

  @override
  State<_ScriptEditDialog> createState() => _ScriptEditDialogState();
}

class _ScriptEditDialogState extends State<_ScriptEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late bool _service;
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.script.name);
    _command = TextEditingController(text: widget.script.commandText);
    _service = widget.script.type == 'service';
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty || _command.text.trim().isEmpty) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.pop(
      context,
      ProjectScriptDraft(
        id: widget.script.id,
        name: _name.text,
        commandText: _command.text,
        commandOriginalKind: widget.script.commandOriginalKind,
        type: _service ? 'service' : '',
        portText: widget.script.portText,
        rawEntry: widget.script.rawEntry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    key: const Key('script-edit-modal'),
    title: Text(
      widget.script.name.isEmpty ? 'New script' : 'Edit ${widget.script.name}',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Name'),
        const SizedBox(height: 6),
        TextBox(
          key: const Key('script-edit-name'),
          controller: _name,
          placeholder: 'dev',
        ),
        if (_showErrors && _name.text.trim().isEmpty)
          const Text('Name is required.', key: Key('script-edit-name-error')),
        const SizedBox(height: 12),
        const Text('Command'),
        const SizedBox(height: 6),
        TextBox(
          key: const Key('script-edit-command'),
          controller: _command,
          minLines: 3,
          maxLines: 6,
          placeholder: 'npm run dev',
        ),
        if (_showErrors && _command.text.trim().isEmpty)
          const Text(
            'Command is required.',
            key: Key('script-edit-command-error'),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Run as a service'),
                  Text('Keep this script running as a managed service.'),
                ],
              ),
            ),
            Checkbox(
              key: const Key('script-edit-service-toggle'),
              checked: _service,
              onChanged: (value) => setState(() => _service = value ?? false),
            ),
          ],
        ),
      ],
    ),
    actions: [
      Button(
        key: const Key('script-edit-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('script-edit-save'),
        onPressed: _save,
        child: const Text('Save'),
      ),
    ],
  );
}
