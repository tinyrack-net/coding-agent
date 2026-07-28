/*
 * Adapted from MIT-licensed upstream terminal link parsing.
 * Copyright (c) Microsoft Corporation.
 */

final class TerminalLinkPartialRange {
  const TerminalLinkPartialRange({required this.index, required this.text});

  final int index;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is TerminalLinkPartialRange &&
      other.index == index &&
      other.text == text;

  @override
  int get hashCode => Object.hash(index, text);
}

final class TerminalLinkSuffix {
  const TerminalLinkSuffix({
    required this.row,
    required this.col,
    required this.rowEnd,
    required this.colEnd,
    required this.suffix,
  });

  final int? row;
  final int? col;
  final int? rowEnd;
  final int? colEnd;
  final TerminalLinkPartialRange suffix;
}

final class TerminalParsedLink {
  const TerminalParsedLink({required this.path, this.prefix, this.suffix});

  final TerminalLinkPartialRange path;
  final TerminalLinkPartialRange? prefix;
  final TerminalLinkSuffix? suffix;
}

final _suffixPatterns = <_SuffixPattern>[
  _SuffixPattern(
    RegExp(
      r'''(?::|#|[  ]|['"],|,[  ])(\d+)(?:[:.](\d+)(?:-(?:(\d+)\.)?(\d+))?)?''',
    ),
    rowGroup: 1,
    colGroup: 2,
    rowEndGroup: 3,
    colEndGroup: 4,
  ),
  _SuffixPattern(
    RegExp(
      r'''['"]?(?:,?[  ]|:[  ]?|[  ]on[  ])lines?[  ](\d+)(?:-(\d+))?(?:,?[  ](?:col(?:umn)?|characters?)[  ](\d+)(?:-(\d+))?)?''',
    ),
    rowGroup: 1,
    rowEndGroup: 2,
    colGroup: 3,
    colEndGroup: 4,
  ),
  _SuffixPattern(
    RegExp(r''':?[  ]?[\[(](\d+)(?:(?:,[  ]?|:)(\d+))?[\])]'''),
    rowGroup: 1,
    colGroup: 2,
  ),
];

final class _SuffixPattern {
  const _SuffixPattern(
    this.regex, {
    required this.rowGroup,
    this.colGroup,
    this.rowEndGroup,
    this.colEndGroup,
  });

  final RegExp regex;
  final int rowGroup;
  final int? colGroup;
  final int? rowEndGroup;
  final int? colEndGroup;
}

TerminalLinkSuffix? getTerminalLinkSuffix(String link) {
  TerminalLinkSuffix? result;
  for (final pattern in _suffixPatterns) {
    for (final match in pattern.regex.allMatches(link)) {
      if (match.end == link.length) {
        result = _toLinkSuffix(match, pattern);
      }
    }
  }
  return result;
}

List<TerminalLinkSuffix> _detectLinkSuffixes(String line) {
  final results = <TerminalLinkSuffix>[];
  for (final pattern in _suffixPatterns) {
    for (final match in pattern.regex.allMatches(line)) {
      results.add(_toLinkSuffix(match, pattern));
    }
  }
  results.sort(
    (left, right) => left.suffix.index.compareTo(right.suffix.index),
  );
  final nonOverlapping = <TerminalLinkSuffix>[];
  for (final result in results) {
    final start = result.suffix.index;
    final end = start + result.suffix.text.length;
    if (nonOverlapping.any((existing) {
      final existingStart = existing.suffix.index;
      final existingEnd = existingStart + existing.suffix.text.length;
      return start < existingEnd && end > existingStart;
    })) {
      continue;
    }
    nonOverlapping.add(result);
  }
  return nonOverlapping;
}

TerminalLinkSuffix _toLinkSuffix(RegExpMatch match, _SuffixPattern pattern) {
  int? groupInt(int? index) {
    if (index == null) return null;
    return int.tryParse(match.group(index) ?? '');
  }

  return TerminalLinkSuffix(
    row: groupInt(pattern.rowGroup),
    col: groupInt(pattern.colGroup),
    rowEnd: groupInt(pattern.rowEndGroup),
    colEnd: groupInt(pattern.colEndGroup),
    suffix: TerminalLinkPartialRange(index: match.start, text: match.group(0)!),
  );
}

final _linkWithSuffixPathCharacters = RegExp(
  r'((?:file:///)?[^\s|<>\[({][^\s|<>]*)$',
);

const _unixLocalLinkClause =
    r'''(?:(?:(?:\.\.?|\~|file:\/\/)|(?:[^\x00<>\?\s!`&*()\[\]'":;\\][^\x00<>\?\s!`&*()'":;\\]*))?(?:\/(?:[^\x00<>\?\s!`&*()'":;\\])+)+)''';
const _winLocalLinkClause =
    r'''(?:(?:(?:(?:\\\\\?\\|file:\/\/\/)?[a-zA-Z]:|\.\.?|\~)|(?:[^\x00<>\?\|\/\s!`&*()\[\]'":;\\][^\x00<>\?\|\/\s!`&*()'":;]*))?(?:(?:\\|\/)(?:[^\x00<>\?\|\/\s!`&*()'":;])+)+)''';

List<TerminalParsedLink> detectTerminalLocalLinks(String line) {
  final results = _detectLinksViaSuffix(line);
  _insertNonConflicting(
    results,
    _detectPathsNoSuffix(line, _unixLocalLinkClause),
  );
  _insertNonConflicting(
    results,
    _detectPathsNoSuffix(line, _winLocalLinkClause),
  );
  return results;
}

List<TerminalParsedLink> _detectLinksViaSuffix(String line) {
  final results = <TerminalParsedLink>[];
  for (final suffix in _detectLinkSuffixes(line)) {
    results.addAll(_detectLinksForSuffix(line, suffix));
  }
  return results;
}

List<TerminalParsedLink> _detectLinksForSuffix(
  String line,
  TerminalLinkSuffix suffix,
) {
  final beforeSuffix = line.substring(0, suffix.suffix.index);
  final possiblePathMatch = _linkWithSuffixPathCharacters.firstMatch(
    beforeSuffix,
  );
  final candidate = possiblePathMatch?.group(1);
  if (possiblePathMatch == null || candidate == null) return const [];

  final pathWithPrefix = _trimPathPrefix(
    path: candidate,
    startIndex: possiblePathMatch.start,
    suffix: suffix,
  );
  if (pathWithPrefix == null) return const [];

  final pathIndex =
      pathWithPrefix.startIndex + (pathWithPrefix.prefix?.text.length ?? 0);
  final links = <TerminalParsedLink>[
    TerminalParsedLink(
      path: TerminalLinkPartialRange(
        index: pathIndex,
        text: pathWithPrefix.path,
      ),
      prefix: pathWithPrefix.prefix,
      suffix: suffix,
    ),
  ];

  for (final match in RegExp(r'[\[(]').allMatches(pathWithPrefix.path)) {
    final nextIndex = match.start + 1;
    final next = nextIndex < pathWithPrefix.path.length
        ? pathWithPrefix.path[nextIndex]
        : null;
    if (next == ']' || next == ')') continue;
    links.add(
      TerminalParsedLink(
        path: TerminalLinkPartialRange(
          index: pathIndex + nextIndex,
          text: pathWithPrefix.path.substring(nextIndex),
        ),
        prefix: pathWithPrefix.prefix,
        suffix: suffix,
      ),
    );
  }
  return links;
}

final class _PathWithPrefix {
  const _PathWithPrefix({
    required this.path,
    required this.startIndex,
    this.prefix,
  });

  final String path;
  final int startIndex;
  final TerminalLinkPartialRange? prefix;
}

_PathWithPrefix? _trimPathPrefix({
  required String path,
  required int startIndex,
  required TerminalLinkSuffix suffix,
}) {
  final prefixMatch = RegExp(r'''^(['"]+)''').firstMatch(path);
  final prefixText = prefixMatch?.group(1);
  if (prefixText == null) {
    return _PathWithPrefix(path: path, startIndex: startIndex);
  }

  var prefix = TerminalLinkPartialRange(index: startIndex, text: prefixText);
  final trimmedPath = path.substring(prefixText.length);
  if (trimmedPath.trim().isEmpty) return null;
  final trimAmount = _getTrimPrefixAmount(prefixText, suffix);
  if (trimAmount == 0) {
    return _PathWithPrefix(
      path: trimmedPath,
      startIndex: startIndex,
      prefix: prefix,
    );
  }
  prefix = TerminalLinkPartialRange(
    index: prefix.index + trimAmount,
    text: prefix.text.substring(prefix.text.length - 1),
  );
  return _PathWithPrefix(
    path: trimmedPath,
    startIndex: startIndex + trimAmount,
    prefix: prefix,
  );
}

int _getTrimPrefixAmount(String prefixText, TerminalLinkSuffix suffix) {
  final suffixText = suffix.suffix.text;
  final suffixQuote = suffixText.isEmpty ? null : suffixText[0];
  if (prefixText.length > 1 &&
      (suffixQuote == "'" || suffixQuote == '"') &&
      prefixText[prefixText.length - 1] == suffixQuote) {
    return prefixText.length - 1;
  }
  return 0;
}

List<TerminalParsedLink> _detectPathsNoSuffix(String line, String clause) {
  final results = <TerminalParsedLink>[];
  for (final match in RegExp(clause).allMatches(line)) {
    var text = match.group(0)!;
    var index = match.start;
    if (text.isEmpty) break;
    if (((line.startsWith('--- a/') || line.startsWith('+++ b/')) &&
            index == 4) ||
        (line.startsWith('diff --git') &&
            (text.startsWith('a/') || text.startsWith('b/')))) {
      text = text.substring(2);
      index += 2;
    }
    results.add(
      TerminalParsedLink(
        path: TerminalLinkPartialRange(index: index, text: text),
      ),
    );
  }
  return results;
}

void _insertNonConflicting(
  List<TerminalParsedLink> list,
  List<TerminalParsedLink> newItems,
) {
  for (final item in newItems) {
    final start = item.path.index;
    final end = start + item.path.text.length;
    final hasConflict = list.any((existing) {
      final existingStart = existing.path.index;
      final existingEnd = existing.suffix == null
          ? existing.path.index + existing.path.text.length
          : existing.suffix!.suffix.index + existing.suffix!.suffix.text.length;
      return start < existingEnd && end > existingStart;
    });
    if (!hasConflict) list.add(item);
  }
  list.sort((left, right) => left.path.index.compareTo(right.path.index));
}
