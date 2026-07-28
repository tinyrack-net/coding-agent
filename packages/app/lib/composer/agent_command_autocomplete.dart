import 'package:agent_protocol/agent_protocol.dart';

enum SlashCommandPosition { start, inline }

final class SlashCommandRange {
  const SlashCommandRange({
    required this.start,
    required this.end,
    required this.query,
    required this.position,
  });

  final int start;
  final int end;
  final String query;
  final SlashCommandPosition position;
}

final class CommandAutocompleteEntry {
  const CommandAutocompleteEntry({
    required this.command,
    this.aliases = const [],
    this.isClient = false,
  });

  final AgentSlashCommand command;
  final List<String> aliases;
  final bool isClient;
}

final class _MatchScore {
  const _MatchScore(this.tier, this.offset, [this.spread = 0]);

  final int tier;
  final int offset;
  final int spread;

  _MatchScore operator +(_MatchScore other) => _MatchScore(
    tier + other.tier,
    offset + other.offset,
    spread + other.spread,
  );
}

List<CommandAutocompleteEntry> filterAndRankCommandAutocompleteEntries(
  Iterable<CommandAutocompleteEntry> entries,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  final source = entries.toList(growable: false);
  if (normalized.isEmpty) return List.of(source);

  final scored = <({CommandAutocompleteEntry entry, _MatchScore score})>[];
  for (final entry in source) {
    final score = _scoreTextFields(normalized, [
      entry.command.name,
      ...entry.aliases,
    ]);
    if (score != null) scored.add((entry: entry, score: score));
  }
  scored.sort((left, right) {
    final score = _compareScores(left.score, right.score);
    return score != 0
        ? score
        : left.entry.command.name.compareTo(right.entry.command.name);
  });
  return [for (final item in scored) item.entry];
}

List<CommandAutocompleteEntry> filterInlineSkillCommandEntries(
  Iterable<CommandAutocompleteEntry> entries,
) => [
  for (final entry in entries)
    if (!entry.isClient && entry.command.kind == AgentSlashCommandKind.skill)
      entry,
];

SlashCommandRange? findActiveSlashCommand({
  required String text,
  required int cursorIndex,
}) {
  final cursor = cursorIndex.clamp(0, text.length);
  final beforeCursor = text.substring(0, cursor);
  for (
    var slashIndex = beforeCursor.lastIndexOf('/');
    slashIndex >= 0;
    slashIndex = slashIndex == 0
        ? -1
        : beforeCursor.lastIndexOf('/', slashIndex - 1)
  ) {
    if (slashIndex > 0 && !_isWhitespace(text.codeUnitAt(slashIndex - 1))) {
      continue;
    }
    final query = beforeCursor.substring(slashIndex + 1);
    if (_hasInvalidQueryCharacter(query)) continue;
    return SlashCommandRange(
      start: slashIndex,
      end: cursor,
      query: query,
      position: slashIndex == 0
          ? SlashCommandPosition.start
          : SlashCommandPosition.inline,
    );
  }
  return null;
}

String applySlashCommandReplacement({
  required String text,
  required SlashCommandRange command,
  required String commandName,
}) {
  final replacement = '/$commandName${command.end == text.length ? ' ' : ''}';
  return text.replaceRange(command.start, command.end, replacement);
}

bool _hasInvalidQueryCharacter(String value) {
  for (final rune in value.runes) {
    if (rune == 0x2f || rune == 0x22 || rune == 0x27 || _isWhitespace(rune)) {
      return true;
    }
  }
  return false;
}

bool _isWhitespace(int rune) =>
    rune == 0x20 || rune == 0x09 || rune == 0x0a || rune == 0x0d;

bool _isWordBoundary(String? character) =>
    character == null || !RegExp(r'[a-z0-9]').hasMatch(character);

_MatchScore? _scoreMatch(String query, String text) {
  if (query.isEmpty) return const _MatchScore(0, 0);
  final normalizedText = text.toLowerCase();
  if (normalizedText == query) return const _MatchScore(0, 0);

  _MatchScore? best;
  var position = 0;
  while (position <= normalizedText.length - query.length) {
    final found = normalizedText.indexOf(query, position);
    if (found == -1) break;
    final before = found > 0 ? normalizedText[found - 1] : null;
    final after = found + query.length < normalizedText.length
        ? normalizedText[found + query.length]
        : null;
    final startsAtBoundary = found == 0 || _isWordBoundary(before);
    final endsAtBoundary = _isWordBoundary(after);
    final tier = startsAtBoundary && endsAtBoundary
        ? 1
        : found == 0
        ? 2
        : startsAtBoundary
        ? 3
        : 4;
    final candidate = _MatchScore(tier, found);
    if (best == null || _compareScores(candidate, best) < 0) best = candidate;
    position = found + 1;
  }
  if (best != null) return best;

  var queryIndex = 0;
  var firstIndex = -1;
  var lastIndex = -1;
  for (
    var textIndex = 0;
    textIndex < normalizedText.length && queryIndex < query.length;
    textIndex++
  ) {
    if (normalizedText[textIndex] != query[queryIndex]) continue;
    if (firstIndex == -1) firstIndex = textIndex;
    lastIndex = textIndex;
    queryIndex++;
  }
  if (queryIndex != query.length || firstIndex == -1) return null;
  return _MatchScore(5, firstIndex, lastIndex - firstIndex + 1);
}

_MatchScore? _scoreTextFields(String query, List<String> fields) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty);
  var aggregate = const _MatchScore(0, 0);
  for (final token in tokens) {
    _MatchScore? best;
    for (final field in fields) {
      final score = _scoreMatch(token, field);
      if (score != null && (best == null || _compareScores(score, best) < 0)) {
        best = score;
      }
    }
    if (best == null) return null;
    aggregate += _MatchScore(
      best.tier,
      best.offset,
      best.spread == 0 ? token.length : best.spread,
    );
  }
  return aggregate;
}

int _compareScores(_MatchScore left, _MatchScore right) {
  var result = left.tier.compareTo(right.tier);
  if (result != 0) return result;
  result = left.offset.compareTo(right.offset);
  return result != 0 ? result : left.spread.compareTo(right.spread);
}
