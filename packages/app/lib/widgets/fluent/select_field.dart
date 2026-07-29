import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../adaptive_modal_sheet.dart';

final class SelectFieldDisplay {
  const SelectFieldDisplay({required this.label, this.description});

  final String label;
  final String? description;
}

enum PaseoFieldControlSize { sm, md }

enum SelectFieldOptionKind { directory, file }

final class SelectFieldOption<T> {
  const SelectFieldOption({
    required this.id,
    required this.value,
    required this.label,
    this.description,
    this.kind,
    this.optionKey,
    this.leading,
  });

  final String id;
  final T value;
  final String label;
  final String? description;
  final SelectFieldOptionKind? kind;
  final Key? optionKey;
  final Widget? leading;

  SelectFieldDisplay get display =>
      SelectFieldDisplay(label: label, description: description);
}

typedef SelectFieldChanged<T> =
    void Function(T value, SelectFieldDisplay display);

typedef SelectFieldValueKey<T> = String Function(T value);

final class SelectFieldRenderOptionInput<T> {
  const SelectFieldRenderOptionInput({
    required this.option,
    required this.selected,
    required this.active,
    required this.onPressed,
  });

  final SelectFieldOption<T> option;
  final bool selected;
  final bool active;
  final VoidCallback onPressed;
}

typedef SelectFieldOptionBuilder<T> =
    Widget Function(SelectFieldRenderOptionInput<T> input);

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
    this.size = PaseoFieldControlSize.md,
    this.getValueKey,
    this.renderOption,
    this.triggerLeading,
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
  final PaseoFieldControlSize size;
  final SelectFieldValueKey<T>? getValueKey;
  final SelectFieldOptionBuilder<T>? renderOption;
  final Widget? triggerLeading;
  final Widget? leading;
  final bool field;
  final Key? triggerKey;

  @override
  State<PaseoSelectField<T>> createState() => _PaseoSelectFieldState<T>();
}

class _PaseoSelectFieldState<T> extends State<PaseoSelectField<T>> {
  final _flyoutController = FlyoutController();
  final _anchorKey = GlobalKey();
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
    return _visibleOptions
        .where((option) => _valuesMatch(option.value, value))
        .firstOrNull;
  }

  bool _valuesMatch(T candidate, T value) {
    final getValueKey = widget.getValueKey;
    if (getValueKey != null) {
      return getValueKey(candidate) == getValueKey(value);
    }
    if (candidate is num && value is num) {
      if (candidate is double && value is double) {
        if (candidate.isNaN && value.isNaN) return true;
        if (candidate == 0 && value == 0) {
          return candidate.isNegative == value.isNegative;
        }
      }
      return candidate == value;
    }
    if (candidate is String || candidate is bool || candidate is Enum) {
      return candidate == value;
    }
    return identical(candidate, value);
  }

  double get _desktopAnchorWidth {
    final renderObject = _anchorKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size.width;
    }
    return 200;
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
          compactInitialHeightFactor: .6,
          content: _SelectFieldOptionsPanel<T>(
            triggerKey: widget.triggerKey,
            options: _visibleOptions,
            selectedId: _selectedOption?.id,
            searchable: widget.searchable,
            searchPlaceholder: widget.searchPlaceholder,
            emptyText: _emptyText,
            renderOption: widget.renderOption,
            onSelect: (option) => Navigator.of(sheetContext).pop(option),
            onDismiss: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      );
    } else {
      final anchorWidth = _desktopAnchorWidth;
      selection = await _flyoutController.showFlyout<SelectFieldOption<T>>(
        placementMode: FlyoutPlacementMode.bottomLeft,
        forceAvailableSpace: true,
        additionalOffset: 4,
        barrierColor: Colors.transparent,
        builder: (flyoutContext) => FlyoutContent(
          padding: EdgeInsets.zero,
          color: flyoutContext.paseoPalette.surface1,
          useAcrylic: false,
          constraints: const BoxConstraints(maxHeight: 420).copyWith(
            minWidth: anchorWidth,
            maxWidth: math.max(400, anchorWidth),
          ),
          child: _SelectFieldOptionsPanel<T>(
            triggerKey: widget.triggerKey,
            options: _visibleOptions,
            selectedId: _selectedOption?.id,
            searchable: widget.searchable,
            searchPlaceholder: widget.searchPlaceholder,
            emptyText: _emptyText,
            renderOption: widget.renderOption,
            onSelect: _flyoutController.close,
            onDismiss: _flyoutController.close,
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
      key: _anchorKey,
      controller: _flyoutController,
      child: _SelectFieldButton(
        key: widget.triggerKey,
        label: display?.label ?? widget.placeholder,
        isPlaceholder: display == null,
        placeholder: widget.placeholder,
        leading: widget.triggerLeading ?? widget.leading,
        loading: widget.loading,
        disabled: widget.disabled,
        active: _open || _focused,
        hovered: _hovered,
        size: widget.size,
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

class _SelectFieldButton extends StatelessWidget {
  const _SelectFieldButton({
    super.key,
    required this.label,
    required this.isPlaceholder,
    required this.placeholder,
    required this.loading,
    required this.disabled,
    required this.active,
    required this.hovered,
    required this.accessibilityLabel,
    required this.size,
    required this.onPressed,
    required this.onHoverChanged,
    required this.onFocusChanged,
    this.leading,
  });

  final String label;
  final bool isPlaceholder;
  final String placeholder;
  final Widget? leading;
  final bool loading;
  final bool disabled;
  final bool active;
  final bool hovered;
  final String accessibilityLabel;
  final PaseoFieldControlSize size;
  final VoidCallback onPressed;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onFocusChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: !disabled,
    label: accessibilityLabel,
    child: FocusableActionDetector(
      enabled: !disabled,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (!disabled) onPressed();
            return null;
          },
        ),
      },
      onShowFocusHighlight: onFocusChanged,
      onShowHoverHighlight: onHoverChanged,
      mouseCursor: disabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : onPressed,
        child: PaseoSelectFieldTrigger(
          label: label,
          isPlaceholder: isPlaceholder,
          placeholder: placeholder,
          hovered: hovered,
          focused: active,
          active: active,
          disabled: disabled,
          loading: loading,
          leading: leading,
          size: size,
        ),
      ),
    ),
  );
}

class PaseoSelectFieldTrigger extends StatelessWidget {
  const PaseoSelectFieldTrigger({
    super.key,
    required this.placeholder,
    this.display,
    this.label,
    this.isPlaceholder,
    this.hovered = false,
    this.focused = false,
    this.active = false,
    this.disabled = false,
    this.loading = false,
    this.leading,
    this.size = PaseoFieldControlSize.md,
  });

  final SelectFieldDisplay? display;
  final String? label;
  final bool? isPlaceholder;
  final String placeholder;
  final bool hovered;
  final bool focused;
  final bool active;
  final bool disabled;
  final bool loading;
  final Widget? leading;
  final PaseoFieldControlSize size;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final medium = size == PaseoFieldControlSize.md;
    final height = medium ? 44.0 : 32.0;
    final horizontalPadding = medium ? 16.0 : 12.0;
    final radius = medium ? 8.0 : 6.0;
    final fontSize = medium ? 16.0 : 14.0;
    final effectiveActive = active || focused;
    final borderColor = effectiveActive || hovered
        ? palette.borderAccent
        : Colors.transparent;
    final resolvedLabel = label ?? display?.label ?? placeholder;
    final placeholderLabel = isPlaceholder ?? display == null;
    return AnimatedOpacity(
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
          boxShadow: effectiveActive
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
                resolvedLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: placeholderLabel
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
    required this.onDismiss,
    required this.renderOption,
  });

  final Key? triggerKey;
  final List<SelectFieldOption<T>> options;
  final String? selectedId;
  final bool searchable;
  final String? searchPlaceholder;
  final String emptyText;
  final ValueChanged<SelectFieldOption<T>> onSelect;
  final VoidCallback onDismiss;
  final SelectFieldOptionBuilder<T>? renderOption;

  @override
  State<_SelectFieldOptionsPanel<T>> createState() =>
      _SelectFieldOptionsPanelState<T>();
}

class _SelectFieldOptionsPanelState<T>
    extends State<_SelectFieldOptionsPanel<T>> {
  final _searchController = TextEditingController();
  var _query = '';
  late int _activeIndex;

  @override
  void initState() {
    super.initState();
    _activeIndex = _initialActiveIndex(widget.options);
  }

  @override
  void didUpdateWidget(covariant _SelectFieldOptionsPanel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options != widget.options ||
        oldWidget.selectedId != widget.selectedId) {
      _activeIndex = _initialActiveIndex(_filteredOptions);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SelectFieldOption<T>> get _filteredOptions {
    final normalized = _query.trim().toLowerCase();
    return normalized.isEmpty
        ? widget.options
        : widget.options
              .where(
                (option) =>
                    option.label.toLowerCase().contains(normalized) ||
                    (option.description?.toLowerCase().contains(normalized) ??
                        false),
              )
              .toList(growable: false);
  }

  int _initialActiveIndex(List<SelectFieldOption<T>> options) {
    if (options.isEmpty) return -1;
    if (_query.trim().isNotEmpty) return 0;
    final selectedIndex = options.indexWhere(
      (option) => option.id == widget.selectedId,
    );
    return selectedIndex < 0 ? 0 : selectedIndex;
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _activeIndex = _initialActiveIndex(_filteredOptions);
    });
  }

  void _moveActive(int delta) {
    final visible = _filteredOptions;
    if (visible.isEmpty) {
      setState(() => _activeIndex = -1);
      return;
    }
    setState(() {
      if (_activeIndex < 0) {
        _activeIndex = delta > 0 ? 0 : visible.length - 1;
      } else {
        _activeIndex = (_activeIndex + delta + visible.length) % visible.length;
      }
    });
  }

  void _selectActive() {
    final visible = _filteredOptions;
    if (_activeIndex >= 0 && _activeIndex < visible.length) {
      widget.onSelect(visible[_activeIndex]);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveActive(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveActive(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _selectActive();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filteredOptions;
    final triggerId = switch (widget.triggerKey) {
      ValueKey(:final value) => '$value',
      _ => 'select-field',
    };
    return Focus(
      autofocus: !widget.searchable,
      onKeyEvent: _handleKeyEvent,
      child: ConstrainedBox(
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
                  onChanged: _setQuery,
                  onSubmitted: (_) => _selectActive(),
                ),
              ),
              Divider(
                style: DividerThemeData(
                  decoration: BoxDecoration(
                    color: context.paseoPalette.surface2,
                  ),
                ),
              ),
            ],
            Flexible(
              child: visible.isEmpty
                  ? Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          widget.emptyText,
                          style: TextStyle(
                            color: context.paseoPalette.foregroundMuted,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final option = visible[index];
                        final selected = option.id == widget.selectedId;
                        final active = index == _activeIndex;
                        void onPressed() => widget.onSelect(option);
                        final custom = widget.renderOption?.call(
                          SelectFieldRenderOptionInput(
                            option: option,
                            selected: selected,
                            active: active,
                            onPressed: onPressed,
                          ),
                        );
                        return KeyedSubtree(
                          key:
                              option.optionKey ??
                              ValueKey('$triggerId-option-${option.id}'),
                          child:
                              custom ??
                              _SelectFieldOptionRow<T>(
                                option: option,
                                selected: selected,
                                active: active,
                                onPressed: onPressed,
                              ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectFieldOptionRow<T> extends StatelessWidget {
  const _SelectFieldOptionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.active,
    required this.onPressed,
  });

  final SelectFieldOption<T> option;
  final bool selected;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ListTile(
    tileColor: WidgetStateColor.resolveWith(
      (_) => active ? context.paseoPalette.surface1 : Colors.transparent,
    ),
    shape: const RoundedRectangleBorder(),
    margin: EdgeInsets.zero,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    leading: option.leading ?? _kindIcon(context),
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

  Widget? _kindIcon(BuildContext context) => switch (option.kind) {
    SelectFieldOptionKind.directory => Icon(
      FluentIcons.folder,
      size: 16,
      color: context.paseoPalette.foregroundMuted,
    ),
    SelectFieldOptionKind.file => Icon(
      FluentIcons.page,
      size: 16,
      color: context.paseoPalette.foregroundMuted,
    ),
    null => null,
  };
}
