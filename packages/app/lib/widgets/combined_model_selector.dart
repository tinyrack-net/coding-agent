import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../composer/provider_model_selection.dart';

typedef ProviderModelSelectionCallback =
    void Function(String provider, String modelId);

class CombinedModelSelector extends StatelessWidget {
  const CombinedModelSelector({
    super.key,
    required this.providers,
    required this.selectedProvider,
    required this.selectedModel,
    required this.onSelect,
    this.favoriteKeys = const {},
    this.onToggleFavorite,
    this.onOpen,
    this.onRetryProvider,
    this.isLoading = false,
    this.isRetryingProvider = false,
    this.disabled = false,
  });

  final List<ProviderSelectorProvider> providers;
  final String selectedProvider;
  final String selectedModel;
  final ProviderModelSelectionCallback onSelect;
  final Set<String> favoriteKeys;
  final ProviderModelSelectionCallback? onToggleFavorite;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onRetryProvider;
  final bool isLoading;
  final bool isRetryingProvider;
  final bool disabled;

  Future<void> _open(BuildContext context) async {
    onOpen?.call();
    final selection = await showDialog<_SelectedProviderModel>(
      context: context,
      builder: (context) => _ModelBrowserDialog(
        providers: providers,
        selectedProvider: selectedProvider,
        selectedModel: selectedModel,
        favoriteKeys: favoriteKeys,
        onToggleFavorite: onToggleFavorite,
        onRetryProvider: onRetryProvider,
        isRetryingProvider: isRetryingProvider,
      ),
    );
    if (selection != null) {
      onSelect(selection.provider, selection.modelId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = resolveSelectedModelLabel(
      providers: providers,
      selectedProvider: selectedProvider,
      selectedModel: selectedModel,
      isLoading: isLoading,
    );
    return Button(
      key: const ValueKey('combined-model-selector'),
      onPressed: disabled ? null : () => unawaited(_open(context)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          const Icon(FluentIcons.chevron_down, size: 10),
        ],
      ),
    );
  }
}

final class _SelectedProviderModel {
  const _SelectedProviderModel({required this.provider, required this.modelId});

  final String provider;
  final String modelId;
}

class _ModelBrowserDialog extends StatefulWidget {
  const _ModelBrowserDialog({
    required this.providers,
    required this.selectedProvider,
    required this.selectedModel,
    required this.favoriteKeys,
    required this.onToggleFavorite,
    required this.onRetryProvider,
    required this.isRetryingProvider,
  });

  final List<ProviderSelectorProvider> providers;
  final String selectedProvider;
  final String selectedModel;
  final Set<String> favoriteKeys;
  final ProviderModelSelectionCallback? onToggleFavorite;
  final ValueChanged<String>? onRetryProvider;
  final bool isRetryingProvider;

  @override
  State<_ModelBrowserDialog> createState() => _ModelBrowserDialogState();
}

class _ModelBrowserDialogState extends State<_ModelBrowserDialog> {
  late ModelBrowserView _view;
  late Set<String> _favoriteKeys;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _favoriteKeys = {...widget.favoriteKeys};
    _view = resolveInitialModelBrowserView(
      providers: widget.providers,
      selectedProvider: widget.selectedProvider,
      selectedModel: widget.selectedModel,
      favoriteKeys: _favoriteKeys,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showAll() {
    setState(() {
      _view = const AllModelsView();
      _searchController.clear();
      _searchQuery = '';
    });
  }

  void _showProvider(ProviderSelectorProvider provider) {
    setState(() {
      _view = ProviderModelsView(
        providerId: provider.id,
        providerLabel: provider.label,
      );
      _searchController.clear();
      _searchQuery = '';
    });
  }

  void _select(ProviderSelectionModelRow row) {
    Navigator.of(
      context,
    ).pop(_SelectedProviderModel(provider: row.provider, modelId: row.modelId));
  }

  void _toggleFavorite(ProviderSelectionModelRow row) {
    final callback = widget.onToggleFavorite;
    if (callback == null) return;
    callback(row.provider, row.modelId);
    setState(() {
      if (!_favoriteKeys.remove(row.favoriteKey)) {
        _favoriteKeys.add(row.favoriteKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final providerView = view is ProviderModelsView;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
      title: Row(
        children: [
          if (providerView && widget.providers.length > 1) ...[
            IconButton(
              key: const ValueKey('model-browser-back'),
              icon: const Icon(FluentIcons.back, size: 14),
              onPressed: _showAll,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(providerView ? view.providerLabel : 'Models')),
        ],
      ),
      content: SizedBox(
        width: 400,
        height: 400,
        child: providerView
            ? _buildProviderView(view)
            : _buildAllProvidersView(),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildAllProvidersView() {
    final favoriteRows = [
      for (final row in getAllProviderModelRows(widget.providers))
        if (_favoriteKeys.contains(row.favoriteKey)) row,
    ];
    final children = <Widget>[
      if (favoriteRows.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Favorites'),
          ),
        ),
        for (final row in favoriteRows)
          _ModelRow(
            row: row,
            selected:
                row.provider == widget.selectedProvider &&
                row.modelId == widget.selectedModel,
            favorite: true,
            onSelect: () => _select(row),
            onToggleFavorite: widget.onToggleFavorite == null
                ? null
                : () => _toggleFavorite(row),
          ),
        const Divider(),
      ],
      for (final provider in widget.providers)
        _ProviderRow(
          provider: provider,
          onPressed: () => _showProvider(provider),
        ),
      if (widget.providers.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: Text('No matching models.')),
        ),
    ];
    return ListView(children: children);
  }

  Widget _buildProviderView(ProviderModelsView view) {
    final provider = widget.providers
        .where((entry) => entry.id == view.providerId)
        .firstOrNull;
    if (provider == null) {
      return const Center(child: Text('No matching models.'));
    }
    return switch (provider.modelSelection) {
      ProviderModelsLoading() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [ProgressRing(), SizedBox(height: 8), Text('Loading...')],
        ),
      ),
      ProviderModelsError(:final message) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(FluentIcons.warning),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (widget.onRetryProvider != null) ...[
              const SizedBox(height: 12),
              Button(
                key: ValueKey('retry-model-provider-${provider.id}'),
                onPressed: widget.isRetryingProvider
                    ? null
                    : () => widget.onRetryProvider!(provider.id),
                child: Text(
                  widget.isRetryingProvider ? 'Retrying...' : 'Retry',
                ),
              ),
            ],
          ],
        ),
      ),
      ProviderModelRows(:final rows) => Column(
        children: [
          TextBox(
            key: const ValueKey('model-search-input'),
            controller: _searchController,
            autofocus: true,
            placeholder: 'Search models',
            prefix: const Padding(
              padding: EdgeInsetsDirectional.only(start: 8),
              child: Icon(FluentIcons.search),
            ),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Builder(
              builder: (context) {
                final visible = filterAndRankModelRows(rows, _searchQuery);
                if (visible.isEmpty) {
                  return const Center(child: Text('No matching models.'));
                }
                final ordered = _searchQuery.trim().isEmpty
                    ? [
                        for (final row in visible)
                          if (_favoriteKeys.contains(row.favoriteKey)) row,
                        for (final row in visible)
                          if (!_favoriteKeys.contains(row.favoriteKey)) row,
                      ]
                    : visible;
                return ListView(
                  children: [
                    for (final row in ordered)
                      _ModelRow(
                        row: row,
                        selected:
                            row.provider == widget.selectedProvider &&
                            row.modelId == widget.selectedModel,
                        favorite: _favoriteKeys.contains(row.favoriteKey),
                        onSelect: () => _select(row),
                        onToggleFavorite: widget.onToggleFavorite == null
                            ? null
                            : () => _toggleFavorite(row),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    };
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.provider, required this.onPressed});

  final ProviderSelectorProvider provider;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final state = switch (provider.modelSelection) {
      ProviderModelRows(:final rows) =>
        '${rows.length} ${rows.length == 1 ? 'model' : 'models'}',
      ProviderModelsLoading() => 'Loading...',
      ProviderModelsError() => 'Error',
    };
    return ListTile(
      key: ValueKey('model-provider-${provider.id}'),
      leading: const Icon(FluentIcons.robot),
      title: Text(provider.label),
      subtitle: Text(state),
      trailing: const Icon(FluentIcons.chevron_right, size: 12),
      onPressed: onPressed,
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.row,
    required this.selected,
    required this.favorite,
    required this.onSelect,
    required this.onToggleFavorite,
  });

  final ProviderSelectionModelRow row;
  final bool selected;
  final bool favorite;
  final VoidCallback onSelect;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('model-row-${row.provider}-${row.modelId}'),
    leading: const Icon(FluentIcons.robot, size: 16),
    title: Text(row.modelLabel),
    subtitle: row.description == null ? null : Text(row.description!),
    onPressed: onSelect,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected) const Icon(FluentIcons.check_mark, size: 14),
        if (onToggleFavorite != null)
          IconButton(
            key: ValueKey('favorite-model-${row.provider}-${row.modelId}'),
            icon: Icon(
              favorite
                  ? FluentIcons.favorite_star_fill
                  : FluentIcons.favorite_star,
              size: 14,
            ),
            onPressed: onToggleFavorite,
          ),
      ],
    ),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
