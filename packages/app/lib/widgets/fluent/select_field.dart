import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../core/theme.dart';
import '../adaptive_modal_sheet.dart';

final class SelectFieldDisplay {
  const SelectFieldDisplay({required this.label, this.description});

  final String label;
  final String? description;
}

final class SelectFieldOption<T> {
  const SelectFieldOption({
    required this.id,
    required this.value,
    required this.label,
    this.description,
    this.leading,
  });

  final String id;
  final T value;
  final String label;
  final String? description;
  final Widget? leading;

  SelectFieldDisplay get display =>
      SelectFieldDisplay(label: label, description: description);
}

typedef SelectFieldChanged<T> =
    void Function(T value, SelectFieldDisplay display);

class PaseoSelectField<T> extends StatefulWidget {
  const PaseoSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.placeholder,
    required this.emptyText,
    this.selectedDisplay,
    this.disabled = false,
    this.loading = false,
    this.searchable = false,
    this.searchPlaceholder,
    this.title,
    this.hint,
    this.error,
    this.leading,
    this.field = true,
    this.triggerKey,
  });

  final String label;
  final T? value;
  final SelectFieldDisplay? selectedDisplay;
  final List<SelectFieldOption<T>> options;
  final SelectFieldChanged<T> onChanged;
  final String placeholder;
  final String emptyText;
  final bool disabled;
  final bool loading;
  final bool searchable;
  final String? searchPlaceholder;
  final String? title;
  final String? hint;
  final String? error;
  final Widget? leading;
  final bool field;
  final Key? triggerKey;

  @override
  State<PaseoSelectField<T>> createState() => _PaseoSelectFieldState<T>();
}

class _PaseoSelectFieldState<T> extends State<PaseoSelectField<T>> {
  final _flyoutController = FlyoutController();
  late List<SelectFieldOption<T>> _visibleOptions;
  var _open = false;
  var _hovered = false;
  var _focused = false;

  @override
  void initState() {
    super.initState();
    _visibleOptions = widget.options;
  }

  @override
  void didUpdateWidget(covariant PaseoSelectField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.options.isNotEmpty || !widget.loading) {
      _visibleOptions = widget.options;
    }
  }

  @override
  void dispose() {
    _flyoutController.dispose();
    super.dispose();
  }

  SelectFieldOption<T>? get _selectedOption {
    final value = widget.value;
    if (value == null) return null;
    return _visibleOptions.where((option) => option.value == value).firstOrNull;
  }

  Future<void> _openPicker() async {
    if (widget.disabled || _open) return;
    setState(() => _open = true);
    final compact =
        MediaQuery.sizeOf(context).width < adaptiveModalCompactBreakpoint;
    SelectFieldOption<T>? selection;
    if (compact) {
      selection = await showAdaptiveModalSheet<SelectFieldOption<T>>(
        context: context,
        builder: (sheetContext) => AdaptiveModalSheet(
          title: widget.title ?? widget.label,
          onClose: () => Navigator.of(sheetContext).pop(),
          content: _SelectFieldOptionsPanel<T>(
            triggerKey: widget.triggerKey,
            options: _visibleOptions,
            selectedId: _selectedOption?.id,
            searchable: widget.searchable,
            searchPlaceholder: widget.searchPlaceholder,
            emptyText: _emptyText,
            onSelect: (option) => Navigator.of(sheetContext).pop(option),
          ),
        ),
      );
    } else {
      selection = await _flyoutController.showFlyout<SelectFieldOption<T>>(
        placementMode: FlyoutPlacementMode.bottomLeft,
        forceAvailableSpace: true,
        additionalOffset: 4,
        barrierColor: Colors.transparent,
        builder: (flyoutContext) => FlyoutContent(
          padding: EdgeInsets.zero,
          color: flyoutContext.paseoPalette.surface1,
          useAcrylic: false,
          constraints: const BoxConstraints(
            minWidth: 280,
            maxWidth: 420,
            maxHeight: 420,
          ),
          child: _SelectFieldOptionsPanel<T>(
            triggerKey: widget.triggerKey,
            options: _visibleOptions,
            selectedId: _selectedOption?.id,
            searchable: widget.searchable,
            searchPlaceholder: widget.searchPlaceholder,
            emptyText: _emptyText,
            onSelect: _flyoutController.close,
          ),
        ),
      );
    }
    if (mounted) {
      setState(() => _open = false);
      if (selection != null) {
        widget.onChanged(selection.value, selection.display);
      }
    }
  }

  String get _emptyText => widget.loading && _visibleOptions.isEmpty
      ? 'Loading...'
      : widget.emptyText;

  @override
  Widget build(BuildContext context) {
    final selected = _selectedOption;
    final display = widget.selectedDisplay ?? selected?.display;
    final control = FlyoutTarget(
      controller: _flyoutController,
      child: _SelectFieldTrigger(
        key: widget.triggerKey,
        label: display?.label ?? widget.placeholder,
        placeholder: display == null,
        leading: widget.leading ?? selected?.leading,
        loading: widget.loading,
        disabled: widget.disabled,
        active: _open || _focused,
        hovered: _hovered,
        accessibilityLabel:
            '${widget.label} (${display?.label ?? widget.placeholder})',
        onPressed: () => unawaited(_openPicker()),
        onHoverChanged: (value) => setState(() => _hovered = value),
        onFocusChanged: (value) => setState(() => _focused = value),
      ),
    );
    if (!widget.field) return control;
    final helper = widget.error ?? display?.description ?? widget.hint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            color: context.paseoPalette.foregroundMuted,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        control,
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: widget.error == null
                  ? context.paseoPalette.foregroundMuted
                  : context.statusColors.danger,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

class _SelectFieldTrigger extends StatelessWidget {
  const _SelectFieldTrigger({
    super.key,
    required this.label,
    required this.placeholder,
    required this.loading,
    required this.disabled,
    required this.active,
    required this.hovered,
    required this.accessibilityLabel,
    required this.onPressed,
    required this.onHoverChanged,
    required this.onFocusChanged,
    this.leading,
  });

  final String label;
  final bool placeholder;
  final Widget? leading;
  final bool loading;
  final bool disabled;
  final bool active;
  final bool hovered;
  final String accessibilityLabel;
  final VoidCallback onPressed;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onFocusChanged;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < adaptiveModalCompactBreakpoint;
    final palette = context.paseoPalette;
    final height = compact ? 44.0 : 32.0;
    final horizontalPadding = compact ? 16.0 : 12.0;
    final radius = compact ? 8.0 : 6.0;
    final fontSize = compact ? 16.0 : 14.0;
    final borderColor = active || hovered
        ? palette.borderAccent
        : Colors.transparent;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: accessibilityLabel,
      child: FocusableActionDetector(
        enabled: !disabled,
        onShowFocusHighlight: onFocusChanged,
        onShowHoverHighlight: onHoverChanged,
        mouseCursor: disabled
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: disabled ? null : onPressed,
          child: AnimatedOpacity(
            opacity: disabled ? .5 : 1,
            duration: const Duration(milliseconds: 83),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 83),
              height: height,
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              decoration: BoxDecoration(
                color: palette.surface2,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: borderColor),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: palette.accent,
                          blurRadius: 0,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  if (leading != null) ...[
                    SizedBox.square(dimension: 18, child: leading),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: placeholder
                            ? palette.foregroundMuted
                            : palette.foreground,
                        fontSize: fontSize,
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (loading) ...[
                    const SizedBox(width: 8),
                    const SizedBox.square(
                      dimension: 14,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    FluentIcons.chevron_down,
                    size: 16,
                    color: palette.foregroundMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectFieldOptionsPanel<T> extends StatefulWidget {
  const _SelectFieldOptionsPanel({
    required this.triggerKey,
    required this.options,
    required this.selectedId,
    required this.searchable,
    required this.searchPlaceholder,
    required this.emptyText,
    required this.onSelect,
  });

  final Key? triggerKey;
  final List<SelectFieldOption<T>> options;
  final String? selectedId;
  final bool searchable;
  final String? searchPlaceholder;
  final String emptyText;
  final ValueChanged<SelectFieldOption<T>> onSelect;

  @override
  State<_SelectFieldOptionsPanel<T>> createState() =>
      _SelectFieldOptionsPanelState<T>();
}

class _SelectFieldOptionsPanelState<T>
    extends State<_SelectFieldOptionsPanel<T>> {
  final _searchController = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final visible = normalized.isEmpty
        ? widget.options
        : widget.options
              .where(
                (option) =>
                    option.label.toLowerCase().contains(normalized) ||
                    (option.description?.toLowerCase().contains(normalized) ??
                        false),
              )
              .toList(growable: false);
    final triggerId = switch (widget.triggerKey) {
      ValueKey(:final value) => '$value',
      _ => 'select-field',
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.searchable) ...[
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextBox(
                key: ValueKey('$triggerId-search'),
                controller: _searchController,
                autofocus: true,
                placeholder: widget.searchPlaceholder ?? 'Search...',
                prefix: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8),
                  child: Icon(FluentIcons.search, size: 16),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Divider(
              style: DividerThemeData(
                decoration: BoxDecoration(color: context.paseoPalette.surface2),
              ),
            ),
          ],
          Flexible(
            child: visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(widget.emptyText),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final option = visible[index];
                      final selected = option.id == widget.selectedId;
                      return _SelectFieldOptionRow<T>(
                        key: ValueKey('$triggerId-option-${option.id}'),
                        option: option,
                        selected: selected,
                        onPressed: () => widget.onSelect(option),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SelectFieldOptionRow<T> extends StatelessWidget {
  const _SelectFieldOptionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.onPressed,
  });

  final SelectFieldOption<T> option;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: option.leading,
    title: Text(option.label),
    subtitle: option.description == null ? null : Text(option.description!),
    trailing: selected
        ? Icon(
            FluentIcons.check_mark,
            size: 14,
            color: context.paseoPalette.accentBright,
          )
        : null,
    onPressed: onPressed,
  );
}
