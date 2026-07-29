import 'package:agent_protocol/agent_protocol.dart';

const int liveHistoryFetchTimeoutMs = 2000;

typedef CliTimelineRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// Fetches the complete projected tail timeline used by live CLI views.
Future<List<TimelineItem>> fetchProjectedTimelineItems(
  CliTimelineRpcRequester request,
  String agentId, {
  int? timeoutMs,
}) async {
  final response = request(
    FetchAgentTimelineRequest(
      agentId: agentId,
      requestId: 'cli_timeline_${DateTime.now().microsecondsSinceEpoch}',
      direction: AgentTimelineDirection.tail,
      limit: 0,
      projection: AgentTimelineProjection.projected,
    ).toJson(),
  );
  final payload = timeoutMs == null
      ? await response
      : await response.timeout(Duration(milliseconds: timeoutMs));
  final page = AgentTimelinePage.fromResponseJson({
    'type': AgentTimelinePage.responseType,
    'payload': payload,
  });
  if (page.error case final error?) throw StateError(error);
  return page.entries.map((entry) => entry.item).toList(growable: false);
}
