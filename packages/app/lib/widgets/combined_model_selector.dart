import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../composer/provider_model_selection.dart';
import '../state/provider_settings_provider.dart';
import 'provider_icon.dart';

typedef ProviderModelSelectionCallback =
    void Function(String provider, String modelId);

final class CombinedModelTriggerInput {
  const CombinedModelTriggerInput({
    required this.selectedModelLabel,
    required this.onPressed,
    required this.disabled,
    required this.isOpen,
    required this.hovered,
    required this.pressed,
  });

  final String selectedModelLabel;
  final VoidCallback onPressed;
  final bool disabled;
  final bool isOpen;
  final bool hovered;
  final bool pressed;
}

typedef CombinedModelTriggerBuilder =
    Widget Function(CombinedModelTriggerInput input);

class CombinedModelSelector extends StatefulWidget {
  const CombinedModelSelector({
    super.key,
    required this.providers,
    required this.selectedProvider,
    required this.selectedModel,
    required this.onSelect,
    this.favoriteKeys = const {},
    this.onToggleFavorite,
    this.renderTrigger,
    this.triggerFill = false,
    this.onOpen,
    this.onClose,
    this.onRetryProvider,
    this.serverId,
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
  final CombinedModelTriggerBuilder? renderTrigger;
  final bool triggerFill;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final ValueChanged<String>? onRetryProvider;
  final String? serverId;
  final bool isLoading;
  final bool isRetryingProvider;
  final bool disabled;

  @override
  State<CombinedModelSelector> createState() => _CombinedModelSelectorState();
}

class _CombinedModelSelectorState extends State<CombinedModelSelector> {
  var _open = false;
  var _hovered = false;
  var _pressed = false;

  Future<void> _openSelector() async {
    if (widget.disabled || _open) return;
    setState(() => _open = true);
    widget.onOpen?.call();
    final selection = await showDialog<_SelectedProviderModel>(
      context: context,
      builder: (context) => _ModelBrowserDialog(
        providers: widget.providers,
        selectedProvider: widget.selectedProvider,
        selectedModel: widget.selectedModel,
        favoriteKeys: widget.favoriteKeys,
        onToggleFavorite: widget.onToggleFavorite,
        onRetryProvider: widget.onRetryProvider,
        serverId: widget.serverId,
        isRetryingProvider: widget.isRetryingProvider,
      ),
    );
    if (!mounted) return;
    setState(() {
      _open = false;
      _pressed = false;
    });
    widget.onClose?.call();
    if (selection != null) {
      widget.onSelect(selection.provider, selection.modelId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = resolveSelectedModelLabel(
      providers: widget.providers,
      selectedProvider: widget.selectedProvider,
      selectedModel: widget.selectedModel,
      isLoading: widget.isLoading,
    );
    final renderTrigger = widget.renderTrigger;
    if (renderTrigger != null) {
      final trigger = renderTrigger(
        CombinedModelTriggerInput(
          selectedModelLabel: label,
          onPressed: () => unawaited(_openSelector()),
          disabled: widget.disabled,
          isOpen: _open,
          hovered: _hovered,
          pressed: _pressed,
        ),
      );
      return KeyedSubtree(
        key: const ValueKey('combined-model-selector'),
        child: Semantics(
          button: true,
          enabled: !widget.disabled,
          label: 'Selected model ($label)',
          child: FocusableActionDetector(
            enabled: !widget.disabled,
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  unawaited(_openSelector());
                  return null;
                },
              ),
            },
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            mouseCursor: widget.disabled
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.disabled ? null : () => unawaited(_openSelector()),
              onTapDown: widget.disabled
                  ? null
                  : (_) => setState(() => _pressed = true),
              onTapUp: widget.disabled
                  ? null
                  : (_) => setState(() => _pressed = false),
              onTapCancel: widget.disabled
                  ? null
                  : () => setState(() => _pressed = false),
              child: SizedBox(
                width: widget.triggerFill ? double.infinity : null,
                child: trigger,
              ),
            ),
          ),
        ),
      );
    }
    return Button(
      key: const ValueKey('combined-model-selector'),
      onPressed: widget.disabled ? null : () => unawaited(_openSelector()),
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
    required this.serverId,
    required this.isRetryingProvider,
  });

  final List<ProviderSelectorProvider> providers;
  final String selectedProvider;
  final String selectedModel;
  final Set<String> favoriteKeys;
  final ProviderModelSelectionCallback? onToggleFavorite;
  final ValueChanged<String>? onRetryProvider;
  final String? serverId;
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

  void _openProviderSettings(ProviderModelsView view) {
    final serverId = widget.serverId;
    if (serverId == null || serverId.isEmpty) return;
    ProviderScope.containerOf(context)
        .read(providerSettingsProvider.notifier)
        .open(serverId: serverId, provider: view.providerId);
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
          if (providerView) ...[
            ProviderIcon(
              provider: view.providerId,
              size: 20,
              color: FluentTheme.of(context).resources.textFillColorPrimary,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(providerView ? view.providerLabel : 'Models')),
          if (providerView)
            Tooltip(
              message: '${view.providerLabel} provider settings',
              child: IconButton(
                key: ValueKey('selector-header-settings-${view.providerId}'),
                icon: const Icon(FluentIcons.settings, size: 14),
                onPressed: widget.serverId?.isNotEmpty == true
                    ? () => _openProviderSettings(view)
                    : null,
              ),
            ),
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
      leading: ProviderIcon(
        provider: provider.id,
        size: 16,
        color: FluentTheme.of(context).resources.textFillColorSecondary,
      ),
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
    leading: ProviderIcon(
      provider: row.provider,
      size: 16,
      color: FluentTheme.of(context).resources.textFillColorSecondary,
    ),
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
