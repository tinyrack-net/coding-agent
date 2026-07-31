/// Port of Paseo 0.2.0's four frozen control-geometry modules, grouped here
/// because each answers a pure "what shape / which slot" question that its
/// widget would otherwise have to answer inline, un-testably:
///
/// * `components/ui/autocomplete-utils.ts` — which order an autocomplete popover
///   renders its options in, which option is active when nothing is chosen yet,
///   and how far the list must scroll to keep the active row visible. The popover
///   can open above *or* below the input, and "first logical option" must always
///   land nearest the input, so ordering and the fallback index are two halves of
///   one decision.
/// * `components/ui/combobox-frame-style.ts` — the desktop combobox popover's
///   width/height envelope. The popover must never be capped narrower than the
///   trigger it hangs off, which is why the ceiling is derived from the floor
///   rather than being a fixed constant.
/// * `components/ui/combobox-options.ts` — which rows a combobox shows for a
///   search query, in what order, and whether a synthetic "use what you typed"
///   row belongs at the top.
/// * `components/ui/control-geometry.ts` — the single source of truth for control
///   sizing across buttons, fields, switches and segmented controls, so that the
///   same size name means the same height, label size and horizontal padding on
///   every control kind.
///
/// Arrow-key movement inside a combobox listbox is *not* re-ported here:
/// `keyboard/paseo_shortcut_routing.dart` already carries
/// `combobox-keyboard.ts`, and [getAutocompleteNextIndex] delegates to it exactly
/// as upstream does.
///
/// ## Cross-cutting deviations from upstream
///
/// * React Native style objects are partial dictionaries where an absent key
///   means "inherit". Dart models them as value classes whose unset fields are
///   `null`, and layered style *arrays* (which RN flattens last-wins) are
///   flattened eagerly at build time — see [DesktopFrameStyle].
/// * Upstream's optional `boolean | undefined` flags are read for truthiness.
///   Dart uses non-nullable `bool` defaulting to `false`, which is observably
///   identical because `undefined` and `false` are both falsy.
/// * CSS colors arrive as strings (`"transparent"`, `"#20744A"`); they become
///   [Color] values. `"transparent"` is `Color(0x00000000)`.
library;

import 'package:flutter/widgets.dart' show Color, MainAxisAlignment;

import '../core/theme.dart' show PaseoSpacing;
import '../core/paseo_ui_utils.dart'
    show MatchScore, compareMatchScores, scoreTextFields;
import '../keyboard/paseo_shortcut_routing.dart'
    show ComboboxArrowKey, getNextActiveIndex;

export '../keyboard/paseo_shortcut_routing.dart' show ComboboxArrowKey;

// ---------------------------------------------------------------------------
// autocomplete-utils.ts
// ---------------------------------------------------------------------------

/// Which side of the text input the autocomplete popover occupies.
///
/// Upstream is the `"above-input" | "below-input"` string union; the popover
/// defaults to opening upward because the composer sits at the bottom of the
/// screen.
enum AutocompleteOptionsPosition { aboveInput, belowInput }

/// The options in render order for [position].
///
/// Above the input, render order is reversed so the *first logical* option ends
/// up visually closest to the caret — the list grows away from the input rather
/// than pushing the top match furthest from it.
///
/// Always returns a fresh list, matching upstream's copy-then-reverse: callers
/// hold on to the result and must not observe later mutations of [options].
List<T> orderAutocompleteOptions<T>(
  Iterable<T> options, {
  AutocompleteOptionsPosition position = AutocompleteOptionsPosition.aboveInput,
}) {
  final ordered = options.toList();
  if (position == AutocompleteOptionsPosition.belowInput) {
    return ordered;
  }
  return ordered.reversed.toList();
}

/// The index that should be active when the popover opens with no explicit
/// selection, or `-1` when there is nothing to select.
///
/// This is the render-order counterpart of [orderAutocompleteOptions]: whichever
/// end of the rendered list sits nearest the input is the one that gets focus.
int getAutocompleteFallbackIndex(
  int itemCount, {
  AutocompleteOptionsPosition position = AutocompleteOptionsPosition.aboveInput,
}) {
  if (itemCount <= 0) {
    return -1;
  }
  return position == AutocompleteOptionsPosition.aboveInput ? itemCount - 1 : 0;
}

/// The index to activate after an arrow key, delegating to the shared combobox
/// keyboard rule so autocomplete and combobox wrap identically.
///
/// Kept as a named indirection (rather than callers reaching for
/// `getNextActiveIndex` directly) purely for upstream call-site parity.
int getAutocompleteNextIndex({
  required int currentIndex,
  required int itemCount,
  required ComboboxArrowKey key,
}) {
  return getNextActiveIndex(
    currentIndex: currentIndex,
    itemCount: itemCount,
    key: key,
  );
}

/// The scroll offset that brings the active row fully into view, or
/// [currentOffset] unchanged when it already is.
///
/// Scrolls by the minimum amount in either direction — an item above the
/// viewport is aligned to the top edge, an item below is aligned to the bottom
/// edge — so keyboard traversal never jumps the list further than necessary.
/// A non-positive [viewportHeight] means the list has not been measured yet, so
/// the offset is left alone rather than being clamped against a bogus height.
double getAutocompleteScrollOffset({
  required double currentOffset,
  required double viewportHeight,
  required double itemTop,
  required double itemHeight,
}) {
  if (viewportHeight <= 0) {
    return currentOffset;
  }

  final itemBottom = itemTop + itemHeight;
  final viewportTop = currentOffset;
  final viewportBottom = currentOffset + viewportHeight;

  if (itemTop < viewportTop) {
    return itemTop > 0 ? itemTop : 0;
  }

  if (itemBottom > viewportBottom) {
    final next = itemBottom - viewportHeight;
    return next > 0 ? next : 0;
  }

  return currentOffset;
}

// ---------------------------------------------------------------------------
// combobox-frame-style.ts
// ---------------------------------------------------------------------------

/// The absolute-positioning layer handed to [buildDesktopFrameStyle].
///
/// Upstream this is an opaque `StyleProp<ViewStyle>` produced either by the
/// floating-ui hook or by hand as `{ left, bottom }`; only edge insets are ever
/// present, so those are the fields modelled here. [buildDesktopFrameStyle]
/// never inspects it — it is passed straight through to the flattened result.
final class DesktopFramePositionStyle {
  /// Creates a positioning layer; every unset inset means "not constrained".
  const DesktopFramePositionStyle({
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  /// Distance from the parent's left edge.
  final double? left;

  /// Distance from the parent's top edge.
  final double? top;

  /// Distance from the parent's right edge.
  final double? right;

  /// Distance from the parent's bottom edge.
  final double? bottom;

  @override
  bool operator ==(Object other) =>
      other is DesktopFramePositionStyle &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'DesktopFramePositionStyle(left: $left, top: $top, '
      'right: $right, bottom: $bottom)';
}

/// The resolved style of the desktop combobox popover frame.
///
/// Upstream returns an *array* of partial styles that React Native flattens
/// last-wins. Dart has no such flattening step, so the layers are merged here
/// and only the merged result is exposed. The merge order upstream is
/// base -> fixed height -> position -> hidden -> available height, which is why
/// a measured [availableHeight] outranks a caller-supplied fixed height for
/// [maxHeight] but leaves [minHeight] alone.
///
/// The frame is always `position: absolute`; that is invariant, so it is not
/// modelled as a field.
final class DesktopFrameStyle {
  /// Creates a resolved frame style.
  const DesktopFrameStyle({
    required this.minWidth,
    required this.maxWidth,
    this.width,
    this.minHeight,
    this.maxHeight,
    this.opacity,
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  /// Width floor: the popover never renders narrower than this.
  final double minWidth;

  /// Width ceiling, always at least [minWidth].
  final double maxWidth;

  /// Always `null`. Upstream deliberately emits no `width` so the popover can
  /// size to its content between [minWidth] and [maxWidth]; the field exists to
  /// keep that absence assertable rather than implicit.
  final double? width;

  /// Height floor, set only when the caller pinned a fixed popover height.
  final double? minHeight;

  /// Height ceiling from the fixed height, lowered to the measured space
  /// available on screen once the floating layer has reported it.
  final double? maxHeight;

  /// `0` while the popover is positioned but not yet safe to show, otherwise
  /// `null` (inherit). Suppresses the one-frame flash at the pre-measurement
  /// origin without unmounting the content that is being measured.
  final double? opacity;

  /// Distance from the parent's left edge, passed through from the position
  /// layer.
  final double? left;

  /// Distance from the parent's top edge, passed through from the position
  /// layer.
  final double? top;

  /// Distance from the parent's right edge, passed through from the position
  /// layer.
  final double? right;

  /// Distance from the parent's bottom edge, passed through from the position
  /// layer.
  final double? bottom;

  @override
  bool operator ==(Object other) =>
      other is DesktopFrameStyle &&
      other.minWidth == minWidth &&
      other.maxWidth == maxWidth &&
      other.width == width &&
      other.minHeight == minHeight &&
      other.maxHeight == maxHeight &&
      other.opacity == opacity &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(
    minWidth,
    maxWidth,
    width,
    minHeight,
    maxHeight,
    opacity,
    left,
    top,
    right,
    bottom,
  );

  @override
  String toString() =>
      'DesktopFrameStyle(minWidth: $minWidth, maxWidth: $maxWidth, '
      'width: $width, minHeight: $minHeight, maxHeight: $maxHeight, '
      'opacity: $opacity, left: $left, top: $top, right: $right, '
      'bottom: $bottom)';
}

/// Width fallback used when the trigger has not been measured yet, so the
/// popover opens at a usable size instead of collapsing to zero.
const double _desktopFrameFallbackReferenceWidth = 200;

/// Default width and height ceiling for a desktop popover.
const double _desktopFrameDefaultMaxSize = 400;

/// Builds the desktop combobox popover frame style.
///
/// The width floor is `max(desktopMinWidth, referenceWidth)` — the popover is
/// never narrower than the trigger it hangs off, and never narrower than a
/// caller-declared minimum. The ceiling is `max(400, floor)` rather than a flat
/// 400 so that a trigger *wider* than the default ceiling is not capped below
/// its own width, which would make the popover visibly narrower than the control
/// that opened it.
///
/// [referenceWidth] is `null` until the trigger has been measured;
/// [desktopMinWidth], [desktopFixedHeight] and [availableHeight] are `null` when
/// the caller has no opinion.
DesktopFrameStyle buildDesktopFrameStyle({
  required double? referenceWidth,
  required DesktopFramePositionStyle desktopPositionStyle,
  required bool shouldHideDesktopContent,
  double? desktopMinWidth,
  double? desktopFixedHeight,
  double? availableHeight,
}) {
  final resolvedReferenceWidth =
      referenceWidth ?? _desktopFrameFallbackReferenceWidth;
  final declaredMinWidth = desktopMinWidth ?? 0;
  final floor = declaredMinWidth > resolvedReferenceWidth
      ? declaredMinWidth
      : resolvedReferenceWidth;

  // The available-height layer is applied last upstream, so it overrides the
  // fixed-height layer's ceiling while leaving its floor in place.
  final heightCeiling = desktopFixedHeight ?? _desktopFrameDefaultMaxSize;
  final maxHeight = availableHeight == null
      ? desktopFixedHeight
      : (availableHeight < heightCeiling ? availableHeight : heightCeiling);

  return DesktopFrameStyle(
    minWidth: floor,
    maxWidth: floor > _desktopFrameDefaultMaxSize
        ? floor
        : _desktopFrameDefaultMaxSize,
    minHeight: desktopFixedHeight,
    maxHeight: maxHeight,
    opacity: shouldHideDesktopContent ? 0 : null,
    left: desktopPositionStyle.left,
    top: desktopPositionStyle.top,
    right: desktopPositionStyle.right,
    bottom: desktopPositionStyle.bottom,
  );
}

// ---------------------------------------------------------------------------
// combobox-options.ts
// ---------------------------------------------------------------------------

/// What a combobox row points at, which drives its leading icon.
///
/// Upstream is the optional `"directory" | "file"` union; `null` means the row
/// has no filesystem meaning at all (a branch, a PR, a model name).
enum ComboboxOptionKind { directory, file }

/// One selectable combobox row.
///
/// [id] is the value the caller gets back on selection and [label] is what the
/// user reads; they are frequently the same string (a path, a branch name), but
/// are matched independently so an option can be found by either.
final class ComboboxOptionModel {
  /// Creates a combobox row.
  const ComboboxOptionModel({
    required this.id,
    required this.label,
    this.description,
    this.kind,
  });

  /// Stable value returned to the caller on selection.
  final String id;

  /// Human-readable text shown in the row.
  final String label;

  /// Secondary text, matched only as a last resort — see
  /// [filterAndRankComboboxOptions].
  final String? description;

  /// Optional filesystem role driving the row's icon.
  final ComboboxOptionKind? kind;

  @override
  bool operator ==(Object other) =>
      other is ComboboxOptionModel &&
      other.id == id &&
      other.label == label &&
      other.description == description &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, label, description, kind);

  @override
  String toString() =>
      'ComboboxOptionModel(id: $id, label: $label, '
      'description: $description, kind: $kind)';
}

/// Which side of the search box the option list occupies.
///
/// Upstream is the `"below-search" | "above-search"` string union. Unlike
/// [AutocompleteOptionsPosition] there is no default: every combobox call site
/// states its layout explicitly.
enum ComboboxOptionsPosition { belowSearch, aboveSearch }

/// Penalty added to a description-only match so it always sorts below every
/// label or id match, no matter how weak.
///
/// Upstream picks 99 because match tiers top out at 5, so a single constant
/// larger than the worst achievable tier keeps the two match classes from ever
/// interleaving.
const int _descriptionFallbackTier = 99;

/// Whether the "use exactly what you typed" row should be offered.
///
/// Only meaningful for searchable comboboxes that accept free-form values, and
/// suppressed when the query already names an existing option — otherwise
/// selecting a real directory would show two identical-looking rows.
///
/// Upstream guards with `!input.searchable || !input.allowCustomValue`, JS
/// truthiness over booleans; Dart's `!` over non-nullable `bool` is identical.
bool shouldShowCustomComboboxOption({
  required List<ComboboxOptionModel> options,
  required String searchQuery,
  required bool searchable,
  required bool allowCustomValue,
}) {
  final sanitizedSearchValue = searchQuery.trim();
  if (!searchable || !allowCustomValue || sanitizedSearchValue.isEmpty) {
    return false;
  }

  final needle = sanitizedSearchValue.toLowerCase();
  return !options.any(
    (opt) =>
        opt.id.toLowerCase() == needle || opt.label.toLowerCase() == needle,
  );
}

/// The options matching [search], best match first.
///
/// An empty [search] short-circuits and returns [options] itself (not a copy),
/// matching upstream — callers treat the result as read-only.
///
/// Matching is two-pass per option: label and id first, and only if neither hits
/// does the description get a chance, penalised by [_descriptionFallbackTier].
/// Description text is long and noisy, so letting it compete on equal footing
/// would let an incidental word in a PR body outrank a real branch-name match.
///
/// Deviation: upstream breaks score ties with `String.localeCompare`, which is
/// locale-aware and case-insensitive at its primary strength. Dart's
/// [String.compareTo] is raw UTF-16 code-unit order, which would sort every
/// capitalised label ahead of every lowercase one. This uses a case-insensitive
/// primary comparison with a code-unit tie-break, matching `localeCompare` for
/// ASCII labels; it still differs from ICU's tertiary rules for pairs that
/// differ only by case (`"a"` vs `"A"`) and for non-ASCII collation.
///
/// Deviation: upstream relies on `Array.prototype.sort` being stable so that
/// fully tied options keep input order. Dart's [List.sort] is not stable, so an
/// original-index tie-break is applied last to reproduce that ordering.
List<ComboboxOptionModel> filterAndRankComboboxOptions(
  List<ComboboxOptionModel> options,
  String search,
) {
  if (search.isEmpty) return options;

  final scored = <({ComboboxOptionModel opt, MatchScore score, int index})>[];
  for (var index = 0; index < options.length; index += 1) {
    final opt = options[index];
    final score = _scoreOption(opt, search);
    if (score != null) scored.add((opt: opt, score: score, index: index));
  }

  scored.sort((a, b) {
    final cmp = compareMatchScores(a.score, b.score);
    if (cmp != 0) return cmp;
    final byLabel = _compareLabels(a.opt.label, b.opt.label);
    if (byLabel != 0) return byLabel;
    return a.index - b.index;
  });

  return scored.map((entry) => entry.opt).toList();
}

/// The rows a combobox should render for the current query, custom row first.
///
/// The custom row is prepended rather than appended so a user typing a brand-new
/// path can commit it with a single Enter, without arrowing past filtered
/// leftovers.
///
/// A non-searchable combobox skips filtering entirely (upstream normalises the
/// query to `""` in that case), so every option stays visible.
///
/// [customValuePrefix] is trimmed and, when non-empty, wraps the typed value as
/// `prefix "value"`; an empty prefix shows the raw value so the row reads as the
/// literal thing being created.
List<ComboboxOptionModel> buildVisibleComboboxOptions({
  required List<ComboboxOptionModel> options,
  required String searchQuery,
  required bool searchable,
  required bool allowCustomValue,
  required String customValuePrefix,
  String? customValueDescription,
  ComboboxOptionKind? customValueKind,
}) {
  final normalizedSearch = searchable ? searchQuery.trim().toLowerCase() : '';
  final filteredOptions = filterAndRankComboboxOptions(
    options,
    normalizedSearch,
  );

  final sanitizedSearchValue = searchQuery.trim();
  final showCustomOption = shouldShowCustomComboboxOption(
    options: options,
    searchQuery: searchQuery,
    searchable: searchable,
    allowCustomValue: allowCustomValue,
  );

  final visibleOptions = <ComboboxOptionModel>[];

  if (showCustomOption) {
    final trimmedPrefix = customValuePrefix.trim();
    final customLabel = trimmedPrefix.isNotEmpty
        ? '$trimmedPrefix "$sanitizedSearchValue"'
        : sanitizedSearchValue;
    visibleOptions.add(
      ComboboxOptionModel(
        id: sanitizedSearchValue,
        label: customLabel,
        description: customValueDescription,
        kind: customValueKind,
      ),
    );
  }

  visibleOptions.addAll(filteredOptions);
  return visibleOptions;
}

/// The visible options in render order for [optionsPosition].
///
/// Same reasoning as [orderAutocompleteOptions]: above the search box the list
/// is reversed so the top-ranked row sits nearest the caret. Below-search is the
/// identity case and returns the input list itself, matching upstream.
List<ComboboxOptionModel> orderVisibleComboboxOptions(
  List<ComboboxOptionModel> visibleOptions,
  ComboboxOptionsPosition optionsPosition,
) {
  if (optionsPosition != ComboboxOptionsPosition.aboveSearch) {
    return visibleOptions;
  }
  return visibleOptions.reversed.toList();
}

/// The index active by default, or `-1` when the list is empty.
///
/// Mirrors [getAutocompleteFallbackIndex] against the combobox's own position
/// union.
int getComboboxFallbackIndex(
  int itemCount,
  ComboboxOptionsPosition optionsPosition,
) {
  if (itemCount <= 0) {
    return -1;
  }
  return optionsPosition == ComboboxOptionsPosition.aboveSearch
      ? itemCount - 1
      : 0;
}

/// Scores one option, falling back to its description only when neither the
/// label nor the id matched.
///
/// Deviation: upstream's `if (!opt.description) return null` is JS falsiness, so
/// an empty-string description is skipped exactly like a missing one. The Dart
/// null-or-empty check reproduces that.
MatchScore? _scoreOption(ComboboxOptionModel opt, String search) {
  final best = scoreTextFields(search, [opt.label, opt.id]);
  if (best != null) return best;
  final description = opt.description;
  if (description == null || description.isEmpty) return null;
  final descriptionScore = scoreTextFields(search, [description]);
  if (descriptionScore == null) return null;
  return MatchScore(
    tier: descriptionScore.tier + _descriptionFallbackTier,
    offset: descriptionScore.offset,
    spread: descriptionScore.spread,
  );
}

int _compareLabels(String a, String b) {
  final primary = a.toLowerCase().compareTo(b.toLowerCase());
  if (primary != 0) return primary;
  return a.compareTo(b);
}

// ---------------------------------------------------------------------------
// control-geometry.ts
// ---------------------------------------------------------------------------

/// Button size tiers. `xs` is a genuinely shorter control, not `sm` with a
/// smaller font.
enum ButtonControlSize { xs, sm, md, lg }

/// Size tiers for text-entry style controls, which only come in two heights.
enum FieldControlSize { sm, md }

/// Segmented-control size tiers, deliberately sharing names with
/// [ButtonControlSize] so the same name means the same height and padding.
enum SegmentedControlSize { xs, sm, md }

/// The single visual state a control resolves to after collapsing its
/// individual interaction flags.
enum ControlInteractionPhase { rest, hover, active }

/// How an outline is stroked. Upstream is CSS's `outlineStyle`; only `solid` is
/// ever used, but it is modelled rather than assumed so the emitted style stays
/// self-describing.
enum ControlOutlineStyle { solid }

/// The raw interaction flags a control reports.
///
/// Deviation: upstream's fields are `boolean | undefined` and are read for
/// truthiness. Dart uses non-nullable `bool` defaulting to `false`, which is
/// observably identical since `undefined` and `false` are both falsy.
final class ControlInteractionState {
  /// Creates an interaction state; every unspecified flag is `false`.
  const ControlInteractionState({
    this.hovered = false,
    this.focused = false,
    this.pressed = false,
    this.open = false,
    this.active = false,
    this.disabled = false,
  });

  /// Pointer is over the control.
  final bool hovered;

  /// Control holds keyboard focus.
  final bool focused;

  /// Pointer is currently down on the control.
  final bool pressed;

  /// Control owns an open popover or menu.
  final bool open;

  /// Control is the selected member of a group.
  final bool active;

  /// Control rejects interaction.
  final bool disabled;

  @override
  bool operator ==(Object other) =>
      other is ControlInteractionState &&
      other.hovered == hovered &&
      other.focused == focused &&
      other.pressed == pressed &&
      other.open == open &&
      other.active == active &&
      other.disabled == disabled;

  @override
  int get hashCode =>
      Object.hash(hovered, focused, pressed, open, active, disabled);

  @override
  String toString() =>
      'ControlInteractionState(hovered: $hovered, focused: $focused, '
      'pressed: $pressed, open: $open, active: $active, disabled: $disabled)';
}

/// The per-phase styles a control supplies to
/// [resolveControlInteractionStyles].
///
/// Generic over the style representation so callers can layer either the
/// [ControlSurfaceStyle] values produced by [createControlGeometry] or their own
/// widget-level decorations.
final class ControlInteractionStyleMap<T extends Object> {
  /// Creates a style map. [controlDisabled] is optional because not every
  /// control dims when disabled.
  const ControlInteractionStyleMap({
    required this.controlRest,
    required this.controlHover,
    required this.controlActive,
    this.controlDisabled,
  });

  /// Baseline style, always applied.
  final T controlRest;

  /// Applied on top of [controlRest] in the hover phase.
  final T controlHover;

  /// Applied on top of [controlRest] in the active phase.
  final T controlActive;

  /// Applied on top of everything else while disabled.
  final T? controlDisabled;
}

/// The single phase [state] resolves to.
///
/// The precedence is deliberate: `disabled` wins outright and reports `rest`, so
/// a disabled-but-still-focused control does not draw a focus ring it cannot
/// act on. Focus, open and pressed all collapse into `active` because they are
/// visually the same "this control is engaged" treatment, which keeps a
/// keyboard user and a mouse user seeing the same affordance.
ControlInteractionPhase getControlInteractionPhase(
  ControlInteractionState state,
) {
  if (state.disabled) {
    return ControlInteractionPhase.rest;
  }
  if (state.active || state.focused || state.open || state.pressed) {
    return ControlInteractionPhase.active;
  }
  if (state.hovered) {
    return ControlInteractionPhase.hover;
  }
  return ControlInteractionPhase.rest;
}

/// The style layers for [state], outermost last.
///
/// Always returns exactly four entries — rest, hover, active, disabled — with
/// `null` in the slots that do not apply. Upstream returns the same fixed-length
/// array with `null` holes because React Native ignores them during flattening;
/// preserving the shape keeps slot indices meaningful to callers instead of
/// making them infer which layer survived.
List<T?> resolveControlInteractionStyles<T extends Object>(
  ControlInteractionStyleMap<T> styles,
  ControlInteractionState state,
) {
  final phase = getControlInteractionPhase(state);
  return [
    styles.controlRest,
    phase == ControlInteractionPhase.hover ? styles.controlHover : null,
    phase == ControlInteractionPhase.active ? styles.controlActive : null,
    state.disabled ? styles.controlDisabled : null,
  ];
}

const double _tightControlHeight = 28;
const double _compactControlHeight = 32;
const double _fieldControlHeight = 44;
const double _segmentedTightInset = 2;
const double _segmentedCompactInset = 2;
const double _segmentedFieldInset = 3;
const double _switchTrackWidth = 34;
const double _switchTrackHeight = 20;
const double _switchThumbSize = 16;
const double _controlFocusRingWidth = 2;
const double _controlFocusRingOffset = 1;
const double _fieldTextLineHeightRatio = 1.4;

const double _iconSizeXs = 12;
const double _iconSizeSm = 14;
const double _iconSizeMd = 16;
const double _iconSizeLg = 20;

/// Icon edge length per button size, keyed so a caller only has to know the size
/// name.
const Map<ButtonControlSize, double> buttonIconSize = {
  ButtonControlSize.xs: _iconSizeXs,
  ButtonControlSize.sm: _iconSizeSm,
  ButtonControlSize.md: _iconSizeMd,
  ButtonControlSize.lg: _iconSizeLg,
};

/// Icon edge length per segmented-control size, sharing [buttonIconSize]'s
/// values for the sizes both control kinds offer.
const Map<SegmentedControlSize, double> segmentedIconSize = {
  SegmentedControlSize.xs: _iconSizeXs,
  SegmentedControlSize.sm: _iconSizeSm,
  SegmentedControlSize.md: _iconSizeMd,
};

/// Fixed pixel geometry of the switch control.
///
/// Theme-independent because the switch is sized in absolute pixels rather than
/// from spacing tokens. Upstream exports this as a plain object literal; Dart
/// follows the repo's existing token-holder shape (see `PaseoSpacing`).
abstract final class SwitchGeometry {
  /// Overall track width.
  static const double trackWidth = _switchTrackWidth;

  /// Overall track height; also sets the track's pill radius.
  static const double trackHeight = _switchTrackHeight;

  /// Thumb edge length.
  static const double thumbSize = _switchThumbSize;

  /// Distance the thumb slides between off and on.
  ///
  /// Derived rather than hard-coded so the thumb keeps an equal inset on both
  /// ends: the free track space minus one inset, where the inset is itself the
  /// track/thumb height difference.
  static const double thumbTravel =
      _switchTrackWidth -
      _switchThumbSize -
      (_switchTrackHeight - _switchThumbSize);
}

/// The design tokens [createControlGeometry] reads.
///
/// Upstream takes the whole `Theme` object and picks a dozen fields out of it.
/// Dart narrows that to exactly the consumed tokens so the dependency is
/// visible, and so tests can supply a theme without constructing a full
/// [FluentThemeData]-backed token set.
///
/// Every numeric token defaults to its frozen upstream value (spacing reuses the
/// existing [PaseoSpacing] scale), leaving only the two palette-dependent colors
/// to be supplied.
final class ControlGeometryTheme {
  /// Creates a token set; the numeric defaults are the frozen upstream values.
  const ControlGeometryTheme({
    required this.accent,
    required this.borderAccent,
    this.fontSizeXs = 12,
    this.fontSizeSm = 14,
    this.fontSizeBase = 16,
    this.borderRadiusMd = 6,
    this.borderRadiusLg = 8,
    this.borderRadiusXl = 12,
    this.borderRadiusFull = 9999,
    this.borderWidth1 = 1,
    this.opacity50 = 0.5,
    this.spacing3 = PaseoSpacing.s3,
    this.spacing4 = PaseoSpacing.s4,
    this.spacing6 = PaseoSpacing.s6,
  });

  /// Focus-ring color.
  final Color accent;

  /// Border color for hovered and engaged controls.
  final Color borderAccent;

  /// `theme.fontSize.xs`.
  final double fontSizeXs;

  /// `theme.fontSize.sm`.
  final double fontSizeSm;

  /// `theme.fontSize.base`.
  final double fontSizeBase;

  /// `theme.borderRadius.md`.
  final double borderRadiusMd;

  /// `theme.borderRadius.lg`.
  final double borderRadiusLg;

  /// `theme.borderRadius.xl`.
  final double borderRadiusXl;

  /// `theme.borderRadius.full`; a deliberately absurd radius that reads as a
  /// pill at any height.
  final double borderRadiusFull;

  /// `theme.borderWidth[1]`.
  final double borderWidth1;

  /// `theme.opacity[50]`.
  final double opacity50;

  /// `theme.spacing[3]`.
  final double spacing3;

  /// `theme.spacing[4]`.
  final double spacing4;

  /// `theme.spacing[6]`.
  final double spacing6;
}

/// A box-shaped control style: whichever of height, padding and radius the
/// control actually pins.
///
/// One class stands in for upstream's several distinct object literals because
/// they are all partial `ViewStyle`s over the same key set; an unset field means
/// the key was absent.
final class ControlBoxStyle {
  /// Creates a box style; unset fields mean "not pinned".
  const ControlBoxStyle({
    this.minHeight,
    this.paddingHorizontal,
    this.paddingVertical,
    this.padding,
    this.borderRadius,
    this.justifyContent,
  });

  /// Minimum control height. Controls grow past it when their content demands.
  final double? minHeight;

  /// Left and right inset.
  final double? paddingHorizontal;

  /// Top and bottom inset.
  final double? paddingVertical;

  /// Uniform inset on all four sides.
  final double? padding;

  /// Corner radius.
  final double? borderRadius;

  /// Main-axis alignment. Upstream's `justifyContent: "center"`.
  final MainAxisAlignment? justifyContent;

  @override
  bool operator ==(Object other) =>
      other is ControlBoxStyle &&
      other.minHeight == minHeight &&
      other.paddingHorizontal == paddingHorizontal &&
      other.paddingVertical == paddingVertical &&
      other.padding == padding &&
      other.borderRadius == borderRadius &&
      other.justifyContent == justifyContent;

  @override
  int get hashCode => Object.hash(
    minHeight,
    paddingHorizontal,
    paddingVertical,
    padding,
    borderRadius,
    justifyContent,
  );

  @override
  String toString() =>
      'ControlBoxStyle(minHeight: $minHeight, '
      'paddingHorizontal: $paddingHorizontal, '
      'paddingVertical: $paddingVertical, padding: $padding, '
      'borderRadius: $borderRadius, justifyContent: $justifyContent)';
}

/// Type sizing for a control's label or entered text.
final class ControlTextStyle {
  /// Creates a text style. [lineHeight] is unset for controls that only pin a
  /// font size and let the platform decide leading.
  const ControlTextStyle({required this.fontSize, this.lineHeight});

  /// Type size.
  final double fontSize;

  /// Rendered line box height.
  final double? lineHeight;

  @override
  bool operator ==(Object other) =>
      other is ControlTextStyle &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight);

  @override
  String toString() =>
      'ControlTextStyle(fontSize: $fontSize, lineHeight: $lineHeight)';
}

/// A text input's box and type styles merged.
///
/// Upstream builds this with object spread (`{...fieldControlSm, ...fieldTextSm}`)
/// so the caller reads one flat style. Dart composes the two parts and forwards
/// the keys, which keeps the pairing explicit and the values single-sourced.
final class FormTextInputStyle {
  /// Creates a merged input style from its box and text halves.
  const FormTextInputStyle({required this.box, required this.text});

  /// Box half.
  final ControlBoxStyle box;

  /// Type half.
  final ControlTextStyle text;

  /// Forwarded from [box].
  double? get minHeight => box.minHeight;

  /// Forwarded from [box].
  double? get paddingHorizontal => box.paddingHorizontal;

  /// Forwarded from [box].
  double? get paddingVertical => box.paddingVertical;

  /// Forwarded from [box].
  double? get borderRadius => box.borderRadius;

  /// Forwarded from [text].
  double get fontSize => text.fontSize;

  /// Forwarded from [text].
  double? get lineHeight => text.lineHeight;

  @override
  bool operator ==(Object other) =>
      other is FormTextInputStyle && other.box == box && other.text == text;

  @override
  int get hashCode => Object.hash(box, text);

  @override
  String toString() => 'FormTextInputStyle(box: $box, text: $text)';
}

/// A control's border and focus-ring treatment for one interaction phase.
///
/// Upstream emits several differently-shaped partial `ViewStyle` literals
/// (`controlRest`, `controlHover`, `controlActive`, ...); they are unified here
/// because they are layered on top of each other, and an absent key — modelled
/// as `null` — is exactly what lets a lower layer show through.
final class ControlSurfaceStyle {
  /// Creates a surface style; unset fields inherit from the layer beneath.
  const ControlSurfaceStyle({
    this.borderWidth,
    this.borderColor,
    this.outlineWidth,
    this.outlineColor,
    this.outlineOffset,
    this.outlineStyle,
    this.opacity,
  });

  /// Border stroke width.
  final double? borderWidth;

  /// Border stroke color.
  final Color? borderColor;

  /// Focus-ring stroke width.
  final double? outlineWidth;

  /// Focus-ring stroke color.
  final Color? outlineColor;

  /// Gap between the border and the focus ring.
  final double? outlineOffset;

  /// Focus-ring stroke style.
  final ControlOutlineStyle? outlineStyle;

  /// Whole-control opacity.
  final double? opacity;

  @override
  bool operator ==(Object other) =>
      other is ControlSurfaceStyle &&
      other.borderWidth == borderWidth &&
      other.borderColor == borderColor &&
      other.outlineWidth == outlineWidth &&
      other.outlineColor == outlineColor &&
      other.outlineOffset == outlineOffset &&
      other.outlineStyle == outlineStyle &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(
    borderWidth,
    borderColor,
    outlineWidth,
    outlineColor,
    outlineOffset,
    outlineStyle,
    opacity,
  );

  @override
  String toString() =>
      'ControlSurfaceStyle(borderWidth: $borderWidth, '
      'borderColor: $borderColor, outlineWidth: $outlineWidth, '
      'outlineColor: $outlineColor, outlineOffset: $outlineOffset, '
      'outlineStyle: $outlineStyle, opacity: $opacity)';
}

/// Fully-transparent color, standing in for upstream's `"transparent"` string.
const Color _transparent = Color(0x00000000);

/// Every control style derived from one theme.
///
/// Exposed as a single object (rather than free functions) so that the cross-
/// control invariants upstream cares about — same size name means same height,
/// same label size, same horizontal padding — are visible side by side.
final class ControlGeometry {
  /// Creates a geometry set. Prefer [createControlGeometry], which derives every
  /// field from a theme.
  const ControlGeometry({
    required this.buttonXs,
    required this.buttonSm,
    required this.buttonMd,
    required this.buttonLg,
    required this.buttonText,
    required this.buttonTextXs,
    required this.formTextInputSm,
    required this.formTextInputMd,
    required this.formTextInput,
    required this.fieldControlSm,
    required this.fieldControlMd,
    required this.fieldTextSm,
    required this.fieldTextMd,
    required this.controlRest,
    required this.controlHover,
    required this.controlActive,
    required this.controlFocusRingColor,
    required this.controlDisabled,
    required this.switchControl,
    required this.segmentedContainerXs,
    required this.segmentedContainerSm,
    required this.segmentedContainerMd,
    required this.segmentedSegmentXs,
    required this.segmentedSegmentSm,
    required this.segmentedSegmentMd,
    required this.segmentedLabelXs,
    required this.segmentedLabelSm,
    required this.segmentedLabelMd,
  });

  /// Extra-small button box.
  final ControlBoxStyle buttonXs;

  /// Small button box.
  final ControlBoxStyle buttonSm;

  /// Medium button box.
  final ControlBoxStyle buttonMd;

  /// Large button box. Shares `md`'s height and differs only in padding and
  /// radius — `lg` is a wider button, not a taller one.
  final ControlBoxStyle buttonLg;

  /// Label type for every button size except `xs`.
  final ControlTextStyle buttonText;

  /// Label type for `xs` buttons.
  final ControlTextStyle buttonTextXs;

  /// Small text input, box and type merged.
  final FormTextInputStyle formTextInputSm;

  /// Medium text input, box and type merged.
  final FormTextInputStyle formTextInputMd;

  /// Default text input; an alias of [formTextInputMd] so call sites that do not
  /// state a size get the medium tier.
  final FormTextInputStyle formTextInput;

  /// Small field box, for non-input controls that must line up with
  /// [formTextInputSm].
  final ControlBoxStyle fieldControlSm;

  /// Medium field box, for non-input controls that must line up with
  /// [formTextInputMd].
  final ControlBoxStyle fieldControlMd;

  /// Small field type.
  final ControlTextStyle fieldTextSm;

  /// Medium field type.
  final ControlTextStyle fieldTextMd;

  /// Resting border treatment. The border is transparent rather than absent so
  /// hovering only changes a color and never reflows the control.
  final ControlSurfaceStyle controlRest;

  /// Hover border treatment.
  final ControlSurfaceStyle controlHover;

  /// Engaged border plus focus ring.
  final ControlSurfaceStyle controlActive;

  /// Focus-ring color on its own, for controls that draw their own ring
  /// geometry.
  final ControlSurfaceStyle controlFocusRingColor;

  /// Disabled dimming.
  final ControlSurfaceStyle controlDisabled;

  /// Switch row box.
  final ControlBoxStyle switchControl;

  /// Extra-small segmented track.
  final ControlBoxStyle segmentedContainerXs;

  /// Small segmented track.
  final ControlBoxStyle segmentedContainerSm;

  /// Medium segmented track.
  final ControlBoxStyle segmentedContainerMd;

  /// Extra-small segment.
  final ControlBoxStyle segmentedSegmentXs;

  /// Small segment.
  final ControlBoxStyle segmentedSegmentSm;

  /// Medium segment.
  final ControlBoxStyle segmentedSegmentMd;

  /// Extra-small segment label type.
  final ControlTextStyle segmentedLabelXs;

  /// Small segment label type.
  final ControlTextStyle segmentedLabelSm;

  /// Medium segment label type. Intentionally the same size as
  /// [segmentedLabelSm] — a segmented control's label never grows past `sm`.
  final ControlTextStyle segmentedLabelMd;

  /// The three-phase style map for [resolveControlInteractionStyles].
  ControlInteractionStyleMap<ControlSurfaceStyle> get interactionStyles =>
      ControlInteractionStyleMap<ControlSurfaceStyle>(
        controlRest: controlRest,
        controlHover: controlHover,
        controlActive: controlActive,
        controlDisabled: controlDisabled,
      );
}

/// Line height for a field's text.
///
/// Deviation: upstream uses JS `Math.round`, which breaks ties toward positive
/// infinity, while Dart's [double.round] breaks them away from zero. Font sizes
/// are always positive, so the two agree on every reachable input.
double _fieldLineHeight(double fontSize) {
  return (fontSize * _fieldTextLineHeightRatio).roundToDouble();
}

/// Vertical padding that centres a [lineHeight] line box in a [controlHeight]
/// control.
///
/// Derived rather than tabulated so changing the type ramp cannot silently
/// change control heights.
double _fieldVerticalPadding(double controlHeight, double lineHeight) {
  return (controlHeight - lineHeight) / 2;
}

/// Derives every control style from [theme].
///
/// The sizes deliberately collapse onto three heights (28/32/44) shared across
/// control kinds: a `sm` button, a `sm` field and a `sm` segmented track all
/// measure 32, so mixed rows of controls align without per-call-site nudging.
ControlGeometry createControlGeometry(ControlGeometryTheme theme) {
  final fieldTextSmLineHeight = _fieldLineHeight(theme.fontSizeSm);
  final fieldTextMdLineHeight = _fieldLineHeight(theme.fontSizeBase);

  final fieldControlSm = ControlBoxStyle(
    minHeight: _compactControlHeight,
    paddingHorizontal: theme.spacing3,
    paddingVertical: _fieldVerticalPadding(
      _compactControlHeight,
      fieldTextSmLineHeight,
    ),
    borderRadius: theme.borderRadiusMd,
  );
  final fieldControlMd = ControlBoxStyle(
    minHeight: _fieldControlHeight,
    paddingHorizontal: theme.spacing4,
    paddingVertical: _fieldVerticalPadding(
      _fieldControlHeight,
      fieldTextMdLineHeight,
    ),
    borderRadius: theme.borderRadiusLg,
  );
  final fieldTextSm = ControlTextStyle(
    fontSize: theme.fontSizeSm,
    lineHeight: fieldTextSmLineHeight,
  );
  final fieldTextMd = ControlTextStyle(
    fontSize: theme.fontSizeBase,
    lineHeight: fieldTextMdLineHeight,
  );
  final formTextInputMd = FormTextInputStyle(
    box: fieldControlMd,
    text: fieldTextMd,
  );

  return ControlGeometry(
    buttonXs: ControlBoxStyle(
      minHeight: _tightControlHeight,
      paddingHorizontal: theme.spacing3,
      borderRadius: theme.borderRadiusMd,
    ),
    buttonSm: ControlBoxStyle(
      minHeight: _compactControlHeight,
      paddingHorizontal: theme.spacing3,
      borderRadius: theme.borderRadiusMd,
    ),
    buttonMd: ControlBoxStyle(
      minHeight: _fieldControlHeight,
      paddingHorizontal: theme.spacing4,
      borderRadius: theme.borderRadiusLg,
    ),
    buttonLg: ControlBoxStyle(
      minHeight: _fieldControlHeight,
      paddingHorizontal: theme.spacing6,
      borderRadius: theme.borderRadiusXl,
    ),
    buttonText: ControlTextStyle(fontSize: theme.fontSizeSm),
    buttonTextXs: ControlTextStyle(fontSize: theme.fontSizeXs),
    formTextInputSm: FormTextInputStyle(box: fieldControlSm, text: fieldTextSm),
    formTextInputMd: formTextInputMd,
    formTextInput: formTextInputMd,
    fieldControlSm: fieldControlSm,
    fieldControlMd: fieldControlMd,
    fieldTextSm: fieldTextSm,
    fieldTextMd: fieldTextMd,
    controlRest: ControlSurfaceStyle(
      borderWidth: theme.borderWidth1,
      borderColor: _transparent,
      outlineWidth: 0,
      outlineColor: _transparent,
    ),
    controlHover: ControlSurfaceStyle(borderColor: theme.borderAccent),
    controlActive: ControlSurfaceStyle(
      borderColor: theme.borderAccent,
      outlineColor: theme.accent,
      outlineOffset: _controlFocusRingOffset,
      outlineStyle: ControlOutlineStyle.solid,
      outlineWidth: _controlFocusRingWidth,
    ),
    controlFocusRingColor: ControlSurfaceStyle(outlineColor: theme.accent),
    controlDisabled: ControlSurfaceStyle(opacity: theme.opacity50),
    switchControl: const ControlBoxStyle(
      minHeight: _compactControlHeight,
      justifyContent: MainAxisAlignment.center,
    ),
    segmentedContainerXs: const ControlBoxStyle(
      minHeight: _tightControlHeight,
      padding: 0,
    ),
    segmentedContainerSm: const ControlBoxStyle(
      minHeight: _compactControlHeight,
      padding: 0,
    ),
    segmentedContainerMd: const ControlBoxStyle(
      minHeight: _fieldControlHeight,
      padding: 0,
    ),
    segmentedSegmentXs: ControlBoxStyle(
      minHeight: _tightControlHeight - _segmentedTightInset * 2,
      paddingHorizontal: theme.spacing3,
      borderRadius: theme.borderRadiusFull,
    ),
    segmentedSegmentSm: ControlBoxStyle(
      minHeight: _compactControlHeight - _segmentedCompactInset * 2,
      paddingHorizontal: theme.spacing3,
      borderRadius: theme.borderRadiusFull,
    ),
    segmentedSegmentMd: ControlBoxStyle(
      minHeight: _fieldControlHeight - _segmentedFieldInset * 2,
      paddingHorizontal: theme.spacing4,
      borderRadius: theme.borderRadiusFull,
    ),
    segmentedLabelXs: ControlTextStyle(fontSize: theme.fontSizeXs),
    segmentedLabelSm: ControlTextStyle(fontSize: theme.fontSizeSm),
    segmentedLabelMd: ControlTextStyle(fontSize: theme.fontSizeSm),
  );
}
