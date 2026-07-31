/// Port of six frozen Paseo 0.2.0 `utils/` modules that share one property:
/// each is a pure decision whose *only* impure part is a host capability the
/// browser or the desktop shell supplies. Grouping them here keeps that shape
/// visible — every host touch in this library arrives as an injected interface,
/// never as a plugin call or a global.
///
/// - `utils/confirm-dialog.ts` — which confirmation backend to ask, and with
///   what labels, across native / desktop-bridge / plain-browser hosts.
/// - `utils/assistant-message-height-estimate.ts` — the measured-height cache
///   that lets a virtualized chat list guess an assistant message's height
///   before it has laid out.
/// - `utils/sidebar-shortcuts.ts` — the 1..N keyboard numbering over the
///   sidebar's visible rows, and the wrap-around "next/previous numbered row"
///   traversal.
/// - `utils/markdown-list.ts` — list markers and inter-list spacing for the
///   markdown renderer, derived from a parsed node plus its ancestor chain.
/// - `utils/schedule-format.ts` — the interval/cron humanization the schedules
///   surface shows.
/// - `utils/os-notifications.ts` — posting an OS notification and routing the
///   click that follows.
///
/// ## What this library deliberately does *not* re-implement
///
/// Several of these upstream modules were already partially ported as private
/// helpers or under repo-local names. This library reuses those rather than
/// growing a second copy:
///
/// - `splitMarkdownBlocks` from `core/paseo_markdown_rules.dart`.
/// - `SidebarShortcutModel` / `SidebarShortcutSection` /
///   `SidebarShortcutWorkspaceTarget` from `core/paseo_session_projection.dart`
///   (re-exported below), whose private `_buildSidebarShortcutSections` this
///   library's public [buildSidebarShortcutSections] supersedes.
/// - `scheduleProductName`, `resolveScheduleTitle`, `formatScheduleCadence`
///   and `formatScheduleNextRun` from `state/schedule_row_model.dart`, and
///   `validateScheduleCron` / `describeScheduleCron` from
///   `state/schedule_form_model.dart` (all re-exported below).
/// - `resolveNotificationTarget` / `buildNotificationRoute` from
///   `navigation/paseo_agent_routing.dart`.
/// - `PaseoSpacing` from `core/theme.dart` for the markdown list margins.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart'
    show NewAgentScheduleTarget, ScheduleSummary;

import '../navigation/paseo_agent_routing.dart'
    show buildNotificationRoute, resolveNotificationTarget;
import '../sidebar/sidebar_models.dart'
    show SidebarWorkspaceProjectEntry, StatusGroup;
import 'paseo_markdown_rules.dart' show splitMarkdownBlocks;
import 'paseo_session_projection.dart'
    show
        SidebarShortcutModel,
        SidebarShortcutSection,
        SidebarShortcutWorkspaceTarget;
import 'theme.dart' show PaseoSpacing;

// The shortcut shapes upstream declares in `utils/sidebar-shortcuts.ts` landed
// in the projection library first, because the projection needed them before
// this module was ported. Re-exported so a caller of this library sees the whole
// upstream module surface from one import.
export 'paseo_session_projection.dart'
    show
        SidebarShortcutModel,
        SidebarShortcutSection,
        SidebarShortcutWorkspaceTarget;

// The already-ported half of `utils/schedule-format.ts`, under the names the
// repo gave it. Re-exported for the same reason.
export '../state/schedule_form_model.dart'
    show describeScheduleCron, validateScheduleCron;
export '../state/schedule_row_model.dart'
    show
        formatScheduleCadence,
        formatScheduleNextRun,
        resolveScheduleTitle,
        scheduleProductName;

// ---------------------------------------------------------------------------
// confirm-dialog.ts
// ---------------------------------------------------------------------------

/// The severity a desktop dialog is asked to render with.
///
/// Upstream's `DesktopDialogAskOptions["kind"]` union (`"info" | "warning"`).
enum DesktopDialogKind {
  info('info'),
  warning('warning');

  const DesktopDialogKind(this.wireName);

  /// The literal the desktop bridge expects, kept so a host adapter can pass it
  /// through without a second switch.
  final String wireName;
}

/// Everything a confirmation prompt needs, independent of which backend shows
/// it.
///
/// [confirmLabel] and [cancelLabel] are nullable rather than defaulted at the
/// call site so that "not specified" stays distinguishable all the way to
/// [resolveConfirmButtonLabels] — matching upstream's `?? "Confirm"` / `??
/// "Cancel"`, which fires on `undefined` only.
final class ConfirmDialogInput {
  const ConfirmDialogInput({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.cancelLabel,
    this.destructive,
  });

  final String title;
  final String message;
  final String? confirmLabel;
  final String? cancelLabel;

  /// Nullable rather than defaulted to `false` to mirror upstream's optional
  /// field. Null and false are treated identically everywhere.
  ///
  /// Deviation: upstream tests `input.destructive` for JS truthiness. The only
  /// values TypeScript admits here are `true`, `false` and `undefined`, and all
  /// three round-trip identically through `destructive == true`.
  final bool? destructive;
}

/// The resolved button text for one prompt.
final class ConfirmButtonLabels {
  const ConfirmButtonLabels({
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String confirmLabel;
  final String cancelLabel;

  @override
  bool operator ==(Object other) =>
      other is ConfirmButtonLabels &&
      confirmLabel == other.confirmLabel &&
      cancelLabel == other.cancelLabel;

  @override
  int get hashCode => Object.hash(confirmLabel, cancelLabel);

  @override
  String toString() => 'ConfirmButtonLabels($confirmLabel, $cancelLabel)';
}

/// Applies the default button text.
///
/// Public because both the native and the desktop path need the *same* labels;
/// upstream keeps this private only because both callers live in one file.
ConfirmButtonLabels resolveConfirmButtonLabels(ConfirmDialogInput input) =>
    ConfirmButtonLabels(
      confirmLabel: input.confirmLabel ?? 'Confirm',
      cancelLabel: input.cancelLabel ?? 'Cancel',
    );

/// The desktop bridge's `dialog.ask` options.
final class DesktopDialogAskOptions {
  const DesktopDialogAskOptions({
    required this.title,
    required this.okLabel,
    required this.cancelLabel,
    required this.kind,
  });

  final String title;
  final String okLabel;
  final String cancelLabel;
  final DesktopDialogKind kind;

  /// Value equality so a test can assert the whole options object at once, the
  /// way upstream asserts it as an object literal.
  @override
  bool operator ==(Object other) =>
      other is DesktopDialogAskOptions &&
      title == other.title &&
      okLabel == other.okLabel &&
      cancelLabel == other.cancelLabel &&
      kind == other.kind;

  @override
  int get hashCode => Object.hash(title, okLabel, cancelLabel, kind);

  @override
  String toString() =>
      'DesktopDialogAskOptions($title, $okLabel, $cancelLabel, ${kind.wireName})';
}

/// Maps a prompt onto the desktop bridge's option shape.
///
/// Note the asymmetry with the native path: the desktop bridge takes the
/// message as a *separate* argument, so [DesktopDialogAskOptions] carries the
/// title but not the message. Upstream exposes this through `__private__` purely
/// for its own tests; here it is public because it is genuinely reusable by any
/// host adapter.
DesktopDialogAskOptions buildDesktopAskOptions(ConfirmDialogInput input) {
  final labels = resolveConfirmButtonLabels(input);
  return DesktopDialogAskOptions(
    title: input.title,
    okLabel: labels.confirmLabel,
    cancelLabel: labels.cancelLabel,
    kind: input.destructive == true
        ? DesktopDialogKind.warning
        : DesktopDialogKind.info,
  );
}

/// The message [confirmDialog] throws when running on web with no confirmation
/// backend at all. Exposed so callers can match on it without string-literal
/// duplication.
const String confirmDialogNoBackendMessage =
    '[ConfirmDialog] No web confirmation backend is available.';

/// Formats the single string a plain browser `confirm()` can show, since that
/// API has no separate title.
String buildWebConfirmPrompt(ConfirmDialogInput input) =>
    '${input.title}\n\n${input.message}';

/// A desktop bridge's `dialog.ask`.
typedef DesktopDialogAsk =
    Future<bool> Function(String message, DesktopDialogAskOptions options);

/// A browser `globalThis.confirm`.
typedef BrowserConfirm = bool Function(String message);

/// The host capabilities [confirmDialog] chooses between.
///
/// Injected as an interface rather than reached for directly because the choice
/// upstream makes — native alert, else desktop bridge, else browser `confirm` —
/// is the actual logic under test, and it is only testable if every branch can
/// be present or absent independently.
abstract interface class ConfirmDialogHost {
  /// Upstream's `isNative` (`Platform.OS !== "web"`). When true the native
  /// alert is the only path considered.
  bool get isNative;

  /// Shows the platform alert and resolves with the user's choice. Dismissal
  /// resolves `false`.
  Future<bool> showNativeConfirm({
    required String title,
    required String message,
    required ConfirmButtonLabels labels,
    required bool destructive,
  });

  /// Whether a desktop bridge object exists at all.
  ///
  /// Deliberately separate from [desktopAsk]: upstream blurs the focused
  /// element the moment `getDesktopHost()` returns an object, *before* it
  /// discovers whether that object actually has a `dialog.ask`. A bridge
  /// without `ask` therefore blurs twice — once here, once on the browser
  /// `confirm` fallback — and that is reproduced.
  bool get hasDesktopBridge;

  /// The bridge's `dialog.ask`, or null when the bridge does not expose one.
  DesktopDialogAsk? get desktopAsk;

  /// `globalThis.confirm`, or null when absent.
  BrowserConfirm? get browserConfirm;

  /// Drops focus from the active element so the modal does not return focus to
  /// a control the confirmation is about to invalidate. Upstream no-ops this on
  /// native; a native host implementation should do the same.
  void blurActiveWebElement();
}

/// Asks the user to confirm, using the best backend [host] offers.
///
/// The ladder is native alert -> desktop bridge -> browser `confirm`, and it
/// *throws* rather than silently returning false when web has no backend: a
/// missing confirmation is not a decline, and treating it as one would let a
/// destructive action look user-approved.
Future<bool> confirmDialog({
  required ConfirmDialogInput input,
  required ConfirmDialogHost host,
}) async {
  if (host.isNative) {
    return host.showNativeConfirm(
      title: input.title,
      message: input.message,
      labels: resolveConfirmButtonLabels(input),
      destructive: input.destructive == true,
    );
  }

  final desktopResult = await _showDesktopConfirmDialog(
    input: input,
    host: host,
  );
  if (desktopResult != null) {
    return desktopResult;
  }

  return _showWebConfirmDialog(input: input, host: host);
}

/// Null means "the desktop path did not answer" — either there is no bridge, or
/// the bridge has no `ask`. It never means "the user declined".
Future<bool?> _showDesktopConfirmDialog({
  required ConfirmDialogInput input,
  required ConfirmDialogHost host,
}) async {
  if (!host.hasDesktopBridge) {
    return null;
  }

  host.blurActiveWebElement();
  final options = buildDesktopAskOptions(input);
  final desktopAsk = host.desktopAsk;
  if (desktopAsk == null) {
    return null;
  }
  return desktopAsk(input.message, options);
}

bool _showWebConfirmDialog({
  required ConfirmDialogInput input,
  required ConfirmDialogHost host,
}) {
  final browserConfirm = host.browserConfirm;
  if (browserConfirm == null) {
    throw StateError(confirmDialogNoBackendMessage);
  }

  host.blurActiveWebElement();
  return browserConfirm(buildWebConfirmPrompt(input));
}

// ---------------------------------------------------------------------------
// assistant-message-height-estimate.ts
// ---------------------------------------------------------------------------

/// How many measured markdown blocks are remembered before the least recently
/// touched entry is dropped.
const int assistantMarkdownBlockHeightCacheLimit = 1000;

/// The width every cached markdown block is keyed at.
///
/// Upstream derives this as `MAX_CONTENT_WIDTH - 16`, where `MAX_CONTENT_WIDTH`
/// is 820 in `constants/layout.ts`. That constant has no Dart port yet, so the
/// arithmetic is inlined with the derivation recorded here; a real measurement
/// at any width that *rounds* to this value still hits the cache.
const double assistantMarkdownBlockEstimateWidth = 820 - 16;

/// The assistant bubble's own vertical padding, added once per message.
const int assistantMessageVerticalPadding = 24;

/// The gap between two markdown blocks, added `blockCount - 1` times.
const int assistantMarkdownBlockGap = 12;

/// A fallback estimator consulted when the markdown blocks are not all
/// measured — upstream's `assistant-image-metadata` estimator.
typedef AssistantImageHeightEstimator = int? Function(String markdown);

/// The measured-height cache behind the assistant message height estimate.
///
/// Exists as a class rather than as module-level state so a test can hold an
/// isolated cache, and so the image-metadata fallback can be *injected*. That
/// injection is the one structural deviation from upstream, which imports
/// `assistant-image-metadata`'s estimator directly; that module has no Dart port
/// yet, and hard-wiring a stub would have made the fallback untestable and the
/// eventual port a breaking edit. [estimateFromCache] with no fallback behaves
/// exactly as upstream does when the message contains no measured images.
final class AssistantMessageHeightEstimateCache {
  AssistantMessageHeightEstimateCache({this.imageFallback});

  /// Consulted only when the markdown-block path yields null, matching
  /// upstream's `markdownEstimate ?? imageEstimate`.
  final AssistantImageHeightEstimator? imageFallback;

  /// Insertion-ordered, so the first key is the least recently touched. Dart's
  /// default `Map` is a `LinkedHashMap`, which is the same guarantee JS `Map`
  /// gives — the eviction order is therefore identical.
  final LinkedHashMap<String, int> _heights = LinkedHashMap<String, int>();

  /// Records a real measurement for one markdown block, returning the stored
  /// (ceiled) height, or null when the measurement is unusable.
  ///
  /// The height is ceiled rather than rounded because an under-estimate makes a
  /// virtualized list scroll-jump when the real content turns out taller, while
  /// an over-estimate merely leaves a sliver of slack.
  int? setMarkdownBlockHeight({
    required String block,
    required num width,
    required num height,
  }) {
    if (!_isFinite(height) || height <= 0) {
      return null;
    }
    final key = _createMarkdownBlockHeightKey(block: block, width: width);
    if (key == null) {
      return null;
    }
    final ceiled = height.ceil();
    _touch(key, ceiled);
    return ceiled;
  }

  /// Estimates the whole message's height, or null when any block is unmeasured.
  ///
  /// All-or-nothing on purpose: a partial sum would be confidently wrong, and a
  /// virtualized list would rather fall back to its own placeholder than trust a
  /// number that is short by one paragraph.
  int? estimateFromCache(String markdown) =>
      _estimateFromMarkdownBlocks(markdown) ?? imageFallback?.call(markdown);

  /// Drops every measurement.
  void clear() => _heights.clear();

  /// How many measurements are currently held. Not upstream API; exposed
  /// because the eviction limit is otherwise unobservable.
  int get length => _heights.length;

  int? _estimateFromMarkdownBlocks(String markdown) {
    final blocks = splitMarkdownBlocks(markdown);
    if (blocks.isEmpty) {
      return null;
    }

    var blockHeight = 0;
    for (final block in blocks) {
      final key = _createMarkdownBlockHeightKey(
        block: block,
        width: assistantMarkdownBlockEstimateWidth,
      );
      final cached = key == null ? null : _heights[key];
      if (cached == null) {
        return null;
      }
      blockHeight += cached;
    }

    return assistantMessageVerticalPadding +
        blockHeight +
        assistantMarkdownBlockGap * math.max(0, blocks.length - 1);
  }

  /// Re-inserts [key] at the most-recent end, then evicts the oldest entry if
  /// the cache has grown past its limit.
  void _touch(String key, int value) {
    _heights.remove(key);
    _heights[key] = value;
    if (_heights.length <= assistantMarkdownBlockHeightCacheLimit) {
      return;
    }
    _heights.remove(_heights.keys.first);
  }
}

/// Null for a width that cannot be measured at, or for an empty block.
///
/// An empty block is excluded because every empty string hashes alike, so one
/// cached zero-height would answer for all of them.
String? _createMarkdownBlockHeightKey({
  required String block,
  required num width,
}) {
  final normalizedWidth = _normalizeMarkdownBlockWidth(width);
  if (normalizedWidth == null || block.isEmpty) {
    return null;
  }
  return '$normalizedWidth:${_hashMarkdownBlock(block)}';
}

/// Rounds a measured width to a whole pixel so that sub-pixel layout jitter
/// does not fragment the cache into near-duplicate keys.
///
/// Deviation: JS `Math.round` breaks ties toward `+Infinity` while Dart's
/// `num.round` breaks them away from zero. They differ only at negative halves,
/// which the `<= 0` guard above has already rejected.
int? _normalizeMarkdownBlockWidth(num width) {
  if (!_isFinite(width) || width <= 0) {
    return null;
  }
  return width.round();
}

/// FNV-1a over UTF-16 code units, rendered as `length:base36`.
///
/// Ported bit-for-bit rather than swapped for [Object.hashAll] because the key
/// space has to stay stable across a reload for a warm cache to be worth
/// keeping. Dart ints are 64-bit, so each step masks back to 32 bits to
/// reproduce JS's `^` (int32) and `Math.imul` (low 32 bits of the product);
/// the final `>>> 0` is implicit because the accumulator is already unsigned.
String _hashMarkdownBlock(String block) {
  var hash = 2166136261;
  for (final unit in block.codeUnits) {
    hash = (hash ^ unit) & 0xFFFFFFFF;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return '${block.length}:${hash.toRadixString(36)}';
}

/// Dart's analogue of `Number.isFinite`. An `int` is always finite; only a
/// `double` can be NaN or infinite.
bool _isFinite(num value) => value is! double || value.isFinite;

/// The process-wide cache, matching upstream's module-level singleton.
///
/// Carries no image fallback: `assistant-image-metadata` has no Dart port yet.
/// Construct an [AssistantMessageHeightEstimateCache] directly to supply one.
final AssistantMessageHeightEstimateCache _assistantHeightCache =
    AssistantMessageHeightEstimateCache();

/// Records a measured markdown block height in the process-wide cache.
int? setAssistantMarkdownBlockHeight({
  required String block,
  required num width,
  required num height,
}) => _assistantHeightCache.setMarkdownBlockHeight(
  block: block,
  width: width,
  height: height,
);

/// Estimates an assistant message's height from the process-wide cache.
int? estimateAssistantMessageHeightFromCache(String markdown) =>
    _assistantHeightCache.estimateFromCache(markdown);

/// Empties the process-wide cache. Tests must call this between cases, since
/// the cache outlives any one of them.
void clearAssistantMessageHeightEstimateCache() =>
    _assistantHeightCache.clear();

// ---------------------------------------------------------------------------
// sidebar-shortcuts.ts
// ---------------------------------------------------------------------------

/// Which way [getRelativeSidebarShortcutTarget] steps through the numbered
/// rows.
///
/// Upstream types this as the literal union `1 | -1` and does the arithmetic
/// inline. An enum carrying the step keeps the two legal values enforced by the
/// type system instead of by convention, while [step] preserves the arithmetic
/// verbatim.
enum SidebarShortcutDelta {
  previous(-1),
  next(1);

  const SidebarShortcutDelta(this.step);

  final int step;
}

/// The default number of rows that get a keyboard shortcut.
///
/// Nine because the shortcut is a single digit; there is no tenth key.
const int defaultSidebarShortcutLimit = 9;

/// Numbers the visible rows of [sections] 1..N in render order.
///
/// This is the module upstream owns the numbering in, and it supersedes the
/// private `_buildSidebarShortcutSections` copy inside
/// `core/paseo_session_projection.dart` — that copy exists only because the
/// projection needed the numbering before this module was ported. (It does *not*
/// supersede `buildStatusShortcutIndex` in
/// `sidebar/paseo_sidebar_view_models.dart`, which is a port of a different
/// upstream module, `hooks/sidebar-status-view-model.ts`, and has no notion of a
/// collapsed group.)
///
/// A collapsed section is skipped whole, so a number never lands on a row the
/// user cannot see and press.
///
/// Deviation: a NaN [shortcutLimit] makes JS's `Math.max(0, Math.floor(NaN))`
/// produce NaN, whose `length >= NaN` comparison is always false — silently
/// numbering *every* row. Dart's `double.nan.floor()` throws instead. The JS
/// behavior is a latent bug, not a contract, and no caller can reach it.
SidebarShortcutModel buildSidebarShortcutSections({
  required List<SidebarShortcutSection> sections,
  num? shortcutLimit,
}) {
  final maxShortcuts = math.max(
    0,
    (shortcutLimit ?? defaultSidebarShortcutLimit).floor(),
  );
  final shortcutTargets = <SidebarShortcutWorkspaceTarget>[];
  final shortcutIndexByWorkspaceKey = <String, int>{};

  for (final section in sections) {
    if (section.collapsed ?? false) {
      continue;
    }
    for (final workspace in section.workspaces) {
      if (shortcutTargets.length >= maxShortcuts) {
        break;
      }
      final shortcutNumber = shortcutTargets.length + 1;
      shortcutTargets.add(
        SidebarShortcutWorkspaceTarget(
          serverId: workspace.serverId,
          workspaceId: workspace.workspaceId,
        ),
      );
      shortcutIndexByWorkspaceKey[workspace.workspaceKey] = shortcutNumber;
    }
  }

  return SidebarShortcutModel(
    shortcutTargets: shortcutTargets,
    shortcutIndexByWorkspaceKey: shortcutIndexByWorkspaceKey,
  );
}

/// Numbers the project-grouped sidebar, treating each project as one section.
SidebarShortcutModel buildSidebarShortcutModel({
  required List<SidebarWorkspaceProjectEntry> projects,
  required Set<String> collapsedProjectKeys,
  num? shortcutLimit,
}) => buildSidebarShortcutSections(
  sections: [
    for (final project in projects)
      SidebarShortcutSection(
        workspaces: project.workspaces,
        collapsed: collapsedProjectKeys.contains(project.projectKey),
      ),
  ],
  shortcutLimit: shortcutLimit,
);

/// Numbers the status-grouped sidebar, treating each status bucket as one
/// section.
///
/// [collapsedStatusGroupKeys] is keyed by the bucket's wire name — upstream's
/// `group.bucket` is that string directly, where Dart's [StatusGroup.bucket] is
/// an enum.
SidebarShortcutModel buildStatusSidebarShortcutModel({
  required List<StatusGroup> groups,
  Set<String>? collapsedStatusGroupKeys,
  num? shortcutLimit,
}) => buildSidebarShortcutSections(
  sections: [
    for (final group in groups)
      SidebarShortcutSection(
        workspaces: group.rows,
        // Null (no collapse state supplied) and false behave identically, as
        // upstream's `collapsedStatusGroupKeys?.has(...)` returning undefined
        // does.
        collapsed: collapsedStatusGroupKeys?.contains(group.bucket.wireName),
      ),
  ],
  shortcutLimit: shortcutLimit,
);

/// The numbered row one step before or after [currentTarget].
///
/// The list wraps, so this is a cycle rather than a clamped walk. A
/// [currentTarget] that is not numbered — an unpinned row, a collapsed
/// project's row, or anything past the limit — is treated the same as no
/// current target at all: the traversal enters the list at the edge it is
/// heading away from, so "next" lands on the first row and "previous" on the
/// last. That way a keypress from an un-numbered row always does something
/// predictable instead of nothing.
SidebarShortcutWorkspaceTarget? getRelativeSidebarShortcutTarget({
  required List<SidebarShortcutWorkspaceTarget> targets,
  required SidebarShortcutWorkspaceTarget? currentTarget,
  required SidebarShortcutDelta delta,
}) {
  if (targets.isEmpty) {
    return null;
  }

  if (currentTarget == null) {
    return _shortcutEntryTarget(targets, delta);
  }

  final currentIndex = targets.indexWhere(
    (target) =>
        target.serverId == currentTarget.serverId &&
        target.workspaceId == currentTarget.workspaceId,
  );
  if (currentIndex < 0) {
    return _shortcutEntryTarget(targets, delta);
  }

  final nextIndex =
      (currentIndex + delta.step + targets.length) % targets.length;
  return targets[nextIndex];
}

SidebarShortcutWorkspaceTarget _shortcutEntryTarget(
  List<SidebarShortcutWorkspaceTarget> targets,
  SidebarShortcutDelta delta,
) => targets[delta.step > 0 ? 0 : targets.length - 1];

// ---------------------------------------------------------------------------
// markdown-list.ts
// ---------------------------------------------------------------------------

/// The `start` attribute of an ordered list, which markdown-it may hand over
/// either already-parsed or still as source text.
///
/// Upstream types it as the union `number | string`; Dart gets a sealed
/// hierarchy so both shapes stay reachable and the parse rule below can switch
/// on them exhaustively.
sealed class MarkdownOrderedListStart {
  const MarkdownOrderedListStart();

  /// An already-parsed numeric start.
  const factory MarkdownOrderedListStart.number(num value) =
      MarkdownOrderedListStartNumber;

  /// A raw textual start, parsed with JavaScript `parseInt` semantics.
  const factory MarkdownOrderedListStart.text(String value) =
      MarkdownOrderedListStartText;
}

/// An ordered list `start` that arrived as a number.
final class MarkdownOrderedListStartNumber extends MarkdownOrderedListStart {
  const MarkdownOrderedListStartNumber(this.value);

  final num value;
}

/// An ordered list `start` that arrived as text.
final class MarkdownOrderedListStartText extends MarkdownOrderedListStart {
  const MarkdownOrderedListStartText(this.value);

  final String value;
}

/// A parsed markdown node, reduced to the fields the list rules read.
///
/// Every field is optional because the renderer hands over whatever
/// markdown-it produced, and the rules below are written to survive any of them
/// being absent. Identity equality is deliberately *not* overridden: upstream
/// locates a node inside its parent with `Array.prototype.indexOf`, which is
/// reference-based, and value equality here would make two structurally
/// identical siblings indistinguishable.
final class MarkdownListNode {
  const MarkdownListNode({
    this.type,
    this.index,
    this.markup,
    this.start,
    this.children,
  });

  /// `"bullet_list"`, `"ordered_list"`, `"list_item"`, `"paragraph"`, ...
  final String? type;

  /// The item's own position within its list, when markdown-it supplied one.
  /// A `num` rather than an `int` because upstream only requires it to be a
  /// finite number, and a fractional value reaches the rendered marker.
  final num? index;

  /// The delimiter after an ordered marker, e.g. `"."` or `")"`.
  final String? markup;

  /// Upstream's `attributes.start`. Flattened to one field because
  /// `attributes` carries nothing else the list rules read.
  final MarkdownOrderedListStart? start;

  final List<MarkdownListNode>? children;
}

/// The rendered marker for one list item.
final class MarkdownListMarker {
  const MarkdownListMarker({required this.isOrdered, required this.marker});

  final bool isOrdered;

  /// Either the bullet glyph or `"<number><markup>"`.
  final String marker;

  @override
  bool operator ==(Object other) =>
      other is MarkdownListMarker &&
      isOrdered == other.isOrdered &&
      marker == other.marker;

  @override
  int get hashCode => Object.hash(isOrdered, marker);

  @override
  String toString() => 'MarkdownListMarker($isOrdered, $marker)';
}

/// The vertical margins around one list.
final class MarkdownListSpacing {
  const MarkdownListSpacing({
    required this.marginTop,
    required this.marginBottom,
  });

  final double marginTop;
  final double marginBottom;

  @override
  bool operator ==(Object other) =>
      other is MarkdownListSpacing &&
      marginTop == other.marginTop &&
      marginBottom == other.marginBottom;

  @override
  int get hashCode => Object.hash(marginTop, marginBottom);

  @override
  String toString() => 'MarkdownListSpacing($marginTop, $marginBottom)';
}

const String _markdownListBullet = '•';
const String _defaultOrderedListMarkup = '.';

/// A list always gets a little air above it.
const double markdownListMarginTop = PaseoSpacing.s1;

/// A list followed by prose ends a section, so it gets a full section gap.
const double markdownListMarginBottomToProse = PaseoSpacing.s4;

/// Two adjacent lists are one thought, so they get a tighter gap.
const double markdownListMarginBottomToList = PaseoSpacing.s2;

/// A nested list is spaced by its parent item, not by itself.
const double markdownNestedListMarginBottom = 0;

/// A list at the end of a block has nothing below to be spaced from; the block
/// gap handles it.
const double markdownTerminalListMarginBottom = 0;

/// Normalizes the renderer's ancestor argument into a list.
///
/// Deviation: upstream types the parameter as `unknown` and accepts an array, a
/// single object, or neither. Dart has no `unknown`, so [parent] is `Object?`
/// and the same three shapes are recognised — a `List<MarkdownListNode>`, a
/// bare [MarkdownListNode], or anything else (yielding an empty chain). The
/// looseness is the renderer's contract, not a choice made here.
///
/// Note the ordering convention this implies and that the rules below depend
/// on: index 0 is the *nearest* ancestor.
List<MarkdownListNode> markdownListAncestors(Object? parent) {
  if (parent is List<MarkdownListNode>) {
    return parent;
  }
  if (parent is MarkdownListNode) {
    return [parent];
  }
  return const [];
}

MarkdownListNode? _nearestListParent(Object? parent) {
  for (final ancestor in markdownListAncestors(parent)) {
    if (ancestor.type == 'ordered_list' || ancestor.type == 'bullet_list') {
      return ancestor;
    }
  }
  return null;
}

/// The item's offset within its list.
///
/// Prefers the parser's own [MarkdownListNode.index]; a negative or non-finite
/// one is rejected because it would render a marker running backwards. The
/// fallback searches the parent's children by identity, and a node that is not
/// there at all is treated as the first item so the list still renders.
num _orderedListItemIndex(MarkdownListNode node, MarkdownListNode listParent) {
  final index = node.index;
  if (index != null && _isFinite(index) && index >= 0) {
    return index;
  }

  final children = listParent.children;
  if (children != null) {
    final fallbackIndex = children.indexOf(node);
    if (fallbackIndex >= 0) {
      return fallbackIndex;
    }
  }

  return 0;
}

/// The number the list counts from, defaulting to 1.
num _parseOrderedListStart(MarkdownListNode node) {
  switch (node.start) {
    case MarkdownOrderedListStartNumber(:final value):
      return _isFinite(value) ? value : 1;
    case MarkdownOrderedListStartText(:final value):
      return _parseIntJs(value) ?? 1;
    case null:
      return 1;
  }
}

/// JavaScript `Number.parseInt(value, 10)`, narrowed to what a `start`
/// attribute can hold: optional leading whitespace, an optional sign, then the
/// leading run of digits. Anything with no such run is `NaN` upstream, which
/// fails the `Number.isFinite` check — here, null.
///
/// The prefix behavior matters: `"3.7"` parses as 3, not as 3.7 and not as a
/// failure.
int? _parseIntJs(String value) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Renders [value] the way JavaScript's string coercion would.
///
/// Needed because upstream builds the marker with template interpolation over a
/// plain JS number: a whole value prints without a fraction (`2`, not `2.0`)
/// while a fractional one keeps it (`2.5`). Dart's `double.toString` always
/// emits the `.0`, which would put `1.0.` in front of every list item whose
/// index arrived as a double.
String _formatJsNumber(num value) {
  if (value is int) {
    return '$value';
  }
  final asDouble = value as double;
  if (asDouble.isNaN) {
    return 'NaN';
  }
  if (asDouble.isInfinite) {
    return asDouble.isNegative ? '-Infinity' : 'Infinity';
  }
  if (asDouble == asDouble.truncateToDouble() && asDouble.abs() < 1e21) {
    return asDouble.toInt().toString();
  }
  return asDouble.toString();
}

/// The `type` of the node that follows [node] among its siblings, or null when
/// [node] is last or is not found at all.
///
/// Searches the ancestor chain from the *far* end inward, which is the opposite
/// of [_nearestListParent]'s direction. That is upstream's behavior verbatim:
/// when a node appears in more than one ancestor's children, the outermost
/// ancestor listed wins. Reproduced rather than corrected because the renderer
/// passes a single-element chain in practice, so the asymmetry is unobservable
/// there — and "fixing" it would change spacing in whatever case does hit it.
String? getMarkdownNextSiblingType(MarkdownListNode node, Object? parent) {
  final ancestors = markdownListAncestors(parent);
  for (var i = ancestors.length - 1; i >= 0; i--) {
    final children = ancestors[i].children;
    if (children == null) continue;
    final index = children.indexOf(node);
    if (index >= 0) {
      return index + 1 < children.length ? children[index + 1].type : null;
    }
  }
  return null;
}

bool _isMarkdownListType(String? type) =>
    type == 'bullet_list' || type == 'ordered_list';

bool _hasListItemAncestor(Object? parent) => markdownListAncestors(
  parent,
).any((ancestor) => ancestor.type == 'list_item');

/// The margins to render a list with, given where it sits.
///
/// Three cases, in the order they are decided:
/// 1. Nested inside a list item — the parent item already provides the
///    rhythm, so the list adds nothing below.
/// 2. Last thing in its block — the block boundary provides the gap.
/// 3. Otherwise — a full section gap before prose, a tighter one before
///    another list.
MarkdownListSpacing getMarkdownListSpacing(
  MarkdownListNode node,
  Object? parent,
) {
  if (_hasListItemAncestor(parent)) {
    return const MarkdownListSpacing(
      marginTop: markdownListMarginTop,
      marginBottom: markdownNestedListMarginBottom,
    );
  }

  final nextType = getMarkdownNextSiblingType(node, parent);
  // Deviation: upstream's `!nextType` is a truthiness test, so a sibling whose
  // `type` is the empty string is treated as "no sibling". Matched exactly with
  // an explicit empty check rather than a null check alone.
  if (nextType == null || nextType.isEmpty) {
    return const MarkdownListSpacing(
      marginTop: markdownListMarginTop,
      marginBottom: markdownTerminalListMarginBottom,
    );
  }

  return MarkdownListSpacing(
    marginTop: markdownListMarginTop,
    marginBottom: _isMarkdownListType(nextType)
        ? markdownListMarginBottomToList
        : markdownListMarginBottomToProse,
  );
}

/// The marker to render in front of one list item.
///
/// Anything that is not demonstrably inside an ordered list gets a bullet —
/// including a bare `list_item` whose list ancestor was not passed. Guessing a
/// number there would restart every fragment at 1, which reads worse than a
/// bullet.
MarkdownListMarker getMarkdownListMarker(
  MarkdownListNode node,
  Object? parent,
) {
  final listParent = _nearestListParent(parent);
  if (listParent == null || listParent.type != 'ordered_list') {
    return const MarkdownListMarker(
      isOrdered: false,
      marker: _markdownListBullet,
    );
  }

  final orderedIndex = _orderedListItemIndex(node, listParent);
  final orderedStart = _parseOrderedListStart(listParent);
  final markup = node.markup;
  final orderedMarkup = markup != null && markup.isNotEmpty
      ? markup
      : _defaultOrderedListMarkup;

  return MarkdownListMarker(
    isOrdered: true,
    marker: '${_formatJsNumber(orderedStart + orderedIndex)}$orderedMarkup',
  );
}

// ---------------------------------------------------------------------------
// schedule-format.ts
// ---------------------------------------------------------------------------

/// The units a repeating interval is expressed in.
///
/// Upstream's `IntervalUnit` string union. The repo already carries a private
/// copy of this in `state/schedule_row_model.dart` for its internal cadence
/// label; this is the public one the schedule *form* needs to round-trip a
/// user's chosen number and unit.
enum IntervalUnit {
  minutes(Duration.millisecondsPerMinute, 'minute'),
  hours(Duration.millisecondsPerHour, 'hour'),
  days(Duration.millisecondsPerDay, 'day');

  const IntervalUnit(this.milliseconds, this.noun);

  /// How many milliseconds one of this unit is.
  final int milliseconds;

  /// The singular noun the cadence label pluralizes.
  final String noun;
}

/// An interval split into the largest unit that divides it evenly.
final class IntervalParts {
  const IntervalParts({required this.value, required this.unit});

  final int value;
  final IntervalUnit unit;

  @override
  bool operator ==(Object other) =>
      other is IntervalParts && value == other.value && unit == other.unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'IntervalParts($value, ${unit.name})';
}

/// Splits a millisecond interval into the coarsest whole unit it fits.
///
/// A non-positive or non-finite interval falls back to "every 1 hour" rather
/// than erroring: this feeds a form field, and an unusable stored value should
/// present as a sane default the user can correct, not as a blank.
///
/// Anything that divides neither into days nor hours is rounded to the nearest
/// minute and floored at 1, so a sub-minute interval still shows as a minute
/// rather than as zero.
IntervalParts everyMsToParts(num ms) {
  if (!_isFinite(ms) || ms <= 0) {
    return const IntervalParts(value: 1, unit: IntervalUnit.hours);
  }
  for (final unit in const [IntervalUnit.days, IntervalUnit.hours]) {
    if (ms % unit.milliseconds == 0) {
      return IntervalParts(value: (ms / unit.milliseconds).toInt(), unit: unit);
    }
  }
  return IntervalParts(
    value: math.max(1, (ms / IntervalUnit.minutes.milliseconds).round()),
    unit: IntervalUnit.minutes,
  );
}

/// The inverse of [everyMsToParts]: a user's number and unit as milliseconds.
///
/// A non-finite or sub-1 value collapses to 1, so the round trip through a form
/// field can never produce a zero or negative cadence that the scheduler would
/// spin on.
int partsToEveryMs(num value, IntervalUnit unit) {
  final normalized = _isFinite(value) ? math.max(1, value.round()) : 1;
  return normalized * unit.milliseconds;
}

/// Whether [schedule] creates a fresh agent each run, as opposed to poking an
/// existing one.
///
/// The distinction drives the whole surface: a new-agent record is a "Schedule"
/// with its own project and provider settings, while an agent-targeted record
/// is a "Heartbeat" that only carries a prompt.
bool isNewAgentSchedule(ScheduleSummary schedule) =>
    schedule.target is NewAgentScheduleTarget;

// ---------------------------------------------------------------------------
// os-notifications.ts
// ---------------------------------------------------------------------------

/// The custom event name a web build dispatches when an OS notification is
/// clicked, so an already-open app can route in-place instead of reloading.
const String webNotificationClickEvent = 'paseo:web-notification-click';

/// What an OS notification says and which entity it points at.
final class OsNotificationPayload {
  const OsNotificationPayload({required this.title, this.body, this.data});

  final String title;
  final String? body;

  /// The routing hints (`serverId`, `agentId`, `workspaceId`, `terminalId`)
  /// that a click resolves against. Untyped because it crosses a serialization
  /// boundary and older daemons wrote different key sets.
  final Map<String, Object?>? data;

  @override
  bool operator ==(Object other) =>
      other is OsNotificationPayload &&
      title == other.title &&
      body == other.body &&
      _mapEquals(data, other.data);

  @override
  int get hashCode => Object.hash(
    title,
    body,
    data == null
        ? null
        : Object.hashAllUnordered([
            for (final entry in data!.entries)
              Object.hash(entry.key, entry.value),
          ]),
  );

  @override
  String toString() => 'OsNotificationPayload($title, $body, $data)';
}

/// The detail carried on the click event the app listens for.
final class WebNotificationClickDetail {
  const WebNotificationClickDetail({this.data});

  final Map<String, Object?>? data;

  @override
  bool operator ==(Object other) =>
      other is WebNotificationClickDetail && _mapEquals(data, other.data);

  @override
  int get hashCode => data == null
      ? 0
      : Object.hashAllUnordered([
          for (final entry in data!.entries)
            Object.hash(entry.key, entry.value),
        ]);

  @override
  String toString() => 'WebNotificationClickDetail($data)';
}

bool _mapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// The browser's notification permission state.
///
/// Upstream compares the raw string against `"granted"` and `"denied"` and
/// treats everything else — including the literal `"default"` and any future
/// value — as "not yet decided". [prompt] is that third case.
enum WebNotificationPermission { granted, denied, prompt }

/// A posted web notification, narrowed to the one thing this module does with
/// it.
abstract interface class WebNotificationHandle {
  /// Registers a click handler. Called at most once per notification.
  void addClickListener(void Function() listener);
}

/// The Web Notification API, narrowed to what this module uses.
abstract interface class WebNotificationBackend {
  /// The current permission state.
  WebNotificationPermission get permission;

  /// The browser's `Notification.requestPermission`, or null when the backend
  /// does not expose one — upstream then behaves as if the answer were
  /// [WebNotificationPermission.denied].
  Future<WebNotificationPermission> Function()? get requestPermission;

  /// Posts a notification and returns a handle to it.
  WebNotificationHandle create({
    required String title,
    String? body,
    Map<String, Object?>? data,
    String? icon,
  });
}

/// The host capabilities [OsNotifier] needs.
///
/// Injected rather than reached for so that every branch — native, desktop
/// bridge, web with and without permission, web with and without an event bus —
/// is independently reachable in a test. There is no plugin dependency here on
/// purpose: this library states the *policy*, and `core/desktop/
/// notification_service.dart` is one possible [desktopSender].
abstract interface class OsNotificationHost {
  /// Upstream's `isNative`. Mobile notifications are remote push only, so a
  /// native host never posts locally.
  bool get isNative;

  /// The desktop shell's notification bridge, or null when there is none.
  /// Preferred over the web backend whenever present, because the shell can
  /// post to the real OS notification centre.
  Future<bool> Function(OsNotificationPayload payload)? get desktopSender;

  /// The browser Notification API, or null when unavailable.
  WebNotificationBackend? get webNotifications;

  /// The icon to decorate a web notification with, or null for none.
  ///
  /// Deviation: upstream resolves this from a bundled asset and memoizes it in
  /// a module-level slot. Asset resolution is a host concern with no pure
  /// analogue, so it moves to the host — along with any caching it wants.
  String? get notificationIconUrl;

  /// Dispatches the in-app click event.
  ///
  /// Mirrors DOM `dispatchEvent` exactly, because upstream's "did the app
  /// handle this?" test is literally `!dispatchEvent(event)`:
  /// - null — there is no event bus at all (no `dispatchEvent`, or no
  ///   `CustomEvent`); upstream treats this as *unhandled*.
  /// - true — the event ran to completion and nothing called `preventDefault`,
  ///   i.e. no listener claimed it.
  /// - false — a listener called `preventDefault`, i.e. the app claimed it.
  bool? dispatchWebNotificationClick(WebNotificationClickDetail detail);

  /// Navigates the whole document to [route]. Upstream's
  /// `location.assign(route)` fallback; a host with no location should no-op.
  void navigateToRoute(String route);
}

/// Whether a notification click has somewhere to go.
///
/// Note what is *not* here: `terminalId`. A terminal-only payload gets no click
/// handler even though [buildNotificationRoute] could route it. That is
/// upstream's behavior and it is reproduced rather than widened, because
/// widening it would start opening terminals on click for payloads that have
/// never done so.
bool hasNotificationClickTarget(Map<String, Object?>? data) {
  final target = resolveNotificationTarget(data);
  return target.serverId != null ||
      target.agentId != null ||
      target.workspaceId != null;
}

/// Posts OS notifications and routes their clicks through one [OsNotificationHost].
///
/// A class rather than free functions because upstream keeps a module-level
/// in-flight permission request so that N notifications arriving at once
/// produce one browser prompt, not N. That state has to live somewhere; here it
/// lives with the host it belongs to, which also makes it resettable per test.
final class OsNotifier {
  OsNotifier(this.host);

  final OsNotificationHost host;

  /// The permission prompt currently in flight, shared by every concurrent
  /// caller.
  Future<bool>? _permissionRequest;

  /// Asks for notification permission if it has not been decided yet.
  ///
  /// Returns false on native without prompting: native builds receive remote
  /// push and never post locally, so a local permission would be meaningless.
  Future<bool> ensureOsNotificationPermission() async {
    if (host.isNative) {
      return false;
    }
    return _ensureNotificationPermission();
  }

  Future<bool> _ensureNotificationPermission() async {
    final backend = host.webNotifications;
    if (backend == null) {
      return false;
    }
    switch (backend.permission) {
      case WebNotificationPermission.granted:
        return true;
      case WebNotificationPermission.denied:
        return false;
      case WebNotificationPermission.prompt:
        break;
    }

    final inFlight = _permissionRequest;
    if (inFlight != null) {
      return inFlight;
    }

    final request = backend.requestPermission;
    final pending =
        (request == null
                ? Future<WebNotificationPermission>.value(
                    WebNotificationPermission.denied,
                  )
                : request())
            .then(
              (permission) => permission == WebNotificationPermission.granted,
            );
    _permissionRequest = pending;
    final result = await pending;
    // Only the caller that started the request clears the slot; concurrent
    // awaiters above return without touching it. Reproduced from upstream.
    _permissionRequest = null;
    return result;
  }

  /// Posts [payload], returning whether anything was actually shown.
  ///
  /// The ladder is native (never) -> desktop bridge -> web Notification. False
  /// is a real answer, not an error: a denied permission or a headless
  /// environment simply means the user will find out in-app instead.
  Future<bool> send(OsNotificationPayload payload) async {
    // Mobile/native notifications are remote push only.
    if (host.isNative) {
      return false;
    }

    final desktopSender = host.desktopSender;
    if (desktopSender != null) {
      return desktopSender(payload);
    }

    final backend = host.webNotifications;
    if (backend != null) {
      final granted = await _ensureNotificationPermission();
      if (granted) {
        final notification = backend.create(
          title: payload.title,
          body: payload.body,
          data: payload.data,
          icon: host.notificationIconUrl,
        );
        if (hasNotificationClickTarget(payload.data)) {
          notification.addClickListener(
            () => handleWebNotificationClick(payload.data),
          );
        }
        return true;
      }
    }

    return false;
  }

  /// Routes a click on a notification carrying [data].
  ///
  /// Gives the running app first refusal via the click event, and only falls
  /// back to a full navigation when nothing claimed it — a hard navigation
  /// would otherwise throw away in-memory state for a notification the app was
  /// perfectly able to handle in place.
  ///
  /// Public so a host that owns its own notification objects (a desktop shell,
  /// say) can reuse the same routing decision.
  void handleWebNotificationClick(Map<String, Object?>? data) {
    final dispatched = host.dispatchWebNotificationClick(
      WebNotificationClickDetail(data: data),
    );
    final handledByApp = dispatched == null ? false : !dispatched;
    if (!handledByApp) {
      host.navigateToRoute(buildNotificationRoute(data));
    }
  }
}
