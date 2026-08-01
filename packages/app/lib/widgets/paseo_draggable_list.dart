/// Port of the frozen Paseo 0.2.0 draggable-list + material-file-icon cluster:
/// `components/draggable-list.types.ts`, `components/draggable-list.tsx`,
/// `components/draggable-list.web.tsx`, `components/draggable-list.native.tsx`,
/// `components/material-file-icons.ts` and `components/material-file-icon.tsx`.
///
/// ## Why these six files are one unit
///
/// Upstream `draggable-list.tsx` is a three-line re-export whose only job is to
/// give TypeScript something to resolve; Metro swaps in `.web.tsx` or
/// `.native.tsx` per platform. Flutter has a single runtime, so the two
/// platform implementations collapse into the one [PaseoDraggableList] here and
/// the shared prop surface of `draggable-list.types.ts` becomes its constructor.
/// The material-file-icon pair rides along because it is the icon the
/// reorderable file lists render in their rows, and because its lookup table is
/// pure data that belongs next to its only widget.
///
/// ## Reuse: the reorder maths already lives elsewhere
///
/// `drag-reducer.ts`, `reorder-items.ts` and `pointer-activation.ts` are already
/// ported in `lib/drag_reorder/drag_reorder.dart`, and upstream's
/// `use-drag-reorder-state.ts` hook is nothing but those three composed. This
/// file therefore owns **only the rendering layer**: it holds a [DragState] and
/// drives it with [dragStateReducer], resolves every drop through
/// [reorderItemsOnDragEnd], and reads its activation thresholds from
/// [getDragActivationConstraints]. No ordering arithmetic is re-derived here.
///
/// Likewise the icon table is deliberately *not* folded into
/// `file_explorer_rules.dart` or `paseo_attachment_rules.dart`: those classify
/// files for behaviour (is it text? is it an image the agent can see?), whereas
/// this table is a frozen, auto-generated visual mapping from
/// `material-icon-theme`. Merging them would let a behavioural change silently
/// repaint the UI. Only the *shape* of the extension lookup is shared in
/// spirit; the payloads stay separate.
///
/// ## React Native / dnd-kit primitives with no Flutter equivalent
///
/// - **dnd-kit sensors.** Web drives drags through `MouseSensor`/`TouchSensor`
///   with explicit activation constraints. Flutter's [SliverReorderableList]
///   takes a [MultiDragGestureRecognizer] instead, so the frozen constraints in
///   [paseoDraggableListActivationConfig] are resolved through the shared
///   [getDragActivationConstraints] and then *mapped* onto recognizers: a delay
///   constraint becomes a [DelayedMultiDragGestureRecognizer] with the frozen
///   180 ms, a distance constraint becomes an
///   [ImmediateMultiDragGestureRecognizer]. Flutter's immediate recognizer
///   claims the pointer at `kTouchSlop` rather than the frozen 6 logical
///   pixels; the number is still exported as data so callers and tests can pin
///   it.
/// - **`restrictToVerticalAxis` modifier.** A vertical [SliverReorderableList]
///   only ever translates along its main axis, so the modifier is inherent.
/// - **`transform`/`transition`/`zIndex` inline styles.** The dragged row's
///   frozen look (opacity `0.9`, `scale(1.02)`, lifted above its siblings) is
///   reproduced by [paseoDraggableListProxyDecorator]; Flutter already paints
///   the drag proxy in an overlay, which is what `zIndex: 1000` bought.
/// - **`simultaneousGestureRef` / `waitFor`.** These are
///   `react-native-gesture-handler` refs used to hand-negotiate with a parent
///   pan handler. Flutter's gesture arena performs that negotiation itself, so
///   the two props are dropped rather than faked.
/// - **`extraData`.** A FlatList virtualization hint. Flutter rebuilds children
///   from the element tree, so it is accepted for call-site parity and has no
///   effect.
/// - **`RefreshControl`.** Lives in `react-native`; fluent has no equivalent
///   and Material's `RefreshIndicator` is off-limits here. The *decision* of
///   whether a refresh affordance is showing is the part with real logic, so it
///   is ported as the pure [paseoDraggableListShowsRefreshControl] and rendered
///   with a fluent [ProgressBar].
/// - **`style` / `containerStyle` / `contentContainerStyle`.** RN style objects.
///   Only the two that carry behaviour survive: `containerStyle`'s
///   `flex: 1 / minHeight: 0` is exactly [PaseoDraggableList.scrollEnabled],
///   and `contentContainerStyle` reduces to [PaseoDraggableList.padding].
/// - **`testID`.** Becomes [PaseoDraggableList.listKey] so tests address the
///   scroll view specifically, leaving `key` free for the widget itself.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart'
    show
        DelayedMultiDragGestureRecognizer,
        ImmediateMultiDragGestureRecognizer,
        MultiDragGestureRecognizer;
import 'package:flutter_svg/flutter_svg.dart';

import '../drag_reorder/drag_reorder.dart';

// ---------------------------------------------------------------------------
// draggable-list.web.tsx — frozen constants
// ---------------------------------------------------------------------------

/// `DRAG_ACTIVATION_CONFIG` from `draggable-list.web.tsx`.
///
/// Exported rather than inlined because it is the only input
/// [getDragActivationConstraints] takes, and pinning it is how a test proves
/// this list activates on the same thresholds as every other Paseo drag
/// surface.
const DragActivationConfig paseoDraggableListActivationConfig =
    DragActivationConfig(
      movementDistance: 6,
      touchHoldDelayMs: 180,
      touchHoldTolerance: 8,
    );

/// Opacity applied to the row under the pointer, from the web `style` object.
const double paseoDraggableListDragOpacity = 0.9;

/// `scale(1.02)` on the dragged row — a barely-there lift that reads as
/// "picked up" without the row visibly outgrowing its slot.
const double paseoDraggableListDragScale = 1.02;

/// Vertical drag distance that releases a pull-to-refresh, standing in for
/// `RefreshControl`'s built-in threshold.
///
/// Only reachable under bouncing scroll physics; on clamping platforms (the
/// desktop default) the list simply never overscrolls and refresh stays a
/// caller-driven flag.
const double paseoDraggableListRefreshPullThreshold = 64;

// ---------------------------------------------------------------------------
// draggable-list.types.ts
// ---------------------------------------------------------------------------

/// Resolves a stable identity for an item, mirroring upstream's
/// `(item, index) => string`.
///
/// The index is part of the signature because lists keyed by position are
/// legitimate upstream, and [reorderItemsOnDragEnd] relies on the same shape.
typedef PaseoDraggableListKeyExtractor<T> = String Function(T item, int index);

/// Builds one row from [PaseoDraggableRenderItemInfo], mirroring upstream's
/// `renderItem`.
typedef PaseoDraggableListItemBuilder<T> =
    Widget Function(BuildContext context, PaseoDraggableRenderItemInfo<T> info);

/// Resolves a user-visible string by key.
///
/// Injected rather than read from a global so this widget stays pumpable in a
/// bare test harness; every call site falls back to the frozen English in
/// [paseoDraggableListFallbackStrings].
typedef PaseoDraggableListTranslator = String Function(String key);

/// The frozen English for every string this cluster can show.
///
/// The upstream components render no text at all — the only entry here is the
/// semantics label Flutter needs to announce a drag handle, which React Native
/// got for free from the platform's own reorder affordance.
const Map<String, String> paseoDraggableListFallbackStrings = <String, String>{
  'draggableList.dragHandle': 'Drag to reorder',
};

/// Resolves [key] through [translate], falling back to the frozen English.
///
/// A translator that returns the key unchanged (the common "missing
/// translation" convention) is treated as a miss so the UI never shows a
/// dotted identifier to a user.
String paseoDraggableListString(
  String key, {
  PaseoDraggableListTranslator? translate,
}) {
  final fallback = paseoDraggableListFallbackStrings[key] ?? key;
  final translated = translate?.call(key);
  if (translated == null || translated.isEmpty || translated == key) {
    return fallback;
  }
  return translated;
}

/// The drag-initiation affordance handed to a row when
/// [PaseoDraggableList.useDragHandle] is on.
///
/// Upstream this is dnd-kit's `{attributes, listeners, setActivatorNodeRef}`
/// triple, which the row *spreads* onto whichever element should start the
/// drag. Spreading has no Dart analogue, so the equivalent capability is
/// exposed as [wrap]: whatever widget you pass through it becomes the only
/// place a drag can begin.
@immutable
class PaseoDraggableListDragHandleProps {
  const PaseoDraggableListDragHandleProps({
    required this.index,
    required this.constraint,
    required this.semanticsLabel,
  });

  /// Position of the owning row, which is what the recognizer reports to
  /// [SliverReorderableList] when the drag starts.
  final int index;

  /// The touch activation rule resolved by [getDragActivationConstraints].
  /// Kept on the props (rather than hidden inside [wrap]) so a row can, for
  /// example, show a press-and-hold hint when it is a delay constraint.
  final PointerActivationConstraint constraint;

  /// Already-translated label announced for the handle.
  final String semanticsLabel;

  /// Wraps [child] so that pressing it — and only it — starts the drag.
  ///
  /// This is the `useDragHandle` half of the frozen contract: with a handle,
  /// the rest of the row stays free to scroll, which is precisely why nested
  /// lists stop "fighting" upstream.
  Widget wrap(Widget child) => Semantics(
    label: semanticsLabel,
    child: switch (constraint) {
      DelayActivationConstraint(:final delayMs) =>
        _PaseoDelayedDragStartListener(
          index: index,
          delay: Duration(milliseconds: delayMs),
          child: child,
        ),
      DistanceActivationConstraint() => ReorderableDragStartListener(
        index: index,
        child: child,
      ),
    },
  );
}

/// Everything a row needs to render itself, mirroring upstream's
/// `DraggableRenderItemInfo<T>`.
@immutable
class PaseoDraggableRenderItemInfo<T> {
  const PaseoDraggableRenderItemInfo({
    required this.item,
    required this.index,
    required this.drag,
    required this.isActive,
    this.dragHandleProps,
  });

  final T item;
  final int index;

  /// Upstream's `drag()`. On web it is already an intentional no-op — dnd-kit
  /// initiates drags from its listeners, never imperatively — and Flutter is
  /// the same: [SliverReorderableList] can only begin a drag from a live
  /// pointer-down, so there is nothing to start from a bare callback. It is
  /// retained (and still fires [PaseoDraggableList.onDragIntent]) so rows
  /// ported from the native implementation keep compiling and keep telling
  /// their owner that a drag was requested.
  final VoidCallback drag;

  /// Whether this row is the one currently under the pointer's grab.
  final bool isActive;

  /// Non-null only when [PaseoDraggableList.useDragHandle] is on, exactly as
  /// upstream leaves `dragHandleProps` undefined otherwise.
  final PaseoDraggableListDragHandleProps? dragHandleProps;
}

// ---------------------------------------------------------------------------
// Pure rules extracted from the two platform implementations
// ---------------------------------------------------------------------------

/// Whether the refresh affordance should be on screen.
///
/// Ported verbatim from `draggable-list.native.tsx`:
/// `Boolean(onRefresh) && (!isDragging || Boolean(refreshing))`, further gated
/// by `&& !nestable`. The middle clause is the interesting one — it hides the
/// spinner *while* a drag is in flight so the pull affordance cannot swallow
/// the gesture, but keeps it visible if a refresh was already running when the
/// drag started, which would otherwise make the list flicker.
bool paseoDraggableListShowsRefreshControl({
  required bool hasOnRefresh,
  required bool isDragging,
  required bool refreshing,
  required bool nestable,
}) => hasOnRefresh && (!isDragging || refreshing) && !nestable;

/// Translates a Flutter reorder destination index into dnd-kit's "id of the
/// item that was dropped onto".
///
/// [destinationIndex] is [SliverReorderableList.onReorderItem]'s `newIndex`,
/// i.e. the slot the row lands in *after* it has been lifted out. Read against
/// the pre-drag [items] that index names exactly the row dnd-kit would have
/// reported as `over`, in both directions:
///
/// * dragging `a` of `[a, b, c, d]` below `c` yields `2` → `over = c`, and
///   `arrayMove(items, 0, 2)` gives `[b, c, a, d]`;
/// * dragging `d` above `b` yields `1` → `over = b`, and `arrayMove(items, 3,
///   1)` gives `[a, d, b, c]`.
///
/// Doing the naming here — instead of reordering the list directly — is what
/// lets the drop be resolved by the already-ported [reorderItemsOnDragEnd],
/// so there is exactly one implementation of dnd-kit's `arrayMove` in the app.
/// (Note the older, now-deprecated `onReorder` reports an *insert-before* index
/// that runs one higher for downward moves; this function is written against
/// the current callback.)
///
/// Returns null when the index does not address a real row, which
/// [reorderItemsOnDragEnd] then reads as "no drop target" — the same no-op it
/// takes for a null `over`.
String? paseoDraggableListOverKey<T>({
  required List<T> items,
  required int destinationIndex,
  required PaseoDraggableListKeyExtractor<T> keyExtractor,
}) {
  if (destinationIndex < 0 || destinationIndex >= items.length) return null;
  return keyExtractor(items[destinationIndex], destinationIndex);
}

/// The frozen "picked up" treatment for the row being dragged.
///
/// Exposed as a top-level function so the visual contract (opacity `0.9`,
/// `scale(1.02)`) can be asserted without staging a full drag gesture.
Widget paseoDraggableListProxyDecorator(
  Widget child,
  int index,
  Animation<double> animation,
) => Opacity(
  opacity: paseoDraggableListDragOpacity,
  child: Transform.scale(scale: paseoDraggableListDragScale, child: child),
);

// ---------------------------------------------------------------------------
// draggable-list.tsx — the single, platform-independent implementation
// ---------------------------------------------------------------------------

/// A vertically reorderable list.
///
/// Holds exactly the state upstream's `useDragReorderState` held — an active
/// key plus a snapshot of the list taken at drag start — and delegates every
/// decision about that state to `lib/drag_reorder/drag_reorder.dart`. Rendering
/// from the snapshot (rather than from [data]) is what keeps a row from
/// teleporting mid-gesture when the underlying query refetches.
class PaseoDraggableList<T> extends StatefulWidget {
  const PaseoDraggableList({
    super.key,
    required this.data,
    required this.keyExtractor,
    required this.renderItem,
    required this.onDragEnd,
    this.padding,
    this.listKey,
    this.footer,
    this.header,
    this.empty,
    this.showsVerticalScrollIndicator = true,
    this.scrollEnabled = true,
    this.useDragHandle = false,
    this.refreshing = false,
    this.onRefresh,
    this.contentContainerFlexGrow = false,
    this.extraData,
    this.onDragBegin,
    this.onDragIntent,
    this.onDragRelease,
    this.nestable = false,
    this.translate,
  });

  /// The items to render, in their persisted order.
  final List<T> data;

  /// Identity for each item; must be stable across rebuilds or a drag will lose
  /// its target.
  final PaseoDraggableListKeyExtractor<T> keyExtractor;

  /// Builds a row. Called with [PaseoDraggableRenderItemInfo] rather than the
  /// bare item so a row can style itself while active and, under
  /// [useDragHandle], claim its own drag affordance.
  final PaseoDraggableListItemBuilder<T> renderItem;

  /// Receives the reordered list — and only when the order actually changed,
  /// because [reorderItemsOnDragEnd] returns null for a no-op drop.
  final ValueChanged<List<T>> onDragEnd;

  /// `contentContainerStyle`, reduced to the only thing it ever carried here.
  final EdgeInsetsGeometry? padding;

  /// `testID`, applied to the scroll view rather than the widget so a test can
  /// address the scrollable specifically.
  final Key? listKey;

  /// `ListFooterComponent`.
  final Widget? footer;

  /// `ListHeaderComponent`.
  final Widget? header;

  /// `ListEmptyComponent`, rendered between [header] and [footer] when [data]
  /// is empty.
  final Widget? empty;

  /// `showsVerticalScrollIndicator`.
  final bool showsVerticalScrollIndicator;

  /// When false the list does not scroll itself and instead sizes to its
  /// content, so an outer scrollable owns the gesture. This is
  /// `containerStyle`'s `flex: 1 / minHeight: 0` branch inverted.
  final bool scrollEnabled;

  /// When true a drag may only begin from the widget a row passes through
  /// [PaseoDraggableListDragHandleProps.wrap], which is what stops a nested
  /// list from stealing its parent's scroll.
  final bool useDragHandle;

  /// Whether a refresh is currently running.
  final bool refreshing;

  /// Invoked when the user pulls past
  /// [paseoDraggableListRefreshPullThreshold]. Its mere presence is also what
  /// [paseoDraggableListShowsRefreshControl] keys off.
  final VoidCallback? onRefresh;

  /// Fill the remaining viewport when the content is shorter than it.
  final bool contentContainerFlexGrow;

  /// Accepted for parity with upstream's FlatList virtualization hint; Flutter
  /// has no cell recycling to invalidate, so it is unused.
  final Object? extraData;

  /// Fired once a drag has been claimed, before any reordering.
  final VoidCallback? onDragBegin;

  /// Fired from [PaseoDraggableRenderItemInfo.drag] so an outer owner can lock
  /// itself the moment a row *asks* to be dragged.
  final VoidCallback? onDragIntent;

  /// Fired when the drag gesture ends, whatever the outcome.
  final VoidCallback? onDragRelease;

  /// Marks this list as living inside another scrolling drag host. Upstream it
  /// swaps in `NestableDraggableFlatList`; here it suppresses the refresh
  /// affordance, which is the only behaviour that variant actually changed.
  final bool nestable;

  /// Resolves user-visible strings; see [paseoDraggableListString].
  final PaseoDraggableListTranslator? translate;

  @override
  State<PaseoDraggableList<T>> createState() => _PaseoDraggableListState<T>();
}

class _PaseoDraggableListState<T> extends State<PaseoDraggableList<T>> {
  DragState<T> _dragState = dragStateInitial<T>();
  double _pullDistance = 0;

  /// The snapshot when a drag is in flight, else the live data — upstream's
  /// `state.dragItems ?? data`.
  List<T> get _items => _dragState.dragItems ?? widget.data;

  bool get _isDragging => _dragState.activeId != null;

  DragActivationConstraints get _constraints => getDragActivationConstraints(
    widget.useDragHandle,
    paseoDraggableListActivationConfig,
  );

  void _handleReorderStart(int index) {
    final items = widget.data;
    if (index < 0 || index >= items.length) return;
    setState(() {
      _dragState = dragStateReducer(
        _dragState,
        DragStartAction<T>(
          id: widget.keyExtractor(items[index], index),
          data: items,
        ),
      );
    });
    widget.onDragBegin?.call();
  }

  void _handleReorderEnd(int index) {
    // A drop routes through [_handleReorder] first, which already cleared the
    // state; this only has to fire the release hook and undo a cancel.
    if (_isDragging) {
      setState(() {
        _dragState = dragStateReducer(_dragState, DragClearAction<T>());
      });
    }
    widget.onDragRelease?.call();
  }

  void _handleReorder(int oldIndex, int newIndex) {
    final items = _items;
    if (oldIndex < 0 || oldIndex >= items.length) return;
    final activeId =
        _dragState.activeId ?? widget.keyExtractor(items[oldIndex], oldIndex);
    final overId = paseoDraggableListOverKey<T>(
      items: items,
      destinationIndex: newIndex,
      keyExtractor: widget.keyExtractor,
    );

    setState(() {
      _dragState = dragStateInitial<T>();
    });

    final reordered = reorderItemsOnDragEnd<T>(
      items: items,
      activeId: activeId,
      overId: overId,
      keyExtractor: widget.keyExtractor,
    );
    if (reordered != null) widget.onDragEnd(reordered);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final onRefresh = widget.onRefresh;
    if (onRefresh == null || widget.refreshing) return false;
    if (notification is ScrollStartNotification) {
      _pullDistance = 0;
    } else if (notification is OverscrollNotification) {
      if (notification.overscroll < 0) _pullDistance -= notification.overscroll;
    } else if (notification is ScrollEndNotification) {
      final pulled = _pullDistance;
      _pullDistance = 0;
      if (pulled >= paseoDraggableListRefreshPullThreshold) onRefresh();
    }
    return false;
  }

  Widget _buildItem(BuildContext context, int index) {
    final items = _items;
    final item = items[index];
    final id = widget.keyExtractor(item, index);
    final info = PaseoDraggableRenderItemInfo<T>(
      item: item,
      index: index,
      drag: () => widget.onDragIntent?.call(),
      isActive: _dragState.activeId == id,
      dragHandleProps: widget.useDragHandle
          ? PaseoDraggableListDragHandleProps(
              index: index,
              constraint: _constraints.touch,
              semanticsLabel: paseoDraggableListString(
                'draggableList.dragHandle',
                translate: widget.translate,
              ),
            )
          : null,
    );

    final row = widget.renderItem(context, info);
    // Without a handle the whole row is the affordance, matching the web
    // implementation spreading dnd-kit's listeners onto the row wrapper.
    return KeyedSubtree(
      key: ValueKey<String>(id),
      child: widget.useDragHandle
          ? row
          : ReorderableDragStartListener(index: index, child: row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final showsRefresh = paseoDraggableListShowsRefreshControl(
      hasOnRefresh: widget.onRefresh != null,
      isDragging: _isDragging,
      refreshing: widget.refreshing,
      nestable: widget.nestable,
    );

    final slivers = <Widget>[
      if (showsRefresh && widget.refreshing)
        const SliverToBoxAdapter(child: ProgressBar()),
      if (widget.header != null) SliverToBoxAdapter(child: widget.header),
      if (items.isEmpty && widget.empty != null)
        SliverToBoxAdapter(child: widget.empty),
      SliverReorderableList(
        itemCount: items.length,
        itemBuilder: _buildItem,
        onReorderItem: _handleReorder,
        onReorderStart: _handleReorderStart,
        onReorderEnd: _handleReorderEnd,
        proxyDecorator: paseoDraggableListProxyDecorator,
      ),
      if (widget.footer != null) SliverToBoxAdapter(child: widget.footer),
      if (widget.contentContainerFlexGrow && widget.scrollEnabled)
        const SliverFillRemaining(hasScrollBody: false),
    ];

    final scrollView = CustomScrollView(
      key: widget.listKey,
      shrinkWrap: !widget.scrollEnabled,
      physics: widget.scrollEnabled
          ? null
          : const NeverScrollableScrollPhysics(),
      slivers: <Widget>[
        if (widget.padding != null)
          SliverPadding(
            padding: widget.padding!,
            sliver: SliverMainAxisGroup(slivers: slivers),
          )
        else
          ...slivers,
      ],
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(
          context,
        ).copyWith(scrollbars: widget.showsVerticalScrollIndicator),
        child: scrollView,
      ),
    );
  }
}

/// A [ReorderableDragStartListener] whose hold duration is the frozen
/// `touchHoldDelayMs` instead of Flutter's 500 ms long-press default.
///
/// Exists because [ReorderableDelayedDragStartListener] hard-codes
/// `kLongPressTimeout`, which would make Paseo's handles feel almost three
/// times slower to grab than upstream.
class _PaseoDelayedDragStartListener extends ReorderableDragStartListener {
  const _PaseoDelayedDragStartListener({
    required super.child,
    required super.index,
    required this.delay,
  });

  final Duration delay;

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(delay: delay, debugOwner: this);
}

// ---------------------------------------------------------------------------
// material-file-icon.tsx
// ---------------------------------------------------------------------------

/// The file-type glyph shown next to a file name.
///
/// Upstream renders the raw SVG through `react-native-svg`'s `SvgXml`; the
/// Flutter equivalent is [SvgPicture.string]. No colour filter is applied — the
/// `material-icon-theme` payloads carry their own per-language fills, and
/// tinting them would erase the only thing that distinguishes a `.ts` from a
/// `.js`.
class MaterialFileIcon extends StatelessWidget {
  const MaterialFileIcon({
    super.key,
    required this.fileName,
    required this.size,
  });

  /// The file's *name*, not its path: the lookup only ever inspects the text
  /// after the final dot.
  final String fileName;

  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string(getFileIconSvg(fileName), width: size, height: size);
}

/// Binds [fileName] into a size-only builder.
///
/// Upstream this returns a `ComponentType<PanelIconProps>` so a panel
/// descriptor can declare its icon without knowing which file backs it. The
/// Dart shape is the same idea: the panel registry keeps a builder and supplies
/// only the size at paint time. `PanelIconProps.color` is intentionally absent
/// here for the same reason [MaterialFileIcon] applies no tint — upstream's
/// bound component ignores it too.
Widget Function(double size) createMaterialFileIcon(String fileName) =>
    (double size) => MaterialFileIcon(fileName: fileName, size: size);

// ---------------------------------------------------------------------------
// material-file-icons.ts
// ---------------------------------------------------------------------------

/// The SVG the file-type icon should paint for [fileName].
///
/// Falls back to `_default` for an unknown extension, for a name with no
/// extension, and for a name ending in a dot — the last case matters because
/// `getExtension` upstream rejects a trailing dot rather than returning `''`
/// and then missing the lookup, and the two paths must stay indistinguishable.
String getFileIconSvg(String fileName) {
  final extension = materialFileIconExtension(fileName);
  if (extension != null) {
    final iconName = materialFileIconNameByExtension[extension];
    if (iconName != null) {
      final svg = materialFileIconSvgs[iconName];
      if (svg != null) return svg;
    }
  }
  return materialFileIconSvgs[materialFileIconDefaultName]!;
}

/// Key of the fallback glyph in [materialFileIconSvgs].
const String materialFileIconDefaultName = '_default';

/// The lowercased text after the final dot of [name], or null when there is
/// none.
///
/// Deliberately *not* reusing `paseo_attachment_rules.dart`'s
/// `getFileExtension`: that one strips `?query` and `#fragment` because
/// attachment paths double as URLs, and it keeps the leading dot. This lookup
/// is fed bare file names from a directory listing, and upstream's
/// `lastIndexOf(".")` would treat a `?` as part of the extension. Matching the
/// frozen behaviour beats sharing a helper whose contract differs.
String? materialFileIconExtension(String name) {
  final index = name.lastIndexOf('.');
  if (index == -1 || index == name.length - 1) return null;
  return name.substring(index + 1).toLowerCase();
}

/// Number of glyphs in [materialFileIconSvgs], including `_default`.
///
/// A named constant so a drifting table fails a test rather than silently
/// dropping a language's icon.
const int materialFileIconSvgCount = 54;

/// Number of entries in [materialFileIconNameByExtension].
const int materialFileIconExtensionCount = 65;

/// The `SVG_ICONS` table, carried over entry-for-entry from the auto-generated
/// `material-file-icons.ts`.
///
/// Kept as inline strings rather than asset files so the glyph for a row is
/// available synchronously during layout — an async asset load would make file
/// lists pop in one icon at a time as the user scrolls. Every payload is
/// `material-icon-theme` output and is not hand-editable; regenerate upstream
/// instead.
const Map<String, String> materialFileIconSvgs = <String, String>{
  '_default':
      '<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><path d="m8.668 6h3.6641l-3.6641-3.668v3.668m-4.668-4.668h5.332l4 4v8c0 0.73828-0.59375 1.3359-1.332 1.3359h-8c-0.73828 0-1.332-0.59766-1.332-1.3359v-10.664c0-0.74219 0.59375-1.3359 1.332-1.3359m3.332 1.3359h-3.332v10.664h8v-6h-4.668z" fill="#90a4ae" /></svg>',
  'astro':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#7c4dff" d="M12.106 25.849c-1.262-1.156-1.63-3.586-1.105-5.346a5.18 5.18 0 0 0 3.484 1.66 9.68 9.68 0 0 0 5.882-.734c.215-.106.413-.247.648-.39a3.5 3.5 0 0 1 .16 1.555 4.26 4.26 0 0 1-1.798 3.021c-.404.3-.832.569-1.25.852a2.613 2.613 0 0 0-1.15 3.372l.048.161a3.4 3.4 0 0 1-1.5-1.285 3.6 3.6 0 0 1-.578-1.962 9 9 0 0 0-.05-1.037c-.114-.831-.504-1.204-1.238-1.225a1.45 1.45 0 0 0-1.507 1.18c-.012.056-.028.112-.046.178M4.901 20a17.75 17.75 0 0 1 7.4-2l2.913-8.38a.765.765 0 0 1 1.527 0L19.7 18a14.24 14.24 0 0 1 7.399 2S20.704 2.877 20.692 2.842C20.51 2.33 20.202 2 19.787 2h-7.619c-.415 0-.71.33-.904.842z"/></svg>',
  'c':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M19.563 22A5.57 5.57 0 0 1 14 16.437v-2.873A5.57 5.57 0 0 1 19.563 8H24V2h-4.437A11.563 11.563 0 0 0 8 13.563v2.873A11.564 11.564 0 0 0 19.563 28H24v-6Z"/></svg>',
  'clojure':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="#64dd17" d="M123.456 129.975a507 507 0 0 0-3.54 7.846c-4.406 9.981-9.284 22.127-11.066 29.908-.64 2.77-1.037 6.205-1.03 10.013 0 1.506.081 3.09.21 4.702a58.1 58.1 0 0 0 19.98 3.559 58.2 58.2 0 0 0 18.29-2.98c-1.352-1.237-2.642-2.554-3.816-4.038-7.796-9.942-12.146-24.512-19.028-49.01m-28.784-49.39C79.782 91.08 70.039 108.387 70.002 128c.037 19.32 9.487 36.403 24.002 46.94 3.56-14.83 12.485-28.41 25.868-55.63a219 219 0 0 0-2.714-7.083c-3.708-9.3-9.059-20.102-13.834-24.993-2.435-2.555-5.389-4.763-8.652-6.648"/><path fill="#7cb342" d="M178.532 194.535c-7.683-.963-14.023-2.124-19.57-4.081a69.4 69.4 0 0 1-30.958 7.249c-38.491 0-69.693-31.198-69.698-69.7 0-20.891 9.203-39.62 23.764-52.392-3.895-.94-7.956-1.49-12.104-1.482-20.45.193-42.037 11.51-51.025 42.075-.84 4.45-.64 7.813-.64 11.8 0 60.591 49.12 109.715 109.705 109.715 37.104 0 69.882-18.437 89.732-46.633-10.736 2.675-21.06 3.955-29.902 3.982-3.314 0-6.425-.177-9.305-.53"/><path fill="#29b6f6" d="M157.922 173.271c.678.336 2.213.884 4.35 1.49 14.375-10.553 23.717-27.552 23.754-46.764h-.005c-.055-32.03-25.974-57.945-58.011-58.009a58.2 58.2 0 0 0-18.213 2.961c11.779 13.426 17.443 32.613 22.922 53.6l.01.025c.01.017 1.752 5.828 4.743 13.538 2.97 7.7 7.203 17.231 11.818 24.178 3.03 4.655 6.363 8 8.632 8.981"/><path fill="#1e88e5" d="M128.009 18.29c-36.746 0-69.25 18.089-89.16 45.826 10.361-6.49 20.941-8.83 30.174-8.747 12.753.037 22.779 3.991 27.589 6.696a51 51 0 0 1 3.345 2.131 69.4 69.4 0 0 1 28.049-5.894c38.496.004 69.703 31.202 69.709 69.698h-.006c0 19.409-7.938 36.957-20.736 49.594 3.142.352 6.492.571 9.912.554 12.15.006 25.284-2.675 35.13-10.956 6.42-5.408 11.798-13.327 14.78-25.199.584-4.586.92-9.247.92-13.991 0-60.588-49.116-109.715-109.705-109.715"/></svg>',
  'console':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#ff7043" d="M2 2a1 1 0 0 0-1 1v10c0 .554.446 1 1 1h12c.554 0 1-.446 1-1V3a1 1 0 0 0-1-1zm0 3h12v8H2zm1 2 2 2-2 2 1 1 3-3-3-3zm5 3.5V12h5v-1.5z"/></svg>',
  'cpp':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M28 14v-4h-2v4h-6v-4h-2v4h-4v2h4v4h2v-4h6v4h2v-4h4v-2z"/><path fill="#0288d1" d="M13.563 22A5.57 5.57 0 0 1 8 16.437v-2.873A5.57 5.57 0 0 1 13.563 8H18V2h-4.437A11.563 11.563 0 0 0 2 13.563v2.873A11.564 11.564 0 0 0 13.563 28H18v-6Z"/></svg>',
  'csharp':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M30 14v-2h-2V8h-2v4h-2V8h-2v4h-2v2h2v2h-2v2h2v4h2v-4h2v4h2v-4h2v-2h-2v-2Zm-4 2h-2v-2h2Zm-12.437 6A5.57 5.57 0 0 1 8 16.437v-2.873A5.57 5.57 0 0 1 13.563 8H18V2h-4.437A11.563 11.563 0 0 0 2 13.563v2.873A11.564 11.564 0 0 0 13.563 28H18v-6Z"/></svg>',
  'css':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#7e57c2" d="M20 18h-2v-2h-2v2c0 .193 0 .703 1.254 1.033A3.345 3.345 0 0 1 20 22h2v2h2v-2c0-.388-.562-.851-1.254-1.034C20.356 20.34 20 18.84 20 18m-3.254 2.966C14.356 20.34 14 18.84 14 18h-2v-2h-2v8h2v-2h4v2h2v-2c0-.388-.562-.851-1.254-1.034"/><path fill="#7e57c2" d="M24 4H4v20a4 4 0 0 0 4 4h16.16A3.84 3.84 0 0 0 28 24.16V8a4 4 0 0 0-4-4m2 14h-2v-2h-2v2c0 .193 0 .703 1.254 1.033A3.345 3.345 0 0 1 26 22v2a2 2 0 0 1-2 2h-2a2 2 0 0 1-2-2 2 2 0 0 1-2 2h-2a2 2 0 0 1-2-2 2 2 0 0 1-2 2h-2a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2 2 2 0 0 1 2-2h2a2 2 0 0 1 2 2 2 2 0 0 1 2-2h2a2 2 0 0 1 2 2Z"/></svg>',
  'dart':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#4fc3f7" d="M16.83 2a1.3 1.3 0 0 0-.916.377l-.013.01L7.323 7.34l8.556 8.55v.005l10.283 10.277 1.96-3.529-7.068-16.96-3.299-3.297A1.3 1.3 0 0 0 16.828 2Z"/><path fill="#01579b" d="m7.343 7.32-4.955 8.565-.01.013a1.297 1.297 0 0 0 .004 1.835l.005.005 4.106 4.107 16.064 6.314 3.632-2.015-.098-.098-.025.002L15.995 15.97h-.012z"/><path fill="#01579b" d="m7.321 7.324 8.753 8.755h.013L26.16 26.156l3.835-.73L30 14.089l-4.049-3.965a6.5 6.5 0 0 0-3.618-1.612l.002-.043L7.323 7.325Z"/><path fill="#64b5f6" d="m7.332 7.335 8.758 8.75v.013l10.079 10.071L25.436 30H14.09l-3.967-4.048a6.5 6.5 0 0 1-1.611-3.618l-.045.004Z"/></svg>',
  'database':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ffca28" d="M16 24c-5.525 0-10-.9-10-2v4c0 1.1 4.475 2 10 2s10-.9 10-2v-4c0 1.1-4.475 2-10 2m0-8c-5.525 0-10-.9-10-2v4c0 1.1 4.475 2 10 2s10-.9 10-2v-4c0 1.1-4.475 2-10 2m0-12C10.477 4 6 4.895 6 6v4c0 1.1 4.475 2 10 2s10-.9 10-2V6c0-1.105-4.477-2-10-2"/></svg>',
  'document':
      '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/><path fill="#42a5f5" d="M8 16h8v2H8zm0-4h8v2H8zm6-10H6c-1.1 0-2 .9-2 2v16c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8zm4 18H6V4h7v5h5z"/></svg>',
  'elixir':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#9575cd" d="M12.173 22.681c-3.86 0-6.99-3.64-6.99-8.13 0-3.678 2.773-8.172 4.916-10.91 1.014-1.296 2.93-2.322 2.93-2.322s-.982 5.239 1.683 7.319c2.366 1.847 4.106 4.25 4.106 6.363 0 4.232-2.784 7.68-6.645 7.68"/></svg>',
  'erlang':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 30"><path fill="#f44336" d="M5.207 4.33q-.072.075-.143.153Q1.5 8.476 1.5 15.33c0 4.418 1.155 7.862 3.459 10.34h19.415c2.553-1.152 4.127-3.43 4.127-3.43l-3.147-2.52L23.9 21.1c-.867.773-.845.931-2.315 1.78-1.495.674-3.04.966-4.634.966-2.515 0-4.423-.909-5.723-2.059-1.286-1.15-1.985-4.511-2.096-6.68l17.458.067-.183-1.472s-.847-7.129-2.541-9.372zm8.76.846c1.565 0 3.22.535 3.961 1.471.74.937.931 1.667.973 3.524H9.11c.112-1.955.436-2.81 1.373-3.698.936-.887 2.03-1.297 3.484-1.297"/></svg>',
  'go':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#00acc1" d="M2 12h4v2H2zm-2 4h6v2H0zm4 4h2v2H4zm16.954-5H14v3h3.239a4.42 4.42 0 0 1-3.531 2 2.65 2.65 0 0 1-2.053-.858 2.86 2.86 0 0 1-.628-2.28A4.515 4.515 0 0 1 15.292 13a2.73 2.73 0 0 1 1.749.584l2.962-1.185A5.6 5.6 0 0 0 15.292 10a7.526 7.526 0 0 0-7.243 6.5 5.614 5.614 0 0 0 5.659 6.5 7.526 7.526 0 0 0 7.243-6.5 6.4 6.4 0 0 0 .003-1.5"/><path fill="#00acc1" d="M26.292 10a7.526 7.526 0 0 0-7.243 6.5 5.614 5.614 0 0 0 5.659 6.5 7.526 7.526 0 0 0 7.243-6.5 5.614 5.614 0 0 0-5.659-6.5m2.681 6.137A4.515 4.515 0 0 1 24.708 20a2.65 2.65 0 0 1-2.053-.858 2.86 2.86 0 0 1-.628-2.28A4.515 4.515 0 0 1 26.292 13a2.65 2.65 0 0 1 2.053.858 2.86 2.86 0 0 1 .628 2.28Z"/></svg>',
  'gradle':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0097a7" d="M16 10v2h6c-2 0-3-2-6-2"/><path fill="#0097a7" d="M26 4h-2a4 4 0 0 0-4 4h4a1 1 0 0 1 2 0v4H16v-2h-5.317A2.683 2.683 0 0 0 8 12.683v2.634A2.683 2.683 0 0 0 10.683 18H16v2h-5.98A4.02 4.02 0 0 1 6 16v-2c-2 0-4 4-4 8 0 5 1 6 2 6h4v-4h4v4h4v-4h4v4h4v-6a2 2 0 0 0 2-2v-2a4 4 0 0 0 4-4V8a4 4 0 0 0-4-4m-4 12h-2a2 2 0 0 1-2-2h6a2 2 0 0 1-2 2"/></svg>',
  'graphql':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ec407a" d="M6 20h20v2H6z"/><circle cx="7" cy="21" r="3" fill="#ec407a"/><circle cx="16" cy="27" r="3" fill="#ec407a"/><circle cx="25" cy="21" r="3" fill="#ec407a"/><path fill="#ec407a" d="M6 10h20v2H6z"/><circle cx="7" cy="11" r="3" fill="#ec407a"/><circle cx="16" cy="5" r="3" fill="#ec407a"/><circle cx="25" cy="11" r="3" fill="#ec407a"/><path fill="#ec407a" d="M6 12h2v10H6zm18-2h2v12h-2z"/><path fill="#ec407a" d="m5.014 19.41 11.674 6.866L15.674 28 4 21.134z"/><path fill="#ec407a" d="M26.688 21.724 15.014 28.59 14 26.866 25.674 20zM5.124 10.382l11.415-7.29 1.077 1.686L6.2 12.068z"/><path fill="#ec407a" d="m25.798 12.067-11.415-7.29 1.077-1.685 11.415 7.29zM6.2 19.932l11.416 7.29-1.077 1.686-11.415-7.29z"/><path fill="#ec407a" d="m26.875 21.619-11.415 7.29-1.077-1.687 11.415-7.289zM5.877 22.6 16.04 3.686l1.762.946L7.638 23.546z"/><path fill="#ec407a" d="M24.361 23.545 14.197 4.633l1.761-.947 10.165 18.913z"/></svg>',
  'groovy':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#26c6da" d="M19.322 2a6.5 6.5 0 0 1 4.352 1.419 4.55 4.55 0 0 1 1.685 3.662 5.82 5.82 0 0 1-1.886 4.275 6.04 6.04 0 0 1-4.34 1.846 4.15 4.15 0 0 1-2.385-.649 1.91 1.91 0 0 1-.936-1.603 1.6 1.6 0 0 1 .356-1.024 1.1 1.1 0 0 1 .861-.447q.469 0 .468.504a.79.79 0 0 0 .358.693 1.43 1.43 0 0 0 .826.245 3.1 3.1 0 0 0 2.39-1.573 5.66 5.66 0 0 0 1.154-3.39 2.64 2.64 0 0 0-.891-2.064 3.28 3.28 0 0 0-2.293-.812 6.18 6.18 0 0 0-4.086 1.736 12.9 12.9 0 0 0-3.215 4.557 13.4 13.4 0 0 0-1.233 5.36 5.86 5.86 0 0 0 1.091 3.723 3.53 3.53 0 0 0 2.905 1.372q3.058 0 5.848-4.002l2.935-.388q.546-.07.545.246a8 8 0 0 1-.423 1.24q-.421 1.097-1.152 3.668A12.7 12.7 0 0 0 26 17.72v1.66a14.2 14.2 0 0 1-4.055 2.57 10.38 10.38 0 0 1-2.764 5.931 6.7 6.7 0 0 1-4.806 2.11 3.3 3.3 0 0 1-2.012-.55 1.8 1.8 0 0 1-.718-1.514q0-2.685 5.634-5.212.532-1.766 1.152-3.507a8.6 8.6 0 0 1-2.853 2.323 7.4 7.4 0 0 1-3.48 1.01 5.46 5.46 0 0 1-4.366-2.093A8.1 8.1 0 0 1 6 15.122a11.6 11.6 0 0 1 1.966-6.426 14.7 14.7 0 0 1 5.162-4.862A12.44 12.44 0 0 1 19.322 2m-2.407 22.17q-4.055 1.875-4.054 3.695a.87.87 0 0 0 .999.97q1.964 0 3.055-4.665"/></svg>',
  'h':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M18.5 11a5.49 5.49 0 0 0-4.5 2.344V4H8v24h6V17a2 2 0 0 1 4 0v11h6V16.5a5.5 5.5 0 0 0-5.5-5.5"/></svg>',
  'haskell':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300"><g stroke-width="2.422"><path fill="#ef5350" d="m23.928 240.5 59.94-89.852-59.94-89.855h44.955l59.94 89.855-59.94 89.852z"/><path fill="#ffa726" d="m83.869 240.5 59.94-89.852-59.94-89.855h44.955l119.88 179.71h-44.95l-37.46-56.156-37.468 56.156z"/><path fill="#ffee58" d="m228.72 188.08-19.98-29.953h69.93v29.956h-49.95zm-29.97-44.924-19.98-29.953h99.901v29.953z"/></g></svg>',
  'hcl':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#eceff1" d="M18 1.2V14h-4v-4l-4 2v16.37l4 2.43V18h4v4l4-2V3.63z"/><path fill="#eceff1" d="M14 1.2 2 8.49v15.02l4 2.43v-15.2l8-4.86zm12 4.86v15.2l-8 4.86v4.68l12-7.29V8.49z"/></svg>',
  'hpp':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M28 6V2h-2v4h-6V2h-2v4h-4v2h4v4h2V8h6v4h2V8h4V6zm-15.5 5A5.49 5.49 0 0 0 8 13.344V4H2v24h6V17a2 2 0 0 1 4 0v11h6V16.5a5.5 5.5 0 0 0-5.5-5.5"/></svg>',
  'html':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#e65100" d="m4 4 2 22 10 2 10-2 2-22Zm19.72 7H11.28l.29 3h11.86l-.802 9.335L15.99 25l-6.635-1.646L8.93 19h3.02l.19 2 3.86.77 3.84-.77.29-4H8.84L8 8h16Z"/></svg>',
  'image':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#26a69a" d="M8.5 6h4l-4-4zM3.875 1H9.5l4 4v8.6c0 .773-.616 1.4-1.375 1.4h-8.25c-.76 0-1.375-.627-1.375-1.4V2.4c0-.777.612-1.4 1.375-1.4M4 13.6h8V8l-2.625 2.8L8 9.4zm1.25-7.7c-.76 0-1.375.627-1.375 1.4s.616 1.4 1.375 1.4c.76 0 1.375-.627 1.375-1.4S6.009 5.9 5.25 5.9"/></svg>',
  'java':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#f44336" d="M4 26h24v2H4zM28 4H7a1 1 0 0 0-1 1v13a4 4 0 0 0 4 4h10a4 4 0 0 0 4-4v-4h4a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2m0 8h-4V6h4Z"/></svg>',
  'javascript':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#ffca28" d="M2 2v12h12V2zm6 6h1v4a1.003 1.003 0 0 1-1 1H7a1.003 1.003 0 0 1-1-1v-1h1v1h1zm3 0h2v1h-2v1h1a1.003 1.003 0 0 1 1 1v1a1.003 1.003 0 0 1-1 1h-2v-1h2v-1h-1a1.003 1.003 0 0 1-1-1V9a1.003 1.003 0 0 1 1-1"/></svg>',
  'json':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path fill="#f9a825" d="M560-160v-80h120q17 0 28.5-11.5T720-280v-80q0-38 22-69t58-44v-14q-36-13-58-44t-22-69v-80q0-17-11.5-28.5T680-720H560v-80h120q50 0 85 35t35 85v80q0 17 11.5 28.5T840-560h40v160h-40q-17 0-28.5 11.5T800-360v80q0 50-35 85t-85 35zm-280 0q-50 0-85-35t-35-85v-80q0-17-11.5-28.5T120-400H80v-160h40q17 0 28.5-11.5T160-600v-80q0-50 35-85t85-35h120v80H280q-17 0-28.5 11.5T240-680v80q0 38-22 69t-58 44v14q36 13 58 44t22 69v80q0 17 11.5 28.5T280-240h120v80z"/></svg>',
  'kotlin':
      '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 24 24"><defs><linearGradient id="a" x1="1.725" x2="22.185" y1="22.67" y2="1.982" gradientTransform="translate(1.306 1.129)scale(.89324)" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#7c4dff"/><stop offset=".5" stop-color="#d500f9"/><stop offset="1" stop-color="#ef5350"/></linearGradient></defs><path fill="url(#a)" d="M2.975 2.976v18.048h18.05v-.03l-4.478-4.511-4.48-4.515 4.48-4.515 4.443-4.477z"/></svg>',
  'less':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#0277bd" d="M8 3a2 2 0 0 0-2 2v4a2 2 0 0 1-2 2H3v2h1a2 2 0 0 1 2 2v4a2 2 0 0 0 2 2h2v-2H8v-5a2 2 0 0 0-2-2 2 2 0 0 0 2-2V5h2V3m6 0a2 2 0 0 1 2 2v4a2 2 0 0 0 2 2h1v2h-1a2 2 0 0 0-2 2v4a2 2 0 0 1-2 2h-2v-2h2v-5a2 2 0 0 1 2-2 2 2 0 0 1-2-2V5h-2V3z"/></svg>',
  'lock':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ffd54f" d="M25 12h-3V8a6 6 0 0 0-12 0v4H7a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h18a1 1 0 0 0 1-1V13a1 1 0 0 0-1-1M14 8a2 2 0 0 1 4 0v4h-4Zm2 17a4 4 0 1 1 4-4 4 4 0 0 1-4 4"/></svg>',
  'lua':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#42a5f5" d="M30 6a3.86 3.86 0 0 1-1.167 2.833 4.024 4.024 0 0 1-5.666 0A3.86 3.86 0 0 1 22 6a3.86 3.86 0 0 1 1.167-2.833 4.024 4.024 0 0 1 5.666 0A3.86 3.86 0 0 1 30 6m-9.208 5.208A10.6 10.6 0 0 0 13 8a10.6 10.6 0 0 0-7.792 3.208A10.6 10.6 0 0 0 2 19a10.6 10.6 0 0 0 3.208 7.792A10.6 10.6 0 0 0 13 30a10.6 10.6 0 0 0 7.792-3.208A10.6 10.6 0 0 0 24 19a10.6 10.6 0 0 0-3.208-7.792m-1.959 7.625a4.024 4.024 0 0 1-5.666 0 4.024 4.024 0 0 1 0-5.666 4.024 4.024 0 0 1 5.666 0 4.024 4.024 0 0 1 0 5.666"/></svg>',
  'markdown':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#42a5f5" d="m14 10-4 3.5L6 10H4v12h4v-6l2 2 2-2v6h4V10zm12 6v-6h-4v6h-4l6 8 6-8z"/></svg>',
  'nix':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500"><g stroke-width=".395"><path fill="#1976d2" d="M133.347 451.499c0-.295-2.752-5.283-6.116-11.084s-6.116-10.776-6.116-11.055 9.514-16.889 21.143-36.912c11.629-20.022 21.323-36.798 21.542-37.279.346-.76-1.608-4.363-14.896-27.466-8.412-14.625-15.294-26.785-15.294-27.023 0-.5 24.46-43.501 25.206-44.31.414-.45.592-.384 1.078.395.32.513 16.876 29.256 36.791 63.87 62.62 108.85 74.852 130.01 75.41 130.46.3.242.544.554.544.694s-11.836.21-26.302.154c-23.023-.09-26.313-.175-26.393-.694-.11-.714-27.662-48.825-28.86-50.392-.746-.978-.906-1.035-1.426-.51-.688.696-28.954 49.323-29.49 50.733l-.364.96h-13.23c-10.895 0-13.228-.095-13.228-.538zm167.58-125.61c-.134-.216 1.189-2.863 2.939-5.882 6.924-11.944 84.29-145.75 96.49-166.88 7.143-12.371 13.143-22.465 13.334-22.433.362.062 25.86 43.105 25.86 43.655 0 .174-6.761 11.952-15.025 26.173-8.46 14.557-14.932 26.104-14.81 26.421.185.483 4.563.564 30.213.564h29.996l.957 1.48c.527.814 3.296 5.547 6.155 10.518s5.45 9.29 5.757 9.597c.705.705.703.724-.16 1.572-.396.388-3.36 5.323-6.588 10.965-3.228 5.643-6.056 10.387-6.285 10.543s-19.695.171-43.256.034l-42.84-.249-.803 1.15c-.442.632-7.505 12.736-15.696 26.897l-14.892 25.747h-15.486c-8.518 0-20.015.116-25.551.259-6.55.168-10.15.121-10.308-.135zm-133.75-157.86c-56.373-.055-102.5-.182-102.5-.282s5.617-10.132 12.481-22.294L89.64 123.34h30.332c27.113 0 30.332-.065 30.332-.611 0-.336-6.659-12.228-14.797-26.427s-14.797-25.917-14.797-26.04 2.682-4.853 5.96-10.51 6.003-10.578 6.056-10.934c.086-.586 1.375-.648 13.572-.648 7.412 0 13.463.143 13.446.317-.018.174.22.707.53 1.184.31.476 9.763 16.937 21.007 36.578 11.244 19.64 20.71 36.022 21.036 36.4.554.647 2.549.691 31.428.691h30.837l12.896 22.145c7.093 12.18 12.8 22.301 12.682 22.492-.117.19-4.776.303-10.352.249-5.575-.054-56.26-.143-112.63-.198z"/><path fill="#64b5f6" d="M23.046 238.939c-6.098 10.563-6.69 11.711-6.224 12.078.282.224 3.18 5.044 6.44 10.712s6.016 10.355 6.123 10.417c.106.061 13.585.153 29.95.204 16.367.052 29.994.23 30.285.399.473.273-1.08 3.094-14.637 26.574l-15.166 26.269 12.907 21.865c7.1 12.026 12.982 21.906 13.068 21.956s23.257-39.831 51.492-88.624c11.352-19.617 21.214-36.64 30.37-52.442 23.308-40.452 30.68-53.468 30.73-54.132-1.096-.11-6.141-.187-13.006-.216-3.945-.01-7.82-.02-12.75-.002l-25.341.092-15.42 26.706c-14.256 24.693-15.445 26.663-16.278 26.86l-.023.037c-.012.003-1.622-.001-1.826 0-4.29.062-20.453.063-40.226-.01-22.632-.082-41.615-.125-42.183-.096-.567.03-1.147-.03-1.29-.132-.141-.102-3.29 5.066-6.996 11.485zm205.16-190.3c-.123.149 5.62 10.392 12.761 22.763 12.2 21.131 89.393 155.03 96.276 167 1.503 2.613 2.92 4.803 3.443 5.348.9-1.249 3.532-5.63 7.954-13.219a1343 1343 0 0 1 10.05-17.76l6.606-11.443c.691-1.403.753-1.818.652-2.117-.161-.48-6.903-12.332-14.982-26.337-8.078-14.005-14.824-25.849-14.99-26.32a.73.73 0 0 1-.01-.366l-.426-.913 21.636-36.976c3.69-6.307 6.425-11.042 9.471-16.29 9.158-15.948 12.036-21.189 11.895-21.55-.126-.324-2.7-4.83-5.72-10.017-3.021-5.185-5.845-10.148-6.275-11.026-.483-.987-.734-1.364-1.1-1.456-.054.014-.083.018-.144.035-.42.112-5.455.195-11.19.185s-11.22.024-12.187.073l-1.76.089-14.998 25.978c-12.824 22.212-15.084 25.964-15.595 25.883-.024-.004-.15-.189-.235-.301-.109.066-.2.09-.271.05-.256-.148-7.144-11.902-15.306-26.119L279.4 48.817c-.116-.186-.444-.744-.458-.752-.476-.275-50.502.287-50.737.57zm-18.646 283.09c-.047.109-.026.262.043.48.328 1.05 25.338 43.735 25.772 43.985.206.119 14.178.239 31.05.266 26.65.044 30.749.152 31.234.832.307.43 9.987 17.214 21.513 37.296s21.152 36.627 21.394 36.767 5.926.243 12.633.23c6.705-.013 12.4.099 12.657.246.131.076.381-.141.851-.795l6.008-10.406c5.234-9.065 6.62-11.684 6.294-11.888-.575-.36-15.597-26.643-23.859-41.482-3.09-5.45-5.37-9.516-5.44-9.774-.196-.712-.066-.822 1.155-.98 1.956-.252 57.397-.057 58.071.205.237.092.79-.569 2.593-3.497 1.866-3.067 5.03-8.524 11.001-18.866 7.22-12.505 13.043-22.784 12.941-22.843s-.77-.051-1.489.016l-.046.001c-4.451.204-33.918.203-149.74.025-38.96-.06-69.786-.09-71.912-.072-1.12.01-2.095.076-2.66.172a.3.3 0 0 0-.062.083z"/></g></svg>',
  'ocaml':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="m12.019 15.021.003-.008c-.005-.021-.006-.026-.003.008"/><path fill="#ff9800" d="M4.51 3.273a2.523 2.523 0 0 0-2.524 2.523V11.3c.361-.13.88-.898 1.043-1.085.285-.327.337-.743.478-1.006C3.83 8.612 3.886 8.2 4.62 8.2c.342 0 .478.08.71.39.16.216.438.615.568.882.15.307.396.724.503.808q.122.095.233.137c.119.044.218-.037.297-.1.102-.082.145-.247.24-.467.135-.317.283-.697.367-.83.146-.23.195-.501.352-.633.232-.195.535-.208.618-.225.466-.092.677.225.907.43.15.133.355.403.5.765.114.283.26.544.32.707.059.158.203.41.289.713.077.275.286.486.365.616 0 0 .121.34.858.65.16.067.482.176.674.246.32.116.63.101 1.025.054.281 0 .434-.408.562-.734.075-.193.148-.745.197-.902.048-.153-.064-.27.031-.405.112-.156.178-.164.242-.368.138-.436.936-.458 1.384-.458.374 0 .327.363.96.239.364-.072.714.046 1.1.149.324.086.63.184.812.398.119.139.412.834.113.863.029.035.05.099.104.134-.067.262-.357.075-.518.041-.217-.045-.37.007-.583.101-.363.162-.894.143-1.21.407-.27.223-.269.721-.394 1 0 0-.348.895-1.106 1.443-.194.14-.574.477-1.4.605a5.3 5.3 0 0 1-1.1.043c-.186-.009-.362-.018-.549-.02-.11-.002-.48-.013-.461.022l-.041.103.024.138c.015.083.019.149.022.225.006.157-.013.32-.005.478.017.328.138.627.154.958.017.368.199.758.375 1.059.067.114.169.128.213.269.052.161.003.333.028.505.1.668.292 1.366.592 1.97l.008.014c.371-.062.743-.196 1.226-.267.885-.132 2.115-.064 2.906-.138 2-.188 3.085.82 4.882.407V5.796a2.523 2.523 0 0 0-2.523-2.523zm-.907 11.144q-.022 0-.046.003c-.159.025-.313.08-.412.24-.08.13-.108.355-.164.505-.064.175-.176.338-.274.505-.18.305-.504.581-.644.879-.028.06-.053.13-.076.2v3.402c.163.028.333.062.524.113 1.407.375 1.75.407 3.13.25l.13-.018c.105-.22.187-.968.255-1.2.054-.178.127-.32.155-.5.026-.173-.003-.337-.017-.493-.04-.393.285-.533.44-.87.14-.304.22-.651.336-.963.11-.298.284-.721.579-.872-.036-.041-.617-.06-.772-.076a5 5 0 0 1-.5-.07c-.314-.064-.656-.126-.965-.2a10 10 0 0 1-.947-.328c-.298-.138-.503-.497-.732-.507m5.737.83c-.74.149-.97.876-1.32 1.451-.192.319-.396.59-.548.928-.14.312-.128.657-.368.924a2.55 2.55 0 0 0-.528.922c-.023.067-.088.776-.158.943l1.101-.078c1.026.07.73.464 2.332.378l2.529-.078a7 7 0 0 0-.228-.588c-.07-.147-.16-.434-.218-.56a3.5 3.5 0 0 0-.309-.526c-.184-.215-.227-.23-.28-.503-.095-.473-.344-1.33-.637-1.923-.151-.306-.403-.562-.634-.784-.2-.195-.655-.522-.734-.505z"/></svg>',
  'php':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#1e88e5" d="M12 18.08c-6.63 0-12-2.72-12-6.08s5.37-6.08 12-6.08S24 8.64 24 12s-5.37 6.08-12 6.08m-5.19-7.95c.54 0 .91.1 1.09.31.18.2.22.56.13 1.03-.1.53-.29.87-.58 1.09q-.42.33-1.29.33h-.87l.53-2.76zm-3.5 5.55h1.44l.34-1.75h1.23c.54 0 .98-.06 1.33-.17.35-.12.67-.31.96-.58.24-.22.43-.46.58-.73.15-.26.26-.56.31-.88.16-.78.05-1.39-.33-1.82-.39-.44-.99-.65-1.82-.65H4.59zm7.25-8.33-1.28 6.58h1.42l.74-3.77h1.14c.36 0 .6.06.71.18s.13.34.07.66l-.57 2.93h1.45l.59-3.07c.13-.62.03-1.07-.27-1.36-.3-.27-.85-.4-1.65-.4h-1.27L12 7.35zM18 10.13c.55 0 .91.1 1.09.31.18.2.22.56.13 1.03-.1.53-.29.87-.57 1.09-.29.22-.72.33-1.3.33h-.85l.5-2.76zm-3.5 5.55h1.44l.34-1.75h1.22c.55 0 1-.06 1.35-.17.35-.12.65-.31.95-.58.24-.22.44-.46.58-.73.15-.26.26-.56.32-.88.15-.78.04-1.39-.34-1.82-.36-.44-.99-.65-1.82-.65h-2.75z"/></svg>',
  'python':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#0288d1" d="M9.86 2A2.86 2.86 0 0 0 7 4.86v1.68h4.29c.39 0 .71.57.71.96H4.86A2.86 2.86 0 0 0 2 10.36v3.781a2.86 2.86 0 0 0 2.86 2.86h1.18v-2.68a2.85 2.85 0 0 1 2.85-2.86h5.25c1.58 0 2.86-1.271 2.86-2.851V4.86A2.86 2.86 0 0 0 14.14 2zm-.72 1.61c.4 0 .72.12.72.71s-.32.891-.72.891c-.39 0-.71-.3-.71-.89s.32-.711.71-.711"/><path fill="#fdd835" d="M17.959 7v2.68a2.85 2.85 0 0 1-2.85 2.859H9.86A2.85 2.85 0 0 0 7 15.389v3.75a2.86 2.86 0 0 0 2.86 2.86h4.28A2.86 2.86 0 0 0 17 19.14v-1.68h-4.291c-.39 0-.709-.57-.709-.96h7.14A2.86 2.86 0 0 0 22 13.64V9.86A2.86 2.86 0 0 0 19.14 7zM8.32 11.513l-.004.004.038-.004zm6.54 7.276c.39 0 .71.3.71.89a.71.71 0 0 1-.71.71c-.4 0-.72-.12-.72-.71s.32-.89.72-.89"/></svg>',
  'r':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#1976d2" d="M11.956 4.05c-5.694 0-10.354 3.106-10.354 6.947 0 3.396 3.686 6.212 8.531 6.813v2.205h3.53V17.82c.88-.093 1.699-.259 2.475-.497l1.43 2.692h3.996l-2.402-4.048c1.936-1.263 3.147-3.034 3.147-4.97 0-3.841-4.659-6.947-10.354-6.947m1.584 2.712c4.349 0 7.558 1.45 7.558 4.753 0 1.77-.952 3.013-2.505 3.779a1 1 0 0 1-.228-.156c-.373-.165-.994-.352-.994-.352s3.085-.227 3.085-3.302-3.23-3.127-3.23-3.127h-7.092v7.413c-2.64-.766-4.462-2.392-4.462-4.255 0-2.63 3.52-4.753 7.868-4.753m.156 4.12h2.143s.983-.05.983.974c0 1.004-.983 1.004-.983 1.004h-2.143v-1.977m-.031 4.566h.952c.186 0 .28.052.445.207.135.103.28.3.404.476-.57.073-1.17.104-1.801.104z"/></svg>',
  'react':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#00bcd4" d="M16 12c7.444 0 12 2.59 12 4s-4.556 4-12 4-12-2.59-12-4 4.556-4 12-4m0-2c-7.732 0-14 2.686-14 6s6.268 6 14 6 14-2.686 14-6-6.268-6-14-6"/><path fill="#00bcd4" d="M16 14a2 2 0 1 0 2 2 2 2 0 0 0-2-2"/><path fill="#00bcd4" d="M10.458 5.507c2.017 0 5.937 3.177 9.006 8.493 3.722 6.447 3.757 11.687 2.536 12.392a.9.9 0 0 1-.457.1c-2.017 0-5.938-3.176-9.007-8.492C8.814 11.553 8.779 6.313 10 5.608a.9.9 0 0 1 .458-.1m-.001-2A2.87 2.87 0 0 0 9 3.875C6.13 5.532 6.938 12.304 10.804 19c3.284 5.69 7.72 9.493 10.74 9.493A2.87 2.87 0 0 0 23 28.124c2.87-1.656 2.062-8.428-1.804-15.124-3.284-5.69-7.72-9.493-10.74-9.493Z"/><path fill="#00bcd4" d="M21.543 5.507a.9.9 0 0 1 .457.1c1.221.706 1.186 5.946-2.536 12.393-3.07 5.316-6.99 8.493-9.007 8.493a.9.9 0 0 1-.457-.1C8.779 25.686 8.814 20.446 12.536 14c3.07-5.316 6.99-8.493 9.007-8.493m0-2c-3.02 0-7.455 3.804-10.74 9.493C6.939 19.696 6.13 26.468 9 28.124a2.87 2.87 0 0 0 1.457.369c3.02 0 7.455-3.804 10.74-9.493C25.061 12.304 25.87 5.532 23 3.876a2.87 2.87 0 0 0-1.457-.369"/></svg>',
  'react_ts':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#0288d1" d="M16 12c7.444 0 12 2.59 12 4s-4.556 4-12 4-12-2.59-12-4 4.556-4 12-4m0-2c-7.732 0-14 2.686-14 6s6.268 6 14 6 14-2.686 14-6-6.268-6-14-6"/><path fill="#0288d1" d="M16 14a2 2 0 1 0 2 2 2 2 0 0 0-2-2"/><path fill="#0288d1" d="M10.458 5.507c2.017 0 5.937 3.177 9.006 8.493 3.722 6.447 3.757 11.687 2.536 12.392a.9.9 0 0 1-.457.1c-2.017 0-5.938-3.176-9.007-8.492C8.814 11.553 8.779 6.313 10 5.608a.9.9 0 0 1 .458-.1m-.001-2A2.87 2.87 0 0 0 9 3.875C6.13 5.532 6.938 12.304 10.804 19c3.284 5.69 7.72 9.493 10.74 9.493A2.87 2.87 0 0 0 23 28.124c2.87-1.656 2.062-8.428-1.804-15.124-3.284-5.69-7.72-9.493-10.74-9.493Z"/><path fill="#0288d1" d="M21.543 5.507a.9.9 0 0 1 .457.1c1.221.706 1.186 5.946-2.536 12.393-3.07 5.316-6.99 8.493-9.007 8.493a.9.9 0 0 1-.457-.1C8.779 25.686 8.814 20.446 12.536 14c3.07-5.316 6.99-8.493 9.007-8.493m0-2c-3.02 0-7.455 3.804-10.74 9.493C6.939 19.696 6.13 26.468 9 28.124a2.87 2.87 0 0 0 1.457.369c3.02 0 7.455-3.804 10.74-9.493C25.061 12.304 25.87 5.532 23 3.876a2.87 2.87 0 0 0-1.457-.369"/></svg>',
  'ruby':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#f44336" d="M18.041 3.177c2.24.382 2.879 1.919 2.843 3.527V6.67l-1.013 13.266-13.132.897h.008c-1.093-.044-3.518-.151-3.634-3.545l1.217-2.222 2.462 5.74 2.097-6.77-.045.009.018-.018 6.85 2.186L13.945 9.3l6.53-.409-5.144-4.212 2.71-1.51v.009M3.113 17.252v.017zM6.916 6.874c2.63-2.622 6.033-4.168 7.34-2.844 1.297 1.306-.072 4.523-2.702 7.135-2.666 2.613-6.015 4.248-7.322 2.933-1.306-1.324.036-4.612 2.675-7.224z"/></svg>',
  'rust':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ff7043" d="m30 12-4-2V6h-4l-2-4-4 2-4-2-2 4H6v4l-4 2 2 4-2 4 4 2v4h4l2 4 4-2 4 2 2-4h4v-4l4-2-2-4ZM6 16a9.9 9.9 0 0 1 .842-4H10v8H6.842A9.9 9.9 0 0 1 6 16m10 10a9.98 9.98 0 0 1-7.978-4H16v-2h-2v-2h4c.819.819.297 2.308 1.179 3.37a1.89 1.89 0 0 0 1.46.63h3.34A9.98 9.98 0 0 1 16 26m-2-12v-2h4a1 1 0 0 1 0 2Zm11.158 6H24a2.006 2.006 0 0 1-2-2 2 2 0 0 0-2-2 3 3 0 0 0 3-3q0-.08-.004-.161A3.115 3.115 0 0 0 19.83 10H8.022a9.986 9.986 0 0 1 17.136 10"/></svg>',
  'sass':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ec407a" d="M27.837 5.673a4.33 4.33 0 0 0-2.293-2.701c-2.362-1.261-6.11-1.298-9.548-.092a26.3 26.3 0 0 0-8.76 4.966c-2.752 2.542-3.438 4.925-3.189 6.194.523 2.668 3.274 4.539 5.485 6.042.418.284.822.559 1.175.816-1.429.76-4.261 2.444-5.088 4.248a3.88 3.88 0 0 0-.118 3.332A2.37 2.37 0 0 0 6.869 29.8a5.6 5.6 0 0 0 1.49.2 6.35 6.35 0 0 0 5.19-2.856 6.74 6.74 0 0 0 .864-5.382 7.3 7.3 0 0 1 2.044-.03 3.92 3.92 0 0 1 2.816 1.311 1.82 1.82 0 0 1 .423 1.262 1.55 1.55 0 0 1-.772 1.05c-.234.14-.586.355-.504.803.036.194.198.633.894.512a2.93 2.93 0 0 0 2.145-2.651 4 4 0 0 0-1.197-2.904 5.94 5.94 0 0 0-4.396-1.626 10.6 10.6 0 0 0-2.672.304 20 20 0 0 0-2.203-1.846c-1.712-1.3-3.33-2.529-3.235-4.26.125-2.263 2.468-4.532 6.964-6.744 4.016-1.976 7.254-2.037 8.944-1.438a2 2 0 0 1 1.204.883 2.77 2.77 0 0 1-.36 2.47 9.71 9.71 0 0 1-7.425 4.304 3.86 3.86 0 0 1-3.238-.757c-.278-.302-.593-.645-1.074-.383q-.565.31-.225 1.189a3.9 3.9 0 0 0 2.407 1.92 11.7 11.7 0 0 0 7.128-.671c3.527-1.35 6.681-5.202 5.756-8.787M11.895 24.475a4 4 0 0 1-.192.468 4.5 4.5 0 0 1-.753 1.081 2.83 2.83 0 0 1-2.533 1.107c-.056-.032-.078-.146-.085-.193a3.28 3.28 0 0 1 1.076-2.284 11.3 11.3 0 0 1 2.644-1.933 3.85 3.85 0 0 1-.157 1.754"/></svg>',
  'scala':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#f44336" d="m6.457 9.894 12.523 5.163-.456 1.211L6 11.105Zm7.02-3.091L26 11.966l-.457 1.21L13.02 8.015ZM6.465 18.885l12.524 5.163-.457 1.21L6.01 20.097Zm7.007-3.086 12.524 5.163-.456 1.21-12.524-5.162Z"/><path fill="#f44336" d="M6 24.07V30l19.997-3.106V20.96zM6 5.11v5.99l20-3.11V2zm0 9.96v5.03l20-3.11v-5.03z"/></svg>',
  'settings':
      '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/><path fill="#42a5f5" d="M19.43 12.98c.04-.32.07-.64.07-.98s-.03-.66-.07-.98l2.11-1.65c.19-.15.24-.42.12-.64l-2-3.46a.5.5 0 0 0-.61-.22l-2.49 1c-.52-.4-1.08-.73-1.69-.98l-.38-2.65A.49.49 0 0 0 14 2h-4c-.25 0-.46.18-.49.42l-.38 2.65c-.61.25-1.17.59-1.69.98l-2.49-1a.6.6 0 0 0-.18-.03c-.17 0-.34.09-.43.25l-2 3.46c-.13.22-.07.49.12.64l2.11 1.65c-.04.32-.07.65-.07.98s.03.66.07.98l-2.11 1.65c-.19.15-.24.42-.12.64l2 3.46a.5.5 0 0 0 .61.22l2.49-1c.52.4 1.08.73 1.69.98l.38 2.65c.03.24.24.42.49.42h4c.25 0 .46-.18.49-.42l.38-2.65c.61-.25 1.17-.59 1.69-.98l2.49 1q.09.03.18.03c.17 0 .34-.09.43-.25l2-3.46c.12-.22.07-.49-.12-.64zm-1.98-1.71c.04.31.05.52.05.73s-.02.43-.05.73l-.14 1.13.89.7 1.08.84-.7 1.21-1.27-.51-1.04-.42-.9.68c-.43.32-.84.56-1.25.73l-1.06.43-.16 1.13-.2 1.35h-1.4l-.19-1.35-.16-1.13-1.06-.43c-.43-.18-.83-.41-1.23-.71l-.91-.7-1.06.43-1.27.51-.7-1.21 1.08-.84.89-.7-.14-1.13c-.03-.31-.05-.54-.05-.74s.02-.43.05-.73l.14-1.13-.89-.7-1.08-.84.7-1.21 1.27.51 1.04.42.9-.68c.43-.32.84-.56 1.25-.73l1.06-.43.16-1.13.2-1.35h1.39l.19 1.35.16 1.13 1.06.43c.43.18.83.41 1.23.71l.91.7 1.06-.43 1.27-.51.7 1.21-1.07.85-.89.7zM12 8c-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4m0 6c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2"/></svg>',
  'svelte':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300"><path fill="#ff5722" d="M175.94 24.328c-13.037.252-26.009 3.872-37.471 11.174L79.912 72.818a67.13 67.13 0 0 0-30.355 44.906 70.8 70.8 0 0 0 6.959 45.445 67.2 67.2 0 0 0-10.035 25.102 71.54 71.54 0 0 0 12.236 54.156c23.351 33.41 69.468 43.311 102.81 22.07l58.559-37.158a67.36 67.36 0 0 0 30.355-44.906 70.77 70.77 0 0 0-6.982-45.422 67.65 67.65 0 0 0 10.059-25.102 71.63 71.63 0 0 0-12.236-54.156v-.18c-15.324-21.925-40.453-33.727-65.342-33.246zm5.137 28.68a46.5 46.5 0 0 1 36.09 19.969 42.98 42.98 0 0 1 7.365 32.557 45 45 0 0 1-1.393 5.455l-1.123 3.37-2.986-2.247a75.9 75.9 0 0 0-22.902-11.45l-2.244-.651.201-2.246a13.16 13.16 0 0 0-2.379-8.711 13.99 13.99 0 0 0-14.953-5.412 12.8 12.8 0 0 0-3.594 1.572l-58.578 37.25a12.24 12.24 0 0 0-5.502 8.15 13.1 13.1 0 0 0 2.246 9.834 14.03 14.03 0 0 0 14.93 5.569 13.5 13.5 0 0 0 3.594-1.573l22.453-14.234a41.8 41.8 0 0 1 11.898-5.232 46.48 46.48 0 0 1 49.914 18.502 43.02 43.02 0 0 1 7.363 32.557 40.42 40.42 0 0 1-18.254 27.078l-58.58 37.316a43 43 0 0 1-11.898 5.23A46.545 46.545 0 0 1 82.81 227.14a42.98 42.98 0 0 1-7.341-32.557 38 38 0 0 1 1.39-5.41l1.102-3.37 3.008 2.246a75.9 75.9 0 0 0 22.836 11.361l2.244.65-.201 2.247a13.25 13.25 0 0 0 2.447 8.644 14.03 14.03 0 0 0 15.043 5.569 13.1 13.1 0 0 0 3.592-1.573l58.467-37.316a12.17 12.17 0 0 0 5.502-8.173 12.96 12.96 0 0 0-2.246-9.811 14.03 14.03 0 0 0-15.043-5.568 12.8 12.8 0 0 0-3.592 1.57l-22.453 14.258a42.9 42.9 0 0 1-11.877 5.209 46.52 46.52 0 0 1-49.846-18.5 43.02 43.02 0 0 1-7.297-32.557A40.42 40.42 0 0 1 96.798 96.98l58.646-37.316a42.8 42.8 0 0 1 11.811-5.21 46.5 46.5 0 0 1 13.822-1.444z"/></svg>',
  'svg':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#ffb300" d="M29.168 14.03a2.7 2.7 0 0 0-1.968-.83 2.51 2.51 0 0 0-1.929.8h-4.443l3.078-3.078a2.835 2.835 0 0 0 2.857-2.842 2.6 2.6 0 0 0-.831-1.969 2.82 2.82 0 0 0-2.014-.788 2.67 2.67 0 0 0-1.968.788 2.36 2.36 0 0 0-.812 1.922L18 11.17V6.726a2.51 2.51 0 0 0 .8-1.929 2.7 2.7 0 0 0-.832-1.968 2.745 2.745 0 0 0-3.936 0 2.7 2.7 0 0 0-.832 1.968 2.51 2.51 0 0 0 .8 1.93v4.443l-3.138-3.138a2.36 2.36 0 0 0-.812-1.922 2.66 2.66 0 0 0-1.968-.788 2.83 2.83 0 0 0-2.014.788 2.6 2.6 0 0 0-.831 1.969 2.74 2.74 0 0 0 .831 2.013 2.8 2.8 0 0 0 2.026.829l3.078 3.078H6.729a2.51 2.51 0 0 0-1.929-.8 2.7 2.7 0 0 0-1.968.831 2.745 2.745 0 0 0 0 3.937 2.7 2.7 0 0 0 1.968.832 2.51 2.51 0 0 0 1.929-.8h4.443l-3.078 3.077a2.835 2.835 0 0 0-2.857 2.842 2.6 2.6 0 0 0 .831 1.969 2.82 2.82 0 0 0 2.014.788 2.67 2.67 0 0 0 1.968-.788 2.36 2.36 0 0 0 .812-1.922L14 20.827v4.444a2.51 2.51 0 0 0-.8 1.929 2.784 2.784 0 0 0 4.768 1.968A2.7 2.7 0 0 0 18.8 27.2a2.51 2.51 0 0 0-.8-1.929v-4.444l3.138 3.138a2.36 2.36 0 0 0 .812 1.922 2.66 2.66 0 0 0 1.968.788 2.83 2.83 0 0 0 2.014-.788 2.6 2.6 0 0 0 .831-1.969 2.74 2.74 0 0 0-.831-2.013 2.8 2.8 0 0 0-2.026-.829L20.828 18h4.443a2.51 2.51 0 0 0 1.93.8 2.784 2.784 0 0 0 1.967-4.769Z"/></svg>',
  'swift':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#ff6e40" d="M17.087 19.721c-2.36 1.36-5.59 1.5-8.86.1a13.8 13.8 0 0 1-6.23-5.32c.67.55 1.46 1 2.3 1.4 3.37 1.57 6.73 1.46 9.1 0-3.37-2.59-6.24-5.96-8.37-8.71-.45-.45-.78-1.01-1.12-1.51 8.28 6.05 7.92 7.59 2.41-1.01 4.89 4.94 9.43 7.74 9.43 7.74.16.09.25.16.36.22.1-.25.19-.51.26-.78.79-2.85-.11-6.12-2.08-8.81 4.55 2.75 7.25 7.91 6.12 12.24-.03.11-.06.22-.05.39 2.24 2.83 1.64 5.78 1.35 5.22-1.21-2.39-3.48-1.65-4.62-1.17"/></svg>',
  'terraform':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#5c6bc0" d="m2 10 8 4V6L2 2zm10 5 8 4v-8l-8-4zm0 11 8 4v-8l-8-4zm10-14v8l8-4V8z"/></svg>',
  'toml':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#cfd8dc" d="M4 6V4h8v2H9v7H7V6z"/><path fill="#ef5350" d="M4 1v1H2v12h2v1H1V1zm8 0v1h2v12h-2v1h3V1z"/></svg>',
  'typescript':
      '<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 16 16"><path fill="#0288d1" d="M2 2v12h12V2zm4 6h3v1H8v4H7V9H6zm5 0h2v1h-2v1h1a1.003 1.003 0 0 1 1 1v1a1.003 1.003 0 0 1-1 1h-2v-1h2v-1h-1a1.003 1.003 0 0 1-1-1V9a1.003 1.003 0 0 1 1-1"/></svg>',
  'vue':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#41b883" d="M1.791 3.851 12 21.471 22.209 3.936V3.85H18.24l-6.18 10.616L5.906 3.851z"/><path fill="#35495e" d="m5.907 3.851 6.152 10.617L18.24 3.851h-3.723L12.084 8.03 9.66 3.85z"/></svg>',
  'webassembly':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#7c4dff" d="M22 18h4v4h-4z"/><path fill="#7c4dff" d="M20 2a4 4 0 0 1-8 0H2v28h28V2Zm-2 24h-2v2h-4v-2h-2v2H6v-2H4V16h2v10h4V16h2v10h4V16h2Zm10 2h-2v-4h-4v4h-2V18h2v-2h4v2h2Z"/></svg>',
  'xml':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#8bc34a" d="M13 9h5.5L13 3.5zM6 2h8l6 6v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4c0-1.11.89-2 2-2m.12 13.5 3.74 3.74 1.42-1.41-2.33-2.33 2.33-2.33-1.42-1.41zm11.16 0-3.74-3.74-1.42 1.41 2.33 2.33-2.33 2.33 1.42 1.41z"/></svg>',
  'yaml':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#ff5252" d="M13 9h5.5L13 3.5zM6 2h8l6 6v12c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2m12 16v-2H9v2zm-4-4v-2H6v2z"/></svg>',
  'zig':
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="#f9a825" d="M2 8h6v4H2zm8 0h12v4H10zm0 12h12v4H10zm14 0h2v4h-2zM8 20l-3 4H2V12h4v8zm14-8h-6l-6 8h6z"/><path fill="#f9a825" d="M16 20h-6l-6 8m12-16h6l6-8m2 4v16h-4V12h-2l3-4z"/></svg>',
};

/// The `EXTENSION_TO_ICON` table, carried over entry-for-entry.
///
/// Several extensions deliberately collapse onto one glyph (`jpg`/`jpeg`/`png`
/// → `image`, `sh`/`bash` → `console`, `cfg`/`conf`/`ini` → `settings`), so this
/// map is larger than [materialFileIconSvgs] and the two counts are asserted
/// separately.
const Map<String, String> materialFileIconNameByExtension = <String, String>{
  'astro': 'astro',
  'bash': 'console',
  'c': 'c',
  'cfg': 'settings',
  'clj': 'clojure',
  'conf': 'settings',
  'cpp': 'cpp',
  'cs': 'csharp',
  'css': 'css',
  'dart': 'dart',
  'erl': 'erlang',
  'ex': 'elixir',
  'exs': 'elixir',
  'gif': 'image',
  'go': 'go',
  'gql': 'graphql',
  'gradle': 'gradle',
  'graphql': 'graphql',
  'groovy': 'groovy',
  'h': 'h',
  'hcl': 'hcl',
  'hpp': 'hpp',
  'hs': 'haskell',
  'html': 'html',
  'ico': 'image',
  'ini': 'settings',
  'java': 'java',
  'jpeg': 'image',
  'jpg': 'image',
  'js': 'javascript',
  'json': 'json',
  'jsx': 'react',
  'kt': 'kotlin',
  'less': 'less',
  'lock': 'lock',
  'lua': 'lua',
  'markdown': 'markdown',
  'md': 'markdown',
  'ml': 'ocaml',
  'nix': 'nix',
  'php': 'php',
  'png': 'image',
  'py': 'python',
  'r': 'r',
  'rb': 'ruby',
  'rs': 'rust',
  'scala': 'scala',
  'scss': 'sass',
  'sh': 'console',
  'sql': 'database',
  'svelte': 'svelte',
  'svg': 'svg',
  'swift': 'swift',
  'tf': 'terraform',
  'toml': 'toml',
  'ts': 'typescript',
  'tsx': 'react_ts',
  'txt': 'document',
  'vue': 'vue',
  'wasm': 'webassembly',
  'webp': 'image',
  'xml': 'xml',
  'yaml': 'yaml',
  'yml': 'yaml',
  'zig': 'zig',
};
