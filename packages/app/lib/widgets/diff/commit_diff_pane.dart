import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/changes_preferences_provider.dart';
import '../../state/checkout_commits_provider.dart';
import '../../state/code_appearance_provider.dart';
import '../../state/workspace_checkout_status_provider.dart';
import 'diff_view.dart';

class CommitDiffPane extends ConsumerStatefulWidget {
  const CommitDiffPane({
    super.key,
    required this.serverId,
    required this.cwd,
    required this.sha,
  });

  final String serverId;
  final String cwd;
  final String sha;

  @override
  ConsumerState<CommitDiffPane> createState() => _CommitDiffPaneState();
}

class _CommitDiffPaneState extends ConsumerState<CommitDiffPane> {
  final _controller = DiffViewController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(
      checkoutStatusDaemonClientProvider(widget.serverId),
    );
    if (!supportsCheckoutCommits(client)) {
      return const Center(child: Text('Update the host to view commit diffs.'));
    }
    if (widget.cwd.trim().isEmpty) {
      return const Center(child: Text('Workspace directory is unavailable.'));
    }
    final preferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();
    final appearance = ref.watch(codeAppearanceProvider);
    final commitsAsync = ref.watch(
      checkoutCommitsProvider((serverId: widget.serverId, cwd: widget.cwd)),
    );

    Widget content;
    if (commitsAsync.isLoading) {
      content = const Center(child: ProgressRing());
    } else if (commitsAsync.hasError ||
        commitsAsync.value?.error != null ||
        commitsAsync.value == null) {
      content = const Center(child: Text('Failed to load commits'));
    } else {
      final commit = commitsAsync.value!.commits
          .where((candidate) => candidate.sha == widget.sha)
          .firstOrNull;
      content = commit == null
          ? const Center(child: Text('No changes to display'))
          : _commitContent(
              context,
              commit,
              preferences,
              appearance.codeFontSize,
              appearance.monoFontFamily,
            );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Tooltip(
                message: preferences.layout == ChangesLayout.split
                    ? 'Show unified diff'
                    : 'Show split diff',
                child: IconButton(
                  key: const ValueKey('commit-diff-layout-toggle'),
                  icon: Icon(
                    preferences.layout == ChangesLayout.split
                        ? FluentIcons.single_column
                        : FluentIcons.column_left_two_thirds,
                    size: 14,
                  ),
                  onPressed: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        layout: preferences.layout == ChangesLayout.unified
                            ? ChangesLayout.split
                            : ChangesLayout.unified,
                      ),
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: context.paseoPalette.border),
        Expanded(child: content),
      ],
    );
  }

  Widget _commitContent(
    BuildContext context,
    CheckoutCommit commit,
    ChangesPreferences preferences,
    double codeFontSize,
    String monoFontFamily,
  ) {
    var loading = false;
    String? error;
    final files = <CheckoutDiffFile>[];
    for (final metadata in commit.files) {
      final result = ref.watch(
        checkoutCommitFileDiffProvider((
          serverId: widget.serverId,
          cwd: widget.cwd,
          sha: commit.sha,
          path: metadata.path,
        )),
      );
      if (result.hasError) {
        error ??= 'Failed to load file diff';
        continue;
      }
      if (result.isLoading || result.value == null) {
        loading = true;
        continue;
      }
      if (result.value!.error != null) {
        error ??= 'Failed to load file diff';
        continue;
      }
      final file = result.value!.file;
      files.add(
        file ??
            CheckoutDiffFile(
              path: metadata.path,
              isNew: metadata.status == CheckoutCommitFileStatus.added,
              isDeleted: metadata.status == CheckoutCommitFileStatus.deleted,
              additions: metadata.additions,
              deletions: metadata.deletions,
              hunks: const [],
              status: CheckoutDiffFileStatus.binary,
            ),
      );
    }
    if (error != null) {
      return Center(child: Text(error));
    }
    if (loading) {
      return const Center(child: ProgressRing());
    }
    if (files.isEmpty) {
      return const Center(child: Text('No changes to display'));
    }
    final diff = CheckoutDiffPayload(
      subscriptionId: '',
      cwd: widget.cwd,
      files: files,
      error: null,
    ).toLegacyDiff();
    return DiffView(
      diff: diff,
      layout: preferences.layout,
      viewMode: preferences.viewMode,
      wrapLines: preferences.wrapLines,
      codeFontSize: codeFontSize,
      monoFontFamily: monoFontFamily,
      controller: _controller,
    );
  }
}
