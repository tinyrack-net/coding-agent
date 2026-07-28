import 'dart:convert';

import 'package:agent_daemon/src/server/agent_directory_pager.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _defaultSort = [
  AgentDirectorySort(
    key: AgentDirectorySortKey.updatedAt,
    direction: AgentDirectorySortDirection.desc,
  ),
];

AgentSummary _agent({
  required String id,
  String title = 'Agent',
  AgentRunState state = AgentRunState.idle,
  AgentAttentionReason? attentionReason,
  bool requiresAttention = false,
  int createdAtMs = 1,
  String? updatedAt,
}) => AgentSummary(
  agentId: id,
  title: title,
  cwd: '/repo',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: state,
  createdAtMs: createdAtMs,
  updatedAt: updatedAt,
  attentionReason: attentionReason,
  requiresAttention: requiresAttention,
);

String _token(Object? value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Matcher _cursorError(String message) => isA<AgentDirectoryCursorException>()
    .having((error) => error.message, 'message', message);

void main() {
  test('normalizes defaults and deduplicates sort keys', () {
    expect(normalizeAgentDirectorySort(const []), _defaultSort);
    final normalized = normalizeAgentDirectorySort(const [
      AgentDirectorySort(
        key: AgentDirectorySortKey.title,
        direction: AgentDirectorySortDirection.asc,
      ),
      AgentDirectorySort(
        key: AgentDirectorySortKey.title,
        direction: AgentDirectorySortDirection.desc,
      ),
      AgentDirectorySort(
        key: AgentDirectorySortKey.createdAt,
        direction: AgentDirectorySortDirection.desc,
      ),
    ]);
    expect(normalized.map((entry) => entry.key), [
      AgentDirectorySortKey.title,
      AgentDirectorySortKey.createdAt,
    ]);
    expect(normalized.first.direction, AgentDirectorySortDirection.asc);
  });

  test('matches frozen status priority including attention reasons', () {
    expect(
      agentDirectoryStatusPriority(
        _agent(
          id: 'permission',
          attentionReason: AgentAttentionReason.permission,
        ),
      ),
      0,
    );
    expect(
      agentDirectoryStatusPriority(
        _agent(id: 'error', attentionReason: AgentAttentionReason.error),
      ),
      1,
    );
    expect(
      agentDirectoryStatusPriority(
        _agent(id: 'running', state: AgentRunState.running),
      ),
      2,
    );
    expect(
      agentDirectoryStatusPriority(
        _agent(id: 'initializing', state: AgentRunState.initializing),
      ),
      3,
    );
    expect(
      agentDirectoryStatusPriority(
        _agent(id: 'attention', requiresAttention: true),
      ),
      4,
    );
    expect(
      agentDirectoryStatusPriority(
        _agent(id: 'closed', state: AgentRunState.closed),
      ),
      4,
    );
  });

  test('sorts by direction, secondary values, nulls, and final id', () {
    const sort = [
      AgentDirectorySort(
        key: AgentDirectorySortKey.updatedAt,
        direction: AgentDirectorySortDirection.desc,
      ),
      AgentDirectorySort(
        key: AgentDirectorySortKey.title,
        direction: AgentDirectorySortDirection.asc,
      ),
    ];
    final newest = _agent(
      id: 'a',
      title: 'Zulu',
      updatedAt: '2026-07-28T02:00:00.000Z',
    );
    final tied = _agent(
      id: 'b',
      title: 'Alpha',
      updatedAt: '2026-07-28T02:00:00.000Z',
    );
    final older = _agent(id: 'c', updatedAt: '2026-07-28T01:00:00.000Z');
    expect(compareAgentDirectoryEntries(tied, newest, sort), lessThan(0));
    expect(compareAgentDirectoryEntries(newest, older, sort), lessThan(0));
    expect(
      compareAgentDirectoryEntries(
        _agent(id: 'a', updatedAt: 'bad'),
        _agent(id: 'z', updatedAt: 'bad'),
        _defaultSort,
      ),
      lessThan(0),
    );
  });

  test('encodes the exact Node base64url cursor shape and decodes it', () {
    const sort = [
      AgentDirectorySort(
        key: AgentDirectorySortKey.updatedAt,
        direction: AgentDirectorySortDirection.desc,
      ),
      AgentDirectorySort(
        key: AgentDirectorySortKey.title,
        direction: AgentDirectorySortDirection.asc,
      ),
    ];
    final agent = _agent(
      id: 'agent-1',
      title: 'First',
      updatedAt: '1970-01-01T00:00:00.200Z',
    );
    final token = encodeAgentDirectoryCursor(agent, sort);
    expect(
      token,
      'eyJzb3J0IjpbeyJrZXkiOiJ1cGRhdGVkX2F0IiwiZGlyZWN0aW9uIjoiZGVz'
      'YyJ9LHsia2V5IjoidGl0bGUiLCJkaXJlY3Rpb24iOiJhc2MifV0sInZhbHVl'
      'cyI6eyJ1cGRhdGVkX2F0IjoyMDAsInRpdGxlIjoiZmlyc3QifSwiaWQiOiJh'
      'Z2VudC0xIn0',
    );
    final decoded = decodeAgentDirectoryCursor(token, sort);
    expect(decoded.agentId, 'agent-1');
    expect(decoded.values, {'updated_at': 200, 'title': 'first'});
    expect(compareAgentDirectoryEntryWithCursor(agent, decoded, sort), 0);
    expect(
      compareAgentDirectoryEntryWithCursor(
        _agent(id: 'older', updatedAt: '1970-01-01T00:00:00.100Z'),
        decoded,
        sort,
      ),
      greaterThan(0),
    );
    final padding = List.filled((4 - token.length % 4) % 4, '=').join();
    expect(
      decodeAgentDirectoryCursor('$token$padding', sort).agentId,
      'agent-1',
    );
  });

  test(
    'cursor remains stable when the cursor row is removed or rows insert',
    () {
      final cursorRow = _agent(
        id: 'cursor',
        updatedAt: '2026-07-28T02:00:00.000Z',
      );
      final cursor = decodeAgentDirectoryCursor(
        encodeAgentDirectoryCursor(cursorRow, _defaultSort),
        _defaultSort,
      );
      final insertedAhead = _agent(
        id: 'ahead',
        updatedAt: '2026-07-28T03:00:00.000Z',
      );
      final insertedBehind = _agent(
        id: 'behind',
        updatedAt: '2026-07-28T01:00:00.000Z',
      );
      expect(
        compareAgentDirectoryEntryWithCursor(
          insertedAhead,
          cursor,
          _defaultSort,
        ),
        lessThan(0),
      );
      expect(
        compareAgentDirectoryEntryWithCursor(
          insertedBehind,
          cursor,
          _defaultSort,
        ),
        greaterThan(0),
      );
    },
  );

  test('rejects malformed and sort-mismatched cursors', () {
    for (final token in [
      '@@@',
      _token(['array']),
      _token({
        'sort': [
          {'key': 'updated_at', 'direction': 'desc'},
        ],
        'values': {'updated_at': 1},
      }),
      _token({
        'sort': [
          {'key': 'made_up', 'direction': 'desc'},
        ],
        'values': <String, Object?>{},
        'id': 'agent',
      }),
    ]) {
      expect(
        () => decodeAgentDirectoryCursor(token, _defaultSort),
        throwsA(_cursorError('Invalid fetch_agents cursor')),
      );
    }
    final wrongSort = _token({
      'sort': [
        {'key': 'updated_at', 'direction': 'asc'},
      ],
      'values': {'updated_at': 1},
      'id': 'agent',
    });
    expect(
      () => decodeAgentDirectoryCursor(wrongSort, _defaultSort),
      throwsA(_cursorError('fetch_agents cursor does not match current sort')),
    );
  });
}
