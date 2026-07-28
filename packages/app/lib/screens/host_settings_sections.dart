import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/daemon_config_provider.dart';
import '../widgets/fluent/toast.dart';

class HostAgentsSettingsSection extends ConsumerWidget {
  const HostAgentsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(daemonConfigProvider);
    final value = config.value;
    return _HostSettingsPage(
      title: 'Agents',
      config: config,
      children: value == null
          ? const []
          : [
              _ConfigToggleCard(
                title: 'Enable Tinyrack tools',
                subtitle:
                    'Agents will be able to manage worktrees, agents and schedules',
                accessibilityLabel: 'Inject Tinyrack tools',
                value: value.injectMcpIntoAgents,
                patch: (next) => ref
                    .read(daemonConfigProvider.notifier)
                    .patch(MutableDaemonConfigPatch(injectMcpIntoAgents: next)),
              ),
              const SizedBox(height: 12),
              _ConfigToggleCard(
                title: 'Browser tools',
                subtitle:
                    'Allow agents to access and control Tinyrack browser tabs, '
                    'including logged-in browser state. Only enable this for '
                    'agents you trust.',
                accessibilityLabel: 'Enable browser tools',
                value: value.browserToolsEnabled,
                pendingLabel: 'Updating browser tools…',
                patch: (next) => ref
                    .read(daemonConfigProvider.notifier)
                    .patch(MutableDaemonConfigPatch(browserToolsEnabled: next)),
              ),
              const SizedBox(height: 12),
              _SystemPromptCard(prompt: value.appendSystemPrompt),
            ],
    );
  }
}

class HostWorkspacesSettingsSection extends ConsumerWidget {
  const HostWorkspacesSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(daemonConfigProvider);
    final value = config.value;
    return _HostSettingsPage(
      title: 'Workspaces',
      config: config,
      children: value == null
          ? const []
          : [
              _ConfigToggleCard(
                title: 'Archive merged PR workspaces',
                subtitle:
                    'Automatically archive clean Tinyrack workspaces after '
                    'their pull request is merged',
                accessibilityLabel: 'Archive merged PR workspaces',
                value: value.autoArchiveAfterMerge,
                patch: (next) => ref
                    .read(daemonConfigProvider.notifier)
                    .patch(
                      MutableDaemonConfigPatch(autoArchiveAfterMerge: next),
                    ),
              ),
            ],
    );
  }
}

class HostTerminalsSettingsSection extends ConsumerWidget {
  const HostTerminalsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(daemonConfigProvider);
    final value = config.value;
    return _HostSettingsPage(
      title: 'Terminals',
      config: config,
      children: value == null
          ? const []
          : [
              _ConfigToggleCard(
                title: 'Enable terminal agent hooks',
                subtitle:
                    'Get notifications and status from terminal agents. '
                    'This installs hooks in your agent config files.',
                accessibilityLabel: 'Enable terminal agent hooks',
                value: value.enableTerminalAgentHooks,
                errorLabel: 'Unable to update terminal agent hooks',
                patch: (next) => ref
                    .read(daemonConfigProvider.notifier)
                    .setTerminalAgentHooks(next),
              ),
              const SizedBox(height: 24),
              _TerminalProfilesCard(
                profiles: resolveTerminalProfiles(value.terminalProfiles),
              ),
            ],
    );
  }
}

class _HostSettingsPage extends StatelessWidget {
  const _HostSettingsPage({
    required this.title,
    required this.config,
    required this.children,
  });

  final String title;
  final AsyncValue<MutableDaemonConfig?> config;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final unavailableText = switch (title) {
      'Agents' => 'Connect to this host to manage agents',
      'Workspaces' => 'Connect to this host to manage workspaces',
      _ => 'Connect to this host to manage terminal profiles',
    };
    return ScaffoldPage(
      header: PageHeader(title: Text(title)),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (config.isLoading)
                const Center(child: ProgressRing())
              else if (config.hasError)
                InfoBar(
                  title: const Text('Unable to load host settings'),
                  content: Text('${config.error}'),
                  severity: InfoBarSeverity.error,
                )
              else if (config.value == null)
                Card(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(unavailableText),
                    ),
                  ),
                )
              else
                ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfigToggleCard extends StatefulWidget {
  const _ConfigToggleCard({
    required this.title,
    required this.subtitle,
    required this.accessibilityLabel,
    required this.value,
    required this.patch,
    this.pendingLabel,
    this.errorLabel,
  });

  final String title;
  final String subtitle;
  final String accessibilityLabel;
  final bool value;
  final Future<Object?> Function(bool value) patch;
  final String? pendingLabel;
  final String? errorLabel;

  @override
  State<_ConfigToggleCard> createState() => _ConfigToggleCardState();
}

class _ConfigToggleCardState extends State<_ConfigToggleCard> {
  bool _saving = false;
  String? _error;

  Future<void> _change(bool next) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.patch(next);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title),
                const SizedBox(height: 4),
                Text(widget.subtitle, style: context.textStyles.bodySmall),
                if (_saving && widget.pendingLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.pendingLabel!,
                    style: context.textStyles.bodySmall,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.errorLabel == null
                        ? _error!
                        : '${widget.errorLabel}: $_error',
                    style: TextStyle(color: context.tokens.error),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Semantics(
            label: widget.accessibilityLabel,
            child: ToggleSwitch(
              checked: widget.value,
              onChanged: _saving ? null : _change,
            ),
          ),
        ],
      ),
    );
  }
}

class _SystemPromptCard extends ConsumerWidget {
  const _SystemPromptCard({required this.prompt});

  final String prompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('System prompt'),
                SizedBox(height: 4),
                Text('Adds a system prompt to all agents'),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Button(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialogContext) => _SystemPromptDialog(
                initial: prompt,
                save: (value) => ref
                    .read(daemonConfigProvider.notifier)
                    .patch(MutableDaemonConfigPatch(appendSystemPrompt: value)),
              ),
            ),
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }
}

class _SystemPromptDialog extends StatefulWidget {
  const _SystemPromptDialog({required this.initial, required this.save});

  final String initial;
  final Future<Object?> Function(String value) save;

  @override
  State<_SystemPromptDialog> createState() => _SystemPromptDialogState();
}

class _SystemPromptDialogState extends State<_SystemPromptDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial)
      ..addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _controller.text != widget.initial;
    return ContentDialog(
      title: const Text('Append system prompt'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: 'Append system prompt',
              child: TextBox(
                controller: _controller,
                placeholder: 'Always keep replies concise.',
                minLines: 6,
                maxLines: 10,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: context.tokens.error)),
            ],
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: !changed || _saving
              ? null
              : () => _controller.text = widget.initial,
          child: const Text('Reset'),
        ),
        FilledButton(
          onPressed: !changed || _saving ? null : _save,
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class _TerminalProfilesCard extends ConsumerWidget {
  const _TerminalProfilesCard({required this.profiles});

  final List<TerminalProfile> profiles;

  Future<void> _save(WidgetRef ref, List<TerminalProfile> next) => ref
      .read(daemonConfigProvider.notifier)
      .patch(MutableDaemonConfigPatch(terminalProfiles: next));

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    TerminalProfile? profile,
  }) async {
    final draft = await showDialog<_TerminalProfileDraft>(
      context: context,
      builder: (context) => _TerminalProfileDialog(profile: profile),
    );
    if (draft == null) return;
    final nextProfile = TerminalProfile(
      id: profile?.id ?? _generateProfileId(),
      name: draft.name,
      command: draft.command,
      args: _parseArgs(draft.args),
      icon: profile?.icon,
      extra: profile?.extra ?? const {},
    );
    final next = profile == null
        ? [...profiles, nextProfile]
        : [
            for (final current in profiles)
              if (current.id == profile.id) nextProfile else current,
          ];
    try {
      await _save(ref, next);
    } catch (error) {
      if (context.mounted) AppToast.show(context, 'Unable to save: $error');
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    TerminalProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Remove profile?'),
        content: Text('Remove "${profile.name}"?'),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _save(
        ref,
        profiles.where((current) => current.id != profile.id).toList(),
      );
    } catch (error) {
      if (context.mounted) AppToast.show(context, 'Unable to save: $error');
    }
  }

  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    int index,
    int offset,
  ) async {
    final target = index + offset;
    if (target < 0 || target >= profiles.length) return;
    final next = [...profiles];
    final item = next.removeAt(index);
    next.insert(target, item);
    try {
      await _save(ref, next);
    } catch (error) {
      if (context.mounted) AppToast.show(context, 'Unable to save: $error');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Terminal profiles',
                style: context.textStyles.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(FluentIcons.add),
              onPressed: () => _edit(context, ref),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          padding: EdgeInsets.zero,
          child: profiles.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      'No profiles yet. Add one to launch terminals with a '
                      'specific command.',
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (var index = 0; index < profiles.length; index++) ...[
                      if (index > 0) const Divider(),
                      _TerminalProfileRow(
                        profile: profiles[index],
                        isFirst: index == 0,
                        isLast: index == profiles.length - 1,
                        edit: () =>
                            _edit(context, ref, profile: profiles[index]),
                        remove: () => _remove(context, ref, profiles[index]),
                        moveUp: () => _move(context, ref, index, -1),
                        moveDown: () => _move(context, ref, index, 1),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _TerminalProfileRow extends StatelessWidget {
  const _TerminalProfileRow({
    required this.profile,
    required this.isFirst,
    required this.isLast,
    required this.edit,
    required this.remove,
    required this.moveUp,
    required this.moveDown,
  });

  final TerminalProfile profile;
  final bool isFirst;
  final bool isLast;
  final VoidCallback edit;
  final VoidCallback remove;
  final VoidCallback moveUp;
  final VoidCallback moveDown;

  @override
  Widget build(BuildContext context) {
    final command = profile.args?.isNotEmpty == true
        ? '${profile.command} ${profile.args!.join(' ')}'
        : profile.command;
    return Padding(
      key: ValueKey('terminal-profile-${profile.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(FluentIcons.command_prompt, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textStyles.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(FluentIcons.up),
            onPressed: isFirst ? null : moveUp,
          ),
          IconButton(
            icon: const Icon(FluentIcons.down),
            onPressed: isLast ? null : moveDown,
          ),
          IconButton(icon: const Icon(FluentIcons.edit), onPressed: edit),
          IconButton(icon: const Icon(FluentIcons.delete), onPressed: remove),
        ],
      ),
    );
  }
}

class _TerminalProfileDraft {
  const _TerminalProfileDraft({
    required this.name,
    required this.command,
    required this.args,
  });

  final String name;
  final String command;
  final String args;
}

class _TerminalProfileDialog extends StatefulWidget {
  const _TerminalProfileDialog({this.profile});

  final TerminalProfile? profile;

  @override
  State<_TerminalProfileDialog> createState() => _TerminalProfileDialogState();
}

class _TerminalProfileDialogState extends State<_TerminalProfileDialog> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _args;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile?.name ?? '');
    _command = TextEditingController(text: widget.profile?.command ?? '');
    _args = TextEditingController(text: widget.profile?.args?.join(' ') ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    super.dispose();
  }

  void _save() {
    setState(() => _submitted = true);
    final name = _name.text.trim();
    final command = _command.text.trim();
    if (name.isEmpty || command.isEmpty) return;
    Navigator.of(context).pop(
      _TerminalProfileDraft(name: name, command: command, args: _args.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text(
        widget.profile == null
            ? 'Add terminal profile'
            : 'Edit terminal profile',
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InfoLabel(
              label: 'Name',
              child: TextBox(controller: _name, placeholder: 'Claude Code'),
            ),
            if (_submitted && _name.text.trim().isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Name is required'),
              ),
            const SizedBox(height: 12),
            InfoLabel(
              label: 'Command',
              child: TextBox(controller: _command, placeholder: 'claude'),
            ),
            if (_submitted && _command.text.trim().isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Command is required'),
              ),
            const SizedBox(height: 12),
            InfoLabel(
              label: 'Arguments',
              child: TextBox(
                controller: _args,
                placeholder: '--dangerously-skip-permissions',
              ),
            ),
            const SizedBox(height: 4),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Space-separated arguments passed to the command'),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

String _generateProfileId() {
  final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final suffix = Random().nextInt(1 << 32).toRadixString(36);
  return 'profile_${timestamp}_$suffix';
}

List<String>? _parseArgs(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed
      .split(RegExp(r'\s+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}
