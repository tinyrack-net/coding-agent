import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/terminal/terminal_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PaseoTerminalInfo created(String id, String name, {String? title}) =>
      PaseoTerminalInfo(id: id, name: name, cwd: '/tmp/project', title: title);

  test('adds a created terminal when the list is empty', () {
    final result = upsertTerminalListEntry(
      terminals: const [],
      terminal: created('term-1', 'Terminal 1'),
    );

    expect(result, hasLength(1));
    expect(result.single.id, 'term-1');
    expect(result.single.name, 'Terminal 1');
    expect(result.single.title, isNull);
  });

  test('appends a created terminal when the id does not already exist', () {
    const original = TerminalListEntry(id: 'term-1', name: 'Terminal 1');
    final terminals = <TerminalListEntry>[original];
    final result = upsertTerminalListEntry(
      terminals: terminals,
      terminal: created('term-2', 'Terminal 2'),
    );

    expect(result.map((entry) => entry.id), ['term-1', 'term-2']);
    expect(identical(result.first, original), isTrue);
    expect(terminals, hasLength(1));
  });

  test('replaces the existing terminal entry in place when ids match', () {
    const first = TerminalListEntry(id: 'term-1', name: 'Terminal 1');
    final terminals = <TerminalListEntry>[
      first,
      const TerminalListEntry(id: 'term-2', name: 'Old Name'),
    ];
    final result = upsertTerminalListEntry(
      terminals: terminals,
      terminal: created('term-2', 'Renamed Terminal'),
    );

    expect(result.map((entry) => entry.id), ['term-1', 'term-2']);
    expect(identical(result.first, first), isTrue);
    expect(result.last.name, 'Renamed Terminal');
    expect(terminals.last.name, 'Old Name');
  });

  test('preserves non-empty titles and omits empty titles', () {
    final titled = upsertTerminalListEntry(
      terminals: const [],
      terminal: created('term-3', 'Terminal 3', title: 'Build Output'),
    );
    final emptyTitle = upsertTerminalListEntry(
      terminals: const [],
      terminal: created('term-4', 'Terminal 4', title: ''),
    );

    expect(titled.single.title, 'Build Output');
    expect(emptyTitle.single.title, isNull);
  });
}
