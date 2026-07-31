/// Port of Paseo 0.2.0's render-time decision rules — four frozen modules that
/// each answer "what exactly do we draw here?" without touching a store, a
/// theme or a network client:
///
/// - `components/markdown/part-groups.ts` — pairs a run of inline images that
///   flow with text against the lead paragraph that follows them, so GitHub
///   style status badges sit beside their heading instead of stacking above it.
/// - `components/markdown-text-style.ts` — resolves a style prop down to plain
///   values before it crosses a third-party text boundary, dropping the style
///   engine's private tracking metadata.
/// - `components/root-error-details.ts` — turns an arbitrary caught value into
///   the text the crash screen shows, and is itself never allowed to throw.
/// - `components/worktree-setup-callout-policy.ts` — decides whether the
///   sidebar nags about missing worktree setup commands, and what that nag says.
///
/// Grouped into one library because none of them is large enough to own a file
/// and all four are pure functions the render layer calls synchronously.
library;

import 'dart:convert';

import '../composer/composer_input_labels.dart';
import 'host_routes.dart';

// ---------------------------------------------------------------------------
// markdown/part-groups.ts
// ---------------------------------------------------------------------------

/// One piece of a message body after the html-ish splitter has run.
///
/// Upstream this is the structural union `MarkdownDisplayPart` from
/// `components/markdown/html-ish.ts`. That splitter is not ported yet, so the
/// three variants are declared here as a sealed hierarchy — grouping is the
/// only consumer that exists on the Dart side so far, and re-declaring them
/// later next to the splitter would fork the type.
///
/// Value equality is implemented on every variant because grouping is
/// specified in terms of deep comparison upstream (`toEqual`), and callers
/// diff group lists to decide whether a re-render is needed.
sealed class MarkdownDisplayPart {
  const MarkdownDisplayPart();
}

/// A run of literal markdown source.
final class MarkdownTextPart extends MarkdownDisplayPart {
  const MarkdownTextPart(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is MarkdownTextPart && other.text == text;

  @override
  int get hashCode => Object.hash('markdown', text);

  @override
  String toString() => 'MarkdownTextPart($text)';
}

/// A collapsed `<details>` block, with its body kept both as raw markdown and
/// (optionally) as an already-split part list.
final class MarkdownDetailsPart extends MarkdownDisplayPart {
  const MarkdownDetailsPart({
    required this.summary,
    required this.body,
    this.bodyParts,
  });

  final String summary;
  final String body;

  /// Null models upstream's absent `bodyParts?` — an empty list is a distinct,
  /// meaningful value (a details block whose body split into nothing).
  final List<MarkdownDisplayPart>? bodyParts;

  @override
  bool operator ==(Object other) =>
      other is MarkdownDetailsPart &&
      other.summary == summary &&
      other.body == body &&
      _listEquals(other.bodyParts, bodyParts);

  @override
  int get hashCode => Object.hash(
    'details',
    summary,
    body,
    bodyParts == null ? null : Object.hashAll(bodyParts!),
  );

  @override
  String toString() => 'MarkdownDetailsPart($summary)';
}

/// An image lifted out of the markdown stream so it can be rendered as a real
/// image widget.
final class MarkdownInlineImagePart extends MarkdownDisplayPart {
  const MarkdownInlineImagePart({
    required this.alt,
    required this.src,
    this.href,
    this.width,
    this.height,
    this.flowsWithText = false,
  });

  final String alt;
  final String src;
  final String? href;

  /// Intrinsic pixel dimensions when the source declared them; `double`
  /// because the renderer feeds them straight into layout constraints.
  final double? width;
  final double? height;

  /// Whether the image opened a line that text then continued on.
  ///
  /// Upstream this is `boolean | undefined` and every read is a truthiness
  /// check, so absent and `false` are indistinguishable in behaviour; the Dart
  /// port collapses them to a non-nullable `false` default.
  final bool flowsWithText;

  @override
  bool operator ==(Object other) =>
      other is MarkdownInlineImagePart &&
      other.alt == alt &&
      other.src == src &&
      other.href == href &&
      other.width == width &&
      other.height == height &&
      other.flowsWithText == flowsWithText;

  @override
  int get hashCode =>
      Object.hash('inlineImage', alt, src, href, width, height, flowsWithText);

  @override
  String toString() => 'MarkdownInlineImagePart($alt, $src)';
}

/// One renderable row: either a part on its own, or images laid out beside the
/// paragraph that belongs with them.
sealed class MarkdownPartGroup {
  const MarkdownPartGroup();
}

/// A part that gets its own full-width row.
final class MarkdownSinglePartGroup extends MarkdownPartGroup {
  const MarkdownSinglePartGroup(this.part);

  final MarkdownDisplayPart part;

  @override
  bool operator ==(Object other) =>
      other is MarkdownSinglePartGroup && other.part == part;

  @override
  int get hashCode => Object.hash('part', part);

  @override
  String toString() => 'MarkdownSinglePartGroup($part)';
}

/// Images plus the lead paragraph they flow with, and whatever text was left
/// over below that paragraph.
final class MarkdownImageTextGroup extends MarkdownPartGroup {
  const MarkdownImageTextGroup({
    required this.images,
    required this.lead,
    required this.rest,
  });

  final List<MarkdownInlineImagePart> images;

  /// The first paragraph, trimmed — it renders inline next to [images].
  final String lead;

  /// Everything after the paragraph break, untrimmed and possibly empty. It
  /// renders full width below the image row.
  final String rest;

  @override
  bool operator ==(Object other) =>
      other is MarkdownImageTextGroup &&
      other.lead == lead &&
      other.rest == rest &&
      _listEquals(other.images, images);

  @override
  int get hashCode =>
      Object.hash('imageText', Object.hashAll(images), lead, rest);

  @override
  String toString() => 'MarkdownImageTextGroup($images, $lead, $rest)';
}

/// Pairs a run of inline images that flow with text with the lead paragraph of
/// the markdown part that follows, so the renderer can lay them out side by
/// side instead of stacking the images as their own blocks.
///
/// The pairing is all-or-nothing: if the trailing part is not markdown, or its
/// first line is blank (meaning the text deliberately starts on a new visual
/// row), the images fall back to plain parts and nothing is consumed beyond
/// them. Whitespace-only markdown parts *between* flowing images are swallowed
/// on the successful path and re-emitted verbatim on the fallback path, which
/// is why the run is scanned with a lookahead rather than consumed eagerly.
List<MarkdownPartGroup> groupMarkdownParts(List<MarkdownDisplayPart> parts) {
  final groups = <MarkdownPartGroup>[];
  var index = 0;

  while (index < parts.length) {
    final part = parts[index];

    if (part is MarkdownInlineImagePart && part.flowsWithText) {
      // Collect the maximal run of flowing images, skipping whitespace-only
      // markdown between them.
      final images = <MarkdownInlineImagePart>[part];
      var lookahead = index + 1;

      while (lookahead < parts.length) {
        final candidate = parts[lookahead];
        if (_isWhitespaceOnlyMarkdown(candidate)) {
          lookahead += 1;
          continue;
        }
        if (candidate is MarkdownInlineImagePart && candidate.flowsWithText) {
          images.add(candidate);
          lookahead += 1;
          continue;
        }
        break;
      }

      final trailing = lookahead < parts.length ? parts[lookahead] : null;
      if (trailing is MarkdownTextPart) {
        final split = _splitLeadParagraph(trailing.text);
        if (split.lead.isNotEmpty) {
          groups.add(
            MarkdownImageTextGroup(
              images: images,
              lead: split.lead,
              rest: split.rest,
            ),
          );
          index = lookahead + 1;
          continue;
        }
      }

      // No usable lead — emit the images (and any whitespace parts) as plain
      // parts. The trailing part itself is left for the next iteration.
      for (var i = index; i < lookahead; i += 1) {
        groups.add(MarkdownSinglePartGroup(parts[i]));
      }
      index = lookahead;
      continue;
    }

    groups.add(MarkdownSinglePartGroup(part));
    index += 1;
  }

  return groups;
}

bool _isWhitespaceOnlyMarkdown(MarkdownDisplayPart part) =>
    part is MarkdownTextPart && part.text.trim().isEmpty;

/// Matches a first line that holds nothing but spaces/tabs — the signal that
/// the author meant the text to start on its own row, below the images.
final _leadingBlankLinePattern = RegExp(r'^[ \t]*\r?\n');

/// Matches the paragraph break: a newline, optional horizontal whitespace,
/// then another newline.
final _paragraphBoundaryPattern = RegExp(r'\r?\n[ \t]*\r?\n');

final class _LeadParagraph {
  const _LeadParagraph({required this.lead, required this.rest});

  final String lead;
  final String rest;
}

_LeadParagraph _splitLeadParagraph(String text) {
  if (_leadingBlankLinePattern.hasMatch(text)) {
    return _LeadParagraph(lead: '', rest: text);
  }

  final boundary = _paragraphBoundaryPattern.firstMatch(text);
  if (boundary == null) {
    return _LeadParagraph(lead: text.trim(), rest: '');
  }

  return _LeadParagraph(
    lead: text.substring(0, boundary.start).trim(),
    rest: text.substring(boundary.end),
  );
}

// ---------------------------------------------------------------------------
// markdown-text-style.ts
// ---------------------------------------------------------------------------

/// The prefix the style engine (Unistyles) stamps its private bookkeeping keys
/// with. Anything under it is tracking metadata, never a real style value.
const String unistylesMetadataKeyPrefix = 'unistyles_';

/// Flattens a React-Native-shaped style prop into a single map.
///
/// Reproduces `StyleSheet.flatten`: a list is walked left to right with later
/// entries winning and nested lists recursed into, a bare map passes through,
/// and anything else (null, `false` from a conditional style, a registered
/// style id) contributes nothing. Exposed rather than private because the
/// interesting property of [resolvePlainMarkdownTextStyle] is what survives a
/// *second* flatten downstream, which callers and tests need to reproduce.
///
/// Deviation: upstream returns `undefined` for a null prop and hands back the
/// very same object for a non-list prop. Dart has no `undefined`, so an absent
/// prop becomes an empty map (upstream's callers immediately apply `?? {}`),
/// and a map prop is copied rather than aliased so the result is always safe
/// to mutate.
Map<String, Object?> flattenTextStyleProp(Object? style) {
  final flattened = _flattenTextStyleProp(style);
  return flattened ?? <String, Object?>{};
}

Map<String, Object?>? _flattenTextStyleProp(Object? style) {
  if (style is Map) {
    return style.map((key, value) => MapEntry(key.toString(), value));
  }
  if (style is! List) {
    // null, false, a registered style id — all `undefined` after flattening.
    return null;
  }

  final result = <String, Object?>{};
  for (final entry in style) {
    final computed = _flattenTextStyleProp(entry);
    if (computed == null) continue;
    result.addAll(computed);
  }
  return result;
}

/// Resolves a markdown text style to concrete values and strips the style
/// engine's private metadata.
///
/// iOS markdown text goes through `react-native-uitextview`, which inherits
/// styles by flattening `[parentStyle, childStyle]` before handing the result
/// to native View-backed components. If both entries still carry Unistyles
/// metadata, that flatten collapses two sets of `unistyles_*` keys into one
/// object and Unistyles rightly warns that the style should have stayed
/// array-shaped. UITextView is a third-party boundary rather than a
/// Unistyles-tracked component in Paseo's ownership model, so the values are
/// resolved and only the private tracking keys dropped before crossing it —
/// preserving iOS paragraph-spanning text selection without the metadata merge.
///
/// Deviation: the port stays map-shaped instead of producing a Flutter
/// `TextStyle`. The entire point of the module is removing keys that a typed
/// style object cannot represent, so converting here would erase the behaviour
/// being ported.
Map<String, Object?> resolvePlainMarkdownTextStyle(Object? style) {
  final plainStyle = flattenTextStyleProp(style);
  plainStyle.removeWhere(
    (key, _) => key.startsWith(unistylesMetadataKeyPrefix),
  );
  return plainStyle;
}

// ---------------------------------------------------------------------------
// root-error-details.ts
// ---------------------------------------------------------------------------

/// Stand-in for JavaScript's `undefined`, which the error formatter treats as
/// distinct from `null`: an absent `message` contributes no section at all,
/// while a `null` one renders as the literal text `null`. Dart has a single
/// null, so absence is spelled with this sentinel.
final class JsUndefined {
  const JsUndefined._();

  @override
  String toString() => 'undefined';
}

/// The single [JsUndefined] instance; compare with `identical`.
const JsUndefined jsUndefined = JsUndefined._();

/// A caught JavaScript `Error` reduced to the surface the crash formatter
/// actually reads.
///
/// Deliberately an open class with getters rather than a `final class` of
/// fields: upstream reads every property through `Reflect.get`, so a property
/// that *throws* is a real, tested case (a broken `message` getter must
/// degrade to fallback text instead of taking down the crash screen). Dart's
/// only equivalent of `Object.defineProperty(error, "message", {get(){throw}})`
/// is a subclass that overrides the getter.
///
/// [hasCause] and [hasErrors] are separate from their values because upstream
/// uses `Reflect.has`: an error carrying `cause: null` is not the same as one
/// with no `cause` at all, and only the former prints a `Cause:` section.
class CaughtError {
  CaughtError({
    this.name = jsUndefined,
    this.message = jsUndefined,
    this.stack = jsUndefined,
    this.hasCause = false,
    this.cause,
    this.hasErrors = false,
    this.errors,
    this.fields = const <String, Object?>{},
  });

  /// Usually a `String`, but any value is possible and must not crash the
  /// formatter — hence `Object?`.
  final Object? name;
  final Object? message;
  final Object? stack;

  /// Whether the error carries a `cause` property at all.
  final bool hasCause;
  final Object? cause;

  /// Whether the error carries an `errors` property at all (the `AggregateError`
  /// shape).
  final bool hasErrors;
  final Object? errors;

  /// Extra own properties, i.e. everything `Object.keys(error)` would yield.
  /// The five reserved names are filtered out at format time, matching
  /// upstream, so callers may pass them without producing duplicate output.
  final Map<String, Object?> fields;

  /// Mirrors `Error.prototype.toString`, which is what `String(error)` reaches
  /// for when an error has no formattable sections at all.
  @override
  String toString() {
    final resolvedName = identical(name, jsUndefined)
        ? 'Error'
        : _safeString(name);
    final resolvedMessage = identical(message, jsUndefined)
        ? ''
        : _safeString(message);
    if (resolvedName.isEmpty) return resolvedMessage;
    if (resolvedMessage.isEmpty) return resolvedName;
    return '$resolvedName: $resolvedMessage';
  }
}

/// Renders any caught value as the detail text shown on the crash screen.
///
/// The contract is that this never throws: the crash screen is the last thing
/// standing, so a value whose own getters explode still has to produce
/// *something*. When formatting fails the fallback prints whatever the value
/// stringifies to plus the formatting failure underneath, so the failure is
/// visible rather than silently swallowed.
String formatCaughtValue(Object? value) {
  try {
    return _formatCaughtValueWithSeenErrors(value, Set<Object>.identity());
  } catch (formattingError) {
    return _formatFormattingFailure(value, formattingError);
  }
}

String _formatCaughtValueWithSeenErrors(Object? value, Set<Object> seenErrors) {
  if (value is CaughtError) {
    return _formatError(value, seenErrors);
  }

  // A thrown string is already the message; quoting or JSON-encoding it would
  // only add noise.
  if (value is String) {
    return value;
  }

  if (value == null || identical(value, jsUndefined)) {
    return _safeString(value);
  }

  // Upstream routes only `object`/`function` values through JSON; every other
  // primitive stringifies. Lists and maps are the Dart stand-ins for JS
  // objects and arrays.
  if (value is! List && value is! Map) {
    return _safeString(value);
  }

  return _stringifyJson(value, seenErrors) ?? _safeString(value);
}

String _formatError(CaughtError error, Set<Object> seenErrors) {
  if (seenErrors.contains(error)) {
    return '[Circular Error]';
  }

  seenErrors.add(error);
  final sections = <String>[];
  final name = _formatErrorTextProperty(error.name, seenErrors);
  final message = _formatErrorTextProperty(error.message, seenErrors);
  final stack = _formatErrorTextProperty(error.stack, seenErrors);

  if (name != null) {
    sections.add('Name: $name');
  }
  if (message != null) {
    sections.add('Message: $message');
  }
  if (stack != null) {
    sections.add('Stack:\n$stack');
  }

  if (error.hasCause) {
    sections.add(
      'Cause:\n${_formatCaughtValueWithSeenErrors(error.cause, seenErrors)}',
    );
  }

  if (error.hasErrors) {
    sections.add(
      'Errors:\n${_formatCaughtValueWithSeenErrors(error.errors, seenErrors)}',
    );
  }

  final fields = _getErrorFields(error);
  if (fields != null) {
    sections.add(
      'Fields:\n${_stringifyJson(fields, seenErrors) ?? _safeString(fields)}',
    );
  }

  // Removed rather than left behind so the same error appearing twice down
  // two independent branches still renders in full; only a true cycle is
  // marked circular.
  seenErrors.remove(error);
  return sections.isEmpty ? _safeString(error) : sections.join('\n\n');
}

/// Renders `name`/`message`/`stack`, returning null for "print no section".
///
/// A blank or whitespace-only string is treated as absent, but a non-string
/// value is preserved through JSON so a malformed error still shows what it
/// actually held.
String? _formatErrorTextProperty(Object? value, Set<Object> seenErrors) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (identical(value, jsUndefined)) {
    return null;
  }
  return _stringifyJson(value, seenErrors) ?? _safeString(value);
}

Map<String, Object?>? _getErrorFields(CaughtError error) {
  const reserved = {'name', 'message', 'stack', 'cause', 'errors'};
  final fields = <String, Object?>{};
  for (final entry in error.fields.entries) {
    if (reserved.contains(entry.key)) continue;
    fields[entry.key] = entry.value;
  }
  return fields.isEmpty ? null : fields;
}

/// `JSON.stringify(value, replacer, 2)` with upstream's replacer.
///
/// The replacer substitutes nested errors with their formatted text, renders
/// big integers as decimal strings, and marks any object it has already
/// visited as `[Circular]`. Note that the visited set is never unwound, so a
/// value referenced twice in a non-cyclic graph is also marked circular —
/// upstream behaviour, preserved on purpose.
///
/// Returns null when serialization is impossible, matching upstream's
/// `catch { return null }`. The catch is deliberately unfiltered: the replacer
/// reads error properties, and one of those can throw.
String? _stringifyJson(Object? value, Set<Object> seenErrors) {
  final seen = Set<Object>.identity();
  try {
    // A top-level `undefined` makes `JSON.stringify` return undefined, not a
    // string; upstream then falls through to `safeString`.
    return _serializeJsonValue(value, 0, seen, seenErrors);
  } catch (_) {
    return null;
  }
}

String? _serializeJsonValue(
  Object? value,
  int indentLevel,
  Set<Object> seen,
  Set<Object> seenErrors,
) {
  final replaced = _jsonReplace(value, seen, seenErrors);

  if (identical(replaced, jsUndefined)) return null;
  if (replaced == null) return 'null';
  if (replaced is bool) return replaced ? 'true' : 'false';
  if (replaced is num) {
    // Non-finite numbers have no JSON form and serialize as null in JS.
    return replaced.isFinite ? _jsNumberToString(replaced) : 'null';
  }
  if (replaced is String) return jsonEncode(replaced);

  final childIndent = '  ' * (indentLevel + 1);
  final closeIndent = '  ' * indentLevel;

  if (replaced is List) {
    if (replaced.isEmpty) return '[]';
    final entries = replaced
        .map(
          (element) =>
              // An `undefined` element becomes `null` rather than vanishing,
              // because dropping it would change the array's length.
              _serializeJsonValue(element, indentLevel + 1, seen, seenErrors) ??
              'null',
        )
        .join(',\n$childIndent');
    return '[\n$childIndent$entries\n$closeIndent]';
  }

  if (replaced is Map) {
    final entries = <String>[];
    for (final entry in replaced.entries) {
      final serialized = _serializeJsonValue(
        entry.value,
        indentLevel + 1,
        seen,
        seenErrors,
      );
      // An `undefined` property is omitted entirely.
      if (serialized == null) continue;
      entries.add('${jsonEncode(entry.key.toString())}: $serialized');
    }
    if (entries.isEmpty) return '{}';
    return '{\n$childIndent${entries.join(',\n$childIndent')}\n$closeIndent}';
  }

  // Deviation: JavaScript serializes an unrecognised object by walking its own
  // enumerable properties, which Dart cannot do without mirrors. Such a value
  // therefore renders as a property-less object — exactly what JS produces for
  // a class instance that declares none — rather than aborting the whole
  // serialization and losing its siblings.
  return '{}';
}

Object? _jsonReplace(Object? value, Set<Object> seen, Set<Object> seenErrors) {
  if (value is CaughtError) {
    return _formatError(value, seenErrors);
  }
  if (value is BigInt) {
    return value.toString();
  }
  if (value != null && (value is List || value is Map)) {
    if (seen.contains(value)) {
      return '[Circular]';
    }
    seen.add(value);
  }
  return value;
}

/// `String(value)` that cannot throw, so a value with a hostile `toString` can
/// still be reported.
String _safeString(Object? value) {
  try {
    if (value == null) return 'null';
    if (identical(value, jsUndefined)) return 'undefined';
    if (value is num) return _jsNumberToString(value);
    if (value is bool) return value ? 'true' : 'false';
    if (value is String) return value;
    // `Array.prototype.toString` joins with commas and renders nullish
    // elements as empty strings; Dart's `List.toString` would print brackets.
    if (value is List) {
      return value
          .map(
            (element) => element == null || identical(element, jsUndefined)
                ? ''
                : _safeString(element),
          )
          .join(',');
    }
    // Plain JS objects stringify to this regardless of contents.
    if (value is Map) return '[object Object]';
    return value.toString();
  } catch (_) {
    return '[Unserializable value]';
  }
}

/// Renders a number the way JavaScript does: no trailing `.0` on integral
/// values, since `String(42)` is `"42"` where Dart's `42.0.toString()` is
/// `"42.0"`.
String _jsNumberToString(num value) {
  if (value is int) return value.toString();
  final asDouble = value.toDouble();
  if (asDouble.isNaN) return 'NaN';
  if (asDouble.isInfinite) {
    return asDouble.isNegative ? '-Infinity' : 'Infinity';
  }
  // JS prints negative zero as "0".
  if (asDouble == 0) return '0';
  if (asDouble == asDouble.roundToDouble() && asDouble.abs() < 1e21) {
    return asDouble.toStringAsFixed(0);
  }
  return asDouble.toString();
}

String _formatFormattingFailure(Object? value, Object? formattingError) {
  final valueText = _safeString(value);
  final formattingErrorText = _safeString(formattingError);
  // If even the failure will not stringify there is nothing useful to append.
  if (formattingErrorText == '[Unserializable value]') {
    return valueText;
  }
  return '$valueText\n\nDetails unavailable:\n$formattingErrorText';
}

// ---------------------------------------------------------------------------
// worktree-setup-callout-policy.ts
// ---------------------------------------------------------------------------

/// The workspace fields the callout policy reads.
///
/// Upstream nests the repo root under `project?.checkout?.mainRepoRoot` and
/// reaches it with optional chaining, which collapses "no project", "no
/// checkout" and "no main root" into the same nullish result. The Dart port
/// flattens all three into [projectCheckoutMainRepoRoot] because no caller can
/// observe the difference.
final class WorktreeSetupWorkspaceInput {
  const WorktreeSetupWorkspaceInput({
    required this.projectId,
    required this.projectKind,
    required this.projectRootPath,
    this.projectCheckoutMainRepoRoot,
  });

  final String projectId;

  /// Free-form upstream (`"git"`, `"local"`, …) and kept as a string so an
  /// unrecognised kind is simply not git, rather than a parse failure.
  final String projectKind;
  final String projectRootPath;
  final String? projectCheckoutMainRepoRoot;
}

/// A git-backed project the sidebar can offer worktree setup for.
final class ActiveGitWorkspaceProject {
  const ActiveGitWorkspaceProject({
    required this.serverId,
    required this.projectKey,
    required this.repoRoot,
  });

  final String serverId;
  final String projectKey;
  final String repoRoot;

  @override
  bool operator ==(Object other) =>
      other is ActiveGitWorkspaceProject &&
      other.serverId == serverId &&
      other.projectKey == projectKey &&
      other.repoRoot == repoRoot;

  @override
  int get hashCode => Object.hash(serverId, projectKey, repoRoot);

  @override
  String toString() =>
      'ActiveGitWorkspaceProject($serverId, $projectKey, $repoRoot)';
}

/// The outcome of reading a project's `paseo` config.
///
/// Upstream carries the whole `PaseoConfigRaw`, but the policy reads exactly
/// one path out of it — `config.worktree.setup` — so the port narrows to that
/// value. An absent config, a null config, `{}` and `{worktree: {}}` all
/// collapse to a null [worktreeSetup], which is what upstream's optional
/// chaining does too.
final class ReadProjectConfigResult {
  const ReadProjectConfigResult({required this.ok, this.worktreeSetup});

  /// Whether the read completed successfully. A failed read must not be
  /// mistaken for "no setup commands configured".
  final bool ok;

  /// `String`, `List` of commands, or null. Untyped because the raw config is
  /// unvalidated user YAML upstream and the policy is deliberately tolerant of
  /// whatever shape it finds.
  final Object? worktreeSetup;
}

/// Everything the sidebar needs to render and dismiss the worktree setup nag.
final class WorktreeSetupCalloutPolicy {
  const WorktreeSetupCalloutPolicy({
    required this.id,
    required this.dismissalKey,
    required this.priority,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.projectSettingsRoute,
    required this.testID,
  });

  final String id;

  /// Equal to [id] today, but kept separate because dismissal is persisted:
  /// changing how callouts are identified must not silently un-dismiss every
  /// callout a user already dismissed.
  final String dismissalKey;
  final int priority;
  final String title;
  final String description;
  final String actionLabel;
  final String projectSettingsRoute;

  /// Upstream field name (`testID`) kept verbatim so the value matches what
  /// upstream's test selectors look for.
  final String testID;

  @override
  bool operator ==(Object other) =>
      other is WorktreeSetupCalloutPolicy &&
      other.id == id &&
      other.dismissalKey == dismissalKey &&
      other.priority == priority &&
      other.title == title &&
      other.description == description &&
      other.actionLabel == actionLabel &&
      other.projectSettingsRoute == projectSettingsRoute &&
      other.testID == testID;

  @override
  int get hashCode => Object.hash(
    id,
    dismissalKey,
    priority,
    title,
    description,
    actionLabel,
    projectSettingsRoute,
    testID,
  );

  @override
  String toString() => 'WorktreeSetupCalloutPolicy($id)';
}

/// Identifies the git project behind the focused workspace, or null when there
/// is nothing worktree setup could apply to.
///
/// The repo root prefers the checkout's main root over the workspace path,
/// because a workspace opened *inside* a worktree must still point setup at the
/// primary checkout. Both coordinates are trimmed and required to be non-empty:
/// a blank key would produce a callout that can never be dismissed
/// deterministically, and a blank root has nothing to run setup in.
ActiveGitWorkspaceProject? selectActiveGitWorkspaceProject(
  String serverId,
  WorktreeSetupWorkspaceInput workspace,
) {
  if (workspace.projectKind != 'git') {
    return null;
  }

  final projectKey = workspace.projectId.trim();
  // Nullish rather than falsy coalescing upstream: an explicitly empty main
  // root stays empty and disqualifies the project instead of falling back.
  final repoRoot =
      (workspace.projectCheckoutMainRepoRoot ?? workspace.projectRootPath)
          .trim();
  if (projectKey.isEmpty || repoRoot.isEmpty) {
    return null;
  }

  return ActiveGitWorkspaceProject(
    serverId: serverId,
    projectKey: projectKey,
    repoRoot: repoRoot,
  );
}

/// Whether the sidebar should nag about missing worktree setup commands.
///
/// Requires a *successful* read: while the read is pending or after it failed,
/// staying quiet is the safe default, because claiming setup is missing when it
/// might not be would push users to duplicate config they already have.
bool shouldShowWorktreeSetupCallout(ReadProjectConfigResult? readResult) {
  if (readResult == null || !readResult.ok) return false;
  return !_hasSetupCommands(readResult.worktreeSetup);
}

/// A single command string counts, and so does a list in which *any* entry is a
/// non-blank string — a list padded with blanks is still a configured setup.
bool _hasSetupCommands(Object? setup) {
  if (setup is String) {
    return setup.trim().isNotEmpty;
  }
  if (setup is List) {
    return setup.any(
      (command) => command is String && command.trim().isNotEmpty,
    );
  }
  return false;
}

/// Builds the sidebar callout for a project that has no worktree setup
/// commands.
///
/// The id and dismissal key are both derived from the project key so the
/// callout is stable across reconnects and its dismissal sticks to the project
/// rather than the session. Priority 100 puts it below urgent, actionable
/// callouts — it is a suggestion, not a problem.
///
/// [t] is the translator, injected because this repo has no localization layer
/// yet (`i18n/*` is tracked separately); upstream reaches for the `i18n`
/// singleton directly at the same three keys.
WorktreeSetupCalloutPolicy buildWorktreeSetupCalloutPolicy(
  ActiveGitWorkspaceProject project, {
  required ComposerTranslator t,
}) {
  final calloutKey = 'worktree-setup-missing:${project.projectKey}';

  return WorktreeSetupCalloutPolicy(
    id: calloutKey,
    dismissalKey: calloutKey,
    priority: 100,
    title: t('sidebar.worktreeSetup.title'),
    description: t('sidebar.worktreeSetup.description'),
    actionLabel: t('sidebar.worktreeSetup.openProjectSettings'),
    projectSettingsRoute: buildProjectSettingsRoute(project.projectKey),
    testID: 'worktree-setup-callout-${project.projectKey}',
  );
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
