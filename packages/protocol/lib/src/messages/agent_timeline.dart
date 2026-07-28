library;

import '../timeline/paseo_timeline_codec.dart';
import '../timeline/timeline_item.dart';

const int agentTimelineFetchPageSize = 40;

enum AgentTimelineDirection {
  tail,
  before,
  after;

  static AgentTimelineDirection fromWire(Object? value) => switch (value) {
    'tail' => tail,
    'before' => before,
    'after' => after,
    _ => throw FormatException('Unknown timeline direction: $value'),
  };
}

enum AgentTimelineProjection {
  projected,
  canonical;

  static AgentTimelineProjection fromWire(Object? value) => switch (value) {
    'projected' => projected,
    'canonical' => canonical,
    _ => throw FormatException('Unknown timeline projection: $value'),
  };
}

enum AgentTimelineCollapsedKind {
  assistantMerge('assistant_merge'),
  reasoningMerge('reasoning_merge'),
  toolLifecycle('tool_lifecycle');

  const AgentTimelineCollapsedKind(this.wire);

  final String wire;

  static AgentTimelineCollapsedKind fromWire(Object? value) => switch (value) {
    'assistant_merge' => assistantMerge,
    'reasoning_merge' => reasoningMerge,
    'tool_lifecycle' => toolLifecycle,
    _ => throw FormatException('Unknown timeline collapsed kind: $value'),
  };
}

final class AgentTimelineCursor {
  const AgentTimelineCursor({required this.epoch, required this.seq});

  final String epoch;
  final int seq;

  static AgentTimelineCursor fromJson(Map<String, Object?> json) =>
      AgentTimelineCursor(
        epoch: _requiredString(json, 'epoch'),
        seq: _requiredNonnegativeInt(json, 'seq'),
      );

  Map<String, Object?> toJson() => {'epoch': epoch, 'seq': seq};

  @override
  bool operator ==(Object other) =>
      other is AgentTimelineCursor && other.epoch == epoch && other.seq == seq;

  @override
  int get hashCode => Object.hash(epoch, seq);
}

final class AgentTimelineCursorRange {
  const AgentTimelineCursorRange({
    required this.epoch,
    required this.startSeq,
    required this.endSeq,
  });

  final String epoch;
  final int startSeq;
  final int endSeq;

  AgentTimelineCursor get start =>
      AgentTimelineCursor(epoch: epoch, seq: startSeq);
  AgentTimelineCursor get end => AgentTimelineCursor(epoch: epoch, seq: endSeq);
}

final class AgentTimelineWindow {
  const AgentTimelineWindow({
    required this.minSeq,
    required this.maxSeq,
    required this.nextSeq,
  });

  final int minSeq;
  final int maxSeq;
  final int nextSeq;

  static AgentTimelineWindow fromJson(Map<String, Object?> json) =>
      AgentTimelineWindow(
        minSeq: _requiredNonnegativeInt(json, 'minSeq'),
        maxSeq: _requiredNonnegativeInt(json, 'maxSeq'),
        nextSeq: _requiredNonnegativeInt(json, 'nextSeq'),
      );

  Map<String, Object?> toJson() => {
    'minSeq': minSeq,
    'maxSeq': maxSeq,
    'nextSeq': nextSeq,
  };
}

final class AgentTimelineSeqRange {
  const AgentTimelineSeqRange({required this.startSeq, required this.endSeq});

  final int startSeq;
  final int endSeq;

  static AgentTimelineSeqRange fromJson(Map<String, Object?> json) =>
      AgentTimelineSeqRange(
        startSeq: _requiredNonnegativeInt(json, 'startSeq'),
        endSeq: _requiredNonnegativeInt(json, 'endSeq'),
      );

  Map<String, Object?> toJson() => {'startSeq': startSeq, 'endSeq': endSeq};
}

final class AgentTimelineEntry {
  AgentTimelineEntry({
    required this.provider,
    required this.item,
    required this.timestamp,
    required this.seqStart,
    required this.seqEnd,
    required List<AgentTimelineSeqRange> sourceSeqRanges,
    required List<AgentTimelineCollapsedKind> collapsed,
  }) : sourceSeqRanges = List.unmodifiable(sourceSeqRanges),
       collapsed = List.unmodifiable(collapsed);

  final String provider;
  final TimelineItem item;
  final String timestamp;
  final int seqStart;
  final int seqEnd;
  final List<AgentTimelineSeqRange> sourceSeqRanges;
  final List<AgentTimelineCollapsedKind> collapsed;

  static AgentTimelineEntry fromJson(Map<String, Object?> json) {
    final seqStart = _requiredNonnegativeInt(json, 'seqStart');
    final seqEnd = _requiredNonnegativeInt(json, 'seqEnd');
    if (seqEnd < seqStart) {
      throw const FormatException('seqEnd must be >= seqStart');
    }
    final rawItem = _requiredMap(json, 'item');
    return AgentTimelineEntry(
      provider: _requiredString(json, 'provider'),
      item: PaseoTimelineCodec.decode(
        rawItem,
        fallbackId: 'timeline:$seqStart-$seqEnd',
      ),
      timestamp: _requiredString(json, 'timestamp'),
      seqStart: seqStart,
      seqEnd: seqEnd,
      sourceSeqRanges: _requiredMapList(
        json,
        'sourceSeqRanges',
      ).map(AgentTimelineSeqRange.fromJson).toList(growable: false),
      collapsed: _requiredList(
        json,
        'collapsed',
      ).map(AgentTimelineCollapsedKind.fromWire).toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'item': PaseoTimelineCodec.encode(item),
    'timestamp': timestamp,
    'seqStart': seqStart,
    'seqEnd': seqEnd,
    'sourceSeqRanges': [for (final range in sourceSeqRanges) range.toJson()],
    'collapsed': [for (final kind in collapsed) kind.wire],
  };
}

final class FetchAgentTimelineRequest {
  const FetchAgentTimelineRequest({
    required this.agentId,
    required this.requestId,
    this.direction,
    this.cursor,
    this.limit,
    this.projection,
  });

  static const type = 'fetch_agent_timeline_request';

  final String agentId;
  final String requestId;
  final AgentTimelineDirection? direction;
  final AgentTimelineCursor? cursor;
  final int? limit;
  final AgentTimelineProjection? projection;

  Map<String, Object?> toJson() {
    if (agentId.isEmpty || requestId.isEmpty) {
      throw const FormatException('agentId and requestId must not be empty');
    }
    final effectiveLimit = limit;
    if (effectiveLimit != null && effectiveLimit < 0) {
      throw const FormatException('limit must be nonnegative');
    }
    return {
      'type': type,
      'agentId': agentId,
      'requestId': requestId,
      if (direction != null) 'direction': direction!.name,
      if (cursor != null) 'cursor': cursor!.toJson(),
      if (effectiveLimit != null) 'limit': effectiveLimit,
      if (projection != null) 'projection': projection!.name,
    };
  }
}

final class AgentTimelinePage {
  AgentTimelinePage({
    required this.requestId,
    required this.agentId,
    required this.agent,
    required this.direction,
    required this.projection,
    required this.epoch,
    required this.reset,
    required this.staleCursor,
    required this.gap,
    required this.window,
    required this.startCursor,
    required this.endCursor,
    required this.hasOlder,
    required this.hasNewer,
    required List<AgentTimelineEntry> entries,
    required this.error,
  }) : entries = List.unmodifiable(entries);

  factory AgentTimelinePage.empty({
    required String agentId,
    String requestId = 'local-empty',
    String epoch = '0',
    AgentTimelineDirection direction = AgentTimelineDirection.tail,
    AgentTimelineProjection projection = AgentTimelineProjection.projected,
  }) => AgentTimelinePage(
    requestId: requestId,
    agentId: agentId,
    agent: null,
    direction: direction,
    projection: projection,
    epoch: epoch,
    reset: false,
    staleCursor: false,
    gap: false,
    window: const AgentTimelineWindow(minSeq: 0, maxSeq: 0, nextSeq: 0),
    startCursor: null,
    endCursor: null,
    hasOlder: false,
    hasNewer: false,
    entries: const [],
    error: null,
  );

  static const responseType = 'fetch_agent_timeline_response';

  final String requestId;
  final String agentId;
  final Map<String, Object?>? agent;
  final AgentTimelineDirection direction;
  final AgentTimelineProjection projection;
  final String epoch;
  final bool reset;
  final bool staleCursor;
  final bool gap;
  final AgentTimelineWindow window;
  final AgentTimelineCursor? startCursor;
  final AgentTimelineCursor? endCursor;
  final bool hasOlder;
  final bool hasNewer;
  final List<AgentTimelineEntry> entries;
  final String? error;

  AgentTimelineCursorRange? get cursorRange {
    final start = startCursor;
    final end = endCursor;
    if (start == null || end == null || start.epoch != end.epoch) return null;
    return AgentTimelineCursorRange(
      epoch: start.epoch,
      startSeq: start.seq,
      endSeq: end.seq,
    );
  }

  static AgentTimelinePage fromResponseJson(Map<String, Object?> json) {
    if (json['type'] != responseType) {
      throw FormatException('Expected $responseType');
    }
    final payload = _requiredMap(json, 'payload');
    final rawAgent = payload['agent'];
    if (rawAgent != null && rawAgent is! Map) {
      throw const FormatException('agent must be an object or null');
    }
    final rawError = payload['error'];
    if (rawError != null && rawError is! String) {
      throw const FormatException('error must be a string or null');
    }
    final startCursor = _optionalMap(payload, 'startCursor');
    final endCursor = _optionalMap(payload, 'endCursor');
    final Map<String, Object?>? agent;
    if (rawAgent is Map) {
      agent = Map<String, Object?>.unmodifiable(
        rawAgent.cast<String, Object?>(),
      );
    } else {
      agent = null;
    }
    return AgentTimelinePage(
      requestId: _requiredString(payload, 'requestId'),
      agentId: _requiredString(payload, 'agentId'),
      agent: agent,
      direction: AgentTimelineDirection.fromWire(payload['direction']),
      projection: AgentTimelineProjection.fromWire(payload['projection']),
      epoch: _requiredString(payload, 'epoch'),
      reset: _requiredBool(payload, 'reset'),
      staleCursor: _requiredBool(payload, 'staleCursor'),
      gap: _requiredBool(payload, 'gap'),
      window: AgentTimelineWindow.fromJson(_requiredMap(payload, 'window')),
      startCursor: startCursor == null
          ? null
          : AgentTimelineCursor.fromJson(startCursor),
      endCursor: endCursor == null
          ? null
          : AgentTimelineCursor.fromJson(endCursor),
      hasOlder: _requiredBool(payload, 'hasOlder'),
      hasNewer: _requiredBool(payload, 'hasNewer'),
      entries: _requiredMapList(
        payload,
        'entries',
      ).map(AgentTimelineEntry.fromJson).toList(growable: false),
      error: rawError as String?,
    );
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

int _requiredNonnegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  final result = switch (value) {
    int() => value,
    num() when value == value.toInt() => value.toInt(),
    _ => throw FormatException('$key must be an integer'),
  };
  if (result < 0) throw FormatException('$key must be nonnegative');
  return result;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, Object?>();
}

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) {
    throw FormatException('$key must be an object or null');
  }
  return value.cast<String, Object?>();
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return value;
}

List<Map<String, Object?>> _requiredMapList(
  Map<String, Object?> json,
  String key,
) => _requiredList(json, key)
    .map((entry) {
      if (entry is! Map) {
        throw FormatException('$key entries must be objects');
      }
      return entry.cast<String, Object?>();
    })
    .toList(growable: false);
