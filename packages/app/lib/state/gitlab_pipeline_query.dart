import 'package:agent_protocol/agent_protocol.dart';

const gitlabLivePipelineRefetchInterval = Duration(seconds: 15);
const gitlabFinishedPipelineStaleTime = Duration(hours: 24);

final class PrPaneTimelineQueryKey {
  const PrPaneTimelineQueryKey({
    required this.serverId,
    required this.cwd,
    required this.prNumber,
  });

  final String serverId;
  final String cwd;
  final int? prNumber;

  @override
  bool operator ==(Object other) =>
      other is PrPaneTimelineQueryKey &&
      other.serverId == serverId &&
      other.cwd == cwd &&
      other.prNumber == prNumber;

  @override
  int get hashCode => Object.hash(serverId, cwd, prNumber);
}

final class GitlabPipelineQueryKey {
  const GitlabPipelineQueryKey({
    required this.serverId,
    required this.cwd,
    required this.pipelineId,
    required this.changeRequestNumber,
  });

  final String serverId;
  final String cwd;
  final int pipelineId;
  final int changeRequestNumber;

  @override
  bool operator ==(Object other) =>
      other is GitlabPipelineQueryKey &&
      other.serverId == serverId &&
      other.cwd == cwd &&
      other.pipelineId == pipelineId &&
      other.changeRequestNumber == changeRequestNumber;

  @override
  int get hashCode =>
      Object.hash(serverId, cwd, pipelineId, changeRequestNumber);
}

final class GitlabPipelineCacheSnapshot {
  const GitlabPipelineCacheSnapshot({
    required this.pipeline,
    required this.updatedAt,
  });

  /// A successful query may legitimately return null. The snapshot object's
  /// presence, rather than [pipeline], distinguishes that from a cache miss.
  final CheckoutPipeline? pipeline;
  final DateTime updatedAt;

  bool isFreshAt(DateTime now) =>
      now.difference(updatedAt) < gitlabFinishedPipelineStaleTime;
}

final class GitlabPipelineQueryCache {
  GitlabPipelineQueryCache({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<GitlabPipelineQueryKey, GitlabPipelineCacheSnapshot> _entries = {};
  final Map<GitlabPipelineQueryKey, Future<CheckoutPipeline?>> _inFlight = {};
  final Map<GitlabPipelineQueryKey, int> _epochs = {};

  GitlabPipelineCacheSnapshot? snapshot(GitlabPipelineQueryKey key) =>
      _entries[key];

  bool shouldFetch(GitlabPipelineQueryKey key, {required bool live}) {
    if (live) return true;
    final cached = _entries[key];
    return cached == null || !cached.isFreshAt(_now());
  }

  void record(GitlabPipelineQueryKey key, CheckoutPipeline? pipeline) {
    _entries[key] = GitlabPipelineCacheSnapshot(
      pipeline: pipeline,
      updatedAt: _now(),
    );
  }

  Future<CheckoutPipeline?> fetch(
    GitlabPipelineQueryKey key,
    Future<CheckoutPipeline?> Function() loader,
  ) async {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final epoch = _epochs[key] ?? 0;
    final request = Future<CheckoutPipeline?>.sync(loader);
    _inFlight[key] = request;
    try {
      final pipeline = await request;
      if ((_epochs[key] ?? 0) == epoch) record(key, pipeline);
      return pipeline;
    } finally {
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    }
  }

  void invalidate({required String serverId, required String cwd}) {
    final matchingKeys = {
      ..._entries.keys.where(
        (key) => key.serverId == serverId && key.cwd == cwd,
      ),
      ..._inFlight.keys.where(
        (key) => key.serverId == serverId && key.cwd == cwd,
      ),
    };
    for (final key in matchingKeys) {
      _epochs[key] = (_epochs[key] ?? 0) + 1;
      _inFlight.remove(key);
    }
    _entries.removeWhere(
      (key, _) => key.serverId == serverId && key.cwd == cwd,
    );
  }
}
