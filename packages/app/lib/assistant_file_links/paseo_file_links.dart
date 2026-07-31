/// Port of Paseo 0.2.0's `assistant-file-links/parse.ts` and
/// `assistant-file-links/resolver.ts`.
///
/// Assistants write file references in a dozen shapes — `src/app.ts:12`,
/// `file:///Users/me/app.tsx#L81`, a bare `README.md`, `C:\repo\a.ts(12,4)` —
/// and markdown-it linkifies some of them into `<a href="http://dumm.md">`
/// before the renderer ever sees them. These two modules are the single place
/// that decides, for one such reference:
///
/// * **Is it a file at all?** ([classifyAssistantFileLink]) External URLs must
///   stay external, and ordinary prose tokens (`main`, `origin/main`, a commit
///   sha, `google.com`) must not become clickable file links. The heuristics
///   are deliberately conservative: a bare token only counts as a file when its
///   last segment carries a known source-file extension, and a multi-segment
///   path additionally must not start with a domain-looking segment.
/// * **Which absolute path and line range does it point at?**
///   ([parseAssistantFileLink]) Workspace-relative paths are resolved under the
///   workspace root, `~/…` stays home-relative, and absolute paths — even ones
///   outside the workspace — are honoured as-is.
/// * **Can we answer now, or must the daemon look it up?**
///   ([classifyForResolution]) A bare basename like `dumm.md` could live
///   anywhere in the tree, so it is flagged `needsLookup` and resolved through
///   a directory-suggestion search instead of being guessed at.
///
/// The port is deliberately literal. Upstream leans on two JavaScript
/// behaviours Dart does not share, both reproduced here rather than
/// approximated:
///
/// * `String.prototype.trim()` — JS trims exactly the set its `\s` regex class
///   matches; Dart's [String.trim] additionally strips U+0085 NEL. Every trim
///   on this path goes through [_jsTrim] so a NEL-padded token keeps behaving
///   as upstream does. (Dart's RegExp `\s` *is* byte-identical to JS's, so the
///   whitespace *rejection* checks port over unchanged.)
/// * The WHATWG `URL` constructor — upstream runs hrefs through `new URL()` and
///   reads `.pathname`/`.hash`, which percent-encodes, resolves `.`/`..`
///   segments and swallows the authority. Dart's [Uri] is RFC 3986 and differs
///   on all three, so [_WhatwgUrl] implements the subset upstream depends on.
///   See its doc comment for the observable consequences.
library;

import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart'
    show DirectorySuggestionEntry, DirectorySuggestionKind;

import '../core/path.dart';

// ---------------------------------------------------------------------------
// JavaScript-compatible primitives
// ---------------------------------------------------------------------------

final RegExp _leadingJsWhitespace = RegExp(r'^\s+');
final RegExp _trailingJsWhitespace = RegExp(r'\s+$');

/// JavaScript's `String.prototype.trim()`.
///
/// Dart's [String.trim] strips U+0085 NEL, which JS does not, so a token
/// wrapped in NEL would parse differently under a naive port. Driving the trim
/// off Dart's RegExp `\s` — verified to match JS's `\s` class exactly, U+00A0
/// and U+FEFF included, U+0085/U+200B/U+180E excluded — keeps the two engines
/// in lockstep.
String _jsTrim(String value) => value
    .replaceFirst(_leadingJsWhitespace, '')
    .replaceFirst(_trailingJsWhitespace, '');

/// JavaScript's `decodeURIComponent`, wrapped so a malformed escape yields the
/// input instead of throwing.
///
/// This is load-bearing, not defensive dressing: assistant output routinely
/// contains `100% packet loss`, `%PATH%` and `0% off`, all of which raise
/// `URIError` upstream and would otherwise take down the whole message
/// renderer. Dart raises `ArgumentError` for a malformed escape and
/// `FormatException` for a well-formed escape that decodes to invalid UTF-8;
/// both are caught, matching JS's single `URIError`.
String _safeDecodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

/// JS `parseInt(digits, 10)` guarded by upstream's `Number.isFinite` and
/// `<= 0` checks, collapsed into one nullable result.
///
/// Deviation: JS numbers are doubles, so a 20-to-308-digit run parses to a
/// finite (if imprecise) value upstream and is accepted, while a 309+ digit run
/// becomes `Infinity` and is rejected. Dart ints are 64-bit, so anything past
/// ~19 digits fails [int.tryParse] and is rejected here. Both engines agree on
/// every line number a human or tool would ever emit, and both reject the
/// absurd end of the range; only the nonsense middle differs.
int? _parsePositiveJsInt(String digits) {
  final value = int.tryParse(digits);
  if (value == null || value <= 0) return null;
  return value;
}

// ---------------------------------------------------------------------------
// WHATWG URL subset
// ---------------------------------------------------------------------------

/// The slice of a WHATWG-parsed URL that upstream reads: `protocol`,
/// `pathname` and `hash`.
///
/// Dart's [Uri] cannot stand in for `new URL()` here. Three differences are
/// observable in the parsed file target:
///
/// * **Percent-encoding.** `new URL()` encodes spaces, `"`, `<`, `>`, `^`,
///   `` ` ``, `{`, `}`, C0 controls and every non-ASCII code point in the path.
///   Upstream then decodes the result, so most of it round-trips — but a path
///   holding a bare `%` does not: `/tmp/100% packet loss` becomes
///   `/tmp/100%%20packet%20loss`, which `decodeURIComponent` then refuses,
///   leaving that mangled string as the final path. [Uri] would have produced
///   something else entirely.
/// * **Dot-segment removal.** `/tmp/../etc/passwd` collapses to `/etc/passwd`.
/// * **Authority stripping.** `\\server\share\x.txt` is an absolute path by
///   [isAbsolutePath], reaches the URL branch, and `new URL()` reads `server`
///   as the host — so the resulting file path is `/share/x.txt`. Surprising,
///   but it is what upstream does, so the port reproduces it.
///
/// Only what the two call sites need is implemented: full fidelity for the
/// `file:` scheme and for scheme-less inputs resolved against the
/// `http://paseo.invalid` base, plus generic non-special schemes (which is how
/// a bare `C:/…` drive letter is read). Other special schemes report their
/// protocol only, because both call sites reject a non-`file:` protocol before
/// looking at anything else.
final class _WhatwgUrl {
  const _WhatwgUrl({
    required this.protocol,
    required this.pathname,
    required this.hash,
  });

  /// Lower-cased scheme including the trailing colon, e.g. `file:`.
  final String protocol;

  final String pathname;

  /// `#`-prefixed fragment, or the empty string when there is no fragment (an
  /// input ending in a bare `#` also reports the empty string, exactly as
  /// `URL.hash` does).
  final String hash;
}

final RegExp _urlSchemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+\-.]*:');
final RegExp _urlTabOrNewline = RegExp('[\t\n\r]');
final RegExp _windowsDriveLetterPattern = RegExp(r'^[A-Za-z][:|]$');

const Set<String> _specialUrlSchemes = {
  'ftp',
  'file',
  'http',
  'https',
  'ws',
  'wss',
};

/// The WHATWG "path percent-encode set", as observed from the reference
/// implementation: C0 controls, space, `"`, `<`, `>`, `^`, `` ` ``, `{`, `}`,
/// DEL, and every byte above ASCII.
bool _isPathEncodedByte(int byte) =>
    byte <= 0x20 ||
    byte == 0x22 ||
    byte == 0x3c ||
    byte == 0x3e ||
    byte == 0x5e ||
    byte == 0x60 ||
    byte == 0x7b ||
    byte == 0x7d ||
    byte >= 0x7f;

/// The WHATWG "fragment percent-encode set": narrower than the path set —
/// `^`, `{` and `}` survive a fragment untouched.
bool _isFragmentEncodedByte(int byte) =>
    byte <= 0x20 ||
    byte == 0x22 ||
    byte == 0x3c ||
    byte == 0x3e ||
    byte == 0x60 ||
    byte >= 0x7f;

/// The "C0 control percent-encode set", used for opaque (non-hierarchical)
/// paths such as `mailto:someone@example.com`.
bool _isC0ControlEncodedByte(int byte) => byte <= 0x1f || byte >= 0x7f;

String _percentEncode(String value, bool Function(int) shouldEncode) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (shouldEncode(byte)) {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    } else {
      buffer.writeCharCode(byte);
    }
  }
  return buffer.toString();
}

/// WHATWG strips leading and trailing C0-control-or-space characters from the
/// input and removes every embedded tab/CR/LF before parsing.
String _stripUrlControlCharacters(String input) {
  var start = 0;
  var end = input.length;
  while (start < end && input.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && input.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  return input.substring(start, end).replaceAll(_urlTabOrNewline, '');
}

bool _isSingleDotSegment(String segment) =>
    segment == '.' || segment.toLowerCase() == '%2e';

bool _isDoubleDotSegment(String segment) {
  if (segment == '..') return true;
  final lower = segment.toLowerCase();
  return lower == '.%2e' || lower == '%2e.' || lower == '%2e%2e';
}

/// Runs the WHATWG "path state" over [rawPath] and serialises the result.
///
/// A `.` segment is dropped, a `..` segment pops the previous one, and either
/// of them appends an empty segment when it is the *last* thing in the path —
/// which is why `/tmp/a/.` serialises with its trailing slash intact while
/// `/tmp/a/./b` does not gain one.
String _buildUrlPath(String rawPath, {required bool isFileScheme}) {
  final body = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
  final parts = body.split('/');
  final segments = <String>[];
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    final isLast = index == parts.length - 1;
    if (_isDoubleDotSegment(part)) {
      if (segments.isNotEmpty) segments.removeLast();
      if (isLast) segments.add('');
    } else if (_isSingleDotSegment(part)) {
      if (isLast) segments.add('');
    } else {
      segments.add(_percentEncode(part, _isPathEncodedByte));
    }
  }

  // `file:///C|/x.txt` is the legacy spelling of a Windows drive letter; the
  // spec normalises the `|` back to `:` so the path is usable.
  if (isFileScheme &&
      segments.isNotEmpty &&
      _windowsDriveLetterPattern.hasMatch(segments.first)) {
    segments[0] = '${segments.first[0]}:';
  }

  return '/${segments.join('/')}';
}

/// Parses everything after `scheme:` for a URL whose scheme is already known.
_WhatwgUrl _parseUrlAfterScheme(String scheme, String rest) {
  final protocol = '$scheme:';

  // Non-`file:` special schemes are never inspected past their protocol by
  // either call site, and emulating their host rules would buy nothing.
  if (scheme != 'file' && _specialUrlSchemes.contains(scheme)) {
    return _WhatwgUrl(protocol: protocol, pathname: '', hash: '');
  }

  var head = rest;
  var fragment = '';
  final hashIndex = head.indexOf('#');
  if (hashIndex >= 0) {
    fragment = head.substring(hashIndex + 1);
    head = head.substring(0, hashIndex);
  }
  final queryIndex = head.indexOf('?');
  if (queryIndex >= 0) {
    head = head.substring(0, queryIndex);
  }

  final isFile = scheme == 'file';
  if (isFile) {
    // `file:` is a special scheme, so backslashes are path separators.
    head = head.replaceAll(r'\', '/');
  }

  final String pathname;
  if (head.startsWith('//')) {
    final afterSlashes = head.substring(2);
    final hostEnd = afterSlashes.indexOf('/');
    final host = hostEnd < 0
        ? afterSlashes
        : afterSlashes.substring(0, hostEnd);
    final remainder = hostEnd < 0 ? '' : afterSlashes.substring(hostEnd);
    // `file://C:/x.txt` names a drive, not a host, so the "host" rejoins the
    // path instead of being discarded.
    pathname = isFile && _windowsDriveLetterPattern.hasMatch(host)
        ? _buildUrlPath('$host$remainder', isFileScheme: true)
        : _buildUrlPath(remainder, isFileScheme: isFile);
  } else if (isFile || head.startsWith('/')) {
    pathname = _buildUrlPath(head, isFileScheme: isFile);
  } else {
    // Opaque path: no segment normalisation, no leading slash.
    pathname = _percentEncode(head, _isC0ControlEncodedByte);
  }

  return _WhatwgUrl(
    protocol: protocol,
    pathname: pathname,
    hash: fragment.isEmpty
        ? ''
        : '#${_percentEncode(fragment, _isFragmentEncodedByte)}',
  );
}

/// `new URL(input)` — fails when [input] carries no scheme, since there is no
/// base to resolve against.
_WhatwgUrl? _parseAbsoluteUrl(String input) {
  final sanitized = _stripUrlControlCharacters(input);
  final schemeMatch = _urlSchemePattern.firstMatch(sanitized);
  if (schemeMatch == null) return null;
  final scheme = sanitized.substring(0, schemeMatch.end - 1).toLowerCase();
  return _parseUrlAfterScheme(scheme, sanitized.substring(schemeMatch.end));
}

/// `new URL(input, "http://paseo.invalid")`.
///
/// An [input] that carries its own scheme ignores the base entirely — which is
/// how `C:/repo/a?b.txt` ends up parsed as the non-special scheme `c:` and
/// yields the path `/repo/a`.
_WhatwgUrl? _parseUrlAgainstHttpBase(String input) {
  final sanitized = _stripUrlControlCharacters(input);
  final schemeMatch = _urlSchemePattern.firstMatch(sanitized);
  if (schemeMatch != null) {
    final scheme = sanitized.substring(0, schemeMatch.end - 1).toLowerCase();
    return _parseUrlAfterScheme(scheme, sanitized.substring(schemeMatch.end));
  }

  var head = sanitized;
  var fragment = '';
  final hashIndex = head.indexOf('#');
  if (hashIndex >= 0) {
    fragment = head.substring(hashIndex + 1);
    head = head.substring(0, hashIndex);
  }
  final queryIndex = head.indexOf('?');
  if (queryIndex >= 0) {
    head = head.substring(0, queryIndex);
  }
  // `http:` is special, so backslashes are separators here too — this is what
  // turns a UNC path into a host plus a share-relative path.
  head = head.replaceAll(r'\', '/');

  final String pathname;
  if (head.startsWith('//')) {
    // "Special authority ignore slashes state" skips *every* leading slash,
    // not just two.
    var index = 0;
    while (index < head.length && head.codeUnitAt(index) == 0x2f) {
      index++;
    }
    final afterSlashes = head.substring(index);
    final hostEnd = afterSlashes.indexOf('/');
    final remainder = hostEnd < 0 ? '' : afterSlashes.substring(hostEnd);
    pathname = _buildUrlPath(remainder, isFileScheme: false);
  } else {
    pathname = _buildUrlPath(head, isFileScheme: false);
  }

  return _WhatwgUrl(
    protocol: 'http:',
    pathname: pathname,
    hash: fragment.isEmpty
        ? ''
        : '#${_percentEncode(fragment, _isFragmentEncodedByte)}',
  );
}

// ---------------------------------------------------------------------------
// parse.ts
// ---------------------------------------------------------------------------

/// One file reference the assistant emitted, resolved to a path plus an
/// optional line range. Port of TS `InlinePathTarget`.
final class InlinePathTarget {
  const InlinePathTarget({
    required this.raw,
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  /// The originating token, kept verbatim so callers can echo what the
  /// assistant actually wrote. Note that upstream is inconsistent about
  /// trimming here and the port matches it: the `file:` and Windows-path
  /// branches record the untrimmed input, while the inline-token and
  /// workspace-relative branches record the trimmed one.
  final String raw;

  /// The resolved path, always `/`-separated. Either absolute, or
  /// home-relative (`~/…`) when the reference was written that way.
  final String path;

  /// 1-based first line, or null when the reference named no line.
  final int? lineStart;

  /// 1-based last line of an explicit range. Null for a single-line reference;
  /// never less than [lineStart].
  final int? lineEnd;

  InlinePathTarget copyWithPath(String path) => InlinePathTarget(
    raw: raw,
    path: path,
    lineStart: lineStart,
    lineEnd: lineEnd,
  );

  @override
  bool operator ==(Object other) =>
      other is InlinePathTarget &&
      other.raw == raw &&
      other.path == path &&
      other.lineStart == lineStart &&
      other.lineEnd == lineEnd;

  @override
  int get hashCode => Object.hash(raw, path, lineStart, lineEnd);

  @override
  String toString() =>
      'InlinePathTarget(raw: $raw, path: $path, lineStart: $lineStart, '
      'lineEnd: $lineEnd)';
}

/// A path split into the directory to list and the file to focus. Port of TS
/// `NormalizedInlinePathTarget`.
final class NormalizedInlinePathTarget {
  const NormalizedInlinePathTarget({required this.directory, this.file});

  /// The directory to open, `.` for the workspace root itself.
  final String directory;

  /// The file to select inside [directory], or null when the reference named
  /// a directory rather than a file.
  final String? file;

  @override
  bool operator ==(Object other) =>
      other is NormalizedInlinePathTarget &&
      other.directory == directory &&
      other.file == file;

  @override
  int get hashCode => Object.hash(directory, file);

  @override
  String toString() =>
      'NormalizedInlinePathTarget(directory: $directory, file: $file)';
}

/// What [classifyAssistantFileLink] decided a link is. Port of the TS
/// `AssistantFileLinkClassification` union.
sealed class AssistantFileLinkClassification {
  const AssistantFileLinkClassification();
}

/// Not a file: open it in the browser, never in the editor.
final class ExternalFileLinkClassification
    extends AssistantFileLinkClassification {
  const ExternalFileLinkClassification(this.raw);

  /// The href as written, untrimmed.
  final String raw;

  @override
  bool operator ==(Object other) =>
      other is ExternalFileLinkClassification && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'ExternalFileLinkClassification(raw: $raw)';
}

/// A file whose path the token pinned down on its own.
final class DirectFileLinkClassification
    extends AssistantFileLinkClassification {
  const DirectFileLinkClassification(this.target);

  final InlinePathTarget target;

  @override
  bool operator ==(Object other) =>
      other is DirectFileLinkClassification && other.target == target;

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'DirectFileLinkClassification(target: $target)';
}

/// A bare basename inside the workspace, e.g. `dumm.md`.
///
/// [target] holds the optimistic root-relative guess, but the file could sit
/// anywhere in the tree, so the resolver searches for it rather than trusting
/// the guess.
final class AmbiguousFileCandidateClassification
    extends AssistantFileLinkClassification {
  const AmbiguousFileCandidateClassification(this.target);

  final InlinePathTarget target;

  @override
  bool operator ==(Object other) =>
      other is AmbiguousFileCandidateClassification && other.target == target;

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'AmbiguousFileCandidateClassification(target: $target)';
}

const String _fileProtocol = 'file:';

final RegExp _inlineLineFragment = RegExp(
  r'^L([0-9]+)(?:C[0-9]+)?(?:-L?([0-9]+)(?:C[0-9]+)?)?$',
  caseSensitive: false,
);
final RegExp _inlineColonLineSuffix = RegExp(
  r'^(.+?):([0-9]+)(?::[0-9]+)?(?:-([0-9]+)(?::[0-9]+)?)?$',
);
final RegExp _inlineParenLineSuffix = RegExp(
  r'^(.+?)\(([0-9]+)(?:,[0-9]+)?(?:-([0-9]+)(?:,[0-9]+)?)?\)$',
);
final RegExp _inlineWordLineSuffix = RegExp(
  r'^(.+?)\s+lines?\s+([0-9]+)(?:-([0-9]+))?$',
  caseSensitive: false,
);
final RegExp _leadingQuote = RegExp('^[\'"`]');
final RegExp _trailingQuote = RegExp('[\'"`]\$');
final RegExp _trailingSlashes = RegExp(r'/+$');
final RegExp _leadingSlashes = RegExp(r'^/+');
final RegExp _repeatedSlashes = RegExp(r'/{2,}');
final RegExp _whitespaceAnywhere = RegExp(r'\s');
final RegExp _windowsPathHref = RegExp(r'^([A-Za-z]:[\\/][^?#]*)(#[^?]+)?$');
final RegExp _fileUrlDrivePrefix = RegExp(r'^/[A-Za-z]:/');
final RegExp _uriSchemePrefix = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');
final RegExp _windowsDrivePrefix = RegExp(r'^[A-Za-z]:[\\/]');
final RegExp _windowsDriveCompare = RegExp(r'^[A-Za-z]:');
final RegExp _domainLikeSegment = RegExp(
  r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$',
);

/// Extensions that make a bare token look like source rather than prose.
///
/// The list is an allow-list on purpose: without it `google.com` and
/// `origin/main` would both linkify into dead file links.
const Set<String> _assistantFileExtensions = {
  'astro',
  'bash',
  'c',
  'cc',
  'cjs',
  'cpp',
  'cs',
  'css',
  'cts',
  'cxx',
  'env',
  'fish',
  'go',
  'gql',
  'gradle',
  'graphql',
  'h',
  'hpp',
  'htm',
  'html',
  'ini',
  'java',
  'js',
  'json',
  'jsonc',
  'jsx',
  'kt',
  'kts',
  'less',
  'lock',
  'lua',
  'md',
  'mdx',
  'mjs',
  'mts',
  'php',
  'proto',
  'py',
  'rb',
  'rs',
  'sass',
  'scss',
  'sh',
  'sql',
  'svelte',
  'swift',
  'toml',
  'ts',
  'tsx',
  'txt',
  'vue',
  'xml',
  'yaml',
  'yml',
  'zsh',
};

/// A parsed `#L12-L20`-style fragment. Both fields null means "no line
/// information", which is a *valid* outcome; an unparseable fragment is
/// reported by returning null from [_parseLineFragment] instead.
final class _LineRange {
  const _LineRange(this.lineStart, this.lineEnd);

  final int? lineStart;
  final int? lineEnd;
}

String? _normalizePathToken(String value) {
  final trimmed = _jsTrim(
    value,
  ).replaceFirst(_leadingQuote, '').replaceFirst(_trailingQuote, '');
  if (trimmed.isEmpty) return null;
  return trimmed.replaceAll(r'\', '/');
}

/// Like [_normalizePathToken] but also collapses repeated slashes, which is
/// what makes a root of `/Users/test/project//` compare equal to the same root
/// without the doubled separator.
String? _normalizePathInput(String? value) {
  if (value == null || value.isEmpty) return null;
  final trimmed = _jsTrim(
    value,
  ).replaceFirst(_leadingQuote, '').replaceFirst(_trailingQuote, '');
  if (trimmed.isEmpty) return null;
  return trimmed.replaceAll(r'\', '/').replaceAll(_repeatedSlashes, '/');
}

/// Parses `#L12`, `#L12C4-L20C8`, `#L12-20` and friends.
///
/// Returns a range with both fields null for a fragment that simply is not a
/// line marker (`#introduction`) — such a link is still a perfectly good file
/// link, it just has no line to scroll to. Returns null only when the fragment
/// *is* a line marker but an impossible one: a zero or negative line, or an end
/// before the start.
_LineRange? _parseLineFragment(String value) {
  final rawFragment = value.startsWith('#') ? value.substring(1) : value;
  if (rawFragment.isEmpty) return const _LineRange(null, null);

  final lineMatch = _inlineLineFragment.firstMatch(rawFragment);
  int? lineStart;
  int? lineEnd;
  if (lineMatch != null) {
    final rawStart = lineMatch.group(1);
    if (rawStart != null) {
      lineStart = _parsePositiveJsInt(rawStart);
      if (lineStart == null) return null;
    }
    final rawEnd = lineMatch.group(2);
    if (rawEnd != null) {
      lineEnd = _parsePositiveJsInt(rawEnd);
      if (lineEnd == null) return null;
    }
  }

  if (lineStart != null && lineEnd != null && lineEnd < lineStart) return null;

  return _LineRange(lineStart, lineEnd);
}

/// Strict VSCode-style markers only.
///
/// Supported:
/// - `filename:linenumber`
/// - `filename:linenumber:columnnumber` as a line target
/// - `filename:lineStart-lineEnd`
/// - `filename(line,column)` and `filename(start,col-end,col)`
/// - `filename lines start-end` (also `line`, any case)
///
/// Not supported (by design):
/// - plain `filename` (no line)
/// - `:linenumber` (range-only), because the leading `(.+?)` needs at least one
///   character of path
///
/// A base path containing `://` is rejected outright so `https://x.dev/a.ts:12`
/// is never mistaken for a file.
///
/// Deviation: upstream's parameter is nullable in practice (`value ?? ""`);
/// Dart's type system makes that guard unreachable, so it is dropped.
InlinePathTarget? parseInlinePathToken(String value) {
  final trimmed = _jsTrim(value);
  if (trimmed.isEmpty) return null;

  final match =
      _inlineColonLineSuffix.firstMatch(trimmed) ??
      _inlineParenLineSuffix.firstMatch(trimmed) ??
      _inlineWordLineSuffix.firstMatch(trimmed);
  if (match == null) return null;

  final rawBase = match.group(1);
  final basePathRaw = rawBase == null ? '' : _jsTrim(rawBase);
  if (basePathRaw.isEmpty) return null;

  // Avoid accidentally treating URLs as file paths.
  if (basePathRaw.contains('://')) return null;

  final normalizedPath = _normalizePathToken(basePathRaw);
  if (normalizedPath == null) return null;

  final lineStart = _parsePositiveJsInt(match.group(2)!);
  if (lineStart == null) return null;

  int? lineEnd;
  final rawEnd = match.group(3);
  if (rawEnd != null) {
    lineEnd = _parsePositiveJsInt(rawEnd);
    if (lineEnd == null) return null;
    if (lineEnd < lineStart) return null;
  }

  return InlinePathTarget(
    raw: value,
    path: normalizedPath,
    lineStart: lineStart,
    lineEnd: lineEnd,
  );
}

/// Parses a `file:` URL into a path plus an optional line range.
///
/// Returns null for any other scheme, and for a URL whose fragment names an
/// impossible line range. Note that `file://host/share/x.txt` loses its host —
/// `new URL()` treats it as an authority — so the path becomes `/share/x.txt`.
InlinePathTarget? parseFileProtocolUrl(String value) {
  final trimmed = _jsTrim(value);
  if (trimmed.isEmpty) return null;

  final parsedUrl = _parseAbsoluteUrl(trimmed);
  if (parsedUrl == null) return null;
  if (parsedUrl.protocol != _fileProtocol) return null;

  final normalizedPath = _normalizeFileUrlPath(parsedUrl.pathname);
  if (normalizedPath == null) return null;

  final lines = _parseLineFragment(parsedUrl.hash);
  if (lines == null) return null;

  return InlinePathTarget(
    raw: value,
    path: normalizedPath,
    lineStart: lines.lineStart,
    lineEnd: lines.lineEnd,
  );
}

InlinePathTarget? _parseAssistantInlinePathLink(String value) {
  final inlinePathTarget = parseInlinePathToken(value);
  if (inlinePathTarget == null) return null;

  final normalizedPath = _normalizePathToken(inlinePathTarget.path);
  if (normalizedPath == null || !isAbsolutePath(normalizedPath)) return null;

  return inlinePathTarget.copyWithPath(normalizedPath);
}

/// Decides what an assistant-authored href is, before any daemon round-trip.
///
/// Returns null for anything that must stay inert text. Whitespace anywhere in
/// the token disqualifies it: that is what keeps a pasted shell command such as
/// `npm run lint -- packages/app/src/a.ts` from linkifying, even though its
/// arguments are perfectly good paths.
///
/// Deviation: upstream's `AssistantHrefParseOptions` object carries a single
/// optional field, so it collapses to the [workspaceRoot] named parameter.
AssistantFileLinkClassification? classifyAssistantFileLink(
  String value, {
  String? workspaceRoot,
}) {
  final trimmed = _jsTrim(value);
  if (trimmed.isEmpty) return null;

  if (_isExternalHref(trimmed)) {
    return ExternalFileLinkClassification(value);
  }

  if (_whitespaceAnywhere.hasMatch(trimmed)) return null;

  final target = parseAssistantFileLink(trimmed, workspaceRoot: workspaceRoot);
  if (target == null) return null;

  if (_isAmbiguousWorkspaceCandidate(trimmed, target, workspaceRoot)) {
    return AmbiguousFileCandidateClassification(target);
  }

  return DirectFileLinkClassification(target);
}

/// Resolves an assistant-authored href to a concrete file target.
///
/// The branches are tried in upstream's order, and the order matters:
/// `file:` URLs win outright (they are allowed to point outside the workspace),
/// then absolute inline `path:line` tokens, then bare Windows paths, then
/// workspace-relative paths, and only finally the generic URL parse that
/// handles absolute POSIX paths and percent-escapes.
///
/// Returns null when the value is external, is relative with no workspace root
/// to anchor it, escapes above the workspace root, or names an impossible line
/// range.
InlinePathTarget? parseAssistantFileLink(
  String value, {
  String? workspaceRoot,
}) {
  final fileUrlTarget = parseFileProtocolUrl(value);
  if (fileUrlTarget != null) return fileUrlTarget;

  final trimmed = _jsTrim(value);
  if (trimmed.isEmpty) return null;

  if (_isExternalHref(trimmed)) return null;

  final inlinePathTarget = _parseAssistantInlinePathLink(trimmed);
  if (inlinePathTarget != null) return inlinePathTarget;

  final windowsPathMatch = _windowsPathHref.firstMatch(trimmed);
  if (windowsPathMatch != null) {
    final normalizedPath = _normalizePathToken(windowsPathMatch.group(1) ?? '');
    if (normalizedPath == null) return null;

    final lines = _parseLineFragment(windowsPathMatch.group(2) ?? '');
    if (lines == null) return null;

    return InlinePathTarget(
      raw: value,
      path: normalizedPath,
      lineStart: lines.lineStart,
      lineEnd: lines.lineEnd,
    );
  }

  final relativeTarget = _parseWorkspaceRelativeFileLink(
    trimmed,
    workspaceRoot: workspaceRoot,
  );
  if (relativeTarget != null) return relativeTarget;

  if (!isAbsolutePath(trimmed)) return null;

  final parsedUrl = _parseUrlAgainstHttpBase(trimmed);
  if (parsedUrl == null) return null;

  final normalizedPath = _normalizePathToken(
    _safeDecodeUriComponent(parsedUrl.pathname),
  );
  if (normalizedPath == null || !isAbsolutePath(normalizedPath)) return null;

  final lines = _parseLineFragment(parsedUrl.hash);
  if (lines == null) return null;

  return InlinePathTarget(
    raw: value,
    path: normalizedPath,
    lineStart: lines.lineStart,
    lineEnd: lines.lineEnd,
  );
}

/// Whether rendered link text looks enough like a file path to be preferred
/// over the href markdown-it built from it.
///
/// This is the guard that lets `dumm.md` — auto-linkified into
/// `http://dumm.md` — be recovered as a file, while `google.com` keeps its
/// generated href and stays a web link.
bool isFileLookingAssistantToken(String value) {
  final normalized = _normalizePathToken(value);
  if (normalized == null ||
      _whitespaceAnywhere.hasMatch(normalized) ||
      normalized.contains('?') ||
      normalized.contains('://')) {
    return false;
  }

  final path = _getHeuristicLocalPath(normalized);
  if (path == null) return false;

  return _isPlausibleAssistantLocalPath(path);
}

InlinePathTarget? _parseWorkspaceRelativeFileLink(
  String value, {
  String? workspaceRoot,
}) {
  final parsed = _parseLocalPathParts(value);
  if (parsed == null || isAbsolutePath(parsed.path)) return null;

  if (_isHomeRelativePath(parsed.path)) {
    return InlinePathTarget(
      raw: value,
      path: parsed.path,
      lineStart: parsed.lines.lineStart,
      lineEnd: parsed.lines.lineEnd,
    );
  }

  final normalizedRoot = _normalizePathInput(workspaceRoot);
  if (normalizedRoot == null) return null;

  final normalizedPath = _resolveRelativePathUnderRoot(
    parsed.path,
    normalizedRoot,
  );
  if (normalizedPath == null) return null;

  return InlinePathTarget(
    raw: value,
    path: normalizedPath,
    lineStart: parsed.lines.lineStart,
    lineEnd: parsed.lines.lineEnd,
  );
}

final class _LocalPathParts {
  const _LocalPathParts(this.path, this.lines);

  final String path;
  final _LineRange lines;
}

/// Splits a local-looking token into its path and line range.
///
/// When the part before `#` is itself an inline `path:line` token, that token's
/// line range wins and the `#` fragment's is discarded — so `a.ts:12#L20`
/// resolves to line 12, not 20.
_LocalPathParts? _parseLocalPathParts(String value) {
  final normalized = _normalizePathToken(value);
  if (normalized == null || normalized.contains('?')) return null;

  final hashIndex = normalized.indexOf('#');
  final beforeHash = hashIndex >= 0
      ? normalized.substring(0, hashIndex)
      : normalized;
  final hash = hashIndex >= 0 ? normalized.substring(hashIndex) : '';
  final fragmentLines = _parseLineFragment(hash);
  if (fragmentLines == null) return null;

  final inlinePathTarget = parseInlinePathToken(beforeHash);
  if (inlinePathTarget != null) {
    if (!_isPlausibleAssistantLocalPath(inlinePathTarget.path)) return null;

    return _LocalPathParts(
      inlinePathTarget.path,
      _LineRange(inlinePathTarget.lineStart, inlinePathTarget.lineEnd),
    );
  }

  // A colon that did not parse as a line marker is a scheme or a drive letter,
  // neither of which belongs on this path.
  if (beforeHash.isEmpty || beforeHash.contains(':')) return null;

  if (!_isPlausibleAssistantLocalPath(beforeHash)) return null;

  return _LocalPathParts(beforeHash, fragmentLines);
}

/// Splits a path into the directory to list and the file to focus, re-rooting
/// it under [cwd] when it lives there.
///
/// Absolute paths inside [cwd] come back workspace-relative so the file
/// explorer can address them; anything else keeps its shape. A trailing slash,
/// or a path equal to [cwd], means "directory" and yields no file.
///
/// Deviation: upstream takes `cwd` positionally; it is named here.
NormalizedInlinePathTarget? normalizeInlinePathTarget(
  String rawPath, {
  String? cwd,
}) {
  if (rawPath.isEmpty) return null;

  final normalizedInput = _normalizePathInput(rawPath);
  if (normalizedInput == null) return null;

  var normalized = normalizedInput;
  final cwdRelative = _resolvePathAgainstCwd(normalized, cwd);
  if (cwdRelative != null) {
    normalized = cwdRelative;
  }

  if (normalized.startsWith('./')) {
    final rest = normalized.substring(2);
    normalized = rest.isEmpty ? '.' : rest;
  }

  if (normalized.isEmpty) {
    normalized = '.';
  }

  if (normalized == '.') {
    return const NormalizedInlinePathTarget(directory: '.');
  }

  if (normalized.endsWith('/')) {
    final dir = normalized.replaceFirst(_trailingSlashes, '');
    return NormalizedInlinePathTarget(directory: dir.isNotEmpty ? dir : '.');
  }

  final lastSlash = normalized.lastIndexOf('/');
  final directory = lastSlash >= 0 ? normalized.substring(0, lastSlash) : '.';

  return NormalizedInlinePathTarget(
    directory: directory.isNotEmpty ? directory : '.',
    file: normalized,
  );
}

bool _isAllowedAbsolutePath(String pathValue, String? workspaceRoot) {
  final normalizedWorkspaceRoot = _normalizePathInput(workspaceRoot);
  if (normalizedWorkspaceRoot == null) return true;

  final comparePath = _normalizePathForCompare(pathValue);
  final trimmedRoot = normalizedWorkspaceRoot.replaceFirst(
    _trailingSlashes,
    '',
  );
  final compareWorkspaceRoot = _normalizePathForCompare(
    trimmedRoot.isEmpty ? '/' : trimmedRoot,
  );
  final comparePrefix = compareWorkspaceRoot == '/'
      ? '/'
      : '$compareWorkspaceRoot/';

  return comparePath == compareWorkspaceRoot ||
      comparePath.startsWith(comparePrefix);
}

bool _isHomeRelativePath(String pathValue) =>
    pathValue == '~' ||
    pathValue.startsWith('~/') ||
    pathValue.startsWith('~\\');

/// Whether an href must be handed to the browser instead of the editor.
///
/// `file://` is the one scheme that survives the `://` test, and a bare drive
/// letter (`C:\repo`) is explicitly carved out of the generic scheme test so
/// Windows paths are not mistaken for a custom protocol.
bool _isExternalHref(String value) {
  if (value.contains('://')) {
    return !value.toLowerCase().startsWith('$_fileProtocol//');
  }

  if (parseInlinePathToken(value) != null) return false;

  return _uriSchemePrefix.hasMatch(value) &&
      !_windowsDrivePrefix.hasMatch(value);
}

/// Whether a token that resolved inside the workspace was really just a
/// basename, and so needs a daemon search rather than the optimistic
/// root-relative guess.
bool _isAmbiguousWorkspaceCandidate(
  String value,
  InlinePathTarget target,
  String? workspaceRoot,
) {
  final normalizedWorkspaceRoot = _normalizePathInput(workspaceRoot);
  if (normalizedWorkspaceRoot == null ||
      !_isAllowedAbsolutePath(target.path, normalizedWorkspaceRoot)) {
    return false;
  }

  final parsed = _parseLocalPathParts(value);
  if (parsed == null || isAbsolutePath(parsed.path)) return false;

  return !parsed.path.contains('/');
}

String? _getHeuristicLocalPath(String value) {
  final hashIndex = value.indexOf('#');
  final beforeHash = hashIndex >= 0 ? value.substring(0, hashIndex) : value;
  final hash = hashIndex >= 0 ? value.substring(hashIndex) : '';
  if (_parseLineFragment(hash) == null) return null;

  final inlinePathTarget = parseInlinePathToken(beforeHash);
  if (inlinePathTarget != null) return inlinePathTarget.path;

  if (beforeHash.isEmpty || beforeHash.contains(':')) return null;

  return beforeHash;
}

/// The core "is this prose or a path?" heuristic.
///
/// Absolute and explicitly relative (`./`, `../`, `~/`) paths are trusted on
/// their shape alone. Everything else has to earn it: the last segment needs a
/// known source extension, and a multi-segment path additionally must not lead
/// with a domain-looking segment, which is what separates `openai.com/path`
/// from `src/app.ts`.
bool _isPlausibleAssistantLocalPath(String pathValue) {
  final normalized = _normalizePathToken(pathValue);
  if (normalized == null) return false;

  if (isAbsolutePath(normalized)) return true;

  final explicitRelative =
      normalized.startsWith('./') ||
      normalized.startsWith('../') ||
      normalized.startsWith('~/');
  if (explicitRelative) return true;

  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return false;
  final firstSegment = segments.first;

  if (segments.length > 1) {
    final lastSegment = segments.last;
    return !_isDomainLikePathSegment(firstSegment) &&
        _isPlausibleAssistantFileName(lastSegment);
  }

  return _isPlausibleAssistantFileName(firstSegment);
}

/// Dotfiles (`.env`, `.gitignore`) count without an extension check; everything
/// else must end in a known source extension.
bool _isPlausibleAssistantFileName(String? fileName) {
  if (fileName == null || fileName.isEmpty) return false;

  if (fileName.startsWith('.') && fileName.length > 1) return true;

  final lastDot = fileName.lastIndexOf('.');
  if (lastDot < 0) return false;

  final extension = fileName.substring(lastDot + 1).toLowerCase();
  return _assistantFileExtensions.contains(extension);
}

bool _isDomainLikePathSegment(String segment) =>
    _domainLikeSegment.hasMatch(segment);

/// Joins a relative path onto [workspaceRoot], collapsing `.` and `..`.
///
/// Returns null when the path climbs above the root — a link the assistant
/// wrote must never navigate outside the workspace.
String? _resolveRelativePathUnderRoot(String pathValue, String workspaceRoot) {
  final normalizedPath = _normalizePathToken(pathValue);
  if (normalizedPath == null || isAbsolutePath(normalizedPath)) return null;

  final trimmedRoot = workspaceRoot.replaceFirst(_trailingSlashes, '');
  final root = trimmedRoot.isEmpty ? '/' : trimmedRoot;
  final resolvedSegments = <String>[];
  for (final segment in normalizedPath.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (resolvedSegments.isEmpty) return null;
      resolvedSegments.removeLast();
      continue;
    }
    resolvedSegments.add(segment);
  }

  if (resolvedSegments.isEmpty) return root;

  return root == '/'
      ? '/${resolvedSegments.join('/')}'
      : '$root/${resolvedSegments.join('/')}';
}

/// `new URL("file:///C:/x").pathname` is `/C:/x`; the leading slash is a URL
/// artefact, not part of the Windows path, so it is dropped.
String? _normalizeFileUrlPath(String pathname) {
  if (pathname.isEmpty) return null;

  final decoded = _safeDecodeUriComponent(pathname).replaceAll(r'\', '/');
  if (decoded.isEmpty) return null;

  if (_fileUrlDrivePrefix.hasMatch(decoded)) return decoded.substring(1);

  return decoded;
}

/// Re-roots an absolute path under [cwd], or returns null when it lives
/// elsewhere. `.` means the path *is* [cwd].
String? _resolvePathAgainstCwd(String pathValue, String? cwd) {
  final normalizedCwd = _normalizePathInput(cwd);
  if (normalizedCwd == null ||
      !isAbsolutePath(pathValue) ||
      !isAbsolutePath(normalizedCwd)) {
    return null;
  }

  final trimmedCwd = normalizedCwd.replaceFirst(_trailingSlashes, '');
  final normalizedCwdBase = trimmedCwd.isEmpty ? '/' : trimmedCwd;
  final comparePath = _normalizePathForCompare(pathValue);
  final compareCwd = _normalizePathForCompare(normalizedCwdBase);
  final prefix = normalizedCwdBase == '/' ? '/' : '$normalizedCwdBase/';
  final comparePrefix = _normalizePathForCompare(prefix);

  if (comparePath == compareCwd) return '.';

  if (comparePath.startsWith(comparePrefix)) {
    final rest = pathValue.substring(prefix.length);
    return rest.isEmpty ? '.' : rest;
  }

  return null;
}

/// Windows paths compare case-insensitively; POSIX ones do not. Detected by the
/// drive-letter prefix rather than by host platform, because the daemon may run
/// on a different OS than the UI.
String _normalizePathForCompare(String value) =>
    _windowsDriveCompare.hasMatch(value) ? value.toLowerCase() : value;

// ---------------------------------------------------------------------------
// resolver.ts
// ---------------------------------------------------------------------------

/// How the link reached the resolver, when that changes the decision.
///
/// Upstream types this as `"inline-code" | undefined`; the enum has one member
/// for the same reason.
enum AssistantFileLinkSourceType {
  /// The token came from a markdown inline-code span, not an `<a>`. Backticked
  /// workspace paths are resolved through a daemon search rather than trusted,
  /// because an assistant writing `` `file.ts` `` rarely means "the file at the
  /// workspace root".
  inlineCode,
}

/// One rendered link, with the markdown provenance the resolver needs. Port of
/// TS `AssistantFileLinkSource`.
final class AssistantFileLinkSource {
  const AssistantFileLinkSource({
    required this.href,
    this.text,
    this.markup,
    this.sourceInfo,
    this.sourceType,
  });

  final String href;

  /// The rendered link text, which for an auto-linkified token is the thing the
  /// assistant actually typed.
  final String? text;

  /// markdown-it's `token.markup`; `linkify` means the href was synthesised.
  final String? markup;

  /// markdown-it's `token.info`; `auto` likewise means auto-linkified.
  final String? sourceInfo;

  final AssistantFileLinkSourceType? sourceType;
}

/// The workspace a link is being resolved in. Port of TS
/// `AssistantFileLinkContext`.
final class AssistantFileLinkContext {
  const AssistantFileLinkContext({this.workspaceRoot});

  final String? workspaceRoot;
}

/// One directory-suggestion search result. Port of TS
/// `DirectorySuggestionResult`.
///
/// Reuses `DirectorySuggestionEntry` from `package:agent_protocol` rather than
/// redeclaring it; only the two-field result wrapper is local, because the
/// protocol's `DirectorySuggestionsResponse` additionally requires wire-only
/// fields (`directories`, `requestId`) this contract has no use for.
final class DirectorySuggestionResult {
  const DirectorySuggestionResult({required this.entries, this.error});

  final List<DirectorySuggestionEntry> entries;

  /// A daemon-side failure message. Note that upstream tests this for JS
  /// truthiness, so an empty string reads as "no error"; the port keeps that.
  final String? error;
}

/// The exact search [fetchDaemonResolution] issues. Port of the inline input
/// type of TS `GetDirectorySuggestions`, whose literal types (`includeFiles:
/// true`, `matchMode: "suffix"`) are fixed values rather than choices.
final class DirectorySuggestionQuery {
  const DirectorySuggestionQuery({
    required this.query,
    required this.cwd,
    required this.includeFiles,
    required this.includeDirectories,
    required this.matchMode,
    required this.limit,
  });

  final String query;
  final String cwd;
  final bool includeFiles;
  final bool includeDirectories;

  /// Always suffix matching: the query is a path tail (`src/file.ts`), so a
  /// fuzzy match would happily return an unrelated file.
  final String matchMode;
  final int limit;
}

/// Searches the workspace for files matching a query. Port of TS
/// `GetDirectorySuggestions`.
typedef GetDirectorySuggestions =
    Future<DirectorySuggestionResult> Function(DirectorySuggestionQuery input);

/// What a link resolved to. Port of the TS `ResolvedAssistantFileLink` union.
sealed class ResolvedAssistantFileLink {
  const ResolvedAssistantFileLink();
}

/// Open in the browser.
final class ExternalAssistantFileLink extends ResolvedAssistantFileLink {
  const ExternalAssistantFileLink(this.url);

  final String url;

  @override
  bool operator ==(Object other) =>
      other is ExternalAssistantFileLink && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'ExternalAssistantFileLink(url: $url)';
}

/// Open in the editor.
final class FileAssistantFileLink extends ResolvedAssistantFileLink {
  const FileAssistantFileLink(this.target);

  final InlinePathTarget target;

  @override
  bool operator ==(Object other) =>
      other is FileAssistantFileLink && other.target == target;

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'FileAssistantFileLink(target: $target)';
}

/// Render as inert text.
final class IgnoredAssistantFileLink extends ResolvedAssistantFileLink {
  const IgnoredAssistantFileLink();

  @override
  bool operator ==(Object other) => other is IgnoredAssistantFileLink;

  @override
  int get hashCode => (IgnoredAssistantFileLink).hashCode;

  @override
  String toString() => 'IgnoredAssistantFileLink()';
}

/// Whether the link is settled or still needs a daemon search. Port of the TS
/// `AssistantFileLinkResolution` union.
sealed class AssistantFileLinkResolution {
  const AssistantFileLinkResolution();
}

/// Settled synchronously; no daemon round-trip needed.
final class ResolvedFileLinkResolution extends AssistantFileLinkResolution {
  const ResolvedFileLinkResolution(this.value);

  final ResolvedAssistantFileLink value;

  @override
  bool operator ==(Object other) =>
      other is ResolvedFileLinkResolution && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ResolvedFileLinkResolution(value: $value)';
}

/// Needs [fetchDaemonResolution] before it can be opened.
final class NeedsLookupFileLinkResolution extends AssistantFileLinkResolution {
  const NeedsLookupFileLinkResolution({
    required this.ambiguousQuery,
    required this.token,
    required this.target,
  });

  /// The suffix to search for — the path relative to the workspace root when
  /// the guess landed inside it, otherwise the bare basename.
  final String ambiguousQuery;

  /// The token as classified, used for the error message when nothing matches.
  final String token;

  /// The optimistic guess, whose line range survives into the resolved target.
  final InlinePathTarget target;

  @override
  bool operator ==(Object other) =>
      other is NeedsLookupFileLinkResolution &&
      other.ambiguousQuery == ambiguousQuery &&
      other.token == token &&
      other.target == target;

  @override
  int get hashCode => Object.hash(ambiguousQuery, token, target);

  @override
  String toString() =>
      'NeedsLookupFileLinkResolution(ambiguousQuery: $ambiguousQuery, '
      'token: $token, target: $target)';
}

/// Builds the user-facing message for an [UnresolvedFileLinkError].
typedef UnresolvedFileLinkMessageBuilder = String Function(String token);

/// The English text of `common.errors.noFileFound` in `assets/i18n/en.json`.
String _defaultUnresolvedFileLinkMessage(String token) =>
    'No file found for $token';

/// Raised when a link needed a daemon lookup and the lookup came back empty.
///
/// Upstream builds its message from the i18next singleton at construction
/// time. Dart has no such singleton — this app's `Translations` is passed
/// explicitly — so the English string is the default and [describe] is the hook
/// a caller uses to supply a localised one, e.g.
/// `describe: (token) => translations.t('common.errors.noFileFound',
/// args: {'token': token})`.
final class UnresolvedFileLinkError implements Exception {
  UnresolvedFileLinkError(
    this.token, {
    UnresolvedFileLinkMessageBuilder? describe,
  }) : message = (describe ?? _defaultUnresolvedFileLinkMessage)(token);

  /// The token that could not be resolved.
  final String token;

  final String message;

  @override
  bool operator ==(Object other) =>
      other is UnresolvedFileLinkError &&
      other.token == token &&
      other.message == message;

  @override
  int get hashCode => Object.hash(token, message);

  @override
  String toString() => 'UnresolvedFileLinkError: $message';
}

/// Asks the daemon where an ambiguous token actually lives.
///
/// Every failure mode collapses to the same [UnresolvedFileLinkError]: no
/// workspace root, a daemon that threw, no matching entry, a directory-only
/// match, or a result carrying an error. The daemon's path is workspace
/// relative, so it is joined back onto the root; the original [target]'s line
/// range rides along unchanged.
Future<InlinePathTarget> fetchDaemonResolution({
  required String ambiguousQuery,
  required String token,
  required InlinePathTarget target,
  required GetDirectorySuggestions getDirectorySuggestions,
  String? workspaceRoot,
  UnresolvedFileLinkMessageBuilder? describeUnresolved,
}) async {
  final trimmedRoot = workspaceRoot == null ? '' : _jsTrim(workspaceRoot);
  if (trimmedRoot.isEmpty) {
    throw UnresolvedFileLinkError(token, describe: describeUnresolved);
  }

  DirectorySuggestionResult suggestions;
  try {
    suggestions = await getDirectorySuggestions(
      DirectorySuggestionQuery(
        query: ambiguousQuery,
        cwd: trimmedRoot,
        includeFiles: true,
        includeDirectories: false,
        matchMode: 'suffix',
        limit: 1,
      ),
    );
  } catch (_) {
    throw UnresolvedFileLinkError(token, describe: describeUnresolved);
  }

  DirectorySuggestionEntry? match;
  for (final entry in suggestions.entries) {
    if (entry.kind == DirectorySuggestionKind.file) {
      match = entry;
      break;
    }
  }
  final error = suggestions.error;
  if (match == null || (error != null && error.isNotEmpty)) {
    throw UnresolvedFileLinkError(token, describe: describeUnresolved);
  }

  return target.copyWithPath(_joinWorkspacePath(trimmedRoot, match.path));
}

/// The synchronous half of link resolution.
///
/// An ambiguous basename, or a backticked workspace-relative path, comes back
/// as [NeedsLookupFileLinkResolution] for [fetchDaemonResolution] to finish.
/// Without a workspace root there is nothing to search, so such a link is
/// ignored rather than guessed at.
AssistantFileLinkResolution classifyForResolution(
  AssistantFileLinkSource source,
  AssistantFileLinkContext context,
) {
  final token = _jsTrim(getAssistantFileLinkToken(source));
  if (token.isEmpty) {
    return const ResolvedFileLinkResolution(IgnoredAssistantFileLink());
  }

  final classification = classifyAssistantFileLink(
    token,
    workspaceRoot: context.workspaceRoot,
  );
  switch (classification) {
    case null:
      return const ResolvedFileLinkResolution(IgnoredAssistantFileLink());
    case ExternalFileLinkClassification(:final raw):
      return ResolvedFileLinkResolution(ExternalAssistantFileLink(raw));
    case DirectFileLinkClassification(:final target):
      if (!shouldResolveDirectFileThroughSuggestions(
        context: context,
        source: source,
        token: token,
        target: target,
      )) {
        return ResolvedFileLinkResolution(FileAssistantFileLink(target));
      }
      return _needsLookupOrIgnored(context, token, target);
    case AmbiguousFileCandidateClassification(:final target):
      return _needsLookupOrIgnored(context, token, target);
  }
}

/// Without a workspace root there is nothing to search, so an unresolvable
/// token is dropped rather than left pointing at a guess.
AssistantFileLinkResolution _needsLookupOrIgnored(
  AssistantFileLinkContext context,
  String token,
  InlinePathTarget target,
) {
  final rawRoot = context.workspaceRoot;
  final workspaceRoot = rawRoot == null ? '' : _jsTrim(rawRoot);
  if (workspaceRoot.isEmpty) {
    return const ResolvedFileLinkResolution(IgnoredAssistantFileLink());
  }

  return NeedsLookupFileLinkResolution(
    ambiguousQuery: getAmbiguousSuggestionQuery(target, workspaceRoot),
    token: token,
    target: target,
  );
}

/// Picks the string to classify: the rendered text, or the href.
///
/// markdown-it turns a bare `dumm.md` into `<a href="http://dumm.md">dumm.md`,
/// so for auto-linkified and inline-code sources the *text* is the assistant's
/// real intent — but only when it still looks like a file, which keeps
/// `google.com` pointed at its href.
String getAssistantFileLinkToken(AssistantFileLinkSource source) {
  if (_isLinkifiedSource(source) ||
      source.sourceType == AssistantFileLinkSourceType.inlineCode) {
    final rawText = source.text;
    final text = rawText == null ? '' : _jsTrim(rawText);
    if (text.isNotEmpty && isFileLookingAssistantToken(text)) {
      return text;
    }
  }

  return source.href;
}

/// Builds the suffix query for a daemon search.
///
/// A path under the workspace root keeps its root-relative shape, which is
/// specific enough to pick the right file out of several same-named ones;
/// anything else falls back to the bare basename.
String getAmbiguousSuggestionQuery(
  InlinePathTarget target,
  String workspaceRoot,
) {
  final normalizedRoot = workspaceRoot
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashes, '');
  final normalizedPath = target.path.replaceAll(r'\', '/');
  final prefix = '$normalizedRoot/';
  if (normalizedPath.startsWith(prefix)) {
    return normalizedPath.substring(prefix.length);
  }

  final lastSlash = normalizedPath.lastIndexOf('/');
  return lastSlash >= 0
      ? normalizedPath.substring(lastSlash + 1)
      : normalizedPath;
}

/// Whether a token that already resolved to a concrete workspace path should
/// still be searched for.
///
/// Only inline code qualifies, and only when it was written relatively:
/// `` `file.ts` `` almost never means the workspace root, whereas an absolute
/// path, a `file://` URL or a drive letter is an unambiguous instruction.
bool shouldResolveDirectFileThroughSuggestions({
  required AssistantFileLinkContext context,
  required AssistantFileLinkSource source,
  required String token,
  required InlinePathTarget target,
}) {
  if (source.sourceType != AssistantFileLinkSourceType.inlineCode) return false;

  if (_isAbsoluteInlineCodeToken(token)) return false;

  final rawRoot = context.workspaceRoot;
  final workspaceRoot = rawRoot == null ? '' : _jsTrim(rawRoot);
  if (workspaceRoot.isEmpty) return false;

  final normalizedRoot = workspaceRoot
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashes, '');
  final normalizedPath = target.path.replaceAll(r'\', '/');
  return normalizedPath.startsWith('$normalizedRoot/');
}

bool _isAbsoluteInlineCodeToken(String token) =>
    token.startsWith('/') ||
    token.toLowerCase().startsWith('file://') ||
    _windowsDrivePrefix.hasMatch(token);

bool _isLinkifiedSource(AssistantFileLinkSource source) =>
    source.markup == 'linkify' || source.sourceInfo == 'auto';

String _joinWorkspacePath(String workspaceRoot, String relativePath) {
  final root = workspaceRoot
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashes, '');
  final child = relativePath
      .replaceAll(r'\', '/')
      .replaceFirst(_leadingSlashes, '');
  return root.isNotEmpty ? '$root/$child' : child;
}
