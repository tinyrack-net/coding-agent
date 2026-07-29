import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/terminal/terminal_list.dart';
import 'package:coding_agent_app/terminal/workspace_terminal_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TerminalListEntry listed(String id) =>
      TerminalListEntry(id: id, name: id, title: id);

  PaseoTerminalInfo created(String id) =>
      PaseoTerminalInfo(id: id, name: id, cwd: '/repo', title: id);

  test('builds scoped keys and applies the frozen creation gate', () {
    expect(buildTerminalsQueryKey('host-1', '/repo', 'workspace-1'), (
      namespace: 'terminals',
      serverId: 'host-1',
      workspaceDirectory: '/repo',
      workspaceId: 'workspace-1',
    ));
    expect(terminalsQueryStaleTime, const Duration(seconds: 5));
    expect(
      canCreateWorkspaceTerminal(
        isRouteFocused: true,
        client: Object(),
        isConnected: true,
        workspaceDirectory: '/repo',
      ),
      isTrue,
    );
    for (final input in [
      (focused: false, client: Object(), connected: true, directory: '/repo'),
      (focused: true, client: null, connected: true, directory: '/repo'),
      (focused: true, client: Object(), connected: false, directory: '/repo'),
      (focused: true, client: Object(), connected: true, directory: ''),
    ]) {
      expect(
        canCreateWorkspaceTerminal(
          isRouteFocused: input.focused,
          client: input.client,
          isConnected: input.connected,
          workspaceDirectory: input.directory,
        ),
        isFalse,
      );
    }
  });

  test(
    'keeps pending script terminals until live or superseded by a fresh list',
    () {
      final pending = {
        'older-than-list': 10,
        'now-live': 20,
        'still-pending': 30,
      };

      final reconciled = reconcilePendingScriptTerminals(
        liveTerminalIds: const ['now-live'],
        dataUpdatedAt: 20,
        pendingTerminalIds: pending,
      );

      expect(reconciled, {'still-pending': 30});
      expect(pending, hasLength(3));
    },
  );

  test('returns the same pending map when reconciliation changes nothing', () {
    final pending = {'still-pending': 30};

    final reconciled = reconcilePendingScriptTerminals(
      liveTerminalIds: const [],
      dataUpdatedAt: 20,
      pendingTerminalIds: pending,
    );

    expect(identical(reconciled, pending), isTrue);
  });

  test('combines and classifies terminal ids without duplicates', () {
    final pending = {'script-pending': 10, 'terminal-1': 10};

    expect(
      collectKnownTerminalIds(
        liveTerminalIds: const ['terminal-1', 'terminal-2'],
        pendingScriptTerminalIds: pending,
      ),
      ['terminal-1', 'terminal-2', 'script-pending'],
    );
    expect(
      collectScriptTerminalIds(
        pendingScriptTerminalIds: pending,
        scripts: const [
          WorkspaceScriptTerminal(terminalId: 'script-live'),
          WorkspaceScriptTerminal(),
        ],
      ),
      {'script-pending', 'terminal-1', 'script-live'},
    );
    expect(
      collectStandaloneTerminalIds(
        terminals: [
          listed('terminal-1'),
          listed('terminal-2'),
          listed('script-live'),
        ],
        scriptTerminalIds: {'terminal-1', 'script-live'},
      ),
      ['terminal-2'],
    );
  });

  test('updates terminal cache entries for created and closed terminals', () {
    final current = ListTerminalsPayload(
      cwd: '/repo',
      requestId: 'existing',
      terminals: [listed('terminal-1')],
    );

    final added = upsertCreatedTerminalPayload(
      current: current,
      terminal: created('terminal-2'),
      workspaceDirectory: '/ignored',
    );
    expect(added.cwd, '/repo');
    expect(added.requestId, 'existing');
    expect(added.terminals.map((entry) => entry.id), [
      'terminal-1',
      'terminal-2',
    ]);
    expect(added.terminals.last.title, 'terminal-2');

    final removed = removeTerminalFromPayload('terminal-1', current);
    expect(removed?.cwd, '/repo');
    expect(removed?.requestId, 'existing');
    expect(removed?.terminals, isEmpty);
    expect(removeTerminalFromPayload('terminal-1', null), isNull);
  });

  test('creates fallback payload metadata exactly once', () {
    final payload = upsertCreatedTerminalPayload(
      current: null,
      terminal: created('terminal-3'),
      workspaceDirectory: '/repo',
    );
    expect(payload.cwd, '/repo');
    expect(payload.requestId, 'terminal-create-terminal-3');

    final noCwd = upsertCreatedTerminalPayload(
      current: null,
      terminal: created('terminal-4'),
      workspaceDirectory: '',
    );
    expect(noCwd.cwd, isNull);
  });
}
