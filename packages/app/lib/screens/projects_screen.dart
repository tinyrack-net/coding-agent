import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import '../core/host_routes.dart';
import '../core/worktree_actions.dart';
import '../hosts/host_chooser.dart';
import '../import_sessions/import_session_dialog.dart';
import '../state/add_project_flow_provider.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../widgets/fluent/page_back_button.dart';
import '../widgets/fluent/toast.dart';

/// Lists registered projects and, per project, their git worktrees —
/// showing which agent (if any) is using each one and letting the user
/// archive idle worktrees. This is the Paseo-style "workspace list" view.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);
    final localServerId = ref.watch(desktopManagedDaemonServerIdProvider);

    void addProject() {
      unawaited(ref.read(addProjectFlowProvider.notifier).open());
    }

    void importSession() {
      openHostChooser(
        context,
        ref,
        ChooseHostInput(
          title: 'Import from host',
          onChooseHost: (serverId) async {
            final client = ref.read(hostDaemonClientProvider(serverId));
            final imported = await showImportSessionDialog(
              context: context,
              client: client,
            );
            if (imported == null || !context.mounted) return;
            try {
              await ref
                  .read(projectsProvider.notifier)
                  .addForHost(
                    serverId: serverId,
                    client: client!,
                    path: imported.cwd,
                  );
            } on Object catch (error) {
              if (!context.mounted) return;
              AppToast.show(
                context,
                'Unable to add imported project: $error',
                key: const ValueKey('import-session-project-error'),
                severity: InfoBarSeverity.error,
              );
              return;
            }
            if (!context.mounted) return;
            ref.read(agentsProvider.notifier).upsert(imported);
            context.push(
              buildHostAgentDetailRoute(
                serverId,
                imported.agentId,
                workspaceId: imported.workspaceId,
              ),
            );
          },
        ),
        localServerId: localServerId,
      );
    }

    void setupProviders() {
      openHostChooser(
        context,
        ref,
        ChooseHostInput(
          title: 'Choose host',
          onChooseHost: (serverId) {
            context.push(
              buildSettingsHostSectionRoute(
                serverId,
                HostSectionSlug.providers,
              ),
            );
          },
        ),
        localServerId: localServerId,
      );
    }

    void pairDevice() {
      final serverId = localServerId;
      if (serverId == null) return;
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => PairDeviceDialog(
            client: ref.read(hostDaemonClientProvider(serverId)),
          ),
        ),
      );
    }

    return ScaffoldPage(
      header: PageHeader(
        leading: const PageBackButton(),
        title: const Text('Projects & worktrees'),
      ),
      content: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: [
          Align(
            alignment: AlignmentDirectional.center,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 452),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _OpenProjectTile(
                    key: const ValueKey('open-project-submit'),
                    icon: FluentIcons.folder_open,
                    title: 'Add a project',
                    description: 'Open a folder on your machine',
                    accent: true,
                    onPressed: addProject,
                  ),
                  _OpenProjectTile(
                    key: const ValueKey('open-project-import-session'),
                    icon: FluentIcons.download,
                    title: 'Import session',
                    description: 'Bring in recent external CLI sessions',
                    onPressed: importSession,
                  ),
                  _OpenProjectTile(
                    key: const ValueKey('open-project-setup-providers'),
                    icon: FluentIcons.plug_connected,
                    title: 'Setup providers',
                    description: 'Configure Claude Code, Codex, and more',
                    onPressed: setupProviders,
                  ),
                  if (localServerId != null)
                    _OpenProjectTile(
                      key: const ValueKey('open-project-pair-device'),
                      icon: FluentIcons.cell_phone,
                      title: 'Pair device',
                      description: 'Connect your phone to this daemon',
                      onPressed: pairDevice,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Registered projects',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          projectsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: ProgressRing()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text('Failed to load projects: $e')),
            ),
            data: (projects) => projects.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('No projects registered yet.')),
                  )
                : Column(
                    children: [
                      for (final project in projects)
                        _ProjectSection(project: project),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _OpenProjectTile extends StatelessWidget {
  const _OpenProjectTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onPressed,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onPressed;
  final bool accent;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title. $description',
    child: HoverButton(
      onPressed: onPressed,
      builder: (context, states) {
        final theme = FluentTheme.of(context);
        final hovered =
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 220,
          constraints: const BoxConstraints(minHeight: 132),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: hovered
                ? theme.resources.subtleFillColorSecondary
                : theme.resources.cardBackgroundFillColorDefault,
            border: Border.all(
              color: hovered
                  ? theme.accentColor
                  : theme.resources.cardStrokeColorDefault,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 20,
                color: accent
                    ? theme.accentColor
                    : theme.resources.textFillColorSecondary,
              ),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  color: theme.resources.textFillColorSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class PairDeviceDialog extends StatefulWidget {
  const PairDeviceDialog({super.key, required this.client});

  final DaemonClient? client;

  @override
  State<PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends State<PairDeviceDialog> {
  DaemonGetPairingOfferResponse? _offer;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final client = widget.client;
      if (client == null) throw StateError('Local daemon is unavailable');
      final requestId = const Uuid().v4();
      final response = DaemonGetPairingOfferResponse.fromJson(
        await client.requestSessionMessage(
          DaemonGetPairingOfferRequest(requestId: requestId).toJson(),
        ),
      );
      if (response.requestId != requestId) {
        throw StateError('Pairing response correlation failed');
      }
      if (!mounted) return;
      setState(() => _offer = response);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return ContentDialog(
      key: const ValueKey('open-project-pair-device-modal'),
      title: const Text('Pair device'),
      content: SizedBox(
        width: 520,
        child: _error != null
            ? Text('Unable to create pairing offer: $_error')
            : offer == null
            ? const Center(child: ProgressRing())
            : !offer.relayEnabled || offer.url.isEmpty
            ? const Text(
                'Relay pairing is disabled for this daemon. Enable the relay '
                'in host settings to pair another device.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Scan this code on your phone, or copy the pairing link.',
                  ),
                  if (offer.qr case final String qr when qr.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SelectableText(
                      _withoutAnsi(qr),
                      key: const ValueKey('pair-device-qr'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8,
                        height: 1,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SelectableText(
                    offer.url,
                    key: const ValueKey('pair-device-url'),
                  ),
                ],
              ),
      ),
      actions: [
        if (offer != null && offer.url.isNotEmpty)
          Button(
            key: const ValueKey('pair-device-copy-link'),
            onPressed: () => Clipboard.setData(ClipboardData(text: offer.url)),
            child: const Text('Copy link'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

String _withoutAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

class _ProjectSection extends ConsumerWidget {
  const _ProjectSection({required this.project});

  final ProjectInfo project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: project.isGitRepo
          ? Expander(
              header: _ProjectHeader(project: project),
              content: _WorktreeList(projectPath: project.path),
            )
          : ListTile(
              key: ValueKey('project-${project.path}'),
              leading: const Icon(FluentIcons.folder),
              title: Text(project.name.isEmpty ? project.path : project.name),
              subtitle: Text(
                project.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project});

  final ProjectInfo project;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(project.name.isEmpty ? project.path : project.name),
      Text(project.path, maxLines: 1, overflow: TextOverflow.ellipsis),
    ],
  );
}

class _WorktreeList extends ConsumerWidget {
  const _WorktreeList({required this.projectPath});

  final String projectPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worktreesAsync = ref.watch(worktreesProvider(projectPath));
    final agents = ref.watch(agentsProvider);

    return worktreesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: ProgressRing()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load worktrees: $e'),
      ),
      data: (worktrees) {
        if (worktrees.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No worktrees.'),
          );
        }
        return Column(
          children: [
            for (final worktree in worktrees)
              _WorktreeTile(
                worktree: worktree,
                owner: agents.values
                    .where((a) => a.cwd == worktree.path)
                    .firstOrNull,
              ),
          ],
        );
      },
    );
  }
}

class _WorktreeTile extends ConsumerWidget {
  const _WorktreeTile({required this.worktree, required this.owner});

  final WorktreeInfo worktree;
  final AgentSummary? owner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        worktree.isMain ? FluentIcons.home : FluentIcons.branch_fork2,
        size: 18,
      ),
      title: Text(worktree.branch.isEmpty ? '(detached)' : worktree.branch),
      subtitle: Text(
        owner == null
            ? worktree.path
            : 'in use by "${owner!.title.isEmpty ? owner!.agentId : owner!.title}" · ${worktree.path}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: worktree.isMain
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (owner != null)
                  Tooltip(
                    message: 'Open agent',
                    child: IconButton(
                      icon: const Icon(
                        FluentIcons.open_in_new_window,
                        size: 18,
                      ),
                      onPressed: () {
                        final worktreePath = resolveWorktreeKey(owner!);
                        ref
                            .read(worktreeTabsProvider(worktreePath).notifier)
                            .focusAgent(owner!.agentId);
                        ref
                            .read(selectedWorktreeProvider.notifier)
                            .select(worktreePath);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                Tooltip(
                  message: 'Archive worktree',
                  child: IconButton(
                    icon: const Icon(FluentIcons.delete, size: 18),
                    onPressed: () => archiveWorktreeWithConfirm(
                      context,
                      ref,
                      worktree.projectPath,
                      worktree.path,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
