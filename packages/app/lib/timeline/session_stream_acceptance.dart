/// Port of the acceptance tables in Paseo 0.2.0's
/// `timeline/session-stream-reducers.ts`.
///
/// A timeline replica must never apply a page or event that would silently
/// corrupt its window: a stale epoch, a sequence it already has, or a page
/// that starts past the end of what it holds (which would leave a hole).
/// These pure decisions are shared by the live-event path and both paging
/// directions so the rules stay in one place.
library;

import 'package:agent_protocol/agent_protocol.dart';

/// What to do with a live `agent_stream` event given the replica's cursor.
enum SessionTimelineSeqDecision {
  /// No cursor yet: this event establishes the live epoch.
  init,

  /// The event belongs to a different epoch than the replica holds.
  dropEpoch,

  /// Already applied.
  dropStale,

  /// Exactly the next sequence.
  accept,

  /// Skips ahead, so the replica must catch up before applying it.
  gap,
}

SessionTimelineSeqDecision classifySessionTimelineSeq({
  required AgentTimelineCursorRange? cursor,
  required String epoch,
  required int seq,
}) {
  if (cursor == null) return SessionTimelineSeqDecision.init;
  if (cursor.epoch != epoch) return SessionTimelineSeqDecision.dropEpoch;
  if (seq <= cursor.endSeq) return SessionTimelineSeqDecision.dropStale;
  if (seq == cursor.endSeq + 1) return SessionTimelineSeqDecision.accept;
  return SessionTimelineSeqDecision.gap;
}

/// Outcome of applying one page to the replica.
final class IncrementalAcceptResult {
  const IncrementalAcceptResult({
    required this.accepted,
    required this.cursor,
    required this.gapCursor,
  });

  /// Whether the page's entries may be applied.
  final bool accepted;

  /// The cursor the replica should hold afterwards.
  final AgentTimelineCursorRange? cursor;

  /// When non-null, the replica is missing sequences and must re-fetch
  /// forward from this cursor instead of applying the page.
  final AgentTimelineCursorRange? gapCursor;
}

({int? startSeq, int? endSeq}) _responseRange(AgentTimelinePage page) {
  final entries = page.entries;
  return (
    startSeq:
        page.startCursor?.seq ??
        (entries.isEmpty ? null : entries.first.seqStart),
    endSeq:
        page.endCursor?.seq ?? (entries.isEmpty ? null : entries.last.seqEnd),
  );
}

AgentTimelineCursorRange _gapAt(AgentTimelineCursorRange cursor) =>
    AgentTimelineCursorRange(
      epoch: cursor.epoch,
      startSeq: cursor.startSeq,
      endSeq: cursor.endSeq,
    );

/// Decides whether a forward (`after`) page may be applied.
IncrementalAcceptResult acceptIncrementalTimelineUnits({
  required AgentTimelinePage page,
  required AgentTimelineCursorRange? currentCursor,
}) {
  final (:startSeq, :endSeq) = _responseRange(page);
  if (startSeq == null || endSeq == null) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: null,
    );
  }

  if (currentCursor == null) {
    return IncrementalAcceptResult(
      accepted: true,
      cursor: AgentTimelineCursorRange(
        epoch: page.epoch,
        startSeq: startSeq,
        endSeq: endSeq,
      ),
      gapCursor: null,
    );
  }

  if (currentCursor.epoch != page.epoch) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: null,
    );
  }

  // A page without explicit cursors that straddles the replica's end cannot
  // be positioned reliably, so catch up rather than guess.
  if ((page.startCursor == null || page.endCursor == null) &&
      startSeq <= currentCursor.endSeq &&
      endSeq > currentCursor.endSeq) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: _gapAt(currentCursor),
    );
  }

  if (endSeq <= currentCursor.endSeq) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: null,
    );
  }

  // Starting more than one past the end would leave a hole.
  if (startSeq > currentCursor.endSeq + 1) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: _gapAt(currentCursor),
    );
  }

  return IncrementalAcceptResult(
    accepted: true,
    cursor: AgentTimelineCursorRange(
      epoch: currentCursor.epoch,
      startSeq: currentCursor.startSeq,
      endSeq: endSeq,
    ),
    gapCursor: null,
  );
}

/// Decides whether an older (`before`) page may be prepended. It must sit
/// strictly below what the replica already holds.
IncrementalAcceptResult acceptOlderTimelineUnits({
  required AgentTimelinePage page,
  required AgentTimelineCursorRange? currentCursor,
}) {
  if (currentCursor == null || currentCursor.epoch != page.epoch) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: null,
    );
  }

  final (:startSeq, :endSeq) = _responseRange(page);
  if (startSeq == null || endSeq == null || endSeq >= currentCursor.startSeq) {
    return IncrementalAcceptResult(
      accepted: false,
      cursor: currentCursor,
      gapCursor: null,
    );
  }

  return IncrementalAcceptResult(
    accepted: true,
    cursor: AgentTimelineCursorRange(
      epoch: currentCursor.epoch,
      startSeq: startSeq,
      endSeq: currentCursor.endSeq,
    ),
    gapCursor: null,
  );
}
