import 'package:agent_protocol/agent_protocol.dart';
import '../core/paseo_ui_utils.dart'
    show MatchScore, compareMatchScores, scoreTextFields;

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

List<CommandAutocompleteEntry> filterAndRankCommandAutocompleteEntries(
  Iterable<CommandAutocompleteEntry> entries,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  final source = entries.toList(growable: false);
  if (normalized.isEmpty) return List.of(source);

  final scored = <({CommandAutocompleteEntry entry, MatchScore score})>[];
  for (final entry in source) {
    final score = scoreTextFields(normalized, [
      entry.command.name,
      ...entry.aliases,
    ]);
    if (score != null) scored.add((entry: entry, score: score));
  }
  scored.sort((left, right) {
    final score = compareMatchScores(left.score, right.score);
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
