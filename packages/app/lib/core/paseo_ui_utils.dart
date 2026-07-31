/// Port of six frozen Paseo 0.2.0 `utils/` modules that the UI layer leans on
/// but that carry no UI of their own. They are collected here because each is
/// a handful of pure functions plus, at most, one narrow host capability — too
/// small to deserve a library apiece, and all consumed by the same widget
/// surfaces (command palettes, comboboxes, the composer, message actions).
///
/// * `utils/score-match.ts` — the fuzzy ranking used by every filterable list.
///   **This is the single public home for it.** Three private copies exist in
///   this repo (`composer/agent_command_autocomplete.dart`,
///   `composer/provider_model_selection.dart`, `ui/paseo_control_geometry.dart`);
///   this implementation is behaviourally identical to all three and is meant
///   to replace them.
/// * `utils/web-focus.ts` — retry focus across animation frames, because a
///   freshly mounted or freshly revealed input is routinely not focusable on
///   the frame the caller asks.
/// * `utils/app-visibility.ts` — whether the app is on screen, and whether it
///   is on screen *and* frontmost. Two different answers, deliberately.
/// * `utils/format-shortcut.ts` — keyboard shortcut display strings.
/// * `utils/rich-clipboard.ts` — put markdown on the clipboard as both plain
///   text and HTML, degrading to plain text whenever the rich path is denied.
/// * `utils/assistant-image-source.ts` — decide whether an image reference in
///   assistant output can be handed straight to an image widget or has to be
///   fetched through the daemon's file RPC.
///
/// Every host capability upstream reaches for through a browser global
/// (`requestAnimationFrame`, `document.visibilityState`, `document.hasFocus`,
/// `navigator.clipboard`) is injected here as a plain function or a small
/// value class, so nothing in this library touches `dart:html`, a plugin, or
/// `WidgetsBinding`. That keeps all of it testable without a host and reusable
/// from the desktop shell, which has no `document` at all.
library;

import '../attachments/paseo_attachment_rules.dart' show localFileSourceToPath;
import 'path.dart' show isAbsolutePath;

// ---------------------------------------------------------------------------
// utils/score-match.ts
// ---------------------------------------------------------------------------

/// How well a query matched a piece of text. **Lower is better on every field.**
///
/// [tier] is the match class, and it dominates: `0` exact (or empty query),
/// `1` whole word, `2` string prefix that does not complete a word, `3`
/// word-boundary start that does not complete a word, `4` substring buried
/// inside a word, `5` fuzzy subsequence. [offset] is how far into the text the
/// match began, breaking ties within a tier so earlier hits win.
///
/// [spread] is how many characters a fuzzy match had to span and is `null` for
/// every non-fuzzy tier. The null is load-bearing rather than cosmetic:
/// [scoreTextFields] charges a spread-less match the *token length* instead of
/// zero, so a substring hit stays comparable against a fuzzy hit for the same
/// query. Collapsing `null` into `0` would silently make every substring match
/// look maximally tight.
final class MatchScore {
  const MatchScore({required this.tier, required this.offset, this.spread});

  final int tier;
  final int offset;
  final int? spread;

  @override
  bool operator ==(Object other) =>
      other is MatchScore &&
      other.tier == tier &&
      other.offset == offset &&
      other.spread == spread;

  @override
  int get hashCode => Object.hash(tier, offset, spread);

  @override
  String toString() =>
      'MatchScore(tier: $tier, offset: $offset, '
      'spread: $spread)';
}

/// Upstream tests `/[a-z0-9]/` — lowercase only, which is safe because both
/// query and text are lowercased before any boundary test runs.
final RegExp _wordCharacter = RegExp(r'[a-z0-9]');

final RegExp _whitespaceRun = RegExp(r'\s+');

/// Whether [ch] ends a word.
///
/// A `null` [ch] means "off the end of the text", which counts as a boundary.
/// Upstream passes `undefined` there and gets the same answer; JS also yields
/// `undefined` for an out-of-range index, which is why the two out-of-range
/// call sites below both map to `null` rather than to an empty string.
bool _isWordBoundaryChar(String? ch) {
  if (ch == null) return true;
  return !_wordCharacter.hasMatch(ch);
}

/// Best literal-substring hit, or `null` when [query] is not a substring.
///
/// Every occurrence is examined rather than just the first, because a later
/// occurrence can sit at a better boundary: `"ab"` in `"xxab x-ab-y"` scores
/// tier 1 at offset 7, not tier 4 at offset 2.
MatchScore? _scoreSubstringMatch(String query, String text) {
  MatchScore? best;
  var pos = 0;
  while (pos <= text.length - query.length) {
    final found = text.indexOf(query, pos);
    if (found == -1) break;
    final before = found > 0 ? text[found - 1] : null;
    final afterIndex = found + query.length;
    final after = afterIndex < text.length ? text[afterIndex] : null;
    final startsAtBoundary = found == 0 || _isWordBoundaryChar(before);
    final endsAtBoundary = _isWordBoundaryChar(after);
    final int tier;
    if (startsAtBoundary && endsAtBoundary) {
      tier = 1;
    } else if (found == 0) {
      tier = 2;
    } else if (startsAtBoundary) {
      tier = 3;
    } else {
      tier = 4;
    }
    if (best == null ||
        tier < best.tier ||
        (tier == best.tier && found < best.offset)) {
      best = MatchScore(tier: tier, offset: found);
    }
    pos = found + 1;
  }
  return best;
}

/// Greedy left-to-right subsequence match, or `null` when the query's
/// characters do not all appear in order.
///
/// Greedy, not optimal: the first viable character is always consumed, so the
/// reported [MatchScore.spread] is the span of *that* walk rather than the
/// tightest possible one. Frozen upstream behaviour, and cheap enough to run
/// per keystroke over a whole list.
MatchScore? _scoreSubsequenceMatch(String query, String text) {
  var queryIndex = 0;
  var firstIndex = -1;
  var lastIndex = -1;
  for (
    var textIndex = 0;
    textIndex < text.length && queryIndex < query.length;
    textIndex += 1
  ) {
    if (text[textIndex] != query[queryIndex]) continue;
    if (firstIndex == -1) firstIndex = textIndex;
    lastIndex = textIndex;
    queryIndex += 1;
  }

  if (queryIndex != query.length || firstIndex == -1) return null;
  return MatchScore(
    tier: 5,
    offset: firstIndex,
    spread: lastIndex - firstIndex + 1,
  );
}

/// Scores [query] against [text], case-insensitively, or `null` for no match.
///
/// An empty query matches everything at the best possible score, which is what
/// makes "no filter typed yet" and "filter typed and everything matched" the
/// same code path for callers. A substring hit always beats a fuzzy hit, so
/// fuzzy matching only ever *adds* results rather than reordering solid ones.
MatchScore? scoreMatch(String query, String text) {
  if (query.isEmpty) return const MatchScore(tier: 0, offset: 0);
  final q = query.toLowerCase();
  final t = text.toLowerCase();
  if (t == q) return const MatchScore(tier: 0, offset: 0);

  return _scoreSubstringMatch(q, t) ?? _scoreSubsequenceMatch(q, t);
}

/// Orders two scores best-first: tier, then offset, then spread.
///
/// Returns a negative number when [a] is the better match, mirroring the
/// comparator contract upstream feeds to `Array.prototype.sort`. A `null`
/// spread compares as `0` here — the *comparison* treats spread-less matches
/// as maximally tight, which is correct because they only ever compete against
/// other spread-less matches at tiers 0-4.
int compareMatchScores(MatchScore a, MatchScore b) {
  if (a.tier != b.tier) return a.tier - b.tier;
  if (a.offset != b.offset) return a.offset - b.offset;
  return (a.spread ?? 0) - (b.spread ?? 0);
}

/// Best combined score for a whitespace-separated [query] across [fields], or
/// `null` when any one token matched nothing anywhere.
///
/// Every token must land somewhere, which is what makes a multi-word query
/// narrow the result set instead of widening it. Tokens may land in different
/// fields — "feat pi" matches an item whose title holds `feat` and whose branch
/// holds `pi` — because each token independently picks its own best field.
///
/// A query that is empty or all whitespace yields the all-zero score rather
/// than `null`, so an untouched filter box keeps every row.
MatchScore? scoreTextFields(String query, List<String> fields) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(_whitespaceRun)
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) {
    return const MatchScore(tier: 0, offset: 0, spread: 0);
  }

  var tier = 0;
  var offset = 0;
  var spread = 0;
  for (final token in tokens) {
    MatchScore? best;
    for (final field in fields) {
      final score = scoreMatch(token, field);
      if (score != null &&
          (best == null || compareMatchScores(score, best) < 0)) {
        best = score;
      }
    }
    if (best == null) return null;
    tier += best.tier;
    offset += best.offset;
    // See [MatchScore.spread]: a non-fuzzy match is charged the token length so
    // it stays on the same scale as a fuzzy match of the same query.
    spread += best.spread ?? token.length;
  }
  return MatchScore(tier: tier, offset: offset, spread: spread);
}

// ---------------------------------------------------------------------------
// utils/web-focus.ts
// ---------------------------------------------------------------------------

/// Schedules [callback] on the next rendered frame.
///
/// Upstream this is the browser's `requestAnimationFrame`. It is a parameter
/// rather than a global so this module never depends on a host: on Flutter the
/// natural implementation is `WidgetsBinding.instance.addPostFrameCallback`,
/// and in tests it is a queue the test drains by hand.
typedef FrameScheduler = void Function(void Function() callback);

/// Repeatedly calls [focus] until [isFocused] reports success or [timeout]
/// elapses, returning a cancel callback.
///
/// Why retry at all: a freshly mounted, freshly revealed, or freshly re-parented
/// text input is routinely not focusable on the frame the caller asks for it.
/// One `focus()` call silently does nothing and the user is left typing into a
/// dead composer.
///
/// The first attempt is synchronous, so a target that *is* already focusable
/// never costs a frame — [onSuccess] can fire before this function returns.
/// Subsequent attempts are spaced two frames apart (a frame scheduled from
/// inside a frame), which upstream uses to let layout settle between tries.
///
/// Exceptions from [focus] are swallowed, matching upstream's bare `catch {}`:
/// a host that throws on focus is exactly the case the retry loop exists for,
/// and [isFocused] is the authority on whether it worked anyway.
///
/// [onSuccess] and [onTimeout] are mutually exclusive and each fire at most
/// once. Cancelling suppresses both.
///
/// Deviation from upstream, deliberately preserved: cancellation is checked at
/// the *start* of each attempt, not when a frame is scheduled. A cancelled loop
/// therefore still lets its already-scheduled frame pair run to completion —
/// they simply do nothing. Observably identical, and it keeps the cancel
/// callback free of any handle bookkeeping.
void Function() focusWithRetries({
  required void Function() focus,
  required bool Function() isFocused,
  required FrameScheduler scheduleFrame,
  Duration timeout = const Duration(milliseconds: 1500),
  DateTime Function()? now,
  void Function()? onSuccess,
  void Function()? onTimeout,
}) {
  final clock = now ?? DateTime.now;
  var cancelled = false;
  final deadline = clock().add(timeout);

  void tick() {
    if (cancelled) return;

    try {
      focus();
    } on Object {
      // ignore: a host that refuses focus is the reason this loop exists.
    }

    if (isFocused()) {
      onSuccess?.call();
      return;
    }

    // Upstream compares `Date.now() >= deadlineMs`, so landing exactly on the
    // deadline is a timeout, not another attempt.
    if (!clock().isBefore(deadline)) {
      onTimeout?.call();
      return;
    }

    scheduleFrame(() {
      scheduleFrame(tick);
    });
  }

  tick();

  return () {
    cancelled = true;
  };
}

// ---------------------------------------------------------------------------
// utils/app-visibility.ts
// ---------------------------------------------------------------------------

/// The app state string that means "running in the foreground".
///
/// Upstream types app state as a bare `string` (React Native's
/// `AppStateStatus`) and only ever compares it against this one value, so this
/// port keeps it a string rather than inventing an enum the wire never sees.
const String activeAppState = 'active';

/// Inputs for [isAppVisible].
///
/// [native] short-circuits the web-only checks: a native app has no document,
/// so app state alone decides. On web, [documentVisible] mirrors
/// `document.visibilityState === "visible"` — false for a backgrounded tab, a
/// minimised window, or a locked screen.
final class AppVisibilityInput {
  const AppVisibilityInput({
    required this.appState,
    required this.native,
    required this.documentVisible,
  });

  final String appState;
  final bool native;
  final bool documentVisible;
}

/// Inputs for [isAppActivelyVisible], adding whether this window holds focus.
///
/// Modelled as a subclass so a single value can be passed to both predicates,
/// which is how upstream's `extends`-ed interface is used at every call site.
final class ActiveAppVisibilityInput extends AppVisibilityInput {
  const ActiveAppVisibilityInput({
    required super.appState,
    required super.native,
    required super.documentVisible,
    required this.windowFocused,
  });

  final bool windowFocused;
}

/// Whether the app is on screen at all.
///
/// Deliberately indifferent to focus: a desktop window sitting behind another
/// window is still *visible*, so timelines keep streaming and read receipts
/// keep firing. Use [isAppActivelyVisible] for anything that should only happen
/// while the user is actually looking at this window.
bool isAppVisible(AppVisibilityInput input) =>
    input.appState == activeAppState && (input.native || input.documentVisible);

/// Whether the app is on screen *and* frontmost.
///
/// The stricter of the pair: this is what gates focus stealing, notification
/// suppression, and "mark as read" — actions that would be wrong to take for a
/// window the user can see but is not using.
bool isAppActivelyVisible(ActiveAppVisibilityInput input) =>
    isAppVisible(input) && (input.native || input.windowFocused);

/// The host facts [getIsAppVisible] and [getIsAppActivelyVisible] need.
///
/// Upstream reads these off globals and guards each with a `typeof` check, so
/// "there is no document" and "the document says X" are genuinely different
/// states. That distinction survives here as nullability: a `null`
/// [documentVisible] or [windowFocused] means the host cannot answer — no
/// `document`, or a `document` without a usable `hasFocus` — and upstream
/// treats an unanswerable question as `true`, since a native shell is always
/// considered visible and focused.
final class AppVisibilityHost {
  const AppVisibilityHost({
    required this.native,
    required this.currentAppState,
    this.documentVisible,
    this.windowFocused,
  });

  /// Whether this build runs on a native shell rather than the web.
  final bool native;

  /// The host's current app-state string, read lazily because it changes.
  final String Function() currentAppState;

  /// `null` when the host has no document to ask.
  final bool Function()? documentVisible;

  /// `null` when the host has no document, or no way to report window focus.
  final bool Function()? windowFocused;
}

/// [isAppVisible] against live host state.
///
/// [appState] overrides the host's own reading, matching upstream's defaulted
/// parameter — callers that already hold a fresher app state from a change
/// event pass it rather than re-reading a value that may have moved on.
bool getIsAppVisible(AppVisibilityHost host, [String? appState]) =>
    isAppVisible(
      AppVisibilityInput(
        appState: appState ?? host.currentAppState(),
        native: host.native,
        documentVisible: host.documentVisible?.call() ?? true,
      ),
    );

/// [isAppActivelyVisible] against live host state. See [getIsAppVisible].
bool getIsAppActivelyVisible(AppVisibilityHost host, [String? appState]) =>
    isAppActivelyVisible(
      ActiveAppVisibilityInput(
        appState: appState ?? host.currentAppState(),
        native: host.native,
        documentVisible: host.documentVisible?.call() ?? true,
        windowFocused: host.windowFocused?.call() ?? true,
      ),
    );

// ---------------------------------------------------------------------------
// utils/format-shortcut.ts
// ---------------------------------------------------------------------------

/// Which shortcut vocabulary to render in.
///
/// Upstream's `"mac" | "non-mac"` union. Only two spellings exist because the
/// distinction that matters is glyphs-with-no-separator versus
/// words-joined-by-plus; Linux and Windows differ only in what `meta` is called
/// and that is handled inside the non-mac branch.
enum ShortcutOs { mac, nonMac }

/// Display glyphs for keys whose names would otherwise be printed literally.
const Map<String, String> _keyDisplay = {
  'Backspace': '\u232B',
  'Enter': '\u23CE',
  'Esc': 'Esc',
  'Space': '\u2423',
  'Left': '\u2190',
  'Right': '\u2192',
  'Up': '\u2191',
  'Down': '\u2193',
};

/// Modifier order on macOS, which is a platform convention rather than the
/// order the caller happened to list them in: control, option, shift, command.
const List<String> _macModifierOrder = ['ctrl', 'alt', 'shift', 'mod', 'meta'];

const Map<String, String> _macModifierSymbols = {
  'mod': '\u2318',
  'alt': '\u2325',
  'ctrl': '\u2303',
  'meta': '\u2318',
};

const Map<String, String> _nonMacModifierLabels = {
  'mod': 'Ctrl',
  'shift': 'Shift',
  'alt': 'Alt',
  'ctrl': 'Ctrl',
  'meta': 'Win',
};

/// Single characters are upper-cased (`b` renders as `B`); multi-character key
/// names pass through untouched unless [_keyDisplay] has a glyph for them.
///
/// An empty key stays empty and is dropped downstream, reproducing upstream's
/// `if (!key) return ""` followed by `.filter(Boolean)`.
String _normalizeKey(String key) {
  if (key.isEmpty) return '';
  final display = _keyDisplay[key];
  if (display != null) return display;
  if (key.length == 1) return key.toUpperCase();
  return key;
}

/// Renders [keys] as the shortcut string shown in menus, tooltips, and badges.
///
/// Modifier tokens are the lowercase names the shortcut engine uses (`mod`,
/// `shift`, `alt`, `ctrl`, `meta`); everything else is a literal key name.
/// `mod` is the platform command key — Command on macOS, Control elsewhere —
/// which is why a single binding renders correctly on both.
///
/// Three behaviours are frozen and easy to break by "tidying":
///
/// * On macOS modifiers are re-ordered into platform order and glyphs are
///   concatenated with no separator (`⌘B`), because that is how macOS itself
///   draws them.
/// * Shift is spelled out rather than drawn as `⇧`, and its presence flips the
///   whole macOS string into plus-separated form (`Shift+⌘+P`). The word is
///   wider than a glyph and would collide with its neighbours unseparated.
/// * Duplicate modifiers collapse on macOS but not on non-mac. Upstream builds
///   a `Set` for the macOS branch only; the non-mac branch maps element-wise,
///   so `["mod", "mod", "B"]` renders `⌘B` but `Ctrl+Ctrl+B`. Preserved rather
///   than fixed, since call sites never pass duplicates and a "fix" would be an
///   unpinned behaviour change.
///
/// Deviation: upstream opens with `typeof k === "string" ? k : String(k)`, a
/// guard against untyped JS callers. Dart's type system makes it unreachable,
/// so it is dropped.
String formatShortcut(List<String> keys, ShortcutOs os) {
  if (os == ShortcutOs.mac) {
    final modifierSet = keys.toSet();
    final mods = [
      for (final modifier in _macModifierOrder)
        if (modifierSet.contains(modifier))
          if (modifier == 'shift') 'Shift' else _macModifierSymbols[modifier]!,
    ];
    final main = keys
        .where((key) => !_macModifierOrder.contains(key))
        .map(_normalizeKey)
        .join();
    if (mods.contains('Shift')) {
      return [...mods, main].where((part) => part.isNotEmpty).join('+');
    }
    return '${mods.join()}$main';
  }

  return keys
      .map((key) => _nonMacModifierLabels[key] ?? _normalizeKey(key))
      .where((part) => part.isNotEmpty)
      .join('+');
}

// ---------------------------------------------------------------------------
// utils/rich-clipboard.ts
// ---------------------------------------------------------------------------

/// The two clipboard flavours a markdown copy writes.
///
/// Upstream's `"text/plain" | "text/html"` union. Both are always written
/// together: a paste target that understands HTML gets formatted output, and
/// everything else falls back to the plain flavour of the *same* clipboard
/// entry rather than to a second, stale one.
enum ClipboardMimeType {
  plainText('text/plain'),
  html('text/html');

  const ClipboardMimeType(this.wireValue);

  /// The MIME string the clipboard API keys off.
  final String wireValue;
}

/// One clipboard flavour's payload.
///
/// Stands in for the browser `Blob` upstream constructs. Only two things about
/// that Blob are observable — its text and its declared type — so this carries
/// exactly those, which keeps the module free of `dart:html` and lets tests
/// assert on the payload without decoding anything.
final class ClipboardBlob {
  const ClipboardBlob({required this.mimeType, required this.text});

  final ClipboardMimeType mimeType;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ClipboardBlob &&
      other.mimeType == mimeType &&
      other.text == text;

  @override
  int get hashCode => Object.hash(mimeType, text);

  @override
  String toString() =>
      'ClipboardBlob(${mimeType.wireValue}, ${text.length} chars)';
}

/// A clipboard that can carry more than one flavour at once.
///
/// [supportsHtml] is asked separately from [write] because a host can expose
/// the multi-flavour API while refusing `text/html` specifically; asking first
/// avoids burning a write attempt that is guaranteed to fail.
final class RichClipboardWriter {
  const RichClipboardWriter({required this.supportsHtml, required this.write});

  final bool Function() supportsHtml;
  final Future<void> Function(Map<ClipboardMimeType, ClipboardBlob> data) write;
}

/// Renders markdown source to an HTML fragment.
///
/// Deviation from upstream, and the largest one in this library: upstream
/// constructs a `markdown-it` renderer inside the module
/// (`{ html: false, linkify: true, typographer: true }`) and calls it directly.
/// There is no markdown-it in this app's dependency set and adding one is out
/// of scope for a port, so the renderer is injected instead. Everything that
/// makes the clipboard path *correct* — the `<meta charset>` prefix, the
/// attempt-then-degrade write, the plain-text fallback — is ported exactly; only
/// the markdown-to-HTML step is supplied by the caller.
///
/// Implementations must not emit raw HTML from the source (upstream's
/// `html: false`). Assistant output is untrusted, and this string is handed to
/// whatever application the user pastes into.
typedef MarkdownHtmlRenderer = String Function(String markdown);

/// Both flavours of one markdown copy, ready to hand to a clipboard.
final class MarkdownClipboardContent {
  const MarkdownClipboardContent({required this.plainText, required this.html});

  /// The markdown source, unmodified. What a plain-text target receives.
  final String plainText;

  /// An HTML fragment prefixed with `<meta charset="utf-8">`.
  final String html;

  @override
  bool operator ==(Object other) =>
      other is MarkdownClipboardContent &&
      other.plainText == plainText &&
      other.html == html;

  @override
  int get hashCode => Object.hash(plainText, html);

  @override
  String toString() =>
      'MarkdownClipboardContent(plainText: $plainText, '
      'html: $html)';
}

/// Everything [writeMarkdownToRichClipboard] needs from its host.
///
/// [richWriter] is nullable because most hosts have no multi-flavour clipboard
/// at all; [writePlainText] is not, because it is the floor every host must
/// provide and the fallback the rich path degrades to.
final class MarkdownClipboardEnvironment {
  const MarkdownClipboardEnvironment({
    required this.renderMarkdownHtml,
    required this.writePlainText,
    this.richWriter,
  });

  final MarkdownHtmlRenderer renderMarkdownHtml;
  final Future<void> Function(String text) writePlainText;
  final RichClipboardWriter? richWriter;
}

/// Builds both clipboard flavours from [markdown].
///
/// The `<meta charset="utf-8">` prefix is not decoration: several rich-text
/// targets (Word, Outlook, some webviews) decode a pasted HTML fragment as
/// Latin-1 without it, mangling every non-ASCII character in the copy.
MarkdownClipboardContent createMarkdownClipboardContent(
  String markdown,
  MarkdownHtmlRenderer renderMarkdownHtml,
) => MarkdownClipboardContent(
  plainText: markdown,
  html: '<meta charset="utf-8">${renderMarkdownHtml(markdown)}',
);

/// Copies [markdown] to the clipboard, formatted where possible.
///
/// The rich path is best-effort by design. Hosts advertise a multi-flavour
/// clipboard and then reject the write depending on focus, permission state, or
/// browser policy — often intermittently — so a failed rich write silently
/// degrades to plain text rather than surfacing an error the user cannot act
/// on. Losing formatting is a far better outcome than a copy that does nothing.
///
/// A host with no [MarkdownClipboardEnvironment.richWriter], or one whose
/// writer reports no HTML support, skips straight to the plain path without
/// rendering any markdown.
Future<void> writeMarkdownToRichClipboard(
  String markdown,
  MarkdownClipboardEnvironment environment,
) async {
  final richWriter = environment.richWriter;
  if (richWriter != null && richWriter.supportsHtml()) {
    final content = createMarkdownClipboardContent(
      markdown,
      environment.renderMarkdownHtml,
    );
    try {
      await richWriter.write({
        ClipboardMimeType.plainText: ClipboardBlob(
          mimeType: ClipboardMimeType.plainText,
          text: content.plainText,
        ),
        ClipboardMimeType.html: ClipboardBlob(
          mimeType: ClipboardMimeType.html,
          text: content.html,
        ),
      });
      return;
    } on Object {
      // Fall through to the plain-text path. Some webviews expose rich
      // clipboard APIs but deny writes depending on focus, permissions, or
      // browser policy.
    }
  }

  await environment.writePlainText(markdown);
}

// ---------------------------------------------------------------------------
// utils/assistant-image-source.ts
// ---------------------------------------------------------------------------

/// How an image referenced by assistant output should be loaded.
///
/// Upstream's `{ kind: "direct" } | { kind: "file_rpc" }` union, as a sealed
/// hierarchy so callers must handle both arms.
sealed class AssistantImageSourceResolution {
  const AssistantImageSourceResolution();
}

/// The reference is already a URI an image widget can load itself.
///
/// Covers `http:`, `https:`, `data:` and `blob:` — the schemes that need no
/// filesystem access and therefore no daemon round trip.
final class AssistantImageDirectSource extends AssistantImageSourceResolution {
  const AssistantImageDirectSource({required this.uri});

  final String uri;

  @override
  bool operator ==(Object other) =>
      other is AssistantImageDirectSource && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'AssistantImageDirectSource($uri)';
}

/// The reference is a file on the agent's machine and must be read over the
/// daemon's file RPC.
///
/// [cwd] is the root the read is *scoped to*, not merely a base for joining:
/// the daemon refuses reads that escape it. That is why an in-workspace path
/// keeps the workspace as its root while an out-of-workspace absolute path
/// falls back to the filesystem (or drive) root — the alternative is a read
/// that is rejected rather than an image that fails to draw.
final class AssistantImageFileRpcSource extends AssistantImageSourceResolution {
  const AssistantImageFileRpcSource({required this.cwd, required this.path});

  final String cwd;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is AssistantImageFileRpcSource &&
      other.cwd == cwd &&
      other.path == path;

  @override
  int get hashCode => Object.hash(cwd, path);

  @override
  String toString() => 'AssistantImageFileRpcSource(cwd: $cwd, path: $path)';
}

/// Schemes an image widget can load without touching the filesystem. Anchored
/// and case-insensitive, matching upstream's `/^(https?:|data:|blob:)/i`.
final RegExp _directImageUriScheme = RegExp(
  r'^(https?:|data:|blob:)',
  caseSensitive: false,
);

/// Decides how to load the image at [source], or `null` when it cannot be
/// loaded at all.
///
/// [workspaceRoot] is the agent's working directory, used to scope relative
/// paths and to recognise absolute paths that live inside the workspace.
/// Without it, a relative path is unresolvable and returns `null` — guessing a
/// root would produce a read against the wrong machine-local directory.
///
/// Note the scheme test runs against the *raw* trimmed source, before any
/// path normalisation: `file://` URIs are deliberately not "direct", because
/// an image widget cannot read the agent's filesystem even when the agent is
/// local. They are normalised into a file RPC like any other local path.
AssistantImageSourceResolution? resolveAssistantImageSource({
  required String source,
  String? workspaceRoot,
}) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  if (_directImageUriScheme.hasMatch(trimmed)) {
    return AssistantImageDirectSource(uri: trimmed);
  }

  final readTarget = _resolveFilePreviewReadTarget(
    path: localFileSourceToPath(trimmed),
    workspaceRoot: workspaceRoot,
  );
  if (readTarget == null) {
    return null;
  }

  return AssistantImageFileRpcSource(
    cwd: readTarget.cwd,
    path: readTarget.path,
  );
}

// ---------------------------------------------------------------------------
// file-explorer/preview-target.ts (private dependency of
// assistant-image-source.ts)
// ---------------------------------------------------------------------------
//
// Upstream `assistant-image-source.ts` imports `resolveFilePreviewReadTarget`
// from `file-explorer/preview-target.ts`. That module is outside this port's
// cluster and has no shared public Dart home yet — `file_explorer/
// file_explorer_rules.dart` covers a different set of upstream files — so it is
// carried privately here. When `preview-target.ts` is ported for real, this
// copy should be deleted in favour of it.

/// Where the daemon should read a file from: a scope root plus a path.
final class _FilePreviewReadTarget {
  const _FilePreviewReadTarget({required this.cwd, required this.path});

  final String cwd;
  final String path;
}

final RegExp _bareDriveRoot = RegExp(r'^[A-Za-z]:[\\/]?$');
final RegExp _trailingSeparators = RegExp(r'[\\/]+$');
final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:/');
final RegExp _driveRootPrefix = RegExp(r'^([A-Za-z]:)[\\/]');
final RegExp _uncRootPrefix = RegExp(r'^(\\\\[^\\]+\\[^\\]+)');

/// Strips trailing separators, except from a root that *is* a separator —
/// `/` and `C:\` would otherwise be trimmed into nothing and an empty drive
/// letter respectively.
String _trimTrailingSeparators(String value) {
  if (value == '/' || _bareDriveRoot.hasMatch(value)) {
    return value.replaceAll(r'\', '/');
  }
  return value.replaceAll(_trailingSeparators, '');
}

/// Normalises a path for containment comparison only — never for use as a path.
///
/// Separators are unified and the Windows drive letter upper-cased, so `c:/repo`
/// and `C:\repo\` compare equal. Case is *not* folded beyond the drive letter:
/// Windows is case-insensitive but the daemon may be running on a
/// case-sensitive filesystem, and folding here would let a path escape its
/// declared root.
String _normalizeForPathComparison(String value) {
  final normalized = _trimTrailingSeparators(value.replaceAll(r'\', '/'));
  if (_drivePrefix.hasMatch(normalized)) {
    return normalized.substring(0, 1).toUpperCase() + normalized.substring(1);
  }
  return normalized;
}

/// Whether [candidatePath] is [rootPath] or sits beneath it.
///
/// The `${root}/` suffix test is what stops `/repo-backup` from being treated
/// as inside `/repo`.
bool _isPathWithinRoot(String candidatePath, String rootPath) {
  final candidate = _normalizeForPathComparison(candidatePath);
  final root = _normalizeForPathComparison(rootPath);
  if (candidate.isEmpty || root.isEmpty) {
    return false;
  }
  if (root == '/') {
    return candidate.startsWith('/');
  }
  if (candidate == root) {
    return true;
  }
  return candidate.startsWith('$root/');
}

/// The widest root that still contains [value]: `/`, `C:/`, or a UNC share.
///
/// A UNC root stops at `\\server\share` because the share, not the server, is
/// the mountable unit.
String? _deriveFilesystemRootFromAbsolutePath(String value) {
  if (value.startsWith('/')) {
    return '/';
  }

  final driveMatch = _driveRootPrefix.firstMatch(value);
  if (driveMatch != null) {
    return '${driveMatch.group(1)}/';
  }

  final uncMatch = _uncRootPrefix.firstMatch(value);
  if (uncMatch != null) {
    return uncMatch.group(1);
  }

  return null;
}

bool _isHomeRelativePath(String value) =>
    value == '~' || value.startsWith('~/') || value.startsWith(r'~\');

/// Resolves a preview path to a daemon read target, or `null` when it cannot be
/// scoped to any root.
///
/// The order of the checks is the behaviour: `~` paths win outright (the daemon
/// expands them itself, so no local root applies), then relative paths need the
/// workspace, then absolute paths prefer the workspace when they are inside it
/// and fall back to the filesystem root when they are not.
_FilePreviewReadTarget? _resolveFilePreviewReadTarget({
  required String path,
  String? workspaceRoot,
}) {
  final previewPath = path.trim();
  if (previewPath.isEmpty) {
    return null;
  }

  if (_isHomeRelativePath(previewPath)) {
    return _FilePreviewReadTarget(cwd: '~', path: previewPath);
  }

  final root = workspaceRoot?.trim();
  // Upstream's `input.workspaceRoot?.trim()` is then tested for JS truthiness,
  // so an empty or all-whitespace root is indistinguishable from an absent one.
  final hasRoot = root != null && root.isNotEmpty;

  if (!isAbsolutePath(previewPath)) {
    if (!hasRoot || !isAbsolutePath(root)) {
      return null;
    }
    return _FilePreviewReadTarget(cwd: root, path: previewPath);
  }

  if (hasRoot && isAbsolutePath(root) && _isPathWithinRoot(previewPath, root)) {
    return _FilePreviewReadTarget(cwd: root, path: previewPath);
  }

  final filesystemRoot = _deriveFilesystemRootFromAbsolutePath(previewPath);
  if (filesystemRoot == null) {
    return null;
  }

  return _FilePreviewReadTarget(cwd: filesystemRoot, path: previewPath);
}
