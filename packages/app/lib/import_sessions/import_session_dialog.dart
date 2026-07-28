import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../providers/providers_snapshot.dart';
import '../state/providers_snapshot_provider.dart';
import 'import_session_view_model.dart';

typedef ImportSessionSnapshotLoader =
    Future<List<ProviderSnapshotEntry>> Function();
typedef ImportSessionProviderLoader =
    Future<FetchRecentProviderSessionsResponse> Function(String provider);
typedef ImportSessionImporter =
    Future<ImportAgentStatusResponse> Function(
      RecentProviderSessionDescriptor entry,
    );

Future<AgentSummary?> showImportSessionDialog({
  required BuildContext context,
  required DaemonClient? client,
  String? cwd,
  String? workspaceId,
  void Function(AgentSummary agent)? onImported,
}) => showDialog<AgentSummary>(
  context: context,
  builder: (context) => ImportSessionDialog(
    client: client,
    cwd: cwd,
    workspaceId: workspaceId,
    onImported: onImported,
  ),
);

/// Paseo 0.2.0's adaptive import-session sheet represented as a bounded
/// desktop dialog and a viewport-filling compact dialog.
class ImportSessionDialog extends ConsumerStatefulWidget {
  const ImportSessionDialog({
    super.key,
    required this.client,
    this.cwd,
    this.workspaceId,
    this.onImported,
    this.supportsSnapshot,
    this.supportsWorkspaceTarget,
    this.snapshotLoader,
    this.providerLoader,
    this.importer,
  });

  final DaemonClient? client;
  final String? cwd;
  final String? workspaceId;
  final void Function(AgentSummary agent)? onImported;

  /// Test seams also model an older host without requiring a real socket.
  final bool? supportsSnapshot;
  final bool? supportsWorkspaceTarget;
  final ImportSessionSnapshotLoader? snapshotLoader;
  final ImportSessionProviderLoader? providerLoader;
  final ImportSessionImporter? importer;

  @override
  ConsumerState<ImportSessionDialog> createState() =>
      _ImportSessionDialogState();
}

class _ImportSessionDialogState extends ConsumerState<ImportSessionDialog> {
  List<ProviderSnapshotEntry>? _snapshot;
  List<String>? _providers;
  List<ImportSessionsQueryResult> _queries = const [];
  String _selectedProvider = allImportSessionProviders;
  bool _loadingSnapshot = false;
  bool _snapshotFailed = false;
  bool _refreshing = false;
  bool _importFailed = false;
  String? _importingKey;
  int _generation = 0;

  bool get _supportsSnapshot =>
      widget.supportsSnapshot ??
      widget.client?.serverInfo?.features['providersSnapshot'] == true;

  bool get _supportsWorkspaceTarget =>
      widget.supportsWorkspaceTarget ??
      widget.client?.serverInfo?.features['importSessionWorkspaceTarget'] ==
          true;

  bool get _requiresUpgrade => requiresImportSessionsHostUpgrade(
    supportsSnapshot: _supportsSnapshot,
    workspaceId: widget.workspaceId,
    supportsWorkspaceTarget: _supportsWorkspaceTarget,
  );

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  @override
  void didUpdateWidget(covariant ImportSessionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.cwd != widget.cwd ||
        oldWidget.workspaceId != widget.workspaceId) {
      Future<void>.microtask(_load);
    }
  }

  Future<List<ProviderSnapshotEntry>> _fetchSnapshot() async {
    final override = widget.snapshotLoader;
    if (override != null) return override();
    final client = widget.client!;
    final scope = ProvidersSnapshotScope(
      client: client,
      serverId: client.serverInfo?.serverId,
      cwd: widget.cwd,
    );
    await ref.read(providersSnapshotProvider(scope).notifier).ensureLoaded();
    final snapshot = ref.read(providersSnapshotProvider(scope));
    if (snapshot.error != null) throw StateError(snapshot.error!);
    return snapshot.entries ?? const [];
  }

  Future<FetchRecentProviderSessionsResponse> _fetchProvider(String provider) {
    final override = widget.providerLoader;
    if (override != null) return override(provider);
    return widget.client!.fetchRecentProviderSessions(
      cwd: widget.cwd,
      providers: [provider],
      limit: importSessionsPerProviderLimit,
    );
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _importFailed = false;
      _snapshotFailed = false;
      _loadingSnapshot = true;
      _refreshing = true;
      _snapshot = null;
      _providers = null;
      _queries = const [];
      _selectedProvider = allImportSessionProviders;
    });
    if (widget.client == null || _requiresUpgrade) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingSnapshot = false;
        _refreshing = false;
      });
      return;
    }
    try {
      final snapshot = await _fetchSnapshot();
      if (!mounted || generation != _generation) return;
      final providers = resolveImportSessionProviders(true, snapshot)!;
      setState(() {
        _snapshot = snapshot;
        _providers = providers;
        _loadingSnapshot = false;
        _queries = [
          for (final _ in providers)
            const ImportSessionsQueryResult(isLoading: true, isPending: true),
        ];
      });
      await Future.wait([
        for (var index = 0; index < providers.length; index++)
          _loadProvider(generation, index, providers[index]),
      ]);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingSnapshot = false;
        _snapshotFailed = true;
        _queries = const [];
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _loadProvider(int generation, int index, String provider) async {
    try {
      final response = await _fetchProvider(provider);
      if (!mounted || generation != _generation) return;
      _replaceQuery(index, ImportSessionsQueryResult(data: response));
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _replaceQuery(index, const ImportSessionsQueryResult(isError: true));
    }
  }

  void _replaceQuery(int index, ImportSessionsQueryResult value) {
    setState(() {
      final next = List<ImportSessionsQueryResult>.of(_queries);
      next[index] = value;
      _queries = next;
    });
  }

  Future<void> _import(RecentProviderSessionDescriptor entry) async {
    if (_importingKey != null) return;
    final key = '${entry.providerId}:${entry.providerHandleId}';
    setState(() {
      _importingKey = key;
      _importFailed = false;
    });
    try {
      final importer = widget.importer;
      final result = importer != null
          ? await importer(entry)
          : await widget.client!.importProviderSession(
              providerId: entry.providerId,
              providerHandleId: entry.providerHandleId,
              cwd: entry.cwd,
              workspaceId: widget.workspaceId,
            );
      final agent = result.agent!;
      widget.onImported?.call(agent);
      if (mounted) Navigator.of(context).pop(agent);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _importingKey = null;
        _importFailed = true;
      });
    }
  }

  String _timeAgo(String value) {
    final instant = DateTime.tryParse(value);
    if (instant == null) return value;
    final elapsed = DateTime.now().toUtc().difference(instant.toUtc());
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
    if (elapsed.inDays < 30) return '${elapsed.inDays}d ago';
    return '${(elapsed.inDays / 30).floor()}mo ago';
  }

  @override
  Widget build(BuildContext context) {
    final labels = buildImportProviderLabelMap(_snapshot);
    final entries = aggregateImportSessionEntries(_queries);
    final visibleEntries = _selectedProvider == allImportSessionProviders
        ? entries
        : entries
              .where((entry) => entry.providerId == _selectedProvider)
              .toList();
    final providers = [...?_providers]..sort();
    final isQuerying = _queries.isNotEmpty;
    final loadingSessions =
        _loadingSnapshot ||
        (isQuerying &&
            _queries.any((query) => query.isLoading || query.isPending));
    final allErrored =
        _snapshotFailed ||
        (isQuerying && _queries.every((query) => query.isError));
    final allSettled =
        isQuerying &&
        _queries.every((query) => !query.isLoading && !query.isPending);
    final erroredLabels = collectErroredImportProviderLabels(
      providers: _providers,
      queries: _queries,
      providerLabels: labels,
    );
    final empty = computeImportSessionsEmptyState(
      isLoadingSessions: loadingSessions,
      allQueriesErrored: allErrored,
      isQueryingProviders: isQuerying,
      allQueriesSettled: allSettled,
      selectedProvider: _selectedProvider,
      aggregatedCount: entries.length,
      visibleCount: visibleEntries.length,
      totalAlreadyImportedCount: sumAlreadyImportedSessions(_queries),
      providerLabels: labels,
    );
    final compact = MediaQuery.sizeOf(context).width < 600;
    final maxHeight = MediaQuery.sizeOf(context).height * (compact ? .92 : .7);

    return ContentDialog(
      key: const ValueKey('import-session-sheet'),
      constraints: BoxConstraints(
        maxWidth: compact ? double.infinity : 560,
        maxHeight: maxHeight,
      ),
      title: Row(
        children: [
          const Expanded(child: Text('Import session')),
          IconButton(
            key: const ValueKey('import-session-refresh'),
            onPressed: _refreshing ? null : _load,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 16,
                    child: ProgressRing(strokeWidth: 2),
                  )
                : const Icon(FluentIcons.refresh, size: 16),
          ),
        ],
      ),
      content: SizedBox(
        width: compact ? MediaQuery.sizeOf(context).width : 528,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (providers.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: ComboBox<String>(
                    key: const ValueKey('import-session-filter-trigger'),
                    value: _selectedProvider,
                    items: [
                      const ComboBoxItem(
                        value: allImportSessionProviders,
                        child: Text('All'),
                      ),
                      for (final provider in providers)
                        ComboBoxItem(
                          value: provider,
                          child: Text(labels[provider] ?? provider),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedProvider = value);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (widget.client == null)
                const Text('Connect to a host to import sessions')
              else if (_requiresUpgrade)
                const Text('Update the host to import sessions.')
              else if (_providers?.isEmpty == true)
                const Text('No compatible providers are available.'),
              if (loadingSessions && visibleEntries.isEmpty)
                const _ImportStatus(
                  progress: true,
                  text: 'Loading recent sessions…',
                ),
              if (allErrored) const Text('Could not load recent sessions.'),
              if (!allErrored && erroredLabels.isNotEmpty)
                Text(
                  'Could not load sessions from: ${erroredLabels.join(', ')}',
                ),
              if (_importFailed)
                const Text('Could not import selected session.'),
              if (visibleEntries.isNotEmpty)
                for (final entry in visibleEntries)
                  _ImportSessionRow(
                    entry: entry,
                    showCwd: widget.cwd == null,
                    disabled: _importingKey != null,
                    importing:
                        _importingKey ==
                        '${entry.providerId}:${entry.providerHandleId}',
                    timeAgo: _timeAgo(entry.lastActivityAt),
                    onPressed: () => _import(entry),
                  ),
              if (empty.show)
                Padding(
                  key: const ValueKey('import-session-empty-state'),
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Column(
                    children: [
                      const Icon(FluentIcons.inbox, size: 28),
                      const SizedBox(height: 10),
                      Text(empty.title, textAlign: TextAlign.center),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: _importingKey == null
              ? () => Navigator.of(context).pop()
              : null,
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ImportStatus extends StatelessWidget {
  const _ImportStatus({required this.progress, required this.text});

  final bool progress;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (progress) ...[
        const SizedBox.square(
          dimension: 16,
          child: ProgressRing(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
      ],
      Expanded(child: Text(text)),
    ],
  );
}

class _ImportSessionRow extends StatelessWidget {
  const _ImportSessionRow({
    required this.entry,
    required this.showCwd,
    required this.disabled,
    required this.importing,
    required this.timeAgo,
    required this.onPressed,
  });

  final RecentProviderSessionDescriptor entry;
  final bool showCwd;
  final bool disabled;
  final bool importing;
  final String timeAgo;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Button(
      key: ValueKey(
        'import-session-session-${entry.providerId}-'
        '${entry.providerHandleId}',
      ),
      onPressed: disabled ? null : onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(FluentIcons.download, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          importSessionTitle(entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(importing ? 'Importing…' : timeAgo),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    importSessionPromptPreview(entry),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showCwd) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
