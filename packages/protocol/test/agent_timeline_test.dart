import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('tail request matches the Paseo 0.2.0 wire shape', () {
    expect(
      const FetchAgentTimelineRequest(
        agentId: 'agent-1',
        requestId: 'request-1',
        direction: AgentTimelineDirection.tail,
        limit: agentTimelineFetchPageSize,
        projection: AgentTimelineProjection.projected,
      ).toJson(),
      {
        'type': 'fetch_agent_timeline_request',
        'agentId': 'agent-1',
        'requestId': 'request-1',
        'direction': 'tail',
        'limit': 40,
        'projection': 'projected',
      },
    );
  });

  test('response parses cursors, projection metadata, and rich user ids', () {
    final page = AgentTimelinePage.fromResponseJson({
      'type': 'fetch_agent_timeline_response',
      'payload': {
        'requestId': 'request-1',
        'agentId': 'agent-1',
        'agent': {'id': 'agent-1'},
        'direction': 'before',
        'projection': 'projected',
        'epoch': '7',
        'reset': false,
        'staleCursor': false,
        'gap': false,
        'window': {'minSeq': 1, 'maxSeq': 12, 'nextSeq': 13},
        'startCursor': {'epoch': '7', 'seq': 3},
        'endCursor': {'epoch': '7', 'seq': 8},
        'hasOlder': true,
        'hasNewer': true,
        'entries': [
          {
            'provider': 'codex',
            'item': {
              'type': 'user_message',
              'messageId': 'provider-id',
              'clientMessageId': 'client-id',
              'text': 'hello',
            },
            'timestamp': '2026-07-28T00:00:00.000Z',
            'seqStart': 3,
            'seqEnd': 4,
            'sourceSeqRanges': [
              {'startSeq': 3, 'endSeq': 4},
            ],
            'collapsed': ['assistant_merge', 'tool_lifecycle'],
          },
        ],
        'error': null,
      },
    });

    expect(page.cursorRange?.epoch, '7');
    expect(page.cursorRange?.startSeq, 3);
    expect(page.cursorRange?.endSeq, 8);
    expect(page.window.nextSeq, 13);
    expect(page.hasOlder, isTrue);
    expect(page.hasNewer, isTrue);
    expect(page.entries.single.item, isA<UserMessageItem>());
    expect(
      (page.entries.single.item as UserMessageItem).clientMessageId,
      'client-id',
    );
    expect(page.entries.single.toJson()['collapsed'], [
      'assistant_merge',
      'tool_lifecycle',
    ]);
  });

  test('malformed response boundaries are rejected', () {
    Map<String, Object?> response(Map<String, Object?> overrides) => {
      'type': 'fetch_agent_timeline_response',
      'payload': <String, Object?>{
        'requestId': 'request-1',
        'agentId': 'agent-1',
        'agent': null,
        'direction': 'tail',
        'projection': 'projected',
        'epoch': '1',
        'reset': false,
        'staleCursor': false,
        'gap': false,
        'window': {'minSeq': 0, 'maxSeq': 0, 'nextSeq': 0},
        'startCursor': null,
        'endCursor': null,
        'hasOlder': false,
        'hasNewer': false,
        'entries': <Object?>[],
        'error': null,
        ...overrides,
      },
    };

    expect(
      () => AgentTimelinePage.fromResponseJson(
        response({'direction': 'sideways'}),
      ),
      throwsFormatException,
    );
    expect(
      () => AgentTimelinePage.fromResponseJson(
        response({
          'startCursor': {'epoch': '1', 'seq': -1},
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => AgentTimelinePage.fromResponseJson(response({'error': 42})),
      throwsFormatException,
    );
    expect(
      () => const FetchAgentTimelineRequest(
        agentId: 'agent-1',
        requestId: 'request-1',
        limit: -1,
      ).toJson(),
      throwsFormatException,
    );
  });
}
