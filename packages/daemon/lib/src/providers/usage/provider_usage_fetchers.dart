import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'provider_usage.dart';

typedef ProviderUsageHttpCall =
    Future<http.Response> Function(
      String method,
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    });

List<ProviderUsageFetcher> createDefaultProviderUsageFetchers({
  ProviderUsageHttpCall? httpCall,
  Map<String, String>? environment,
  String? userHome,
}) => [
  ClaudeProviderUsageFetcher(
    httpCall: httpCall,
    environment: environment,
    userHome: userHome,
  ),
  CodexProviderUsageFetcher(
    httpCall: httpCall,
    environment: environment,
    userHome: userHome,
  ),
];

final class ClaudeProviderUsageFetcher implements ProviderUsageFetcher {
  ClaudeProviderUsageFetcher({
    ProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _platformHome();

  static const _oauthBeta = 'oauth-2025-04-20';
  static const _clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';

  final ProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'claude';

  @override
  String get displayName => 'Claude';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final home = _environment['CLAUDE_HOME'] ?? p.join(_userHome, '.claude');
    final path = p.join(home, '.credentials.json');
    final root = await _readJsonFile(path);
    final oauth = _object(root?['claudeAiOauth']);
    var accessToken = _string(oauth?['accessToken']);
    if (accessToken == null) return _unavailable(providerId, displayName);

    var response = await _getUsage(accessToken);
    if (_needsAuth(response)) {
      final refreshToken = _string(oauth?['refreshToken']);
      if (refreshToken == null) return _unavailable(providerId, displayName);
      final refreshed = await _refresh(refreshToken);
      accessToken = _string(refreshed?['access_token']);
      if (accessToken == null) return _unavailable(providerId, displayName);
      oauth!['accessToken'] = accessToken;
      oauth['refreshToken'] =
          _string(refreshed?['refresh_token']) ?? refreshToken;
      await _tryWriteJson(path, root!);
      response = await _getUsage(accessToken);
      if (_needsAuth(response)) return _unavailable(providerId, displayName);
    }
    _requireSuccess(response, 'Claude');
    final body = _decodeObject(response.body);
    final windows = <ProviderUsageWindow>[
      if (_usageWindow(
            _object(body['five_hour']),
            id: 'five_hour',
            label: 'Session',
          )
          case final window?)
        window,
      if (_usageWindow(
            _object(body['seven_day']),
            id: 'weekly',
            label: 'Weekly',
          )
          case final window?)
        window,
      if (_usageWindow(
            _object(body['seven_day_opus']),
            id: 'weekly_opus',
            label: 'Weekly · Opus',
          )
          case final window?)
        window,
      if (_usageWindow(
            _object(body['seven_day_omelette']),
            id: 'weekly_omelette',
            label: 'Weekly · Omelette',
          )
          case final window?)
        window,
    ];
    final extraUsage = _object(body['extra_usage'])?['is_enabled'];
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: _claudePlan(
        _string(oauth?['subscriptionType']),
        _string(oauth?['rateLimitTier']),
      ),
      windows: windows,
      details: extraUsage is bool
          ? [
              ProviderUsageDetail(
                id: 'extra_usage',
                label: 'Extra usage',
                value: extraUsage ? 'Enabled' : 'Disabled',
              ),
            ]
          : const [],
    );
  }

  Future<http.Response> _getUsage(String token) => _httpCall(
    'GET',
    Uri.parse('https://api.anthropic.com/api/oauth/usage'),
    headers: {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.acceptHeader: 'application/json',
      'anthropic-beta': _oauthBeta,
    },
  );

  Future<Map<String, Object?>?> _refresh(String refreshToken) async {
    final response = await _httpCall(
      'POST',
      Uri.parse('https://platform.claude.com/v1/oauth/token'),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': _clientId,
        'scope':
            'user:profile user:inference user:sessions:claude_code '
            'user:mcp_servers',
      }),
    );
    return _isSuccess(response) ? _decodeObject(response.body) : null;
  }
}

final class CodexProviderUsageFetcher implements ProviderUsageFetcher {
  CodexProviderUsageFetcher({
    ProviderUsageHttpCall? httpCall,
    Map<String, String>? environment,
    String? userHome,
  }) : _httpCall = httpCall ?? _defaultHttpCall,
       _environment = environment ?? Platform.environment,
       _userHome = userHome ?? _platformHome();

  static const _clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';

  final ProviderUsageHttpCall _httpCall;
  final Map<String, String> _environment;
  final String _userHome;

  @override
  String get providerId => 'codex';

  @override
  String get displayName => 'Codex';

  @override
  Future<ProviderUsage> fetchUsage() async {
    final configuredHome = _environment['CODEX_HOME'];
    final candidates = <String>[
      if (configuredHome != null) p.join(configuredHome, 'auth.json'),
      p.join(_userHome, '.config', 'codex', 'auth.json'),
      p.join(configuredHome ?? p.join(_userHome, '.codex'), 'auth.json'),
    ];
    Map<String, Object?>? root;
    String? path;
    for (final candidate in candidates) {
      final value = await _readJsonFile(candidate);
      if (_string(_object(value?['tokens'])?['access_token']) == null) continue;
      root = value;
      path = candidate;
      break;
    }
    final tokens = _object(root?['tokens']);
    var accessToken = _string(tokens?['access_token']);
    if (root == null || path == null || accessToken == null) {
      return _unavailable(providerId, displayName);
    }

    var response = await _getUsage(
      accessToken,
      accountId: _string(tokens?['account_id']),
    );
    if (_needsAuth(response)) {
      final refreshToken = _string(tokens?['refresh_token']);
      if (refreshToken == null) return _unavailable(providerId, displayName);
      final refreshed = await _refresh(refreshToken);
      accessToken = _string(refreshed?['access_token']);
      if (accessToken == null) return _unavailable(providerId, displayName);
      tokens!['access_token'] = accessToken;
      tokens['refresh_token'] =
          _string(refreshed?['refresh_token']) ?? refreshToken;
      await _tryWriteJson(path, root);
      response = await _getUsage(
        accessToken,
        accountId: _string(tokens['account_id']),
      );
      if (_needsAuth(response)) return _unavailable(providerId, displayName);
    }
    _requireSuccess(response, 'Codex');
    if (response.body.trimLeft().startsWith('<')) {
      return _unavailable(providerId, displayName);
    }
    final body = _decodeObject(response.body);
    final rateLimit = _object(body['rate_limit']);
    final reviewLimit = _object(body['code_review_rate_limit']);
    final windows = <ProviderUsageWindow>[
      if (_codexWindow(
            _object(rateLimit?['primary_window']),
            id: 'session',
            label: 'Session',
          )
          case final window?)
        window,
      if (_codexWindow(
            _object(rateLimit?['secondary_window']),
            id: 'weekly',
            label: 'Weekly',
          )
          case final window?)
        window,
      if (_codexWindow(
            _object(reviewLimit?['primary_window']),
            id: 'code_review',
            label: 'Code review',
          )
          case final window?)
        window,
    ];
    final balance = _finite(_object(body['credits'])?['balance']);
    return ProviderUsage(
      providerId: providerId,
      displayName: displayName,
      status: ProviderUsageStatus.available,
      planLabel: _string(body['plan_type']),
      windows: windows,
      balances: balance == null
          ? const []
          : [
              ProviderUsageBalance(
                id: 'credits',
                label: 'Credits',
                remaining: balance,
                unit: ProviderUsageBalanceUnit.usd,
                tone: providerBalanceToneFromRemaining(balance),
              ),
            ],
    );
  }

  Future<http.Response> _getUsage(String token, {required String? accountId}) =>
      _httpCall(
        'GET',
        Uri.parse('https://chatgpt.com/backend-api/wham/usage'),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $token',
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.userAgentHeader:
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
          if (accountId != null) 'ChatGPT-Account-Id': accountId,
        },
      );

  Future<Map<String, Object?>?> _refresh(String refreshToken) async {
    final response = await _httpCall(
      'POST',
      Uri.parse('https://auth.openai.com/oauth/token'),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      },
      body: Uri(
        queryParameters: {
          'grant_type': 'refresh_token',
          'client_id': _clientId,
          'refresh_token': refreshToken,
        },
      ).query,
    );
    return _isSuccess(response) ? _decodeObject(response.body) : null;
  }
}

ProviderUsageWindow? _usageWindow(
  Map<String, Object?>? value, {
  required String id,
  required String label,
}) {
  if (value == null) return null;
  final used = _finite(value['utilization']);
  if (used == null) return null;
  return ProviderUsageWindow(
    id: id,
    label: label,
    usedPct: used,
    remainingPct: mathMax(0, 100 - used),
    resetsAt: _string(value['resets_at']),
    tone: providerUsageToneFromUsedPct(used),
  );
}

ProviderUsageWindow? _codexWindow(
  Map<String, Object?>? value, {
  required String id,
  required String label,
}) {
  if (value == null) return null;
  final used = _finite(value['used_percent']) ?? 0;
  final resetAt = _finite(value['reset_at']);
  return ProviderUsageWindow(
    id: id,
    label: label,
    usedPct: used,
    remainingPct: mathMax(0, 100 - used),
    resetsAt: resetAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (resetAt * 1000).round(),
            isUtc: true,
          ).toIso8601String(),
    tone: providerUsageToneFromUsedPct(used),
  );
}

String? _claudePlan(String? subscription, String? tier) {
  if (subscription == null || subscription.isEmpty) return null;
  final label = '${subscription[0].toUpperCase()}${subscription.substring(1)}';
  final suffix = tier?.split('_').last;
  return suffix == null || suffix.isEmpty ? label : '$label $suffix';
}

ProviderUsage _unavailable(String id, String label) => ProviderUsage(
  providerId: id,
  displayName: label,
  status: ProviderUsageStatus.unavailable,
  planLabel: null,
  windows: const [],
);

Future<Map<String, Object?>?> _readJsonFile(String path) async {
  try {
    return _decodeObject(await File(path).readAsString());
  } catch (_) {
    return null;
  }
}

Future<void> _tryWriteJson(String path, Map<String, Object?> value) async {
  try {
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
  } catch (_) {}
}

Map<String, Object?> _decodeObject(String source) =>
    Map<String, Object?>.from(jsonDecode(source) as Map);

Map<String, Object?>? _object(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

double? _finite(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

double mathMax(double a, double b) => a > b ? a : b;

bool _isSuccess(http.Response response) =>
    response.statusCode >= 200 && response.statusCode < 300;

bool _needsAuth(http.Response response) =>
    response.statusCode == 401 || response.statusCode == 403;

void _requireSuccess(http.Response response, String provider) {
  if (!_isSuccess(response)) {
    throw HttpException('$provider usage API returned ${response.statusCode}');
  }
}

Future<http.Response> _defaultHttpCall(
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

String _platformHome() =>
    Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ??
    Directory.current.path;
