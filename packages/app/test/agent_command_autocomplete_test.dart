import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/agent_command_autocomplete.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSlashCommand command(
  String name, {
  AgentSlashCommandKind kind = AgentSlashCommandKind.command,
}) => AgentSlashCommand(
  name: name,
  description: '',
  argumentHint: '',
  kind: kind,
);

void main() {
  test('ranks prefixes above later word-boundary matches', () {
    final result = filterAndRankCommandAutocompleteEntries([
      CommandAutocompleteEntry(command: command('paseo-committee')),
      CommandAutocompleteEntry(command: command('commit')),
      CommandAutocompleteEntry(command: command('paseo-advisor')),
    ], 'comm');
    expect(result.map((entry) => entry.command.name), [
      'commit',
      'paseo-committee',
    ]);
  });

  test('matches aliases and subsequences', () {
    final result = filterAndRankCommandAutocompleteEntries([
      CommandAutocompleteEntry(
        command: command('exit'),
        aliases: const ['quit', 'q'],
        isClient: true,
      ),
      CommandAutocompleteEntry(command: command('clear')),
    ], 'q');
    expect(result.single.command.name, 'exit');
    expect(
      filterAndRankCommandAutocompleteEntries([
        CommandAutocompleteEntry(command: command('paseo-committee')),
      ], 'pct').single.command.name,
      'paseo-committee',
    );
  });

  test('uses name ordering when match scores tie', () {
    final result = filterAndRankCommandAutocompleteEntries([
      CommandAutocompleteEntry(
        command: command('zeta'),
        aliases: const ['same'],
      ),
      CommandAutocompleteEntry(
        command: command('alpha'),
        aliases: const ['same'],
      ),
    ], 'same');
    expect(result.map((entry) => entry.command.name), ['alpha', 'zeta']);
  });

  test('scores all substring boundary tiers', () {
    final result = filterAndRankCommandAutocompleteEntries([
      CommandAutocompleteEntry(command: command('commit')),
      CommandAutocompleteEntry(command: command('item')),
      CommandAutocompleteEntry(command: command('paseo-item')),
      CommandAutocompleteEntry(command: command('split-itemized')),
    ], 'it');
    expect(result.map((entry) => entry.command.name), [
      'item',
      'paseo-item',
      'split-itemized',
      'commit',
    ]);
  });

  test('finds start and inline tokens while rejecting paths', () {
    expect(
      findActiveSlashCommand(text: '/rew', cursorIndex: 4)?.position,
      SlashCommandPosition.start,
    );
    final inline = findActiveSlashCommand(
      text: 'use /tas before',
      cursorIndex: 'use /tas'.length,
    );
    expect(inline?.query, 'tas');
    expect(inline?.position, SlashCommandPosition.inline);
    expect(
      findActiveSlashCommand(
        text: 'read /tmp/project',
        cursorIndex: 'read /tmp/project'.length,
      ),
      isNull,
    );
  });

  test('filters inline commands to provider skills', () {
    final result = filterInlineSkillCommandEntries([
      CommandAutocompleteEntry(command: command('clear'), isClient: true),
      CommandAutocompleteEntry(command: command('compact')),
      CommandAutocompleteEntry(
        command: command('taste', kind: AgentSlashCommandKind.skill),
      ),
    ]);
    expect(result.single.command.name, 'taste');
  });

  test('replaces only the active token and appends space at tail', () {
    final text = 'use /tas';
    expect(
      applySlashCommandReplacement(
        text: text,
        command: const SlashCommandRange(
          start: 4,
          end: 8,
          query: 'tas',
          position: SlashCommandPosition.inline,
        ),
        commandName: 'taste',
      ),
      'use /taste ',
    );
  });
}
