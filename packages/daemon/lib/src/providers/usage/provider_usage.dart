import 'package:agent_protocol/agent_protocol.dart';

/// Frozen Paseo 0.2.0 risk thresholds for quota windows and known limits.
ProviderUsageTone providerUsageToneFromUsedPct(double? usedPct) {
  if (usedPct == null || !usedPct.isFinite) {
    return ProviderUsageTone.defaultTone;
  }
  if (usedPct > 90) return ProviderUsageTone.danger;
  if (usedPct >= 70) return ProviderUsageTone.warning;
  return ProviderUsageTone.ok;
}

double? providerUsageUsedPctOf(double? used, double? limit) {
  if (used == null ||
      limit == null ||
      !used.isFinite ||
      !limit.isFinite ||
      limit <= 0) {
    return null;
  }
  return used / limit * 100;
}

ProviderUsageTone providerBalanceToneFromRemaining(double? remaining) {
  if (remaining == null || !remaining.isFinite) {
    return ProviderUsageTone.defaultTone;
  }
  return remaining <= 0 ? ProviderUsageTone.danger : ProviderUsageTone.ok;
}

abstract interface class ProviderUsageFetcher {
  String get providerId;
  String get displayName;
  Future<ProviderUsage> fetchUsage();
}

final class ProviderUsageListResult {
  const ProviderUsageListResult({
    required this.fetchedAt,
    required this.providers,
  });

  final String fetchedAt;
  final List<ProviderUsage> providers;
}

final class ProviderUsageService {
  ProviderUsageService({
    List<ProviderUsageFetcher> fetchers = const [],
    Duration cacheTtl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _fetchers = List.unmodifiable(fetchers),
       _cacheTtl = cacheTtl,
       _now = now ?? DateTime.now;

  final List<ProviderUsageFetcher> _fetchers;
  final Duration _cacheTtl;
  final DateTime Function() _now;
  ProviderUsageListResult? _cached;
  DateTime? _cachedAt;
  Future<ProviderUsageListResult>? _inFlight;

  Future<ProviderUsageListResult> listUsage({bool forceRefresh = false}) async {
    final now = _now().toUtc();
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) < _cacheTtl) {
      return cached;
    }
    if (_inFlight case final inFlight?) return inFlight;

    final request = _fetchFresh(now);
    _inFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_inFlight, request)) _inFlight = null;
    }
  }

  Future<ProviderUsageListResult> _fetchFresh(DateTime now) async {
    final providers = await Future.wait([
      for (final fetcher in _fetchers) _safeFetch(fetcher),
    ]);
    final result = ProviderUsageListResult(
      fetchedAt: now.toIso8601String(),
      providers: List.unmodifiable(providers),
    );
    _cached = result;
    _cachedAt = now;
    return result;
  }

  Future<ProviderUsage> _safeFetch(ProviderUsageFetcher fetcher) async {
    try {
      return await fetcher.fetchUsage();
    } catch (error) {
      return ProviderUsage(
        providerId: fetcher.providerId,
        displayName: fetcher.displayName,
        status: ProviderUsageStatus.error,
        planLabel: null,
        windows: const [],
        error: '$error',
      );
    }
  }
}

final class ProviderUsageV2Service {
  const ProviderUsageV2Service(this.usage);

  final ProviderUsageService usage;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != ProviderUsageListRequest.type) return null;
    final request = ProviderUsageListRequest.fromJson(message);
    final result = await usage.listUsage();
    return ProviderUsageListResponse(
      requestId: request.requestId,
      fetchedAt: result.fetchedAt,
      providers: result.providers,
    ).toJson();
  }
}
