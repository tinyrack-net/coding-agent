import 'dart:async';

import 'package:agent_daemon/src/providers/usage/provider_usage.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('Paseo usage risk thresholds are exact', () {
    expect(providerUsageToneFromUsedPct(null), ProviderUsageTone.defaultTone);
    expect(providerUsageToneFromUsedPct(0), ProviderUsageTone.ok);
    expect(providerUsageToneFromUsedPct(69.9), ProviderUsageTone.ok);
    expect(providerUsageToneFromUsedPct(70), ProviderUsageTone.warning);
    expect(providerUsageToneFromUsedPct(90), ProviderUsageTone.warning);
    expect(providerUsageToneFromUsedPct(90.1), ProviderUsageTone.danger);
    expect(providerUsageToneFromUsedPct(150), ProviderUsageTone.danger);
  });

  test('known-limit and remaining-only balance helpers match Paseo', () {
    expect(providerUsageUsedPctOf(15.79, 42.5), closeTo(37.15, 0.01));
    expect(providerUsageUsedPctOf(50, 0), isNull);
    expect(providerUsageUsedPctOf(50, -1), isNull);
    expect(
      providerBalanceToneFromRemaining(null),
      ProviderUsageTone.defaultTone,
    );
    expect(providerBalanceToneFromRemaining(0.01), ProviderUsageTone.ok);
    expect(providerBalanceToneFromRemaining(0), ProviderUsageTone.danger);
  });

  test(
    'usage service fetches concurrently, caches, and coalesces requests',
    () async {
      final first = Completer<ProviderUsage>();
      final second = Completer<ProviderUsage>();
      final fetchers = [
        _Fetcher('claude', future: first.future),
        _Fetcher('codex', future: second.future),
      ];
      final service = ProviderUsageService(
        fetchers: fetchers,
        now: () => DateTime.utc(2026, 7, 22, 12),
      );

      final a = service.listUsage();
      final b = service.listUsage();
      expect(fetchers.map((fetcher) => fetcher.calls), everyElement(1));
      first.complete(_usage('claude'));
      second.complete(_usage('codex'));

      expect((await a).providers.map((usage) => usage.providerId), [
        'claude',
        'codex',
      ]);
      expect(identical(await a, await b), isTrue);
      expect(identical(await a, await service.listUsage()), isTrue);
    },
  );

  test(
    'v2 handler emits frozen response and isolates provider failures',
    () async {
      final service = ProviderUsageV2Service(
        ProviderUsageService(
          fetchers: [
            _Fetcher('claude', error: StateError('credentials missing')),
          ],
          now: () => DateTime.utc(2026, 7, 22, 12),
        ),
      );

      final json = await service.handle(
        const ProviderUsageListRequest(requestId: 'req-1').toJson(),
      );
      final response = ProviderUsageListResponse.fromJson(json!);
      expect(response.requestId, 'req-1');
      expect(response.providers.single.status, ProviderUsageStatus.error);
      expect(response.providers.single.error, contains('credentials missing'));
      expect(await service.handle({'type': 'other'}), isNull);
    },
  );
}

ProviderUsage _usage(String id) => ProviderUsage(
  providerId: id,
  displayName: id,
  status: ProviderUsageStatus.available,
  planLabel: null,
  windows: const [],
);

final class _Fetcher implements ProviderUsageFetcher {
  _Fetcher(this.providerId, {this.future, this.error});

  @override
  final String providerId;
  final Future<ProviderUsage>? future;
  final Object? error;
  int calls = 0;

  @override
  String get displayName => providerId;

  @override
  Future<ProviderUsage> fetchUsage() {
    calls += 1;
    if (error != null) return Future.error(error!);
    return future ?? Future.value(_usage(providerId));
  }
}
