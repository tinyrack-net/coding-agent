import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/usage/provider_usage_fetchers.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'Claude windows preserve frozen labels and escalate at 70 percent',
    () async {
      final home = await Directory.systemTemp.createTemp('claude-usage-');
      addTearDown(() => home.delete(recursive: true));
      final claudeHome = Directory(p.join(home.path, '.claude'))
        ..createSync(recursive: true);
      File(p.join(claudeHome.path, '.credentials.json')).writeAsStringSync(
        jsonEncode({
          'claudeAiOauth': {
            'accessToken': 'claude-token',
            'subscriptionType': 'max',
            'rateLimitTier': 'rate_limit_tier_20',
          },
        }),
      );

      final usage = await ClaudeProviderUsageFetcher(
        userHome: home.path,
        environment: const {},
        httpCall: (_, uri, {headers, body}) async {
          expect(uri.host, 'api.anthropic.com');
          expect(headers?['anthropic-beta'], 'oauth-2025-04-20');
          return http.Response(
            jsonEncode({
              'five_hour': {
                'utilization': 75,
                'resets_at': '2026-07-22T17:00:00Z',
              },
              'seven_day_opus': {'utilization': 90.1},
              'extra_usage': {'is_enabled': true},
            }),
            200,
          );
        },
      ).fetchUsage();

      expect(usage.planLabel, 'Max 20');
      expect(usage.windows.map((window) => window.label), [
        'Session',
        'Weekly · Opus',
      ]);
      expect(usage.windows.first.tone, ProviderUsageTone.warning);
      expect(usage.windows.last.tone, ProviderUsageTone.danger);
      expect(usage.details.single.value, 'Enabled');
    },
  );

  test('Codex windows and remaining credits use frozen states', () async {
    final home = await Directory.systemTemp.createTemp('codex-usage-');
    addTearDown(() => home.delete(recursive: true));
    final codexHome = Directory(p.join(home.path, '.codex'))
      ..createSync(recursive: true);
    File(p.join(codexHome.path, 'auth.json')).writeAsStringSync(
      jsonEncode({
        'tokens': {'access_token': 'codex-token', 'account_id': 'account-1'},
      }),
    );

    final usage = await CodexProviderUsageFetcher(
      userHome: home.path,
      environment: const {},
      httpCall: (_, uri, {headers, body}) async {
        expect(uri.host, 'chatgpt.com');
        expect(headers?['ChatGPT-Account-Id'], 'account-1');
        return http.Response(
          jsonEncode({
            'plan_type': 'plus',
            'rate_limit': {
              'primary_window': {'used_percent': 12},
              'secondary_window': {'used_percent': 96},
            },
            'code_review_rate_limit': {
              'primary_window': {'used_percent': 70},
            },
            'credits': {'balance': 0},
          }),
          200,
        );
      },
    ).fetchUsage();

    expect(usage.windows.map((window) => window.label), [
      'Session',
      'Weekly',
      'Code review',
    ]);
    expect(usage.windows.map((window) => window.tone), [
      ProviderUsageTone.ok,
      ProviderUsageTone.danger,
      ProviderUsageTone.warning,
    ]);
    expect(usage.balances.single.label, 'Credits');
    expect(usage.balances.single.tone, ProviderUsageTone.danger);
  });

  test('missing credentials produce unavailable provider cards', () async {
    final home = await Directory.systemTemp.createTemp('usage-empty-');
    addTearDown(() => home.delete(recursive: true));
    final fetchers = createDefaultProviderUsageFetchers(
      userHome: home.path,
      environment: const {},
      httpCall: (_, __, {headers, body}) async =>
          throw StateError('must not fetch'),
    );

    final usage = await Future.wait(
      fetchers.map((fetcher) => fetcher.fetchUsage()),
    );
    expect(
      usage.map((entry) => entry.status),
      everyElement(ProviderUsageStatus.unavailable),
    );
  });
}
