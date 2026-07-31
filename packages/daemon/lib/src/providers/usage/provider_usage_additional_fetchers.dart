import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'provider_usage.dart';

typedef AdditionalProviderUsageHttpCall =
    Future<http.Response> Function(
      String method,
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    });

/// Additional Paseo provider quota adapters which deliberately return an
/// unavailable card when the provider is not configured.  This keeps the
/// aggregate usage request deterministic and avoids probing public APIs with
/// credentials that the user has not supplied.
final class CopilotProviderUsageFetcher implements ProviderUsageFetcher {
  CopilotProviderUsageFetcher({
    AdditionalProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultAdditionalHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _additionalPlatformHome();

  final AdditionalProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'copilot';

  @override
  String get displayName => 'GitHub Copilot';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final token =
        _nonEmpty(_environment['COPILOT_TOKEN']) ??
        _nonEmpty(_environment['GITHUB_TOKEN']) ??
        _nonEmpty(_environment['GITHUB_PAT']) ??
        await _githubCliToken();
    if (token == null) return _additionalUnavailable(providerId, displayName);

    final response = await _httpCall(
      'GET',
      Uri.parse('https://api.github.com/copilot_internal/user'),
      headers: {
        HttpHeaders.authorizationHeader: 'token $token',
        HttpHeaders.acceptHeader: 'application/json',
        'Editor-Version': 'vscode/1.96.2',
        'Editor-Plugin-Version': 'copilot-chat/0.26.7',
        HttpHeaders.userAgentHeader: 'GitHubCopilotChat/0.26.7',
        'X-Github-Api-Version': '2025-04-01',
      },
    );
    if (!_additionalSuccess(response)) {
      return _additionalUnavailable(providerId, displayName);
    }
    final body = _additionalObject(_additionalDecode(response.body));
    final details = <ProviderUsageDetail>[];
    final reset = _additionalString(body?['quota_reset_date']);
    if (reset != null) {
      details.add(
        ProviderUsageDetail(id: 'reset', label: 'Quota reset', value: reset),
      );
    }
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: _additionalString(body?['copilot_plan']),
      windows: const [],
      details: details,
    );
  }

  Future<String?> _githubCliToken() async {
    final candidates = <String>[
      if (_environment['APPDATA'] case final appData?)
        p.join(appData, 'GitHub CLI', 'hosts.yml'),
      p.join(_userHome, '.config', 'gh', 'hosts.yml'),
    ];
    for (final path in candidates) {
      try {
        final raw = await File(path).readAsString();
        final match = RegExp(
          r'''oauth_token:\s*["']?([A-Za-z0-9_-]+)["']?''',
        ).firstMatch(raw);
        if (match != null) return match.group(1);
      } catch (_) {
        // Continue through the platform-specific credential locations.
      }
    }
    return null;
  }
}

final class GrokProviderUsageFetcher implements ProviderUsageFetcher {
  GrokProviderUsageFetcher({
    AdditionalProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultAdditionalHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _additionalPlatformHome();

  final AdditionalProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'grok';

  @override
  String get displayName => 'Grok';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final token =
        _additionalString(_environment['GROK_API_KEY']) ??
        _additionalString(_environment['GROK_TOKEN']) ??
        await _readGrokToken();
    if (token == null) return _additionalUnavailable(providerId, displayName);
    final response = await _httpCall(
      'GET',
      Uri.parse('https://cli-chat-proxy.grok.com/v1/billing'),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        'X-XAI-Token-Auth': 'xai-grok-cli',
        HttpHeaders.acceptHeader: 'application/json',
      },
    );
    if (!_additionalSuccess(response)) {
      return _additionalUnavailable(providerId, displayName);
    }
    final body = _additionalObject(_additionalDecode(response.body));
    final monthlyLimit = _additionalFinite(
      _additionalObject(
        _additionalObject(body?['config'])?['monthlyLimit'],
      )?['val'],
    );
    final creditUsage = _additionalFinite(
      _additionalObject(body?['usage'])?['creditUsage'],
    );
    final balances = <ProviderUsageBalance>[];
    if (monthlyLimit != null || creditUsage != null) {
      final remaining = monthlyLimit != null && creditUsage != null
          ? (monthlyLimit - creditUsage).clamp(0, double.infinity).toDouble()
          : null;
      balances.add(
        ProviderUsageBalance(
          id: 'monthly_credits',
          label: 'Monthly credits',
          used: creditUsage,
          remaining: remaining,
          limit: monthlyLimit,
          unit: ProviderUsageBalanceUnit.credits,
          tone: providerUsageToneFromUsedPct(
            providerUsageUsedPctOf(creditUsage, monthlyLimit),
          ),
        ),
      );
    }
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: null,
      windows: const [],
      balances: balances,
    );
  }

  Future<String?> _readGrokToken() async {
    try {
      final root = _additionalDecode(
        await File(p.join(_userHome, '.grok', 'auth.json')).readAsString(),
      );
      return _additionalString(_additionalObject(root)?['access_token']);
    } catch (_) {
      return null;
    }
  }
}

final class KimiProviderUsageFetcher implements ProviderUsageFetcher {
  KimiProviderUsageFetcher({
    AdditionalProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultAdditionalHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _additionalPlatformHome();

  final AdditionalProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'kimi';

  @override
  String get displayName => 'Kimi';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final token =
        _additionalString(_environment['KIMI_TOKEN']) ??
        _additionalString(_environment['KIMI_API_KEY']) ??
        await _readKimiToken();
    if (token == null) return _additionalUnavailable(providerId, displayName);
    final response = await _httpCall(
      'GET',
      Uri.parse('https://api.kimi.com/coding/v1/usages'),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.acceptHeader: 'application/json',
      },
    );
    if (!_additionalSuccess(response)) {
      return _additionalUnavailable(providerId, displayName);
    }
    final body = _additionalObject(_additionalDecode(response.body));
    final usage = _additionalObject(body?['usage']);
    final limit = _additionalNumber(usage?['limit']);
    final remaining = _additionalNumber(usage?['remaining']);
    final usedPct = limit != null && remaining != null && limit > 0
        ? ((limit - remaining) / limit * 100).clamp(0, 100).toDouble()
        : null;
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: null,
      windows: [
        ProviderUsageWindow(
          id: 'coding_usage',
          label: 'Coding usage',
          usedPct: usedPct,
          // Upstream clamps at zero, so an over-quota provider reports 0%
          // remaining rather than a negative number.
          remainingPct: usedPct == null ? null : math.max(0, 100 - usedPct),
          resetsAt: _additionalString(usage?['resetTime']),
          tone: providerUsageToneFromUsedPct(usedPct),
        ),
      ],
    );
  }

  Future<String?> _readKimiToken() async {
    final root =
        _environment['KIMI_CODE_HOME'] ?? p.join(_userHome, '.kimi-code');
    final candidates = [
      p.join(root, 'credentials', 'kimi-code.json'),
      p.join(_userHome, '.kimi', 'credentials', 'kimi-code.json'),
    ];
    for (final path in candidates) {
      try {
        final value = _additionalObject(
          _additionalDecode(await File(path).readAsString()),
        );
        final token = _additionalString(value?['access_token']);
        if (token != null) return token;
      } catch (_) {
        // Try the next known credential location.
      }
    }
    return null;
  }
}

final class ZaiProviderUsageFetcher implements ProviderUsageFetcher {
  ZaiProviderUsageFetcher({
    AdditionalProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
  }) : _httpCall = httpCall ?? _defaultAdditionalHttpCall,
       _environment = environment ?? Platform.environment;

  final AdditionalProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;

  @override
  String get providerId => 'zai';

  @override
  String get displayName => 'Z.ai';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final token =
        _additionalString(_environment['ZAI_API_KEY']) ??
        _additionalString(_environment['GLM_API_KEY']);
    if (token == null) return _additionalUnavailable(providerId, displayName);
    final response = await _httpCall(
      'GET',
      Uri.parse('https://api.z.ai/api/biz/subscription/list'),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.acceptHeader: 'application/json',
      },
    );
    if (!_additionalSuccess(response)) {
      return _additionalUnavailable(providerId, displayName);
    }
    final body = _additionalObject(_additionalDecode(response.body));
    final rows = body?['data'];
    final subscription = rows is List && rows.isNotEmpty
        ? _additionalObject(rows.first)
        : null;
    if (subscription == null) {
      return _additionalUnavailable(providerId, displayName);
    }
    final details = <ProviderUsageDetail>[];
    for (final entry in const [
      ('status', 'Status'),
      ('valid', 'Valid'),
      ('purchaseTime', 'Purchased'),
    ]) {
      final value = _additionalString(subscription[entry.$1]);
      if (value != null) {
        details.add(
          ProviderUsageDetail(id: entry.$1, label: entry.$2, value: value),
        );
      }
    }
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: _additionalString(subscription['productName']),
      windows: const [],
      details: details,
    );
  }
}

final class MiniMaxProviderUsageFetcher implements ProviderUsageFetcher {
  MiniMaxProviderUsageFetcher({
    AdditionalProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultAdditionalHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _additionalPlatformHome();

  final AdditionalProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'minimax';

  @override
  String get displayName => 'MiniMax';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final config = await _readConfig();
    final token =
        _additionalString(_environment['MINIMAX_API_KEY']) ??
        _additionalString(config?['api_key']) ??
        await _readOauthToken(config);
    if (token == null) return _additionalUnavailable(providerId, displayName);
    final region =
        _additionalString(_environment['MINIMAX_REGION']) ??
        _additionalString(config?['region']);
    final configuredBase =
        _additionalString(_environment['MINIMAX_BASE_URL']) ??
        _additionalString(config?['base_url']);
    final base = configuredBase?.startsWith('http') == true
        ? configuredBase!
        : region == 'cn'
        ? 'https://api.minimaxi.com'
        : 'https://api.minimax.io';
    final response = await _httpCall(
      'GET',
      Uri.parse('$base/v1/token_plan/remains'),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.acceptHeader: 'application/json',
      },
    );
    if (!_additionalSuccess(response)) {
      return _additionalUnavailable(providerId, displayName);
    }
    final body = _additionalObject(_additionalDecode(response.body));
    final rows = body?['model_remains'];
    final windows = <ProviderUsageWindow>[];
    if (rows is List) {
      for (final raw in rows) {
        final row = _additionalObject(raw);
        if (row == null) continue;
        final name = _additionalString(row['model_name']) ?? 'token-plan';
        final interval = _minimaxWindow(
          row,
          id: 'interval_$name',
          label: '$name · Interval',
          remainingPercent: row['current_interval_remaining_percent'],
          total: row['current_interval_total_count'],
          used: row['current_interval_usage_count'],
          reset: row['end_time'],
        );
        if (interval != null) windows.add(interval);
        final weekly = _minimaxWindow(
          row,
          id: 'weekly_$name',
          label: '$name · Weekly',
          remainingPercent: row['current_weekly_remaining_percent'],
          total: row['current_weekly_total_count'],
          used: row['current_weekly_usage_count'],
          reset: row['weekly_end_time'],
        );
        if (weekly != null) windows.add(weekly);
      }
    }
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: windows.isEmpty
          ? ProviderUsageStatus.unavailable
          : ProviderUsageStatus.available,
      planLabel: null,
      windows: windows,
    );
  }

  Future<Map<String, Object?>?> _readConfig() async {
    final path = p.join(_userHome, '.mmx', 'config.json');
    try {
      return _additionalObject(
        _additionalDecode(await File(path).readAsString()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readOauthToken(Map<String, Object?>? config) async {
    final configured = _additionalObject(config?['oauth']);
    final configuredToken = _additionalString(configured?['access_token']);
    if (configuredToken != null) return configuredToken;
    try {
      final root = _additionalObject(
        _additionalDecode(
          await File(
            p.join(_userHome, '.mmx', 'credentials.json'),
          ).readAsString(),
        ),
      );
      return _additionalString(root?['access_token']);
    } catch (_) {
      return null;
    }
  }
}

ProviderUsageWindow? _minimaxWindow(
  Map<String, Object?> row, {
  required String id,
  required String label,
  required Object? remainingPercent,
  required Object? total,
  required Object? used,
  required Object? reset,
}) {
  final remaining = _additionalFinite(remainingPercent);
  final totalValue = _additionalFinite(total);
  final usedValue = _additionalFinite(used);
  final usedPct = remaining != null
      ? (100 - remaining).clamp(0, 100).toDouble()
      : totalValue != null && totalValue > 0 && usedValue != null
      ? (usedValue / totalValue * 100).clamp(0, 100).toDouble()
      : null;
  if (usedPct == null) return null;
  final resetValue = _additionalFinite(reset);
  return ProviderUsageWindow(
    id: id,
    label: label,
    usedPct: usedPct,
    // Upstream clamps at zero; see the note above.
    remainingPct: math.max(0, 100 - usedPct),
    resetsAt: resetValue == null || resetValue <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            resetValue.round(),
            isUtc: true,
          ).toIso8601String(),
    tone: providerUsageToneFromUsedPct(usedPct),
  );
}

ProviderUsage _additionalUnavailable(String id, String label) => ProviderUsage(
  providerId: id,
  displayName: label,
  status: ProviderUsageStatus.unavailable,
  planLabel: null,
  windows: const [],
);

Map<String, Object?>? _additionalObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

Object? _additionalDecode(String source) {
  try {
    return jsonDecode(source);
  } catch (_) {
    return null;
  }
}

String? _additionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

String? _nonEmpty(Object? value) => _additionalString(value);

double? _additionalNumber(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

double? _additionalFinite(Object? value) => _additionalNumber(value);

bool _additionalSuccess(http.Response response) =>
    response.statusCode >= 200 && response.statusCode < 300;

Future<http.Response> _defaultAdditionalHttpCall(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
}) => switch (method) {
  'POST' =>
    http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 15)),
  _ => http.get(uri, headers: headers).timeout(const Duration(seconds: 15)),
};

String _additionalPlatformHome() =>
    Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ??
    Directory.current.path;
