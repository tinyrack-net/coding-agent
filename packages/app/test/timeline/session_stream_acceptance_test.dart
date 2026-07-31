// Port of the acceptance decision tables in Paseo's
// `timeline/session-stream-reducers.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/timeline/session_stream_acceptance.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTimelineCursorRange cursor({
  String epoch = '1',
  int startSeq = 1,
  int endSeq = 10,
}) =>
    AgentTimelineCursorRange(epoch: epoch, startSeq: startSeq, endSeq: endSeq);

AgentTimelineEntry entry(int seq) => AgentTimelineEntry(
  provider: 'codex',
  item: AssistantMessageItem(id: 'i$seq', text: 'i$seq', complete: true),
  timestamp: '2026-07-28T00:00:00.000Z',
  seqStart: seq,
  seqEnd: seq,
  sourceSeqRanges: [AgentTimelineSeqRange(startSeq: seq, endSeq: seq)],
  collapsed: const [],
);

AgentTimelinePage page({
  String epoch = '1',
  required int startSeq,
  required int endSeq,
  bool withCursors = true,
  AgentTimelineDirection direction = AgentTimelineDirection.after,
}) => AgentTimelinePage(
  requestId: 'r1',
  agentId: 'a1',
  agent: null,
  direction: direction,
  projection: AgentTimelineProjection.projected,
  epoch: epoch,
  reset: false,
  staleCursor: false,
  gap: false,
  window: AgentTimelineWindow(
    minSeq: startSeq,
    maxSeq: endSeq,
    nextSeq: endSeq + 1,
  ),
  startCursor: withCursors
      ? AgentTimelineCursor(epoch: epoch, seq: startSeq)
      : null,
  endCursor: withCursors
      ? AgentTimelineCursor(epoch: epoch, seq: endSeq)
      : null,
  hasOlder: false,
  hasNewer: false,
  entries: [for (var seq = startSeq; seq <= endSeq; seq += 1) entry(seq)],
  error: null,
);

void main() {
  group('classifySessionTimelineSeq', () {
    test('init without a cursor', () {
      expect(
        classifySessionTimelineSeq(cursor: null, epoch: '1', seq: 7),
        SessionTimelineSeqDecision.init,
      );
    });

    test('drops a different epoch', () {
      expect(
        classifySessionTimelineSeq(cursor: cursor(), epoch: '2', seq: 11),
        SessionTimelineSeqDecision.dropEpoch,
      );
    });

    test('drops an already-applied sequence', () {
      expect(
        classifySessionTimelineSeq(cursor: cursor(), epoch: '1', seq: 10),
        SessionTimelineSeqDecision.dropStale,
      );
      expect(
        classifySessionTimelineSeq(cursor: cursor(), epoch: '1', seq: 3),
        SessionTimelineSeqDecision.dropStale,
      );
    });

    test('accepts exactly the next sequence', () {
      expect(
        classifySessionTimelineSeq(cursor: cursor(), epoch: '1', seq: 11),
        SessionTimelineSeqDecision.accept,
      );
    });

    test('reports a gap when the sequence skips ahead', () {
      expect(
        classifySessionTimelineSeq(cursor: cursor(), epoch: '1', seq: 12),
        SessionTimelineSeqDecision.gap,
      );
    });
  });

  group('acceptIncrementalTimelineUnits', () {
    test('accepts any page when the replica has no cursor', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 4, endSeq: 6),
        currentCursor: null,
      );

      expect(result.accepted, isTrue);
      expect(result.cursor?.startSeq, 4);
      expect(result.cursor?.endSeq, 6);
      expect(result.gapCursor, isNull);
    });

    test('rejects an empty page', () {
      final result = acceptIncrementalTimelineUnits(
        page: AgentTimelinePage.empty(agentId: 'a1', epoch: '1'),
        currentCursor: cursor(),
      );

      expect(result.accepted, isFalse);
      // AgentTimelineCursorRange has no value equality, so compare fields.
      expect(result.cursor?.startSeq, 1);
      expect(result.cursor?.endSeq, 10);
      expect(result.gapCursor, isNull);
    });

    test('rejects a page from another epoch', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(epoch: '2', startSeq: 11, endSeq: 12),
        currentCursor: cursor(),
      );

      expect(result.accepted, isFalse);
      expect(result.gapCursor, isNull);
    });

    test('rejects a page the replica already holds', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 5, endSeq: 10),
        currentCursor: cursor(),
      );

      expect(result.accepted, isFalse);
      expect(result.gapCursor, isNull);
    });

    test('accepts a page that resumes exactly at the next sequence', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 11, endSeq: 14),
        currentCursor: cursor(),
      );

      expect(result.accepted, isTrue);
      expect(result.cursor?.startSeq, 1);
      expect(result.cursor?.endSeq, 14);
    });

    test('accepts a page that overlaps the end without leaving a hole', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 9, endSeq: 14),
        currentCursor: cursor(),
      );

      expect(result.accepted, isTrue);
      expect(result.cursor?.endSeq, 14);
    });

    test('reports a gap when the page starts past the next sequence', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 12, endSeq: 14),
        currentCursor: cursor(),
      );

      expect(result.accepted, isFalse);
      expect(result.gapCursor?.endSeq, 10);
    });

    test('reports a gap for a cursorless page straddling the end', () {
      final result = acceptIncrementalTimelineUnits(
        page: page(startSeq: 9, endSeq: 14, withCursors: false),
        currentCursor: cursor(),
      );

      expect(result.accepted, isFalse);
      expect(result.gapCursor?.endSeq, 10);
    });
  });

  group('acceptOlderTimelineUnits', () {
    test('rejects when the replica has no cursor', () {
      final result = acceptOlderTimelineUnits(
        page: page(
          startSeq: 1,
          endSeq: 3,
          direction: AgentTimelineDirection.before,
        ),
        currentCursor: null,
      );

      expect(result.accepted, isFalse);
    });

    test('rejects a page from another epoch', () {
      final result = acceptOlderTimelineUnits(
        page: page(
          epoch: '2',
          startSeq: 1,
          endSeq: 3,
          direction: AgentTimelineDirection.before,
        ),
        currentCursor: cursor(startSeq: 5),
      );

      expect(result.accepted, isFalse);
    });

    test('accepts a page strictly below the retained window', () {
      final result = acceptOlderTimelineUnits(
        page: page(
          startSeq: 1,
          endSeq: 4,
          direction: AgentTimelineDirection.before,
        ),
        currentCursor: cursor(startSeq: 5),
      );

      expect(result.accepted, isTrue);
      expect(result.cursor?.startSeq, 1);
      expect(result.cursor?.endSeq, 10);
    });

    test('rejects a page overlapping the retained window', () {
      final result = acceptOlderTimelineUnits(
        page: page(
          startSeq: 1,
          endSeq: 5,
          direction: AgentTimelineDirection.before,
        ),
        currentCursor: cursor(startSeq: 5),
      );

      expect(result.accepted, isFalse);
      expect(result.cursor?.startSeq, 5);
    });

    test('rejects an empty page', () {
      final result = acceptOlderTimelineUnits(
        page: AgentTimelinePage.empty(agentId: 'a1', epoch: '1'),
        currentCursor: cursor(startSeq: 5),
      );

      expect(result.accepted, isFalse);
    });
  });
}
