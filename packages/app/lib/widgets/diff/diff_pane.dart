import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/external_url_launcher.dart';
import '../../core/theme.dart';
import '../../state/changes_preferences_provider.dart';
import '../../state/code_appearance_provider.dart';
import '../../state/daemon_providers.dart';
import '../../state/review_draft_provider.dart';
import '../../state/working_diff_provider.dart';
import '../../state/workspace_checkout_status_provider.dart';
import '../../state/workspace_attachments_provider.dart';
import '../../state/workspace_providers.dart';
import '../../workspace/workspace_file_open.dart';
import 'diff_view.dart';

/// Diff of a worktree's working directory with a manual refresh action.
/// Reflects git state directly, not any one agent conversation — a
/// worktree's `diff`-kind tab is a singleton.
class DiffPane extends ConsumerStatefulWidget {
  const DiffPane({
    super.key,
    required this.cwd,
    this.serverId,
    this.workspaceId,
    this.compact = false,
    this.onOpenWorkspaceFile,
  });

  final String cwd;
  final String? serverId;
  final String? workspaceId;
  final bool compact;
  final ValueChanged<WorkspaceFileOpenRequest>? onOpenWorkspaceFile;

  @override
  ConsumerState<DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends ConsumerState<DiffPane> {
  final _diffViewController = DiffViewController();

  @override
  void initState() {
    super.initState();
    _diffViewController.addListener(_handleDiffViewChanged);
  }

  void _handleDiffViewChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _diffViewController
      ..removeListener(_handleDiffViewChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.serverId;
    if (host != null && host.isNotEmpty) {
      return _LiveDiffPane(
        serverId: host,
        workspaceId: widget.workspaceId,
        cwd: widget.cwd,
        compact: widget.compact,
        diffViewController: _diffViewController,
        onOpenWorkspaceFile: widget.onOpenWorkspaceFile,
      );
    }
    final diffAsync = ref.watch(diffProvider(widget.cwd));
    final changesPreferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();
    final codeAppearance = ref.watch(codeAppearanceProvider);
    final files = diffAsync.value?.files ?? const <DiffFile>[];

    return Column(
      children: [
        if (!widget.compact) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textStyles.bodySmall,
                  ),
                ),
                _DiffLayoutToggle(
                  layout: changesPreferences.layout,
                  onToggle: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        layout:
                            changesPreferences.layout == ChangesLayout.unified
                            ? ChangesLayout.split
                            : ChangesLayout.unified,
                      ),
                ),
                if (files.isNotEmpty) ...[
                  _DiffViewModeToggle(
                    viewMode: changesPreferences.viewMode,
                    onToggle: () {
                      final next =
                          changesPreferences.viewMode == ChangesViewMode.flat
                          ? ChangesViewMode.tree
                          : ChangesViewMode.flat;
                      if (next == ChangesViewMode.tree) {
                        _diffViewController.enterTreeView();
                      }
                      ref
                          .read(changesPreferencesProvider.notifier)
                          .updatePreferences(viewMode: next);
                    },
                  ),
                  _DiffExpandAllToggle(
                    allExpanded: _diffViewController.allExpanded(
                      files,
                      changesPreferences.viewMode,
                    ),
                    onToggle: () => _diffViewController.toggleExpandAll(
                      files,
                      changesPreferences.viewMode,
                    ),
                  ),
                ],
                _DiffOptionsMenu(
                  hideWhitespace: changesPreferences.hideWhitespace,
                  wrapLines: changesPreferences.wrapLines,
                  onToggleHideWhitespace: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        hideWhitespace: !changesPreferences.hideWhitespace,
                      ),
                  onToggleWrapLines: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        wrapLines: !changesPreferences.wrapLines,
                      ),
                  onRefresh: () =>
                      ref.read(diffProvider(widget.cwd).notifier).refresh(),
                ),
              ],
            ),
          ),
          const Divider(),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (files.isNotEmpty) ...[
                  _DiffViewModeToggle(
                    viewMode: changesPreferences.viewMode,
                    onToggle: () {
                      final next =
                          changesPreferences.viewMode == ChangesViewMode.flat
                          ? ChangesViewMode.tree
                          : ChangesViewMode.flat;
                      if (next == ChangesViewMode.tree) {
                        _diffViewController.enterTreeView();
                      }
                      ref
                          .read(changesPreferencesProvider.notifier)
                          .updatePreferences(viewMode: next);
                    },
                  ),
                  _DiffExpandAllToggle(
                    allExpanded: _diffViewController.allExpanded(
                      files,
                      changesPreferences.viewMode,
                    ),
                    onToggle: () => _diffViewController.toggleExpandAll(
                      files,
                      changesPreferences.viewMode,
                    ),
                  ),
                ],
                _DiffOptionsMenu(
                  compact: true,
                  hideWhitespace: changesPreferences.hideWhitespace,
                  wrapLines: changesPreferences.wrapLines,
                  onToggleHideWhitespace: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        hideWhitespace: !changesPreferences.hideWhitespace,
                      ),
                  onToggleWrapLines: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        wrapLines: !changesPreferences.wrapLines,
                      ),
                  onRefresh: () =>
                      ref.read(diffProvider(widget.cwd).notifier).refresh(),
                ),
              ],
            ),
          ),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressRing()),
            error: (e, _) => Center(child: Text('Failed to load diff: $e')),
            data: (diff) => DiffView(
              diff: diff,
              layout: changesPreferences.layout,
              viewMode: changesPreferences.viewMode,
              wrapLines: changesPreferences.wrapLines,
              codeFontSize: codeAppearance.codeFontSize,
              monoFontFamily: codeAppearance.monoFontFamily,
              controller: _diffViewController,
              onOpenFile: widget.onOpenWorkspaceFile == null ? null : _openFile,
              onCopyPath: _copyPath,
              onDownload: _download,
              onAddToChat: _addToChat,
            ),
          ),
        ),
      ],
    );
  }

  void _openFile(String path) => widget.onOpenWorkspaceFile!(
    WorkspaceFileOpenRequest(
      location: WorkspaceFileLocation(path: path),
      disposition: OpenFileDisposition.main,
    ),
  );

  void _copyPath(String path) {
    final resolved = resolveWorkspaceFilePaths(
      path: path,
      workspaceRoot: widget.cwd,
    );
    Clipboard.setData(ClipboardData(text: resolved?.absolutePath ?? path));
  }

  void _addToChat(String path) {
    ref
        .read(workspaceAttachmentsProvider(widget.cwd).notifier)
        .add(_workspaceFileAttachment(path));
  }

  void _download(String path) {
    unawaited(
      ref
          .read(daemonClientProvider)
          .requestFileDownloadUri(cwd: widget.cwd, path: path)
          .then(
            (uri) => ref.read(externalUrlLauncherProvider).open(uri.toString()),
          ),
    );
  }
}

class _LiveDiffPane extends ConsumerWidget {
  const _LiveDiffPane({
    required this.serverId,
    required this.workspaceId,
    required this.cwd,
    required this.compact,
    required this.diffViewController,
    required this.onOpenWorkspaceFile,
  });

  final String serverId;
  final String? workspaceId;
  final String cwd;
  final bool compact;
  final DiffViewController diffViewController;
  final ValueChanged<WorkspaceFileOpenRequest>? onOpenWorkspaceFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref
        .watch(workspaceCheckoutStatusProvider((serverId: serverId, cwd: cwd)))
        .value;
    final changesPreferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();
    final codeAppearance = ref.watch(codeAppearanceProvider);
    final ignoreWhitespace = changesPreferences.hideWhitespace;
    final scopeKey = buildWorkingDiffScopeKey(
      serverId: serverId,
      workspaceId: workspaceId,
      cwd: cwd,
      baseRef: status?.baseRef,
      ignoreWhitespace: ignoreWhitespace,
    );
    final isDirty = status?.isGit == true && status?.isDirty == true;
    final override = ref.watch(
      workingDiffOverrideProvider.select((overrides) => overrides[scopeKey]),
    );
    final mode = resolveWorkingDiffMode(isDirty: isDirty, override: override);
    final compare = CheckoutDiffCompare(
      mode: mode,
      baseRef: mode == CheckoutDiffMode.base ? status?.baseRef : null,
      ignoreWhitespace: ignoreWhitespace,
    );
    final query = CheckoutDiffQuery(
      serverId: serverId,
      cwd: cwd,
      compare: compare,
    );
    final reviewDraftKey = buildReviewDraftKey(
      serverId: serverId,
      workspaceId: workspaceId,
      cwd: cwd,
      mode: mode,
      baseRef: status?.baseRef,
      ignoreWhitespace: ignoreWhitespace,
    );
    final reviewComments = ref.watch(
      reviewDraftProvider.select(
        (state) => state.drafts[reviewDraftKey] ?? const [],
      ),
    );
    final AsyncValue<CheckoutDiffPayload?> diffAsync = switch (status) {
      null => const AsyncLoading(),
      final value when value.isGit => ref.watch(checkoutDiffProvider(query)),
      _ => const AsyncData(null),
    };
    final baseLabel = switch (status?.baseRef?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => 'base',
    };
    final files = diffAsync.value?.toLegacyDiff().files ?? const <DiffFile>[];

    void selectMode(CheckoutDiffMode selected) {
      ref
          .read(workingDiffOverrideProvider.notifier)
          .select(
            scopeKey: scopeKey,
            serverId: serverId,
            cwd: cwd,
            mode: selected,
            isDirty: isDirty,
          );
    }

    final toolbar = Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 4),
      child: Row(
        children: [
          if (!compact)
            Expanded(
              child: Text(
                cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textStyles.bodySmall,
              ),
            )
          else
            const Spacer(),
          SizedBox(
            width: 150,
            child: ComboBox<CheckoutDiffMode>(
              value: mode,
              isExpanded: true,
              items: [
                const ComboBoxItem(
                  value: CheckoutDiffMode.uncommitted,
                  child: Text('Uncommitted'),
                ),
                ComboBoxItem(
                  value: CheckoutDiffMode.base,
                  child: Text('Against $baseLabel'),
                ),
              ],
              onChanged: (value) {
                if (value != null) selectMode(value);
              },
            ),
          ),
          if (!compact)
            _DiffLayoutToggle(
              layout: changesPreferences.layout,
              onToggle: () => ref
                  .read(changesPreferencesProvider.notifier)
                  .updatePreferences(
                    layout: changesPreferences.layout == ChangesLayout.unified
                        ? ChangesLayout.split
                        : ChangesLayout.unified,
                  ),
            ),
          if (!compact && files.isNotEmpty) ...[
            _DiffViewModeToggle(
              viewMode: changesPreferences.viewMode,
              onToggle: () {
                final next = changesPreferences.viewMode == ChangesViewMode.flat
                    ? ChangesViewMode.tree
                    : ChangesViewMode.flat;
                if (next == ChangesViewMode.tree) {
                  diffViewController.enterTreeView();
                }
                ref
                    .read(changesPreferencesProvider.notifier)
                    .updatePreferences(viewMode: next);
              },
            ),
            _DiffExpandAllToggle(
              allExpanded: diffViewController.allExpanded(
                files,
                changesPreferences.viewMode,
              ),
              onToggle: () => diffViewController.toggleExpandAll(
                files,
                changesPreferences.viewMode,
              ),
            ),
          ],
          _DiffOptionsMenu(
            compact: compact,
            hideWhitespace: ignoreWhitespace,
            wrapLines: changesPreferences.wrapLines,
            onToggleHideWhitespace: () => ref
                .read(changesPreferencesProvider.notifier)
                .updatePreferences(hideWhitespace: !ignoreWhitespace),
            onToggleWrapLines: () => ref
                .read(changesPreferencesProvider.notifier)
                .updatePreferences(wrapLines: !changesPreferences.wrapLines),
            onRefresh: () => ref.invalidate(checkoutDiffProvider(query)),
          ),
        ],
      ),
    );

    return Column(
      children: [
        toolbar,
        if (!compact) const Divider(),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressRing()),
            error: (error, _) =>
                Center(child: Text('Failed to load diff: $error')),
            data: (payload) {
              if (payload?.error case final error?) {
                return Center(
                  child: Text('Failed to load diff: ${error.message}'),
                );
              }
              final diff =
                  payload?.toLegacyDiff() ?? const DiffResponse(files: []);
              final reviewAttachment = buildReviewAttachment(
                cwd: cwd,
                mode: mode,
                baseRef: status?.baseRef,
                comments: reviewComments,
                diff: diff,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final attachments = ref.read(
                  workspaceAttachmentsProvider(cwd).notifier,
                );
                if (reviewAttachment == null) {
                  attachments.remove('review', 'working-diff-review');
                } else {
                  attachments.add(
                    WorkspaceContextAttachment(
                      kind: 'review',
                      id: 'working-diff-review',
                      title: 'Code review',
                      subtitle: '${reviewAttachment.comments.length} comments',
                      text: reviewAttachment.comments
                          .map((comment) => comment.body)
                          .join('\n'),
                      url: null,
                      semanticAttachment: reviewAttachment,
                      reviewDraftKey: reviewDraftKey,
                    ),
                  );
                }
              });
              return DiffView(
                diff: diff,
                reviewDraftKey: reviewDraftKey,
                layout: changesPreferences.layout,
                viewMode: changesPreferences.viewMode,
                wrapLines: changesPreferences.wrapLines,
                codeFontSize: codeAppearance.codeFontSize,
                monoFontFamily: codeAppearance.monoFontFamily,
                controller: diffViewController,
                onOpenFile: onOpenWorkspaceFile == null
                    ? null
                    : (path) => onOpenWorkspaceFile!(
                        WorkspaceFileOpenRequest(
                          location: WorkspaceFileLocation(path: path),
                          disposition: OpenFileDisposition.main,
                        ),
                      ),
                onCopyPath: (path) {
                  final resolved = resolveWorkspaceFilePaths(
                    path: path,
                    workspaceRoot: cwd,
                  );
                  Clipboard.setData(
                    ClipboardData(text: resolved?.absolutePath ?? path),
                  );
                },
                onDownload: (path) => unawaited(
                  ref
                      .read(daemonClientProvider)
                      .requestFileDownloadUri(cwd: cwd, path: path)
                      .then(
                        (uri) => ref
                            .read(externalUrlLauncherProvider)
                            .open(uri.toString()),
                      ),
                ),
                onAddToChat: (path) => ref
                    .read(workspaceAttachmentsProvider(cwd).notifier)
                    .add(_workspaceFileAttachment(path)),
              );
            },
          ),
        ),
      ],
    );
  }
}

WorkspaceContextAttachment _workspaceFileAttachment(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final title = normalized.split('/').last;
  return WorkspaceContextAttachment(
    kind: 'file',
    id: normalized,
    title: title,
    subtitle: normalized,
    text: normalized,
    url: null,
    semanticAttachment: TextAgentAttachment(title: title, text: normalized),
  );
}

class _DiffLayoutToggle extends StatelessWidget {
  const _DiffLayoutToggle({required this.layout, required this.onToggle});

  final ChangesLayout layout;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final split = layout == ChangesLayout.split;
    final label = split
        ? 'Switch to unified diff'
        : 'Switch to side-by-side diff';
    return Tooltip(
      message: label,
      child: IconButton(
        key: const ValueKey('changes-toggle-layout'),
        icon: Icon(
          split ? FluentIcons.align_justify : FluentIcons.column,
          size: 16,
        ),
        onPressed: onToggle,
      ),
    );
  }
}

class _DiffViewModeToggle extends StatelessWidget {
  const _DiffViewModeToggle({required this.viewMode, required this.onToggle});

  final ChangesViewMode viewMode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tree = viewMode == ChangesViewMode.tree;
    final label = tree ? 'Show flat file list' : 'Show folder tree';
    return Tooltip(
      message: label,
      child: IconButton(
        key: const ValueKey('changes-toggle-view-mode'),
        icon: Icon(tree ? FluentIcons.list : FluentIcons.folder, size: 16),
        onPressed: onToggle,
      ),
    );
  }
}

class _DiffExpandAllToggle extends StatelessWidget {
  const _DiffExpandAllToggle({
    required this.allExpanded,
    required this.onToggle,
  });

  final bool allExpanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final label = allExpanded ? 'Collapse all files' : 'Expand all files';
    return Tooltip(
      message: label,
      child: IconButton(
        key: const ValueKey('changes-toggle-expand-all'),
        icon: Icon(
          allExpanded ? FluentIcons.collapse_content : FluentIcons.expand_all,
          size: 16,
        ),
        onPressed: onToggle,
      ),
    );
  }
}

class _DiffOptionsMenu extends StatefulWidget {
  const _DiffOptionsMenu({
    required this.hideWhitespace,
    required this.wrapLines,
    required this.onToggleHideWhitespace,
    required this.onToggleWrapLines,
    required this.onRefresh,
    this.compact = false,
  });

  final bool hideWhitespace;
  final bool wrapLines;
  final VoidCallback onToggleHideWhitespace;
  final VoidCallback onToggleWrapLines;
  final VoidCallback onRefresh;
  final bool compact;

  @override
  State<_DiffOptionsMenu> createState() => _DiffOptionsMenuState();
}

class _DiffOptionsMenuState extends State<_DiffOptionsMenu> {
  final _controller = FlyoutController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showMenu() async {
    if (!_controller.isAttached || _controller.isOpen) return;
    await _controller.showFlyout<void>(
      placementMode: FlyoutPlacementMode.bottomRight,
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints.tightFor(width: 240),
        items: [
          ToggleMenuFlyoutItem(
            value: widget.hideWhitespace,
            text: Text(
              widget.hideWhitespace ? 'Show whitespace' : 'Hide whitespace',
            ),
            onChanged: (_) => widget.onToggleHideWhitespace(),
          ),
          ToggleMenuFlyoutItem(
            value: widget.wrapLines,
            text: Text(
              widget.wrapLines ? 'Scroll long lines' : 'Wrap long lines',
            ),
            onChanged: (_) => widget.onToggleWrapLines(),
          ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(
            key: const ValueKey('changes-refresh'),
            leading: const Icon(FluentIcons.refresh, size: 14),
            text: const Text('Refresh'),
            onPressed: widget.onRefresh,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: Tooltip(
        message: 'Diff options',
        child: IconButton(
          key: const ValueKey('changes-options-menu'),
          icon: Icon(FluentIcons.chevron_down, size: widget.compact ? 14 : 16),
          onPressed: () => unawaited(_showMenu()),
        ),
      ),
    );
  }
}
