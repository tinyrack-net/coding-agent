import 'dart:async';

import 'package:agent_daemon/src/cli/cli_timeline.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('fetches the complete projected tail and returns entry items', () async {
    Map<String, Object?>? request;
    const items = [
      UserMessageItem(id: 'user-1', text: 'hello'),
      AssistantMessageItem(id: 'assistant-1', text: 'world', complete: true),
    ];

    final result = await fetchProjectedTimelineItems((message) async {
      request = message;
      return _timelinePayload(message, items);
    }, 'agent-1');

    expect(request, {
      'type': 'fetch_agent_timeline_request',
      'agentId': 'agent-1',
      'requestId': startsWith('cli_timeline_'),
      'direction': 'tail',
      'limit': 0,
      'projection': 'projected',
    });
    expect(result.map((item) => item.id), ['user-1', 'assistant-1']);
    expect((result[0] as UserMessageItem).text, 'hello');
    expect((result[1] as AssistantMessageItem).text, 'world');
  });

  test('surfaces daemon timeline errors', () {
    expect(
      fetchProjectedTimelineItems(
        (message) async =>
            _timelinePayload(message, const [], error: 'timeline unavailable'),
        'agent-1',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'timeline unavailable',
        ),
      ),
    );
  });

  test('applies an optional request timeout', () {
    expect(liveHistoryFetchTimeoutMs, 2000);
    expect(
      fetchProjectedTimelineItems(
        (_) => Completer<Map<String, Object?>>().future,
        'agent-1',
        timeoutMs: 1,
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}

Map<String, Object?> _timelinePayload(
  Map<String, Object?> request,
  List<TimelineItem> items, {
  String? error,
}) => {
  'requestId': request['requestId'],
  'agentId': request['agentId'],
  'agent': null,
  'direction': 'tail',
  'projection': 'projected',
  'epoch': '1',
  'reset': false,
  'staleCursor': false,
  'gap': false,
  'window': {'minSeq': 1, 'maxSeq': items.length, 'nextSeq': items.length + 1},
  'startCursor': items.isEmpty ? null : {'epoch': '1', 'seq': 1},
  'endCursor': items.isEmpty ? null : {'epoch': '1', 'seq': items.length},
  'hasOlder': false,
  'hasNewer': false,
  'entries': [
    for (var index = 0; index < items.length; index++)
      {
        'provider': 'codex',
        'item': PaseoTimelineCodec.encode(items[index]),
        'timestamp': '2026-07-30T00:00:0${index}Z',
        'seqStart': index + 1,
        'seqEnd': index + 1,
        'sourceSeqRanges': [
          {'startSeq': index + 1, 'endSeq': index + 1},
        ],
        'collapsed': <Object?>[],
      },
  ],
  'error': error,
};
