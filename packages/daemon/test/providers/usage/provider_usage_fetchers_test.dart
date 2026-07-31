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

  test('additional provider quota adapters preserve frozen payloads', () async {
    final home = await Directory.systemTemp.createTemp('additional-usage-');
    addTearDown(() => home.delete(recursive: true));
    final calls = <String>[];
    Future<http.Response> call(
      String _,
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    }) async {
      calls.add(uri.host);
      return switch (uri.host) {
        'api.github.com' => http.Response(
          jsonEncode({
            'copilot_plan': 'individual',
            'quota_reset_date': '2026-08-01',
          }),
          200,
        ),
        'cli-chat-proxy.grok.com' => http.Response(
          jsonEncode({
            'config': {
              'monthlyLimit': {'val': 100},
            },
            'usage': {'creditUsage': 25},
          }),
          200,
        ),
        'api.kimi.com' => http.Response(
          jsonEncode({
            'usage': {
              'limit': '100',
              'remaining': '25',
              'resetTime': '2026-08-02T00:00:00Z',
            },
          }),
          200,
        ),
        'api.z.ai' => http.Response(
          jsonEncode({
            'data': [
              {
                'productName': 'Pro',
                'status': 'active',
                'valid': 'true',
                'purchaseTime': '2026-07-01',
              },
            ],
          }),
          200,
        ),
        'api.minimax.io' => http.Response(
          jsonEncode({
            'model_remains': [
              {
                'model_name': 'MiniMax-M1',
                'current_interval_remaining_percent': 20,
                'end_time': 1785542400000,
                'current_weekly_remaining_percent': 50,
                'weekly_end_time': 1786147200000,
              },
            ],
          }),
          200,
        ),
        _ => http.Response('{}', 404),
      };
    }

    final env = const {
      'COPILOT_TOKEN': 'copilot-token',
      'GROK_API_KEY': 'grok-token',
      'KIMI_TOKEN': 'kimi-token',
      'ZAI_API_KEY': 'zai-token',
      'MINIMAX_API_KEY': 'minimax-token',
    };
    final fetchers = createDefaultProviderUsageFetchers(
      userHome: home.path,
      environment: env,
      httpCall: call,
    );
    final byId = {
      for (final usage in await Future.wait(
        fetchers.map((fetcher) => fetcher.fetchUsage()),
      ))
        usage.providerId: usage,
    };

    expect(byId['copilot']?.planLabel, 'individual');
    expect(byId['copilot']?.details.single.value, '2026-08-01');
    expect(byId['grok']?.balances.single.remaining, 75);
    expect(byId['kimi']?.windows.single.usedPct, 75);
    expect(byId['zai']?.details.map((detail) => detail.id), [
      'status',
      'valid',
      'purchaseTime',
    ]);
    expect(byId['minimax']?.windows.map((window) => window.label), [
      'MiniMax-M1 · Interval',
      'MiniMax-M1 · Weekly',
    ]);
    expect(
      calls,
      containsAll(<String>[
        'api.github.com',
        'cli-chat-proxy.grok.com',
        'api.kimi.com',
        'api.z.ai',
        'api.minimax.io',
      ]),
    );
  });
}
