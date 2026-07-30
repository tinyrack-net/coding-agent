import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../state/daemon_providers.dart';
import '../state/explorer_checkout_context.dart';
import '../state/explorer_tab_memory_provider.dart';
import '../state/pull_request_provider.dart';
import '../workspace/workspace_file_open.dart';
import 'diff/diff_pane.dart';
import 'pull_request_pane.dart';
import 'pull_request_tab.dart';

class WorkspaceExplorerVisibilityNotifier extends Notifier<bool> {
  WorkspaceExplorerVisibilityNotifier(this.cwd);

  final String cwd;

  @override
  bool build() => true;

  void show() => state = true;

  void hide() => state = false;
}

final workspaceExplorerVisibilityProvider =
    NotifierProvider.family<WorkspaceExplorerVisibilityNotifier, bool, String>(
      WorkspaceExplorerVisibilityNotifier.new,
    );

class WorkspaceExplorer extends ConsumerStatefulWidget {
  const WorkspaceExplorer({
    super.key,
    required this.serverId,
    required this.cwd,
    required this.isGit,
    required this.onClose,
    this.workspaceId,
    this.changesTabOpen = false,
    this.onToggleChangesTab,
    this.onChangesFilePress,
    this.onOpenFile,
  });

  final String serverId;
  final String? workspaceId;
  final String cwd;
  final bool isGit;
  final VoidCallback onClose;
  final bool changesTabOpen;
  final VoidCallback? onToggleChangesTab;
  final ValueChanged<String>? onChangesFilePress;
  final void Function(WorkspaceFileOpenRequest request)? onOpenFile;

  @override
  ConsumerState<WorkspaceExplorer> createState() => _WorkspaceExplorerState();
}

class _WorkspaceExplorerState extends ConsumerState<WorkspaceExplorer> {
  @override
  Widget build(BuildContext context) {
    final tabMemory = ref.watch(explorerTabMemoryProvider);
    final activeTab = resolveExplorerTabForCheckout(
      serverId: widget.serverId,
      cwd: widget.cwd,
      isGit: widget.isGit,
      explorerTabByCheckout: tabMemory.byCheckout,
    );
    final pullRequest = widget.isGit
        ? ref.watch(pullRequestPaneProvider(widget.cwd))
        : null;
    final status = pullRequest?.value?.status;
    final showPullRequestTab =
        widget.isGit &&
        (status != null ||
            (activeTab == WorkspaceExplorerTab.pullRequest &&
                (pullRequest?.isLoading ?? false)));
    final requestedTab =
        !widget.isGit &&
            (activeTab == WorkspaceExplorerTab.changes ||
                activeTab == WorkspaceExplorerTab.pullRequest)
        ? WorkspaceExplorerTab.files
        : activeTab;
    final resolvedTab =
        requestedTab == WorkspaceExplorerTab.pullRequest && !showPullRequestTab
        ? WorkspaceExplorerTab.changes
        : requestedTab;

    void selectTab(WorkspaceExplorerTab tab) {
      ref
          .read(explorerTabMemoryProvider.notifier)
          .setForCheckout(
            checkout: ExplorerCheckoutContext(
              serverId: widget.serverId,
              cwd: widget.cwd,
              isGit: widget.isGit,
            ),
            tab: tab,
          );
    }

    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.tokens.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              if (widget.isGit)
                _ExplorerTabButton(
                  key: const ValueKey('explorer-tab-changes'),
                  label: 'Changes',
                  selected: resolvedTab == WorkspaceExplorerTab.changes,
                  onPressed: () {
                    ref
                        .read(pullRequestPaneProvider(widget.cwd).notifier)
                        .setTimelineEnabled(false);
                    selectTab(WorkspaceExplorerTab.changes);
                  },
                ),
              _ExplorerTabButton(
                key: const ValueKey('explorer-tab-files'),
                label: 'Files',
                selected: resolvedTab == WorkspaceExplorerTab.files,
                onPressed: () {
                  if (widget.isGit) {
                    ref
                        .read(pullRequestPaneProvider(widget.cwd).notifier)
                        .setTimelineEnabled(false);
                  }
                  selectTab(WorkspaceExplorerTab.files);
                },
              ),
              if (showPullRequestTab)
                _ExplorerTabButton(
                  key: const ValueKey('explorer-tab-pr'),
                  label: formatPullRequestTabLabel(status?.number),
                  leading: (color) => PullRequestTabIcon(
                    key: const ValueKey('explorer-tab-pr-icon'),
                    forge: status?.forge ?? 'git',
                    size: 13,
                    color: color,
                  ),
                  selected: resolvedTab == WorkspaceExplorerTab.pullRequest,
                  onPressed: () {
                    ref
                        .read(pullRequestPaneProvider(widget.cwd).notifier)
                        .setTimelineEnabled(true);
                    selectTab(WorkspaceExplorerTab.pullRequest);
                  },
                ),
              const Spacer(),
              Tooltip(
                message: 'Close explorer',
                child: IconButton(
                  icon: const Icon(FluentIcons.chrome_close, size: 14),
                  onPressed: widget.onClose,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (resolvedTab) {
            WorkspaceExplorerTab.changes => DiffPane(
              serverId: widget.serverId,
              workspaceId: widget.workspaceId,
              cwd: widget.cwd,
              compact: true,
              changesTabOpen: widget.changesTabOpen,
              onToggleChangesTab: widget.onToggleChangesTab,
              onChangesFilePress: widget.onChangesFilePress,
            ),
            WorkspaceExplorerTab.files => _FilesPane(
              cwd: widget.cwd,
              onOpenFile: widget.onOpenFile,
            ),
            WorkspaceExplorerTab.pullRequest => PullRequestPane(
              cwd: widget.cwd,
              manageTimelineActivation: false,
            ),
          },
        ),
      ],
    );
  }
}

class _ExplorerTabButton extends StatelessWidget {
  const _ExplorerTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.leading,
  });

  final String label;
  final Widget Function(Color color)? leading;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = HoverButton(
      onPressed: onPressed,
      builder: (context, states) {
        final foreground = selected
            ? context.paseoPalette.foreground
            : context.paseoPalette.foregroundMuted;
        return Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected || states.contains(WidgetState.hovered)
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!(foreground),
                const SizedBox(width: 8),
              ],
              Text(label, style: TextStyle(fontSize: 12, color: foreground)),
            ],
          ),
        );
      },
    );
    return button;
  }
}

typedef _DirectoryKey = ({String cwd, String path});

final _directoryProvider =
    FutureProvider.family<List<_ExplorerEntry>, _DirectoryKey>((
      ref,
      key,
    ) async {
      const uuid = Uuid();
      final client = ref.watch(daemonClientProvider);
      ref.watch(connectionStateProvider);
      if (client.currentState != DaemonConnectionState.connected) {
        return const [];
      }
      final response = await client.requestSessionMessage({
        'type': 'file_explorer_request',
        'cwd': key.cwd,
        'path': key.path,
        'mode': 'list',
        'acceptBinary': false,
        'requestId': uuid.v4(),
      });
      final payload = Map<String, Object?>.from(response['payload'] as Map);
      final error = payload['error'];
      if (error != null) throw StateError('$error');
      final directory = Map<String, Object?>.from(payload['directory'] as Map);
      return ((directory['entries'] as List?) ?? const [])
          .map(
            (entry) => _ExplorerEntry.fromJson(
              Map<String, Object?>.from(entry as Map),
            ),
          )
          .toList(growable: false);
    });

class _ExplorerEntry {
  const _ExplorerEntry({
    required this.name,
    required this.path,
    required this.directory,
    required this.size,
  });

  final String name;
  final String path;
  final bool directory;
  final num size;

  factory _ExplorerEntry.fromJson(Map<String, Object?> json) => _ExplorerEntry(
    name: json['name'] as String,
    path: json['path'] as String,
    directory: json['kind'] == 'directory',
    size: json['size'] as num? ?? 0,
  );
}

class _FilesPane extends ConsumerStatefulWidget {
  const _FilesPane({required this.cwd, this.onOpenFile});

  final String cwd;
  final void Function(WorkspaceFileOpenRequest request)? onOpenFile;

  @override
  ConsumerState<_FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends ConsumerState<_FilesPane> {
  String _path = '.';

  @override
  Widget build(BuildContext context) {
    final key = (cwd: widget.cwd, path: _path);
    final entries = ref.watch(_directoryProvider(key));
    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.tokens.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              if (_path != '.')
                IconButton(
                  icon: const Icon(FluentIcons.up, size: 14),
                  onPressed: () => setState(() => _path = _parentPath(_path)),
                ),
              Expanded(
                child: Text(
                  _path == '.' ? widget.cwd : _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.tokens.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(FluentIcons.refresh, size: 14),
                onPressed: () => ref.invalidate(_directoryProvider(key)),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.when(
            loading: () => const Center(child: ProgressRing()),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Failed to load files\n$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: context.tokens.error),
                ),
              ),
            ),
            data: (items) => items.isEmpty
                ? const Center(child: Text('Empty folder'))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        leading: Icon(
                          item.directory
                              ? FluentIcons.folder
                              : FluentIcons.page,
                          size: 14,
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: item.directory
                            ? null
                            : Text(
                                _formatBytes(item.size),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: context.tokens.onSurfaceVariant,
                                ),
                              ),
                        onPressed: item.directory
                            ? () => setState(() => _path = item.path)
                            : () => widget.onOpenFile?.call(
                                WorkspaceFileOpenRequest(
                                  location: WorkspaceFileLocation(
                                    path: item.path,
                                  ),
                                  disposition: OpenFileDisposition.main,
                                ),
                              ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

String _parentPath(String path) {
  final segments = path.split('/')..removeWhere((segment) => segment.isEmpty);
  if (segments.length <= 1) return '.';
  return segments.take(segments.length - 1).join('/');
}

String _formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
