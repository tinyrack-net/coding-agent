/// Port of Paseo 0.2.0's `components/markdown/html-ish.ts` — the splitter that
/// turns a bot comment written in "HTML-ish markdown" into the display parts
/// the chat renderer draws.
///
/// Why this module exists at all: automated review comments are markdown that
/// is really markdown *with raw HTML mixed in* —
/// `<details>` blocks, `<img>` status icons wrapped in `<a>`, `<sub>` footers,
/// `<br>` line breaks, HTML comments used as machine-readable markers. A pure
/// markdown renderer would either print those tags literally or, worse, hand
/// them to an HTML engine. Neither is acceptable, so this module owns a third
/// path: parse the HTML *just enough* to lift the structural pieces out
/// (`<details>` → a collapsible part, `<img>` → a real image part), rewrite the
/// safe inline pieces back into markdown (`<br>` → newline, `<code>` →
/// backticks, `<a>` → `[label](href)`), and leave everything else inert as
/// literal text so nothing unknown is ever interpreted.
///
/// Three properties are load-bearing and deliberately frozen:
///
/// - **Code spans win.** Fenced blocks and inline-code spans are located
///   *before* any HTML parsing and handed through as opaque text, so
///   documentation that talks *about* `<details>` never gets parsed as a
///   `<details>`.
/// - **Unsafe things stay inert, never dropped.** An `<img>` with a
///   `javascript:` src is not an image part and not stripped — it round-trips
///   to literal text, which markdown then escapes. Only `<script>`/`<style>`
///   bodies are actively erased.
/// - **Byte-for-byte text preservation.** Everything that is not lifted out
///   must be re-emitted exactly, because the text is markdown and whitespace is
///   syntax. That is why this file carries a faithful port of htmlparser2's
///   tokenizer rather than using a convenience HTML parser: token boundaries,
///   implied-tag suppression and raw-tag reconstruction are all observable in
///   the output.
///
/// The `MarkdownDisplayPart` hierarchy this produces lives in
/// `paseo_render_rules.dart` (ported first, for `part-groups.ts`) and is
/// re-exported here so callers can take splitter and part types from one
/// import.
library;

import 'dart:math' as math;

import 'paseo_render_rules.dart';

export 'paseo_render_rules.dart'
    show
        MarkdownDetailsPart,
        MarkdownDisplayPart,
        MarkdownInlineImagePart,
        MarkdownTextPart;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Splits HTML-ish markdown into the parts the chat renderer draws.
///
/// The result interleaves three kinds of part in source order: literal
/// markdown runs, `<details>` blocks lifted into their own collapsible part,
/// and images lifted into real image parts. Adjacent markdown runs are always
/// merged, so two markdown parts never sit next to each other.
List<MarkdownDisplayPart> splitHtmlishMarkdown(String source) =>
    _splitHtmlishTokens(_tokenizeHtmlishMarkdown(source));

/// Rewrites the inline HTML in [source] into equivalent markdown without
/// splitting anything out.
///
/// Used for text that already lives inside a single rendered block (a summary
/// line, a table cell) where lifting out images or `<details>` is not possible
/// — the caller needs one string back, so `<br>` becomes a newline, `<code>`
/// becomes a backtick span, and anything unrecognised stays literal.
String normalizeHtmlishMarkdown(String source) =>
    _renderInlineTokens(_tokenizeHtmlishMarkdown(source));

// ---------------------------------------------------------------------------
// Patterns and tables
// ---------------------------------------------------------------------------

/// A markdown fence line: up to three leading spaces, then three or more
/// backticks or tildes, then the info string and the line break.
///
/// `multiLine` matches JavaScript's `m` flag exactly — both engines treat
/// `\n`, `\r`, `U+2028` and `U+2029` as line starts, and both let the trailing
/// `$` alternative match before a lone `\r`. Pinned against Node.
final _fenceLinePattern = RegExp(
  r'^ {0,3}([`~]{3,})[^\n\r]*(?:\r?\n|$)',
  multiLine: true,
);

/// A maximal run of backticks, used to find inline-code delimiters.
final _backtickRunPattern = RegExp('`+');

/// Image sources we are willing to hand to a real image widget. Anything else
/// (`javascript:`, `file:`, a bare relative path) is refused.
final _safeImageSrcPattern = RegExp(
  r'^(https?://|data:image/(?:png|gif|jpe?g);base64,)',
  caseSensitive: false,
);

/// Link targets we are willing to emit as a markdown link: absolute http(s),
/// or a non-empty in-page anchor.
final _safeLinkHrefPattern = RegExp(
  r'^(https?://|#(?:$|[\w-]))',
  caseSensitive: false,
);

/// Trailing whitespace since the last line break — used to decide whether an
/// image starts its line. No `multiLine`, so `$` means end of input, matching
/// the upstream literal.
final _trailingLineStartPattern = RegExp(r'(?:^|[\n\r])[ \t]*$');

/// Splits on the first line break so an image's "same line" can be inspected.
final _lineBreakPattern = RegExp(r'\r?\n');

/// An unsigned decimal, optionally fractional — the only shape of `width` /
/// `height` attribute we trust.
final _imageDimensionPattern = RegExp(r'^\d+(?:\.\d+)?$');

/// Tags this module treats as having no children, independent of what the HTML
/// parser thinks. Upstream keeps this list intentionally tiny: it is not the
/// HTML void-element list, it is "tags whose close event we suppress".
const _voidHtmlTags = {'br', 'img'};

// ---------------------------------------------------------------------------
// Internal token model
// ---------------------------------------------------------------------------

/// One event out of the HTML tokenizer, flattened into a list.
///
/// Upstream models this as a discriminated union on `kind`; Dart uses a sealed
/// hierarchy so exhaustive `is` checks replace the string comparisons.
sealed class _HtmlToken {
  const _HtmlToken();
}

final class _HtmlTextToken extends _HtmlToken {
  const _HtmlTextToken(this.value);

  final String value;
}

/// An HTML comment. The body is deliberately discarded — comments are markers
/// for other bots, never content, and dropping the text makes it impossible to
/// accidentally render one.
final class _HtmlCommentToken extends _HtmlToken {
  const _HtmlCommentToken();
}

final class _HtmlTagToken extends _HtmlToken {
  const _HtmlTagToken({
    required this.name,
    required this.closing,
    required this.selfClosing,
    required this.attributes,
    required this.raw,
  });

  final String name;
  final bool closing;

  /// Whether this tag can never have children. Note this is derived from
  /// [_voidHtmlTags], *not* from `/>` in the source: upstream deliberately
  /// ignores the self-closing slash so `<div/>` is still treated as an
  /// unterminated `<div>`.
  final bool selfClosing;

  final Map<String, String> attributes;

  /// The tag re-rendered from its parsed name and attributes, not the original
  /// source text. This normalises case and quoting, and is what gets emitted
  /// when a tag is left inert.
  final String raw;
}

/// A half-open `[start, end)` slice of the source that must not be parsed as
/// HTML because markdown already claimed it as code.
final class _ProtectedMarkdownRange {
  const _ProtectedMarkdownRange({required this.start, required this.end});

  final int start;
  final int end;
}

/// Where a delimiter (fence line or backtick run) was found and where it ends.
final class _MarkdownDelimiterMatch {
  const _MarkdownDelimiterMatch({required this.index, required this.end});

  final int index;
  final int end;
}

/// An image lifted out of the token stream, plus the token index just past it.
final class _InlineImageParseResult {
  const _InlineImageParseResult({required this.part, required this.end});

  final MarkdownInlineImagePart part;
  final int end;
}

// ---------------------------------------------------------------------------
// Splitting
// ---------------------------------------------------------------------------

List<MarkdownDisplayPart> _splitHtmlishTokens(List<_HtmlToken> tokens) {
  final parts = <MarkdownDisplayPart>[];
  var cursor = 0;

  while (cursor < tokens.length) {
    final token = tokens[cursor];
    if (_isOpenTag(token, 'details')) {
      final closeIndex = _findMatchingClose(tokens, cursor, 'details');
      if (closeIndex != null) {
        final details = _parseDetailsTokens(
          tokens.sublist(cursor + 1, closeIndex),
        );
        if (details != null) {
          parts.add(details);
          cursor = closeIndex + 1;
          continue;
        }
      }
    }

    final inlineImage = _parseInlineImageAt(tokens, cursor);
    if (inlineImage != null) {
      parts.add(
        _flowsWithFollowingText(tokens, cursor, inlineImage.end)
            ? _withFlowsWithText(inlineImage.part)
            : inlineImage.part,
      );
      cursor = inlineImage.end;
      continue;
    }

    final nextDetailsIndex = _findNextOpenTag(tokens, cursor + 1, 'details');
    final nextInlineImageIndex = _findNextInlineImageIndex(tokens, cursor + 1);
    final end = math.min(
      nextDetailsIndex ?? tokens.length,
      nextInlineImageIndex ?? tokens.length,
    );
    _appendMarkdownPart(
      parts,
      _renderInlineTokens(tokens.sublist(cursor, end)),
    );
    cursor = end;
  }

  return parts;
}

/// Upstream spreads the part and overrides one field; the Dart part class is
/// immutable, so the copy is spelled out.
MarkdownInlineImagePart _withFlowsWithText(MarkdownInlineImagePart part) =>
    MarkdownInlineImagePart(
      alt: part.alt,
      src: part.src,
      href: part.href,
      width: part.width,
      height: part.height,
      flowsWithText: true,
    );

_InlineImageParseResult? _parseInlineImageAt(
  List<_HtmlToken> tokens,
  int start,
) {
  // Upstream indexes past the end freely and relies on `token?.kind`; Dart has
  // to bounds-check first.
  if (start < 0 || start >= tokens.length) return null;

  final token = tokens[start];
  if (token is! _HtmlTagToken || token.closing) return null;

  if (token.name == 'img') {
    final image = _imageTokenToInlineImage(token, null);
    return image == null
        ? null
        : _InlineImageParseResult(part: image, end: start + 1);
  }

  if (token.name != 'a') return null;

  final closeIndex = _findMatchingClose(tokens, start, 'a');
  if (closeIndex == null) return null;

  final image = _getSingleImageChild(tokens.sublist(start + 1, closeIndex));
  if (image == null) return null;

  final inlineImage = _imageTokenToInlineImage(
    image,
    _safeHref(token.attributes['href']),
  );
  return inlineImage == null
      ? null
      : _InlineImageParseResult(part: inlineImage, end: closeIndex + 1);
}

/// Whether the image at `[start, end)` opened a line that real text continues
/// on — the icon-beside-heading shape automated reviews emit.
bool _flowsWithFollowingText(List<_HtmlToken> tokens, int start, int end) {
  final previous = start - 1 >= 0 && start - 1 < tokens.length
      ? tokens[start - 1]
      : null;
  // At line start if nothing precedes this image, or the preceding token ends
  // with only whitespace since the last newline (covers a bare space between
  // two images on the same line).
  final atLineStart =
      previous == null ||
      (previous is _HtmlTextToken &&
          _trailingLineStartPattern.hasMatch(previous.value));
  if (!atLineStart) return false;

  // Scan forward past same-line whitespace-only text tokens and inline images
  // to find the first substantive text token, without crossing a newline.
  var cursor = end;
  while (cursor < tokens.length) {
    final token = tokens[cursor];
    if (token is _HtmlTextToken) {
      final lines = token.value.split(_lineBreakPattern);
      final sameLine = lines.isEmpty ? '' : lines.first;
      if (sameLine.trim().isNotEmpty) return true;
      // Whitespace-only on this line — keep scanning only if no newline was
      // crossed.
      if (token.value.contains('\n') || token.value.contains('\r')) {
        return false;
      }
      cursor += 1;
      continue;
    }
    // An inline image tag — skip over it (the image itself and its possible
    // wrapping close tag).
    if (token is _HtmlTagToken) {
      final imageResult = _parseInlineImageAt(tokens, cursor);
      if (imageResult != null) {
        cursor = imageResult.end;
        continue;
      }
    }
    break;
  }
  return false;
}

int? _findNextInlineImageIndex(List<_HtmlToken> tokens, int start) {
  for (var index = start; index < tokens.length; index += 1) {
    if (_parseInlineImageAt(tokens, index) != null) return index;
  }
  return null;
}

/// Appends markdown text, merging into the previous part when it is also
/// markdown so the renderer never sees two adjacent text parts.
void _appendMarkdownPart(List<MarkdownDisplayPart> parts, String text) {
  if (text.isEmpty) return;

  final previous = parts.isEmpty ? null : parts.last;
  if (previous is MarkdownTextPart) {
    // Upstream mutates `previous.text` in place; the Dart part is immutable, so
    // the tail element is replaced instead. Observationally identical because
    // nothing else holds a reference to a part still being built.
    parts[parts.length - 1] = MarkdownTextPart(previous.text + text);
    return;
  }
  parts.add(MarkdownTextPart(text));
}

/// Turns the inside of a `<details>` element into a details part, or returns
/// null to signal "this is not a real details block, leave it inert".
MarkdownDetailsPart? _parseDetailsTokens(List<_HtmlToken> tokens) {
  final summaryOpenIndex = _findNextOpenTag(tokens, 0, 'summary');
  if (summaryOpenIndex == null) return null;

  final summaryCloseIndex = _findMatchingClose(
    tokens,
    summaryOpenIndex,
    'summary',
  );
  if (summaryCloseIndex == null) return null;

  final summaryTokens = tokens.sublist(summaryOpenIndex + 1, summaryCloseIndex);
  final bodyTokens = [
    ...tokens.sublist(0, summaryOpenIndex),
    ...tokens.sublist(summaryCloseIndex + 1),
  ];
  final summary = _renderSummaryTokens(summaryTokens).trim();
  if (summary.isEmpty) return null;

  final bodyParts = _splitHtmlishTokens(bodyTokens);
  final body = _renderBodyText(bodyParts);

  return MarkdownDetailsPart(
    summary: summary,
    body: body.trim(),
    // `bodyParts` is only carried when the body holds something the plain
    // markdown string cannot express; otherwise it stays absent so the renderer
    // takes the cheap path.
    bodyParts: bodyParts.any((part) => part is! MarkdownTextPart)
        ? _trimBodyParts(bodyParts)
        : null,
  );
}

String _renderBodyText(List<MarkdownDisplayPart> parts) =>
    parts.map((part) => part is MarkdownTextPart ? part.text : '').join();

/// Trims the outer whitespace off a details body's part list and drops parts
/// that trimming emptied.
List<MarkdownDisplayPart> _trimBodyParts(List<MarkdownDisplayPart> parts) {
  final trimmed = [...parts];
  if (trimmed.isNotEmpty) {
    final first = trimmed.first;
    if (first is MarkdownTextPart) {
      trimmed[0] = MarkdownTextPart(first.text.trimLeft());
    }
  }
  if (trimmed.isNotEmpty) {
    // Read back through the list rather than from `parts`, so a single part
    // that is both first and last gets trimmed at both ends, as upstream's
    // shared object mutation does.
    final last = trimmed.last;
    if (last is MarkdownTextPart) {
      trimmed[trimmed.length - 1] = MarkdownTextPart(last.text.trimRight());
    }
  }
  return trimmed
      .where((part) => part is! MarkdownTextPart || part.text.isNotEmpty)
      .toList();
}

String _renderSummaryTokens(List<_HtmlToken> tokens) =>
    _stripSingleHeadingWrapper(_renderInlineTokens(tokens));

/// Drops a heading wrapper that spans the whole summary, so
/// `<summary><h3>Title</h3></summary>` yields `Title` instead of a heading that
/// would fight the disclosure row's own typography.
String _stripSingleHeadingWrapper(String text) {
  final tokens = _tokenizeHtmlishMarkdown(text.trim());
  if (tokens.length < 3) return text;

  final first = tokens.first;
  final last = tokens.last;
  if (first is! _HtmlTagToken ||
      !_isHeadingTag(first) ||
      !_isClosingTag(last, first.name)) {
    return text;
  }

  return _renderInlineTokens(tokens.sublist(1, tokens.length - 1));
}

/// Rewrites a token run back into markdown, recognising the small set of inline
/// tags that have a markdown equivalent and leaving everything else literal.
String _renderInlineTokens(List<_HtmlToken> tokens) {
  final output = StringBuffer();
  for (var index = 0; index < tokens.length; index += 1) {
    final token = tokens[index];
    if (token is _HtmlTextToken) {
      output.write(token.value);
      continue;
    }
    if (token is! _HtmlTagToken || token.closing) continue;

    if (token.name == 'br') {
      output.write('\n');
      continue;
    }

    if (token.name == 'img') {
      output.write(_renderImageToken(token));
      continue;
    }

    final closeIndex = token.selfClosing
        ? null
        : _findMatchingClose(tokens, index, token.name);
    if (closeIndex == null) {
      output.write(_renderUnknownTag(token));
      continue;
    }

    final children = tokens.sublist(index + 1, closeIndex);
    if (token.name == 'a') {
      output.write(_renderLinkToken(token, children));
      index = closeIndex;
      continue;
    }
    if (token.name == 'sub') {
      output.write(_renderInlineTokens(children));
      index = closeIndex;
      continue;
    }
    // Only a `<code>` whose body is pure text becomes a backtick span; anything
    // with markup inside stays literal so nested tags are never re-interpreted.
    if (token.name == 'code' &&
        children.every((child) => child is _HtmlTextToken)) {
      output.write('`${_renderInlineTokens(children)}`');
      index = closeIndex;
      continue;
    }
    if (_isHeadingTag(token)) {
      output.write(_renderInlineTokens(children));
      index = closeIndex;
      continue;
    }

    output.write(token.raw);
    output.write(_renderInlineTokens(children));
    output.write('</${token.name}>');
    index = closeIndex;
  }

  return output.toString();
}

String _renderImageToken(_HtmlTagToken token) {
  final image = _imageTokenToInlineImage(token, null);
  if (image == null) return token.raw;

  return '![${_escapeMarkdownImageAlt(image.alt)}](${image.src})';
}

String _renderLinkToken(_HtmlTagToken token, List<_HtmlToken> children) {
  final imageOnly = _getSingleImageChild(children);
  if (imageOnly != null) return _renderImageToken(imageOnly);

  final label = _renderInlineTokens(children);
  final href = token.attributes['href'] ?? '';
  if (label.isEmpty || !_safeLinkHrefPattern.hasMatch(href) || href == '#') {
    return label;
  }

  return '[$label]($href)';
}

MarkdownInlineImagePart? _imageTokenToInlineImage(
  _HtmlTagToken token,
  String? href,
) {
  final src = token.attributes['src'] ?? '';
  if (!_safeImageSrcPattern.hasMatch(src)) return null;

  return MarkdownInlineImagePart(
    alt: token.attributes['alt'] ?? '',
    src: src,
    // Upstream spreads `...(href ? { href } : {})`, so an empty string is
    // dropped just like `undefined`; the emptiness check preserves that.
    href: href != null && href.isNotEmpty ? href : null,
    width: _parseImageDimension(token.attributes['width']),
    height: _parseImageDimension(token.attributes['height']),
  );
}

/// Parses a trusted pixel dimension, or null when the attribute is missing,
/// non-numeric, or zero. Zero is rejected because upstream requires `> 0`.
double? _parseImageDimension(String? value) {
  if (value == null ||
      value.isEmpty ||
      !_imageDimensionPattern.hasMatch(value)) {
    return null;
  }

  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite && parsed > 0 ? parsed : null;
}

String? _safeHref(String? href) {
  if (href == null ||
      href.isEmpty ||
      href == '#' ||
      !_safeLinkHrefPattern.hasMatch(href)) {
    return null;
  }
  return href;
}

/// The single `<img>` inside a run of tokens, ignoring comments and whitespace,
/// or null when the run holds anything else.
_HtmlTagToken? _getSingleImageChild(List<_HtmlToken> tokens) {
  final visible = tokens
      .where(
        (token) => token is! _HtmlCommentToken && !_isWhitespaceText(token),
      )
      .toList();
  if (visible.length != 1) return null;

  final only = visible.first;
  return _isOpenTag(only, 'img') ? only as _HtmlTagToken : null;
}

/// Emits a tag we have no markdown equivalent for. `<script>` and `<style>`
/// are the only tags erased outright — everything else survives as literal
/// text so nothing is silently lost.
String _renderUnknownTag(_HtmlTagToken token) {
  if (token.name == 'script' || token.name == 'style') return '';
  return token.raw;
}

String _escapeMarkdownImageAlt(String value) => value.replaceAll(']', r'\]');

int? _findNextOpenTag(List<_HtmlToken> tokens, int start, String name) {
  for (var index = start; index < tokens.length; index += 1) {
    if (_isOpenTag(tokens[index], name)) return index;
  }
  return null;
}

/// Finds the close tag that balances the open tag at [openIndex], honouring
/// nesting so an inner `<details>` cannot terminate its parent.
int? _findMatchingClose(List<_HtmlToken> tokens, int openIndex, String name) {
  var depth = 1;
  for (var index = openIndex + 1; index < tokens.length; index += 1) {
    final token = tokens[index];
    if (token is _HtmlTagToken &&
        token.name == name &&
        !token.closing &&
        !token.selfClosing) {
      depth += 1;
      continue;
    }
    if (_isClosingTag(token, name)) {
      depth -= 1;
      if (depth == 0) return index;
    }
  }
  return null;
}

bool _isOpenTag(_HtmlToken? token, String name) =>
    token is _HtmlTagToken && token.name == name && !token.closing;

bool _isClosingTag(_HtmlToken? token, String name) =>
    token is _HtmlTagToken && token.name == name && token.closing;

bool _isHeadingTag(_HtmlToken? token) =>
    token is _HtmlTagToken && _isHeadingTagName(token.name) && !token.closing;

bool _isHeadingTagName(String name) =>
    name == 'h1' ||
    name == 'h2' ||
    name == 'h3' ||
    name == 'h4' ||
    name == 'h5' ||
    name == 'h6';

/// Deviation: Dart's `String.trim` also strips `U+0085` (NEL), which
/// JavaScript's `String.prototype.trim` keeps. A text token consisting solely
/// of NEL therefore counts as whitespace here and as content upstream. Left
/// as-is: NEL never appears in bot markdown, and reimplementing JS's exact
/// whitespace set would cost more than it protects. The same caveat applies to
/// every other `trim`/`trimLeft`/`trimRight` in this file.
bool _isWhitespaceText(_HtmlToken token) =>
    token is _HtmlTextToken && token.value.trim().isEmpty;

// ---------------------------------------------------------------------------
// Tokenizing: protecting markdown code, then parsing the rest as HTML
// ---------------------------------------------------------------------------

/// Tokenizes [source] as HTML, but hands every markdown code span through
/// untouched as one text token.
///
/// The protected ranges are fed to the parser as pre-made text tokens while the
/// parser is told (via [_HtmlishTokenParser.skip]) how much source it did not
/// see, so comment positions still map back to real source offsets.
List<_HtmlToken> _tokenizeHtmlishMarkdown(String source) {
  final protectedRanges = _getProtectedMarkdownRanges(source);
  final tokens = <_HtmlToken>[];
  final parser = _HtmlishTokenParser(source, tokens);
  var cursor = 0;

  for (final range in protectedRanges) {
    parser.write(source.substring(cursor, range.start));
    tokens.add(_HtmlTextToken(source.substring(range.start, range.end)));
    parser.skip(range.end - range.start);
    cursor = range.end;
  }

  parser.write(source.substring(cursor));
  parser.end();
  return tokens;
}

/// Bridges the HTML parser's events into the flat token list, applying the two
/// adjustments this module needs: implied tags are dropped, and the newline
/// that follows a line-leading comment is swallowed so removing the comment
/// does not leave a blank line behind.
final class _HtmlishTokenParser implements _HtmlHandler {
  _HtmlishTokenParser(this._source, this._tokens) {
    _parser = _HtmlParser(this);
  }

  final String _source;
  final List<_HtmlToken> _tokens;
  late final _HtmlParser _parser;

  bool _stripNextLeadingLineBreak = false;

  /// How much source has been handed through as protected text instead of
  /// being written to the parser, so parser offsets can be mapped back.
  int _skippedLength = 0;

  void write(String chunk) => _parser.write(chunk);

  void skip(int length) => _skippedLength += length;

  void end() => _parser.end();

  @override
  void onOpenTag(String name, Map<String, String> attributes, bool isImplied) {
    if (isImplied) return;
    _tokens.add(
      _HtmlTagToken(
        name: name,
        closing: false,
        selfClosing: _voidHtmlTags.contains(name),
        attributes: attributes,
        raw: _renderStartTag(name, attributes),
      ),
    );
  }

  @override
  void onCloseTag(String name, bool isImplied) {
    if (isImplied || _voidHtmlTags.contains(name)) return;
    _tokens.add(
      _HtmlTagToken(
        name: name,
        closing: true,
        selfClosing: false,
        attributes: const {},
        raw: '</$name>',
      ),
    );
  }

  @override
  void onText(String value) {
    var text = value;
    if (_stripNextLeadingLineBreak) {
      _stripNextLeadingLineBreak = false;
      text = _stripLeadingLineBreak(text);
    }
    if (text.isEmpty) return;
    _tokens.add(_HtmlTextToken(text));
  }

  @override
  void onComment(String data) {
    _stripNextLeadingLineBreak = _isLineStart(
      _source,
      _parser.startIndex + _skippedLength,
    );
    _tokens.add(const _HtmlCommentToken());
  }
}

bool _isLineStart(String source, int index) {
  if (index == 0) return true;
  if (index - 1 >= source.length || index - 1 < 0) return false;
  final previous = source[index - 1];
  return previous == '\n' || previous == '\r';
}

String _stripLeadingLineBreak(String value) {
  if (value.startsWith('\r\n')) return value.substring(2);
  if (value.startsWith('\n') || value.startsWith('\r')) {
    return value.substring(1);
  }
  return value;
}

/// Rebuilds an opening tag from its parsed pieces.
///
/// Deviation: upstream iterates `Object.entries`, which hoists integer-like
/// keys ahead of the rest, so `<x 1="a" b="c">` re-renders as `<x 1="a" b="c">`
/// in JS only by coincidence of ordering rules. Dart's `Map` is strictly
/// insertion-ordered, so an attribute literally named `1` would be re-rendered
/// in source order here. No real markup has numeric attribute names.
String _renderStartTag(String name, Map<String, String> attributes) {
  final buffer = StringBuffer('<$name');
  attributes.forEach((key, value) {
    // An empty value renders as a bare attribute, so `alt=""` comes back as
    // `alt`. That is upstream behaviour, not an accident.
    if (value.isEmpty) {
      buffer.write(' $key');
    } else {
      buffer.write(' $key="${_escapeAttribute(value)}"');
    }
  });
  buffer.write('>');
  return buffer.toString();
}

String _escapeAttribute(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

// ---------------------------------------------------------------------------
// Protected markdown ranges (fenced blocks and inline code)
// ---------------------------------------------------------------------------

List<_ProtectedMarkdownRange> _getProtectedMarkdownRanges(String source) {
  final fencedRanges = _getFencedCodeRanges(source);
  return _mergeProtectedRanges([
    ...fencedRanges,
    ..._getInlineCodeRanges(source, fencedRanges),
  ]);
}

/// Finds the first match of [pattern] at or after [start].
///
/// Stands in for JavaScript's `lastIndex` + `exec` on a global regex.
/// `allMatches(input, start)` is the right analogue rather than matching
/// against a substring: the pattern still sees the whole input, so `^` under
/// `multiLine` anchors against real line starts.
Match? _execFrom(RegExp pattern, String input, int start) {
  if (start < 0 || start > input.length) return null;
  final iterator = pattern.allMatches(input, start).iterator;
  return iterator.moveNext() ? iterator.current : null;
}

/// Ranges covered by fenced code blocks. An unterminated fence swallows the
/// rest of the source, which is what a half-streamed bot comment looks like.
List<_ProtectedMarkdownRange> _getFencedCodeRanges(String source) {
  final ranges = <_ProtectedMarkdownRange>[];
  var lastIndex = 0;

  while (true) {
    final open = _execFrom(_fenceLinePattern, source, lastIndex);
    if (open == null) return ranges;
    lastIndex = open.end;

    final marker = open.group(1);
    if (marker == null || marker.isEmpty) continue;

    final close = _findClosingFence(source, lastIndex, marker);
    if (close == null) {
      ranges.add(
        _ProtectedMarkdownRange(start: open.start, end: source.length),
      );
      return ranges;
    }

    ranges.add(_ProtectedMarkdownRange(start: open.start, end: close.end));
    lastIndex = close.end;
  }
}

/// A fence closes on a run of the same character at least as long as the
/// opener, so ```` inside a ``` block is content, not a terminator.
_MarkdownDelimiterMatch? _findClosingFence(
  String source,
  int start,
  String marker,
) {
  final closePattern = RegExp(
    '^ {0,3}[${marker[0]}]{${marker.length},}'
    r'[^\n\r]*(?:\r?\n|$)',
    multiLine: true,
  );
  final close = _execFrom(closePattern, source, start);
  return close == null
      ? null
      : _MarkdownDelimiterMatch(index: close.start, end: close.end);
}

/// Ranges covered by inline code spans, skipping anything already inside a
/// fenced block.
///
/// Upstream leans on one module-level global regex whose `lastIndex` is shared
/// with [_findClosingBacktickRun]; Dart has no such shared cursor, so the index
/// is threaded explicitly. The two places upstream fixes up `lastIndex` by hand
/// — after an unmatched opener, and after a successful close — are reproduced
/// as explicit assignments.
List<_ProtectedMarkdownRange> _getInlineCodeRanges(
  String source,
  List<_ProtectedMarkdownRange> fencedRanges,
) {
  final ranges = <_ProtectedMarkdownRange>[];
  var lastIndex = 0;

  while (true) {
    final open = _execFrom(_backtickRunPattern, source, lastIndex);
    if (open == null) return ranges;
    lastIndex = open.end;
    if (_isProtectedIndex(open.start, fencedRanges)) continue;

    final marker = open.group(0)!;
    final afterOpen = lastIndex;
    final close = _findClosingBacktickRun(
      source,
      afterOpen,
      marker,
      fencedRanges,
    );
    if (close == null) {
      // Unmatched backtick run — skip past it so the loop doesn't restart from
      // the beginning of the source.
      lastIndex = afterOpen;
      continue;
    }

    ranges.add(_ProtectedMarkdownRange(start: open.start, end: close.end));
    lastIndex = close.end;
  }
}

/// A code span closes only on a backtick run of exactly the same length, which
/// is what lets ``a ` b`` hold a literal backtick.
_MarkdownDelimiterMatch? _findClosingBacktickRun(
  String source,
  int start,
  String marker,
  List<_ProtectedMarkdownRange> fencedRanges,
) {
  var cursor = start;

  while (true) {
    final close = _execFrom(_backtickRunPattern, source, cursor);
    if (close == null) return null;
    cursor = close.end;
    if (close.group(0) == marker &&
        !_isProtectedIndex(close.start, fencedRanges)) {
      return _MarkdownDelimiterMatch(index: close.start, end: close.end);
    }
  }
}

/// Sorts and coalesces overlapping or touching ranges.
///
/// The sort is made stable by hand (Dart's `List.sort` is not) even though
/// equal starts cannot change the merged result — a stable sort keeps the
/// intermediate list identical to upstream's, which makes divergences easier to
/// spot if the merge rule ever changes.
List<_ProtectedMarkdownRange> _mergeProtectedRanges(
  List<_ProtectedMarkdownRange> ranges,
) {
  final indexed = ranges.indexed.toList()
    ..sort((a, b) {
      final byStart = a.$2.start.compareTo(b.$2.start);
      return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
    });

  final merged = <_ProtectedMarkdownRange>[];
  for (final (_, range) in indexed) {
    final previous = merged.isEmpty ? null : merged.last;
    if (previous == null || range.start > previous.end) {
      merged.add(_ProtectedMarkdownRange(start: range.start, end: range.end));
      continue;
    }
    merged[merged.length - 1] = _ProtectedMarkdownRange(
      start: previous.start,
      end: math.max(previous.end, range.end),
    );
  }

  return merged;
}

bool _isProtectedIndex(int index, List<_ProtectedMarkdownRange> ranges) =>
    ranges.any((range) => index >= range.start && index < range.end);

// ---------------------------------------------------------------------------
// htmlparser2 port
//
// A faithful port of htmlparser2 12.0.0's `Tokenizer` + `Parser`, narrowed to
// the option set upstream configures. htmlparser2 is MIT licensed; the notice
// is in THIRD_PARTY_NOTICES.md at the repository root.
//
// The option set is: HTML mode, entity decoding OFF, tag and
// attribute names lowercased, self-closing tags recognised. Everything the
// disabled options make unreachable (the entity decoder, XML mode, processing
// instructions) is left out; every branch that stays reachable is kept, because
// its behaviour on malformed markup is exactly what "leave it inert" depends
// on.
// ---------------------------------------------------------------------------

/// What the parser reports back. Narrowed to the four events this module
/// subscribes to upstream; every other htmlparser2 callback is unregistered
/// there, and an unregistered callback changes parser behaviour (for example an
/// absent `onopentag` suppresses attribute collection), so the omissions are
/// part of the contract.
abstract interface class _HtmlHandler {
  void onOpenTag(String name, Map<String, String> attributes, bool isImplied);
  void onCloseTag(String name, bool isImplied);
  void onText(String value);
  void onComment(String data);
}

enum _TokenizerState {
  text,
  beforeTagName,
  inTagName,
  inSelfClosingTag,
  beforeClosingTagName,
  inClosingTagName,
  afterClosingTagName,
  beforeAttributeName,
  inAttributeName,
  afterAttributeName,
  beforeAttributeValue,
  inAttributeValueDq,
  inAttributeValueSq,
  inAttributeValueNq,
  beforeDeclaration,
  inDeclaration,
  beforeComment,
  cdataSequence,
  declarationSequence,
  inSpecialComment,
  inCommentLike,
  specialStartSequence,
  inSpecialTag,
  inPlainText,
}

enum _QuoteType { noValue, unquoted, single, double }

enum _ForeignContext { none, svg, mathML }

const int _charTab = 0x9;
const int _charNewLine = 0xa;
const int _charFormFeed = 0xc;
const int _charCarriageReturn = 0xd;
const int _charSpace = 0x20;
const int _charExclamationMark = 0x21;
const int _charDoubleQuote = 0x22;
const int _charSingleQuote = 0x27;
const int _charDash = 0x2d;
const int _charSlash = 0x2f;
const int _charLt = 0x3c;
const int _charEq = 0x3d;
const int _charGt = 0x3e;
const int _charQuestionMark = 0x3f;
const int _charUpperA = 0x41;
const int _charUpperZ = 0x5a;
const int _charOpeningSquareBracket = 0x5b;
const int _charLowerA = 0x61;
const int _charLowerZ = 0x7a;

// Match sequences. Upstream stores these as byte arrays compared by identity;
// Dart uses strings compared by value, which is equivalent because every
// sequence is distinct.
const String _seqEmpty = '';
const String _seqCdata = 'CDATA[';
const String _seqCdataEnd = ']]>';
const String _seqCommentEnd = '--!>';
const String _seqDoctype = 'doctype';
const String _seqIframeEnd = '</iframe';
const String _seqNoembedEnd = '</noembed';
const String _seqNoframesEnd = '</noframes';
const String _seqPlaintext = '</plaintext';
const String _seqScriptEnd = '</script';
const String _seqStyleEnd = '</style';
const String _seqTitleEnd = '</title';
const String _seqTextareaEnd = '</textarea';
const String _seqXmpEnd = '</xmp';

/// Maps the first character of a text-only tag name to the end sequence used to
/// scan for its terminator. `style` and `textarea` and `noframes` are reached
/// by branching mid-sequence, exactly as upstream does.
final Map<int, String> _specialStartSequences = {
  _seqIframeEnd.codeUnitAt(2): _seqIframeEnd,
  _seqNoembedEnd.codeUnitAt(2): _seqNoembedEnd,
  _seqPlaintext.codeUnitAt(2): _seqPlaintext,
  _seqScriptEnd.codeUnitAt(2): _seqScriptEnd,
  _seqTitleEnd.codeUnitAt(2): _seqTitleEnd,
  _seqXmpEnd.codeUnitAt(2): _seqXmpEnd,
};

const Set<String> _formTags = {
  'input',
  'option',
  'optgroup',
  'select',
  'button',
  'datalist',
  'textarea',
};
const Set<String> _pTag = {'p'};
const Set<String> _headingTags = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p'};
const Set<String> _tableSectionTags = {'thead', 'tbody'};
const Set<String> _ddtTags = {'dd', 'dt'};
const Set<String> _rtpTags = {'rt', 'rp'};

/// Which already-open tags an opening tag implicitly closes. Ported verbatim:
/// it is what makes `<p>a<p>b` produce two paragraphs, and (more relevantly
/// here) what makes a stray `<p>` before a `<details>` not swallow it.
const Map<String, Set<String>> _openImpliesClose = {
  'tr': {'tr', 'th', 'td'},
  'th': {'th'},
  'td': {'thead', 'th', 'td'},
  'body': {'head', 'link', 'script'},
  'a': {'a'},
  'li': {'li'},
  'p': _pTag,
  'h1': _headingTags,
  'h2': _headingTags,
  'h3': _headingTags,
  'h4': _headingTags,
  'h5': _headingTags,
  'h6': _headingTags,
  'select': _formTags,
  'input': _formTags,
  'output': _formTags,
  'button': _formTags,
  'datalist': _formTags,
  'textarea': _formTags,
  'option': {'option'},
  'optgroup': {'optgroup', 'option'},
  'dd': _ddtTags,
  'dt': _ddtTags,
  'address': _pTag,
  'article': _pTag,
  'aside': _pTag,
  'blockquote': _pTag,
  'details': _pTag,
  'div': _pTag,
  'dl': _pTag,
  'fieldset': _pTag,
  'figcaption': _pTag,
  'figure': _pTag,
  'footer': _pTag,
  'form': _pTag,
  'header': _pTag,
  'hr': _pTag,
  'main': _pTag,
  'nav': _pTag,
  'ol': _pTag,
  'pre': _pTag,
  'section': _pTag,
  'table': _pTag,
  'ul': _pTag,
  'rt': _rtpTags,
  'rp': _rtpTags,
  'tbody': _tableSectionTags,
  'tfoot': _tableSectionTags,
};

const Set<String> _voidElements = {
  'area',
  'base',
  'basefont',
  'br',
  'col',
  'command',
  'embed',
  'frame',
  'hr',
  'img',
  'input',
  'isindex',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

const Set<String> _foreignContextElements = {'math', 'svg'};

const Set<String> _htmlIntegrationElements = {
  'mi',
  'mo',
  'mn',
  'ms',
  'mtext',
  'annotation-xml',
  'foreignObject',
  'desc',
  'title',
};

const Map<String, String> _svgTagNameAdjustments = {
  'altglyph': 'altGlyph',
  'altglyphdef': 'altGlyphDef',
  'altglyphitem': 'altGlyphItem',
  'animatecolor': 'animateColor',
  'animatemotion': 'animateMotion',
  'animatetransform': 'animateTransform',
  'clippath': 'clipPath',
  'feblend': 'feBlend',
  'fecolormatrix': 'feColorMatrix',
  'fecomponenttransfer': 'feComponentTransfer',
  'fecomposite': 'feComposite',
  'feconvolvematrix': 'feConvolveMatrix',
  'fediffuselighting': 'feDiffuseLighting',
  'fedisplacementmap': 'feDisplacementMap',
  'fedistantlight': 'feDistantLight',
  'fedropshadow': 'feDropShadow',
  'feflood': 'feFlood',
  'fefunca': 'feFuncA',
  'fefuncb': 'feFuncB',
  'fefuncg': 'feFuncG',
  'fefuncr': 'feFuncR',
  'fegaussianblur': 'feGaussianBlur',
  'feimage': 'feImage',
  'femerge': 'feMerge',
  'femergenode': 'feMergeNode',
  'femorphology': 'feMorphology',
  'feoffset': 'feOffset',
  'fepointlight': 'fePointLight',
  'fespecularlighting': 'feSpecularLighting',
  'fespotlight': 'feSpotLight',
  'fetile': 'feTile',
  'feturbulence': 'feTurbulence',
  'foreignobject': 'foreignObject',
  'glyphref': 'glyphRef',
  'lineargradient': 'linearGradient',
  'radialgradient': 'radialGradient',
  'textpath': 'textPath',
};

bool _isTokenizerWhitespace(int c) =>
    c == _charSpace ||
    c == _charNewLine ||
    c == _charTab ||
    c == _charFormFeed ||
    c == _charCarriageReturn;

bool _isEndOfTagSection(int c) =>
    c == _charSlash || c == _charGt || _isTokenizerWhitespace(c);

bool _isAsciiAlpha(int c) =>
    (c >= _charLowerA && c <= _charLowerZ) ||
    (c >= _charUpperA && c <= _charUpperZ);

/// Character-level HTML scanner. Emits index pairs into the written stream; the
/// parser turns them into strings.
final class _HtmlTokenizer {
  _HtmlTokenizer(this._cbs);

  final _HtmlParser _cbs;

  _TokenizerState _state = _TokenizerState.text;

  /// The chunk currently being scanned. Older chunks are gone from here but
  /// still addressable through [_offset], which is what lets indices stay
  /// absolute across writes.
  String _buffer = '';
  int _sectionStart = 0;
  int _index = 0;
  bool _isSpecial = false;
  int _offset = 0;
  String _currentSequence = _seqEmpty;
  int _sequenceIndex = 0;

  void write(String chunk) {
    _offset += _buffer.length;
    _buffer = chunk;
    _parse();
  }

  void end() => _finish();

  int _charAt(int index) => _buffer.codeUnitAt(index - _offset);

  int get _limit => _buffer.length + _offset;

  void _stateText(int c) {
    // Entity decoding is disabled, so the tokenizer may always skip straight to
    // the next `<`.
    if (c == _charLt || _fastForwardTo(_charLt)) {
      if (_index > _sectionStart) _cbs.onText(_sectionStart, _index);
      _state = _TokenizerState.beforeTagName;
      _sectionStart = _index;
    }
  }

  void _enterTagBody() {
    if (_currentSequence == _seqPlaintext) {
      _currentSequence = _seqEmpty;
      _state = _TokenizerState.inPlainText;
    } else if (_isSpecial) {
      _state = _TokenizerState.inSpecialTag;
      _sequenceIndex = 0;
    } else {
      _state = _TokenizerState.text;
    }
  }

  void _stateSpecialStartSequence(int c) {
    final lower = c | 0x20;

    if (_sequenceIndex < _currentSequence.length) {
      if (lower == _currentSequence.codeUnitAt(_sequenceIndex)) {
        _sequenceIndex++;
        return;
      }

      if (_sequenceIndex == 3) {
        if (_currentSequence == _seqScriptEnd &&
            lower == _seqStyleEnd.codeUnitAt(3)) {
          _currentSequence = _seqStyleEnd;
          _sequenceIndex = 4;
          return;
        }
        if (_currentSequence == _seqTitleEnd &&
            lower == _seqTextareaEnd.codeUnitAt(3)) {
          _currentSequence = _seqTextareaEnd;
          _sequenceIndex = 4;
          return;
        }
      } else if (_sequenceIndex == 4 &&
          _currentSequence == _seqNoembedEnd &&
          lower == _seqNoframesEnd.codeUnitAt(4)) {
        _currentSequence = _seqNoframesEnd;
        _sequenceIndex = 5;
        return;
      }
    } else if (_isEndOfTagSection(c)) {
      _sequenceIndex = 0;
      _state = _TokenizerState.inTagName;
      _stateInTagName(c);
      return;
    }

    _isSpecial = false;
    _currentSequence = _seqEmpty;
    _sequenceIndex = 0;
    _state = _TokenizerState.inTagName;
    _stateInTagName(c);
  }

  void _stateCdataSequence(int c) {
    if (c == _seqCdata.codeUnitAt(_sequenceIndex)) {
      if (++_sequenceIndex == _seqCdata.length) {
        _state = _TokenizerState.inCommentLike;
        _currentSequence = _seqCdataEnd;
        _sequenceIndex = 0;
        _sectionStart = _index + 1;
      }
    } else {
      _sequenceIndex = 0;
      _state = _TokenizerState.inSpecialComment;
      _stateInSpecialComment(c);
    }
  }

  bool _fastForwardTo(int c) {
    while (++_index < _limit) {
      if (_charAt(_index) == c) return true;
    }

    // The parse loop increments the index at the end of each pass, so land one
    // short of the limit here.
    _index = _limit - 1;
    return false;
  }

  void _emitComment(int offset) {
    _cbs.onComment(_sectionStart, _index, offset);
    _sequenceIndex = 0;
    _sectionStart = _index + 1;
    _state = _TokenizerState.text;
  }

  void _stateInCommentLike(int c) {
    if (_currentSequence == _seqCommentEnd &&
        _sequenceIndex <= 1 &&
        _index == _sectionStart + _sequenceIndex &&
        c == _charGt) {
      // Abruptly closed empty HTML comment (`<!-->` / `<!--->`).
      _emitComment(_sequenceIndex);
    } else if (_currentSequence == _seqCommentEnd &&
        _sequenceIndex == 2 &&
        c == _charGt) {
      // The `!` in `--!>` is optional, so `-->` lands here.
      _emitComment(2);
    } else if (_currentSequence == _seqCommentEnd &&
        _sequenceIndex == _currentSequence.length - 1 &&
        c != _charGt) {
      _sequenceIndex = c == _charDash ? 1 : 0;
    } else if (_sequenceIndex < _currentSequence.length &&
        c == _currentSequence.codeUnitAt(_sequenceIndex)) {
      if (++_sequenceIndex == _currentSequence.length) {
        if (_currentSequence == _seqCdataEnd) {
          _cbs.onCdata(_sectionStart, _index, 2);
        } else {
          _cbs.onComment(_sectionStart, _index, 3);
        }
        _sequenceIndex = 0;
        _sectionStart = _index + 1;
        _state = _TokenizerState.text;
      }
    } else if (_sequenceIndex == 0) {
      if (_fastForwardTo(_currentSequence.codeUnitAt(0))) _sequenceIndex = 1;
    } else if (c != _currentSequence.codeUnitAt(_sequenceIndex - 1)) {
      // Allow long sequences such as `--->` and `]]]>`.
      _sequenceIndex = 0;
    }
  }

  void _stateInSpecialTag(int c) {
    if (_sequenceIndex == _currentSequence.length) {
      if (_isEndOfTagSection(c)) {
        final endOfText = _index - _currentSequence.length;

        if (_sectionStart < endOfText) {
          // Spoof the index so reported locations line up.
          final actualIndex = _index;
          _index = endOfText;
          _cbs.onText(_sectionStart, endOfText);
          _index = actualIndex;
        }

        _isSpecial = false;
        _sectionStart = endOfText + 2; // Skip over the `</`.
        _stateInClosingTagName(c);
        return;
      }

      _sequenceIndex = 0;
    }

    if ((c | 0x20) == _currentSequence.codeUnitAt(_sequenceIndex)) {
      _sequenceIndex += 1;
    } else if (_sequenceIndex == 0) {
      // With entity decoding off, RCDATA tags have nothing to decode, so only
      // the raw-text fast path remains.
      if (_currentSequence != _seqTitleEnd &&
          _currentSequence != _seqTextareaEnd &&
          _fastForwardTo(_charLt)) {
        _sequenceIndex = 1;
      }
    } else {
      // On a `<`, restart the sequence at 1; useful for eg. `<</script>`.
      _sequenceIndex = c == _charLt ? 1 : 0;
    }
  }

  void _stateBeforeTagName(int c) {
    if (c == _charExclamationMark) {
      _state = _TokenizerState.beforeDeclaration;
      _sectionStart = _index + 1;
    } else if (c == _charQuestionMark) {
      _state = _TokenizerState.inSpecialComment;
      _sectionStart = _index;
    } else if (_isAsciiAlpha(c)) {
      _sectionStart = _index;

      final special = _cbs.isInForeignContext()
          ? null
          : _specialStartSequences[c | 0x20];

      if (special == null) {
        _state = _TokenizerState.inTagName;
      } else {
        _isSpecial = true;
        _currentSequence = special;
        _sequenceIndex = 3;
        _state = _TokenizerState.specialStartSequence;
      }
    } else if (c == _charSlash) {
      _state = _TokenizerState.beforeClosingTagName;
    } else {
      _state = _TokenizerState.text;
      _stateText(c);
    }
  }

  void _stateInTagName(int c) {
    if (_isEndOfTagSection(c)) {
      _cbs.onOpenTagName(_sectionStart, _index);
      _sectionStart = -1;
      _state = _TokenizerState.beforeAttributeName;
      _stateBeforeAttributeName(c);
    }
  }

  void _stateBeforeClosingTagName(int c) {
    if (_isTokenizerWhitespace(c)) {
      _state = _TokenizerState.inSpecialComment;
      _sectionStart = _index;
    } else if (c == _charGt) {
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    } else {
      _state = _isAsciiAlpha(c)
          ? _TokenizerState.inClosingTagName
          : _TokenizerState.inSpecialComment;
      _sectionStart = _index;
    }
  }

  void _stateInClosingTagName(int c) {
    if (_isEndOfTagSection(c)) {
      _cbs.onCloseTagIndices(_sectionStart, _index);
      _sectionStart = -1;
      _state = _TokenizerState.afterClosingTagName;
      _stateAfterClosingTagName(c);
    }
  }

  void _stateAfterClosingTagName(int c) {
    // Skip everything until `>`.
    if (c == _charGt || _fastForwardTo(_charGt)) {
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    }
  }

  void _stateBeforeAttributeName(int c) {
    if (c == _charGt) {
      _cbs.onOpenTagEnd(_index);
      _enterTagBody();
      _sectionStart = _index + 1;
    } else if (c == _charSlash) {
      _state = _TokenizerState.inSelfClosingTag;
    } else if (!_isTokenizerWhitespace(c)) {
      _state = _TokenizerState.inAttributeName;
      _sectionStart = _index;
    }
  }

  void _stateInSelfClosingTag(int c) {
    if (c == _charGt) {
      _cbs.onSelfClosingTag(_index);
      _sectionStart = _index + 1;
      // Self-closing tags are recognised, so scanning returns to plain text.
      _state = _TokenizerState.text;
      _isSpecial = false;
      _currentSequence = _seqEmpty;
    } else if (!_isTokenizerWhitespace(c)) {
      _state = _TokenizerState.beforeAttributeName;
      _stateBeforeAttributeName(c);
    }
  }

  void _stateInAttributeName(int c) {
    if (c == _charEq || _isEndOfTagSection(c)) {
      _cbs.onAttribName(_sectionStart, _index);
      _sectionStart = _index;
      _state = _TokenizerState.afterAttributeName;
      _stateAfterAttributeName(c);
    }
  }

  void _stateAfterAttributeName(int c) {
    if (c == _charEq) {
      _state = _TokenizerState.beforeAttributeValue;
    } else if (c == _charSlash || c == _charGt) {
      _cbs.onAttribEnd(_QuoteType.noValue, _sectionStart);
      _sectionStart = -1;
      _state = _TokenizerState.beforeAttributeName;
      _stateBeforeAttributeName(c);
    } else if (!_isTokenizerWhitespace(c)) {
      _cbs.onAttribEnd(_QuoteType.noValue, _sectionStart);
      _state = _TokenizerState.inAttributeName;
      _sectionStart = _index;
    }
  }

  void _stateBeforeAttributeValue(int c) {
    if (c == _charDoubleQuote) {
      _state = _TokenizerState.inAttributeValueDq;
      _sectionStart = _index + 1;
    } else if (c == _charSingleQuote) {
      _state = _TokenizerState.inAttributeValueSq;
      _sectionStart = _index + 1;
    } else if (!_isTokenizerWhitespace(c)) {
      _sectionStart = _index;
      _state = _TokenizerState.inAttributeValueNq;
      _stateInAttributeValueNoQuotes(c); // Reconsume the character.
    }
  }

  void _handleInAttributeValue(int c, int quote) {
    if (c == quote || _fastForwardTo(quote)) {
      _cbs.onAttribData(_sectionStart, _index);
      _sectionStart = -1;
      _cbs.onAttribEnd(
        quote == _charDoubleQuote ? _QuoteType.double : _QuoteType.single,
        _index + 1,
      );
      _state = _TokenizerState.beforeAttributeName;
    }
  }

  void _stateInAttributeValueNoQuotes(int c) {
    if (_isTokenizerWhitespace(c) || c == _charGt) {
      _cbs.onAttribData(_sectionStart, _index);
      _sectionStart = -1;
      _cbs.onAttribEnd(_QuoteType.unquoted, _index);
      _state = _TokenizerState.beforeAttributeName;
      _stateBeforeAttributeName(c);
    }
  }

  void _stateBeforeDeclaration(int c) {
    if (c == _charOpeningSquareBracket) {
      _state = _TokenizerState.cdataSequence;
      _sequenceIndex = 0;
    } else if ((c | 0x20) == _seqDoctype.codeUnitAt(0)) {
      _state = _TokenizerState.declarationSequence;
      _currentSequence = _seqDoctype;
      _sequenceIndex = 1;
    } else if (c == _charGt) {
      _cbs.onComment(_sectionStart, _index, 0);
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    } else if (c == _charDash) {
      _state = _TokenizerState.beforeComment;
    } else {
      _state = _TokenizerState.inSpecialComment;
    }
  }

  void _stateDeclarationSequence(int c) {
    if (_sequenceIndex == _currentSequence.length) {
      _state = _TokenizerState.inDeclaration;
      _stateInDeclaration(c);
    } else if ((c | 0x20) == _currentSequence.codeUnitAt(_sequenceIndex)) {
      _sequenceIndex += 1;
    } else if (c == _charGt) {
      _cbs.onComment(_sectionStart, _index, 0);
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    } else {
      _state = _TokenizerState.inSpecialComment;
    }
  }

  void _stateInDeclaration(int c) {
    if (c == _charGt || _fastForwardTo(_charGt)) {
      _cbs.onDeclaration(_sectionStart, _index);
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    }
  }

  void _stateBeforeComment(int c) {
    if (c == _charDash) {
      _state = _TokenizerState.inCommentLike;
      _currentSequence = _seqCommentEnd;
      _sequenceIndex = 0;
      _sectionStart = _index + 1;
    } else if (c == _charGt) {
      _cbs.onComment(_sectionStart, _index, 0);
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    } else {
      _state = _TokenizerState.inSpecialComment;
    }
  }

  void _stateInSpecialComment(int c) {
    if (c == _charGt || _fastForwardTo(_charGt)) {
      _cbs.onComment(_sectionStart, _index, 0);
      _state = _TokenizerState.text;
      _sectionStart = _index + 1;
    }
  }

  /// Flushes whatever is complete at the end of a chunk. This is why writing
  /// the source in slices around protected ranges produces extra text token
  /// boundaries — a behaviour the split logic depends on.
  void _cleanup() {
    if (_sectionStart == _index) return;

    if (_state == _TokenizerState.text ||
        _state == _TokenizerState.inPlainText ||
        (_state == _TokenizerState.inSpecialTag && _sequenceIndex == 0)) {
      _cbs.onText(_sectionStart, _index);
      _sectionStart = _index;
    } else if (_state == _TokenizerState.inAttributeValueDq ||
        _state == _TokenizerState.inAttributeValueSq ||
        _state == _TokenizerState.inAttributeValueNq) {
      _cbs.onAttribData(_sectionStart, _index);
      _sectionStart = _index;
    }
  }

  void _parse() {
    while (_index < _limit) {
      final c = _charAt(_index);
      switch (_state) {
        case _TokenizerState.text:
          _stateText(c);
        case _TokenizerState.inPlainText:
          // Skip to end of buffer; `_cleanup` emits the text.
          _index = _limit - 1;
        case _TokenizerState.specialStartSequence:
          _stateSpecialStartSequence(c);
        case _TokenizerState.inSpecialTag:
          _stateInSpecialTag(c);
        case _TokenizerState.cdataSequence:
          _stateCdataSequence(c);
        case _TokenizerState.declarationSequence:
          _stateDeclarationSequence(c);
        case _TokenizerState.inAttributeValueDq:
          _handleInAttributeValue(c, _charDoubleQuote);
        case _TokenizerState.inAttributeName:
          _stateInAttributeName(c);
        case _TokenizerState.inCommentLike:
          _stateInCommentLike(c);
        case _TokenizerState.inSpecialComment:
          _stateInSpecialComment(c);
        case _TokenizerState.beforeAttributeName:
          _stateBeforeAttributeName(c);
        case _TokenizerState.inTagName:
          _stateInTagName(c);
        case _TokenizerState.inClosingTagName:
          _stateInClosingTagName(c);
        case _TokenizerState.beforeTagName:
          _stateBeforeTagName(c);
        case _TokenizerState.afterAttributeName:
          _stateAfterAttributeName(c);
        case _TokenizerState.inAttributeValueSq:
          _handleInAttributeValue(c, _charSingleQuote);
        case _TokenizerState.beforeAttributeValue:
          _stateBeforeAttributeValue(c);
        case _TokenizerState.beforeClosingTagName:
          _stateBeforeClosingTagName(c);
        case _TokenizerState.afterClosingTagName:
          _stateAfterClosingTagName(c);
        case _TokenizerState.inAttributeValueNq:
          _stateInAttributeValueNoQuotes(c);
        case _TokenizerState.inSelfClosingTag:
          _stateInSelfClosingTag(c);
        case _TokenizerState.inDeclaration:
          _stateInDeclaration(c);
        case _TokenizerState.beforeDeclaration:
          _stateBeforeDeclaration(c);
        case _TokenizerState.beforeComment:
          _stateBeforeComment(c);
      }
      _index++;
    }
    _cleanup();
  }

  void _finish() {
    _handleTrailingData();
    _cbs.onEnd();
  }

  bool _handleTrailingCommentLikeData(int endIndex) {
    if (_state != _TokenizerState.inCommentLike) return false;

    if (_currentSequence == _seqCdataEnd) {
      // In HTML mode an unclosed CDATA section is a bogus comment.
      final cdataStart = _sectionStart - _seqCdata.length - 1;
      _cbs.onComment(cdataStart, endIndex, 0);
    } else {
      final offset = math.min(_sequenceIndex, _seqCommentEnd.length - 1);
      _cbs.onComment(_sectionStart, endIndex, offset);
    }

    return true;
  }

  bool _handleTrailingMarkupDeclaration(int endIndex) {
    switch (_state) {
      case _TokenizerState.beforeDeclaration:
      case _TokenizerState.inSpecialComment:
      case _TokenizerState.beforeComment:
      case _TokenizerState.cdataSequence:
        _cbs.onComment(_sectionStart, endIndex, 0);
        return true;
      case _TokenizerState.declarationSequence:
        if (_sequenceIndex != _seqDoctype.length) {
          _cbs.onComment(_sectionStart, endIndex, 0);
        }
        return true;
      case _TokenizerState.inDeclaration:
        return true;
      default:
        return false;
    }
  }

  void _handleTrailingData() {
    final endIndex = _limit;

    if (_handleTrailingCommentLikeData(endIndex) ||
        _handleTrailingMarkupDeclaration(endIndex)) {
      return;
    }

    if (_sectionStart >= endIndex) return;

    switch (_state) {
      case _TokenizerState.inTagName:
      case _TokenizerState.beforeAttributeName:
      case _TokenizerState.beforeAttributeValue:
      case _TokenizerState.afterAttributeName:
      case _TokenizerState.inAttributeName:
      case _TokenizerState.inAttributeValueSq:
      case _TokenizerState.inAttributeValueDq:
      case _TokenizerState.inAttributeValueNq:
      case _TokenizerState.inClosingTagName:
        // Staying silent here is how the parser signals "an unterminated tag
        // was in progress; drop it". That is what makes a truncated
        // `<details><summary>` fall back to inert markdown.
        break;
      default:
        _cbs.onText(_sectionStart, endIndex);
    }
  }
}

/// Turns tokenizer index pairs into named events, maintaining the open-element
/// stack that decides which closes are implied.
final class _HtmlParser {
  _HtmlParser(this._handler) {
    _tokenizer = _HtmlTokenizer(this);
  }

  final _HtmlHandler _handler;
  late final _HtmlTokenizer _tokenizer;

  /// Start index of the last event, in source coordinates of everything written
  /// so far. Read by the comment handler to decide whether a comment began a
  /// line.
  int startIndex = 0;
  int endIndex = 0;
  int _openTagStart = 0;

  String _tagname = '';
  String _attribname = '';
  String _attribvalue = '';
  Map<String, String>? _attribs;
  final List<String> _stack = [];
  final List<_ForeignContext> _foreignContext = [_ForeignContext.none];

  /// Everything written so far, concatenated. Upstream keeps a list of chunks
  /// and shifts them as they are consumed; holding one string is equivalent for
  /// the slice sizes this module sees and keeps index arithmetic obvious.
  String _written = '';
  bool _ended = false;

  void write(String chunk) {
    if (_ended) return;
    _written += chunk;
    _tokenizer.write(chunk);
  }

  void end() {
    if (_ended) return;
    _ended = true;
    _tokenizer.end();
  }

  String _getSlice(int start, int end) {
    if (start == end) return '';
    final from = start.clamp(0, _written.length);
    final to = end.clamp(from, _written.length);
    return _written.substring(from, to);
  }

  bool isInForeignContext() => _foreignContext.first != _ForeignContext.none;

  bool _isVoidElement(String name) => _voidElements.contains(name);

  /// Reads a tag name, lowercasing it and applying the two HTML quirks that
  /// survive: SVG's mixed-case element names, and the `image` → `img` alias.
  ///
  /// Deviation: `toLowerCase` follows Dart's Unicode mapping rather than
  /// JavaScript's; the two can differ for exotic letters (`U+0130`), which can
  /// only appear in a tag name after a leading ASCII letter. Never observed in
  /// real markup.
  String _readTagName(int start, int end) {
    final name = _getSlice(start, end).toLowerCase();

    if (_foreignContext.first == _ForeignContext.svg) {
      return _svgTagNameAdjustments[name] ?? name;
    }

    if (_foreignContext.length > 1) {
      final adjusted = _svgTagNameAdjustments[name];
      if (adjusted != null && _stack.contains(adjusted)) return adjusted;
    }

    if (!isInForeignContext()) return name == 'image' ? 'img' : name;

    return name;
  }

  void onText(int start, int end) {
    final data = _getSlice(start, end);
    endIndex = end - 1;
    _handler.onText(data);
    startIndex = end;
  }

  void onOpenTagName(int start, int end) {
    endIndex = end;
    _emitOpenTag(_readTagName(start, end));
  }

  void _emitOpenTag(String name) {
    _openTagStart = startIndex;
    _tagname = name;

    // The spec ignores a second `<form>` while one is open. Blanking the tag
    // name suppresses everything downstream: attributes are never collected, so
    // no open event is emitted at all.
    if (name == 'form' && _stack.contains('form')) {
      _tagname = '';
      return;
    }

    final impliesClose = _openImpliesClose[name];
    if (impliesClose != null) {
      while (_stack.isNotEmpty && impliesClose.contains(_stack.first)) {
        _popElement(true);
      }
    }

    if (!_isVoidElement(name)) {
      _stack.insert(0, name);
      if (name == 'svg') {
        _foreignContext.insert(0, _ForeignContext.svg);
      } else if (name == 'math') {
        _foreignContext.insert(0, _ForeignContext.mathML);
      } else if (_htmlIntegrationElements.contains(name)) {
        _foreignContext.insert(0, _ForeignContext.none);
      }
    }

    _attribs = <String, String>{};
  }

  void _endOpenTag(bool isImplied) {
    startIndex = _openTagStart;

    final attribs = _attribs;
    if (attribs != null) {
      _handler.onOpenTag(_tagname, attribs, isImplied);
      _attribs = null;
    }
    if (_isVoidElement(_tagname)) _handler.onCloseTag(_tagname, true);

    _tagname = '';
  }

  void onOpenTagEnd(int end) {
    endIndex = end;
    _endOpenTag(false);
    startIndex = end + 1;
  }

  void onCloseTagIndices(int start, int end) {
    endIndex = end;
    final name = _readTagName(start, end);

    if (!_isVoidElement(name)) {
      final pos = _stack.indexOf(name);
      if (pos != -1) {
        for (var index = 0; index < pos; index++) {
          _popElement(true);
        }
        _popElement(false);
      } else if (name == 'p') {
        // Implicit open before close.
        _emitOpenTag('p');
        _closeCurrentTag(true);
      }
    } else if (name == 'br') {
      // `br` cannot go through `_emitOpenTag`, which would immediately imply
      // its close.
      _handler.onOpenTag('br', <String, String>{}, true);
      _handler.onCloseTag('br', false);
    }

    startIndex = end + 1;
  }

  void onSelfClosingTag(int end) {
    endIndex = end;
    _closeCurrentTag(false);
    startIndex = end + 1;
  }

  void _popElement(bool implied) {
    final element = _stack.removeAt(0);
    if (_foreignContextElements.contains(element) ||
        _htmlIntegrationElements.contains(element)) {
      _foreignContext.removeAt(0);
    }
    _handler.onCloseTag(element, implied);
  }

  void _closeCurrentTag(bool isOpenImplied) {
    final name = _tagname;
    _endOpenTag(isOpenImplied);

    // Self-closing tags sit on the top of the stack.
    if (_stack.isNotEmpty && _stack.first == name) _popElement(!isOpenImplied);
  }

  void onAttribName(int start, int end) {
    startIndex = start;
    _attribname = _getSlice(start, end).toLowerCase();
  }

  void onAttribData(int start, int end) {
    _attribvalue += _getSlice(start, end);
  }

  void onAttribEnd(_QuoteType quote, int end) {
    endIndex = end;
    // First occurrence of a repeated attribute wins.
    final attribs = _attribs;
    if (attribs != null && !attribs.containsKey(_attribname)) {
      attribs[_attribname] = _attribvalue;
    }
    _attribvalue = '';
  }

  /// Doctypes are parsed and discarded: upstream registers no processing
  /// instruction handler, so `<!DOCTYPE html>` leaves no token behind.
  void onDeclaration(int start, int end) {
    endIndex = end;
    startIndex = end + 1;
  }

  void onComment(int start, int end, int offset) {
    endIndex = end;
    _handler.onComment(_getSlice(start, end - offset));
    startIndex = end + 1;
  }

  /// CDATA is not recognised in HTML mode, so it surfaces as a comment (and
  /// therefore disappears) unless it sits inside `<svg>`/`<math>`, where it is
  /// text.
  void onCdata(int start, int end, int offset) {
    endIndex = end;
    final value = _getSlice(start, end - offset);

    if (isInForeignContext()) {
      _handler.onText(value);
    } else {
      _handler.onComment('[CDATA[$value]]');
    }

    startIndex = end + 1;
  }

  void onEnd() {
    endIndex = startIndex;
    for (final element in _stack) {
      _handler.onCloseTag(element, true);
    }
  }
}
