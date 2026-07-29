import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../providers/provider_diagnostic_models.dart';
import '../providers/providers_snapshot.dart';
import '../state/daemon_config_provider.dart';
import '../state/daemon_providers.dart';
import '../state/providers_snapshot_provider.dart';
import 'adaptive_modal_sheet.dart';
import 'provider_diagnostic_dialog.dart';

Future<void> showProviderSettingsSheet({
  required BuildContext context,
  required String serverId,
  required String provider,
}) => showAdaptiveModalSheet<void>(
  context: context,
  builder: (context) =>
      ProviderSettingsSheet(serverId: serverId, provider: provider),
);

class ProviderSettingsSheet extends ConsumerStatefulWidget {
  const ProviderSettingsSheet({
    super.key,
    required this.serverId,
    required this.provider,
  });

  final String serverId;
  final String provider;

  @override
  ConsumerState<ProviderSettingsSheet> createState() =>
      _ProviderSettingsSheetState();
}

class _ProviderSettingsSheetState extends ConsumerState<ProviderSettingsSheet> {
  ProviderDiscoveredModelsCache? _discoveredCache;
  String _query = '';
  String? _deletingModelId;
  String? _operationError;
  late final Timer _clock;
  var _clockTick = 0;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _clockTick++);
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  ProvidersSnapshotScope _scope() => ProvidersSnapshotScope(
    client: ref.read(daemonClientProvider),
    serverId: widget.serverId,
  );

  List<MutableDaemonProviderModel> _additionalModels() =>
      ref
          .read(daemonConfigProvider)
          .value
          ?.providers[widget.provider]
          ?.additionalModels ??
      const [];

  Future<void> _replaceAdditionalModels(
    List<MutableDaemonProviderModel> models, {
    String? deletingModelId,
  }) async {
    setState(() {
      _operationError = null;
      _deletingModelId = deletingModelId;
    });
    try {
      final current = ref
          .read(daemonConfigProvider)
          .value
          ?.providers[widget.provider];
      await ref
          .read(daemonConfigProvider.notifier)
          .patch(
            MutableDaemonConfigPatch(
              providers: {
                widget.provider: MutableDaemonProviderConfig(
                  enabled: current?.enabled,
                  additionalModels: models,
                  extra: current?.extra ?? const {},
                ),
              },
            ),
          );
      await ref.read(providersSnapshotProvider(_scope()).notifier).refresh([
        widget.provider,
      ]);
    } catch (error) {
      if (mounted) setState(() => _operationError = '$error');
      rethrow;
    } finally {
      if (mounted && deletingModelId != null) {
        setState(() => _deletingModelId = null);
      }
    }
  }

  void _deleteCustomModel(String modelId) {
    final next = [
      for (final model in _additionalModels())
        if (model.id != modelId) model,
    ];
    unawaited(
      _replaceAdditionalModels(
        next,
        deletingModelId: modelId,
      ).catchError((_) {}),
    );
  }

  Future<void> _openAddModel() => showAdaptiveModalSheet<void>(
    context: context,
    builder: (context) => AddCustomProviderModelSheet(
      existingModels: _additionalModels(),
      onAdd: (model) =>
          _replaceAdditionalModels([..._additionalModels(), model]),
    ),
  );

  Future<void> _openDiagnostic() => showProviderDiagnosticDialog(
    context: context,
    client: ref.read(daemonClientProvider),
    provider: widget.provider,
  );

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(daemonClientProvider);
    final scope = ProvidersSnapshotScope(
      client: client,
      serverId: widget.serverId,
    );
    final snapshot = ref.watch(providersSnapshotProvider(scope));
    final config = ref.watch(daemonConfigProvider).value;
    ProviderSnapshotEntry? providerEntry;
    for (final entry in snapshot.entries ?? const <ProviderSnapshotEntry>[]) {
      if (entry.provider == widget.provider) {
        providerEntry = entry;
        break;
      }
    }
    final label = providerEntry?.label ?? widget.provider;
    final refreshing =
        snapshot.isRefreshing ||
        providerEntry?.status == ProviderCatalogStatus.loading;
    final resolution = resolveProviderDiscoveredModels(
      serverId: widget.serverId,
      provider: widget.provider,
      currentModels: providerEntry?.models,
      providerSnapshotRefreshing: refreshing,
      previousCache: _discoveredCache,
    );
    _discoveredCache = resolution.cache;
    final additional =
        config?.providers[widget.provider]?.additionalModels ?? const [];
    final discovered = rankProviderModels(
      resolution.models,
      _query,
      (model) => [model.label, model.id, model.description ?? ''],
    );
    final custom = rankProviderModels(
      additional,
      _query,
      (model) => [model.label, model.id],
    );
    final fetchedAt = DateTime.tryParse(providerEntry?.fetchedAt ?? '');
    final fetchedAtLabel = fetchedAt == null
        ? null
        : formatProviderFetchedAt(fetchedAt, now: DateTime.now());
    void refreshProvider() {
      unawaited(
        ref.read(providersSnapshotProvider(scope).notifier).refresh([
          widget.provider,
        ]),
      );
    }

    return AdaptiveModalSheet(
      key: const ValueKey('provider-settings-sheet'),
      title: label,
      onClose: () => Navigator.of(context).pop(),
      compactInitialHeightFactor: .65,
      compactMaxHeightFactor: .92,
      sizeContentToCurrentSnapPoint: true,
      headerContent: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.paseoPalette.border),
          ),
        ),
        child: TextBox(
          key: const ValueKey('provider-settings-search'),
          placeholder: 'Search models',
          prefix: const Padding(
            padding: EdgeInsets.only(left: 10),
            child: Icon(FluentIcons.search, size: 14),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
      ),
      content: ProviderSettingsModelsBody(
        discoveredModels: discovered,
        customModels: custom,
        totalDiscovered: resolution.models.length,
        totalCustom: additional.length,
        searching: _query.trim().isNotEmpty,
        refreshing: refreshing,
        error:
            _operationError ??
            (providerEntry?.status == ProviderCatalogStatus.error
                ? providerEntry?.error ?? 'Unknown provider error'
                : snapshot.error),
        deletingModelId: _deletingModelId,
        onDeleteCustomModel: _deleteCustomModel,
        onRetry: refreshProvider,
      ),
      footer: ProviderSettingsFooter(
        updatedLabel: fetchedAtLabel,
        refreshing: refreshing,
        onAddModel: _openAddModel,
        onOpenDiagnostic: _openDiagnostic,
        onRefresh: refreshProvider,
      ),
    );
  }
}

class ProviderSettingsModelsBody extends StatelessWidget {
  const ProviderSettingsModelsBody({
    super.key,
    required this.discoveredModels,
    required this.customModels,
    required this.totalDiscovered,
    required this.totalCustom,
    required this.searching,
    required this.refreshing,
    required this.error,
    required this.deletingModelId,
    required this.onDeleteCustomModel,
    required this.onRetry,
  });

  final List<ProviderModelDefinition> discoveredModels;
  final List<MutableDaemonProviderModel> customModels;
  final int totalDiscovered;
  final int totalCustom;
  final bool searching;
  final bool refreshing;
  final String? error;
  final String? deletingModelId;
  final ValueChanged<String> onDeleteCustomModel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (totalDiscovered == 0 && totalCustom == 0 && refreshing) {
      return const _ProviderEmptyState(
        progress: true,
        message: 'Loading models...',
      );
    }
    if (totalDiscovered == 0 && totalCustom == 0 && error != null) {
      return _ProviderEmptyState(
        icon: FluentIcons.warning,
        message: error!,
        action: Button(
          key: const ValueKey('retry-provider-models'),
          onPressed: onRetry,
          child: Text(refreshing ? 'Retrying…' : 'Retry'),
        ),
      );
    }
    if (discoveredModels.isEmpty && customModels.isEmpty && searching) {
      return const _ProviderEmptyState(message: 'No models match your search');
    }
    if (totalDiscovered == 0 && totalCustom == 0) {
      return const _ProviderEmptyState(message: 'No models detected');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          InfoBar(
            title: const Text('Unable to update provider models'),
            content: Text(error!),
            severity: InfoBarSeverity.error,
          ),
          const SizedBox(height: 16),
        ],
        if (discoveredModels.isNotEmpty)
          _ModelSection(
            title: 'Discovered',
            count: discoveredModels.length,
            children: [
              for (final model in discoveredModels)
                _DiscoveredModelRow(model: model),
            ],
          ),
        if (customModels.isNotEmpty)
          _ModelSection(
            title: 'Custom models',
            count: customModels.length,
            children: [
              for (final model in customModels)
                _CustomModelRow(
                  model: model,
                  deleting: deletingModelId == model.id,
                  onDelete: () => onDeleteCustomModel(model.id),
                ),
            ],
          ),
      ],
    );
  }
}

class _ProviderEmptyState extends StatelessWidget {
  const _ProviderEmptyState({
    required this.message,
    this.progress = false,
    this.icon,
    this.action,
  });

  final String message;
  final bool progress;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (progress)
          const ProgressRing()
        else if (icon != null)
          Icon(icon, color: context.paseoPalette.foregroundMuted),
        if (progress || icon != null) const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.paseoPalette.foregroundMuted),
        ),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.title,
    required this.count,
    required this.children,
  });

  final String title;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Expanded(child: Text(title)),
              Text(
                '$count',
                style: TextStyle(
                  color: context.paseoPalette.foregroundMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Card(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const Divider(),
                children[index],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _DiscoveredModelRow extends StatelessWidget {
  const _DiscoveredModelRow({required this.model});

  final ProviderModelDefinition model;

  @override
  Widget build(BuildContext context) => _ModelRow(
    key: ValueKey('discovered-model-${model.id}'),
    label: model.label,
    id: model.id,
    description: model.description,
  );
}

class _CustomModelRow extends StatelessWidget {
  const _CustomModelRow({
    required this.model,
    required this.deleting,
    required this.onDelete,
  });

  final MutableDaemonProviderModel model;
  final bool deleting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => _ModelRow(
    key: ValueKey('custom-model-${model.id}'),
    label: model.label,
    id: model.id,
    trailing: IconButton(
      key: ValueKey('remove-custom-model-${model.id}'),
      onPressed: deleting ? null : onDelete,
      icon: deleting
          ? const SizedBox.square(
              dimension: 16,
              child: ProgressRing(strokeWidth: 2),
            )
          : Icon(
              FluentIcons.delete,
              size: 16,
              color: context.paseoPalette.statusDanger,
            ),
    ),
  );
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    super.key,
    required this.label,
    required this.id,
    this.description,
    this.trailing,
  });

  final String label;
  final String id;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        Flexible(
          child: SelectableText(
            id,
            maxLines: 1,
            style: TextStyle(
              color: context.paseoPalette.foregroundMuted,
              fontFamily: 'Consolas',
              fontSize: 12,
            ),
          ),
        ),
        if (description != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.paseoPalette.foregroundMuted,
                fontSize: 11,
              ),
            ),
          ),
        ] else
          const Spacer(),
        ?trailing,
      ],
    ),
  );
}

class ProviderSettingsFooter extends StatelessWidget {
  const ProviderSettingsFooter({
    super.key,
    required this.updatedLabel,
    required this.refreshing,
    required this.onAddModel,
    required this.onOpenDiagnostic,
    required this.onRefresh,
  });

  final String? updatedLabel;
  final bool refreshing;
  final VoidCallback onAddModel;
  final VoidCallback onOpenDiagnostic;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < adaptiveModalCompactBreakpoint;
    final actions = [
      Button(
        key: const ValueKey('add-custom-model'),
        onPressed: onAddModel,
        child: const Text('Add model'),
      ),
      Button(
        key: const ValueKey('open-provider-diagnostic'),
        onPressed: onOpenDiagnostic,
        child: const Text('Diagnostic'),
      ),
      FilledButton(
        key: const ValueKey('refresh-provider-models'),
        onPressed: refreshing ? null : onRefresh,
        child: Text(refreshing ? 'Refreshing…' : 'Refresh'),
      ),
    ];
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.paseoPalette.border)),
        ),
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (updatedLabel != null) ...[
                    Text(
                      'Updated $updatedLabel',
                      style: TextStyle(
                        color: context.paseoPalette.foregroundMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      for (var index = 0; index < actions.length; index++) ...[
                        if (index > 0) const SizedBox(width: 8),
                        Expanded(child: actions[index]),
                      ],
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      updatedLabel == null ? '' : 'Updated $updatedLabel',
                      style: TextStyle(
                        color: context.paseoPalette.foregroundMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  for (var index = 0; index < actions.length; index++) ...[
                    if (index > 0) const SizedBox(width: 8),
                    actions[index],
                  ],
                ],
              ),
      ),
    );
  }
}

class AddCustomProviderModelSheet extends StatefulWidget {
  const AddCustomProviderModelSheet({
    super.key,
    required this.existingModels,
    required this.onAdd,
  });

  final List<MutableDaemonProviderModel> existingModels;
  final Future<void> Function(MutableDaemonProviderModel model) onAdd;

  @override
  State<AddCustomProviderModelSheet> createState() =>
      _AddCustomProviderModelSheetState();
}

class _AddCustomProviderModelSheetState
    extends State<AddCustomProviderModelSheet> {
  final _controller = TextEditingController();
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canAdd {
    final id = _controller.text.trim();
    return id.isNotEmpty &&
        !widget.existingModels.any((model) => model.id == id);
  }

  Future<void> _add() async {
    if (!_canAdd || _saving) return;
    final id = _controller.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onAdd(MutableDaemonProviderModel(id: id, label: id));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AdaptiveModalSheet(
    key: const ValueKey('add-custom-model-sheet'),
    title: 'Add custom model',
    desktopMaxWidth: 420,
    compactInitialHeightFactor: .4,
    compactMaxHeightFactor: .4,
    sizeContentToCurrentSnapPoint: true,
    onClose: () => Navigator.of(context).pop(),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Model ID'),
        const SizedBox(height: 8),
        TextBox(
          key: const ValueKey('custom-model-id'),
          controller: _controller,
          placeholder: 'e.g. openai/gpt-5',
          enabled: !_saving,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _add(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: context.paseoPalette.statusDanger),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Button(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('confirm-add-custom-model'),
              onPressed: _canAdd && !_saving ? _add : null,
              child: Text(_saving ? 'Adding...' : 'Add'),
            ),
          ],
        ),
      ],
    ),
  );
}
