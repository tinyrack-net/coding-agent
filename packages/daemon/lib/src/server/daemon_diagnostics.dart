import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../workspace/workspace_registry.dart';

typedef DiagnosticToolRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef DiagnosticDiskStatsReader =
    Future<({int freeBytes, int totalBytes})> Function(String path);

final class DaemonDiagnosticsOptions {
  const DaemonDiagnosticsOptions({
    required this.home,
    required this.serverId,
    required this.daemonVersion,
    required this.listen,
    required this.relayEnabled,
    required this.relayEndpoint,
    required this.relayPublicEndpoint,
    required this.relayUseTls,
    required this.relayPublicUseTls,
    required this.startedAt,
    required this.listAgents,
    required this.listProjects,
    required this.listWorkspaces,
    required this.listProviders,
    required this.webSocketRuntime,
    this.environment,
    this.now,
    this.runTool,
    this.readDiskStats,
    this.log,
  });

  final String home;
  final String? serverId;
  final String? daemonVersion;
  final String? listen;
  final bool relayEnabled;
  final String? relayEndpoint;
  final String? relayPublicEndpoint;
  final bool relayUseTls;
  final bool relayPublicUseTls;
  final DateTime startedAt;
  final List<AgentSummary> Function() listAgents;
  final Future<List<PersistedProjectRecord>> Function() listProjects;
  final Future<List<PersistedWorkspaceRecord>> Function() listWorkspaces;
  final Future<List<ProviderAvailabilityV2>> Function() listProviders;
  final Map<String, Object?> Function() webSocketRuntime;
  final Map<String, String>? environment;
  final DateTime Function()? now;
  final DiagnosticToolRunner? runTool;
  final DiagnosticDiskStatsReader? readDiskStats;
  final void Function(String message)? log;
}

Future<String> collectDaemonDiagnostics(
  DaemonDiagnosticsOptions options,
) async {
  final now = (options.now ?? DateTime.now)().toUtc();
  final sections = <String>[
    _section('Tinyrack diagnostics', [
      ('Collected at', now.toIso8601String()),
      ('Server ID', options.serverId ?? 'unknown'),
      ('Daemon version', options.daemonVersion ?? 'unknown'),
    ]),
    await _safeSection(
      'Daemon process',
      () => _processEntries(options, now),
      options,
    ),
    await _safeSection(
      'Runtime config',
      () => _runtimeConfigEntries(options),
      options,
    ),
    await _safeSection('System', _systemEntries, options),
    await _safeSection('Disk', () => _diskEntries(options), options),
    await _safeSection('Agents', () => _agentEntries(options), options),
    await _safeSection('Workspaces', () => _workspaceEntries(options), options),
    await _safeSection('Providers', () => _providerEntries(options), options),
    await _safeSection(
      'WebSocket runtime metrics',
      () => _webSocketEntries(options),
      options,
    ),
    await _safeSection('Tools', () => _toolEntries(options), options),
    await _logTailSection(options),
  ];
  return redactDiagnostic(
    sections.where((section) => section.isNotEmpty).join('\n\n'),
    listen: options.listen,
    relayEndpoint: options.relayEndpoint,
    relayPublicEndpoint: options.relayPublicEndpoint,
  );
}

Future<String> _safeSection(
  String title,
  FutureOr<List<(String, String)>> Function() collect,
  DaemonDiagnosticsOptions options,
) async {
  try {
    return _section(title, await collect());
  } catch (error) {
    options.log?.call('diagnostic section failed ($title): $error');
    return _section(title, [('Error', '$error')]);
  }
}

String _section(String title, List<(String, String)> entries) => [
  title,
  for (final entry in entries) '  ${entry.$1}: ${entry.$2}',
].join('\n');

List<(String, String)> _processEntries(
  DaemonDiagnosticsOptions options,
  DateTime now,
) {
  final environment = options.environment ?? Platform.environment;
  final path = _environmentValue(environment, 'PATH', 'Path') ?? 'unset';
  final shell =
      _environmentValue(environment, 'SHELL') ??
      _environmentValue(environment, 'ComSpec', 'COMSPEC') ??
      'unset';
  return [
    ('PID', '$pid'),
    ('Dart', Platform.version.split(' ').first),
    ('Dart path', Platform.resolvedExecutable),
    ('PATH', path),
    ('Shell', shell),
    ('Uptime', _duration(now.difference(options.startedAt))),
    ('Tinyrack home', options.home),
    ('RSS', _bytes(ProcessInfo.currentRss)),
    ('Max RSS', _bytes(ProcessInfo.maxRss)),
  ];
}

List<(String, String)> _runtimeConfigEntries(
  DaemonDiagnosticsOptions options,
) => [
  ('Listen', _listenKind(options.listen)),
  ('Relay enabled', '${options.relayEnabled}'),
  ('Relay endpoint configured', '${options.relayEndpoint?.isNotEmpty == true}'),
  (
    'Relay public endpoint configured',
    '${options.relayPublicEndpoint?.isNotEmpty == true}',
  ),
  ('Relay TLS', options.relayEnabled ? '${options.relayUseTls}' : 'n/a'),
  (
    'Relay public TLS',
    options.relayEnabled ? '${options.relayPublicUseTls}' : 'n/a',
  ),
];

List<(String, String)> _systemEntries() => [
  ('OS', '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'),
  ('CPU cores', '${Platform.numberOfProcessors}'),
  ('Locale', Platform.localeName),
];

Future<List<(String, String)>> _diskEntries(
  DaemonDiagnosticsOptions options,
) async {
  final stats = await (options.readDiskStats ?? _readDiskStats)(options.home);
  return [
    ('Path', options.home),
    ('Free', '${_bytes(stats.freeBytes)} / ${_bytes(stats.totalBytes)}'),
  ];
}

Future<({int freeBytes, int totalBytes})> _readDiskStats(String path) async {
  if (Platform.isWindows) {
    const variable = 'TINYRACK_DIAGNOSTIC_DISK_PATH';
    final result = await Process.run(
      'powershell',
      const [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$item=Get-Item -LiteralPath $env:TINYRACK_DIAGNOSTIC_DISK_PATH; '
            r'$drive=Get-PSDrive -Name $item.PSDrive.Name; '
            r'[Console]::Write("$($drive.Free)|$($drive.Used + $drive.Free)")',
      ],
      environment: {...Platform.environment, variable: path},
    ).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) {
      throw FileSystemException('${result.stderr}'.trim(), path);
    }
    return _parseDiskStats('${result.stdout}', path);
  }

  final result = await Process.run('df', [
    '-Pk',
    path,
  ]).timeout(const Duration(seconds: 3));
  if (result.exitCode != 0) {
    throw FileSystemException('${result.stderr}'.trim(), path);
  }
  final lines = '${result.stdout}'
      .trim()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length < 2) {
    throw const FormatException('df output is incomplete');
  }
  final columns = lines.last.trim().split(RegExp(r'\s+'));
  if (columns.length < 4) {
    throw const FormatException('df output is malformed');
  }
  final totalKiB = int.parse(columns[1]);
  final freeKiB = int.parse(columns[3]);
  return (freeBytes: freeKiB * 1024, totalBytes: totalKiB * 1024);
}

({int freeBytes, int totalBytes}) _parseDiskStats(String value, String path) {
  final parts = value.trim().split('|');
  if (parts.length != 2) {
    throw FileSystemException('disk stats output is malformed', path);
  }
  return (freeBytes: int.parse(parts[0]), totalBytes: int.parse(parts[1]));
}

List<(String, String)> _agentEntries(DaemonDiagnosticsOptions options) {
  final agents = options.listAgents();
  return [
    ('Total', '${agents.length}'),
    ('By provider', _counts(agents.map((agent) => agent.provider))),
    ('By state', _counts(agents.map((agent) => agent.runState.name))),
    (
      'Attention required',
      '${agents.where((agent) => agent.attentionReason != null).length}',
    ),
  ];
}

Future<List<(String, String)>> _workspaceEntries(
  DaemonDiagnosticsOptions options,
) async {
  final values = await Future.wait<Object>([
    options.listProjects(),
    options.listWorkspaces(),
  ]);
  final projects = values[0] as List<PersistedProjectRecord>;
  final workspaces = values[1] as List<PersistedWorkspaceRecord>;
  final activeProjects = projects.where((value) => value.archivedAt == null);
  final activeWorkspaces = workspaces.where(
    (value) => value.archivedAt == null,
  );
  return [
    ('Projects', '${activeProjects.length} active / ${projects.length} total'),
    (
      'Workspaces',
      '${activeWorkspaces.length} active / ${workspaces.length} total',
    ),
    (
      'Workspaces by kind',
      _counts(activeWorkspaces.map((value) => value.kind.wireName)),
    ),
  ];
}

Future<List<(String, String)>> _providerEntries(
  DaemonDiagnosticsOptions options,
) async {
  final providers = await options.listProviders();
  return [
    ('Total', '${providers.length}'),
    ('Available', '${providers.where((value) => value.available).length}'),
    (
      'Unavailable',
      providers
              .where((value) => !value.available)
              .map(
                (value) => value.error == null
                    ? value.provider
                    : '${value.provider} (${value.error})',
              )
              .join(', ')
              .nullIfEmpty ??
          'none',
    ),
  ];
}

List<(String, String)> _webSocketEntries(DaemonDiagnosticsOptions options) {
  final snapshot = options.webSocketRuntime();
  if (snapshot.isEmpty) {
    return [('Status', 'no runtime metrics window has been flushed yet')];
  }
  final sessions = _stringMap(snapshot['sessions']);
  final sockets = _stringMap(snapshot['sockets']);
  final memory = _stringMap(snapshot['memory']);
  final runtime = _stringMap(snapshot['runtime']);
  final agents = _stringMap(snapshot['agents']);
  final timelineStats = _stringMap(agents['timelineStats']);
  return [
    ('Collected at', '${snapshot['collectedAt'] ?? 'unknown'}'),
    ('Window', _durationMs(snapshot['windowMs'])),
    ('Process uptime', _durationMs(_number(snapshot['uptimeSeconds']) * 1000)),
    (
      'Process memory',
      [
        'rss=${_metricBytes(memory['rss'])}',
        'heap=${_metricBytes(memory['heapUsed'])} / ${_metricBytes(memory['heapTotal'])}',
        'external=${_metricBytes(memory['external'])}',
        'arrayBuffers=${_metricBytes(memory['arrayBuffers'])}',
      ].join(', '),
    ),
    ('Final', '${snapshot['final'] == true}'),
    (
      'Sessions',
      [
        'active=${_numberMetric(sessions['activeConnections'])}',
        'externalKeys=${_numberMetric(sessions['externalSessionKeys'])}',
        'reconnectGrace=${_numberMetric(sessions['reconnectGraceSessions'])}',
      ].join(', '),
    ),
    (
      'Sockets',
      [
        'active=${_numberMetric(sockets['activeSockets'])}',
        'pending=${_numberMetric(sockets['pendingConnections'])}',
      ].join(', '),
    ),
    (
      'Runtime requests',
      [
        'inflight=${_numberMetric(runtime['inflightRequests'])}',
        'peakInflight=${_numberMetric(runtime['peakInflightRequests'])}',
      ].join(', '),
    ),
    (
      'Terminal subscriptions',
      [
        'terminals=${_numberMetric(runtime['terminalSubscriptionCount'])}',
        'directories=${_numberMetric(runtime['terminalDirectorySubscriptionCount'])}',
      ].join(', '),
    ),
    (
      'Checkout diff',
      [
        'targets=${_numberMetric(runtime['checkoutDiffTargetCount'])}',
        'subscriptions=${_numberMetric(runtime['checkoutDiffSubscriptionCount'])}',
        'watchers=${_numberMetric(runtime['checkoutDiffWatcherCount'])}',
        'fallbackRefreshTargets=${_numberMetric(runtime['checkoutDiffFallbackRefreshTargetCount'])}',
      ].join(', '),
    ),
    (
      'Buffered amount',
      'p95=${_metricBytes(_stringMap(snapshot['bufferedAmount'])['p95'])}, '
          'max=${_metricBytes(_stringMap(snapshot['bufferedAmount'])['max'])}',
    ),
    ('Event loop delay', _eventLoopDelay(snapshot['eventLoopDelay'])),
    ('Latency', _latencyStats(snapshot['latency'])),
    ('Inbound messages', _topCounts(snapshot['inboundMessageTypesTop'])),
    (
      'Inbound session requests',
      _topCounts(snapshot['inboundSessionRequestTypesTop']),
    ),
    ('Outbound messages', _topCounts(snapshot['outboundMessageTypesTop'])),
    (
      'Outbound session messages',
      _topCounts(snapshot['outboundSessionMessageTypesTop']),
    ),
    ('Agent streams', _topCounts(snapshot['outboundAgentStreamTypesTop'])),
    (
      'Agent stream agents',
      _topCounts(snapshot['outboundAgentStreamAgentsTop']),
    ),
    ('Binary frames', _topCounts(snapshot['outboundBinaryFrameTypesTop'])),
    ('Counters', _numberRecord(snapshot['counters'], nonZeroOnly: true)),
    (
      'Agent metrics',
      [
        'total=${_numberMetric(agents['total'])}',
        'activeForegroundTurns=${_numberMetric(agents['withActiveForegroundTurn'])}',
      ].join(', '),
    ),
    ('Agent lifecycle', _numberRecord(agents['byLifecycle'])),
    (
      'Agent timelines',
      [
        'items=${_numberMetric(timelineStats['totalItems'])}',
        'maxPerAgent=${_numberMetric(timelineStats['maxItemsPerAgent'])}',
      ].join(', '),
    ),
  ];
}

Map<String, Object?> _stringMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

num _number(Object? value) => value is num ? value : double.nan;

String _numberMetric(Object? value) =>
    value is num && value.isFinite ? '$value' : 'unknown';

String _metricBytes(Object? value) =>
    value is num && value.isFinite ? _bytes(value.round()) : 'unknown';

String _durationMs(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return 'unknown';
  return _duration(Duration(milliseconds: value.round()));
}

String _milliseconds(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return 'unknown';
  return '${value.round()}ms';
}

String _eventLoopDelay(Object? value) {
  if (value == null) return 'unavailable';
  final stats = _stringMap(value);
  return [
    'p50=${_milliseconds(stats['p50Ms'])}',
    'p99=${_milliseconds(stats['p99Ms'])}',
    'max=${_milliseconds(stats['maxMs'])}',
  ].join(', ');
}

String _topCounts(Object? value) {
  if (value is! Iterable) return 'none';
  final counts = <String>[];
  for (final item in value) {
    if (item is List &&
        item.length >= 2 &&
        item[0] is String &&
        item[1] is num) {
      counts.add('${item[0]}=${item[1]}');
    }
  }
  return counts.isEmpty ? 'none' : counts.join(', ');
}

String _latencyStats(Object? value) {
  if (value is! Iterable) return 'none';
  final stats = <String>[];
  for (final item in value) {
    final entry = _stringMap(item);
    final type = entry['type'];
    if (type is! String) continue;
    stats.add(
      '$type count=${_numberMetric(entry['count'])} '
      'p50=${_milliseconds(entry['p50Ms'])} '
      'max=${_milliseconds(entry['maxMs'])} '
      'total=${_milliseconds(entry['totalMs'])}',
    );
  }
  return stats.isEmpty ? 'none' : stats.join('; ');
}

String _numberRecord(Object? value, {bool nonZeroOnly = false}) {
  final entries =
      _stringMap(value).entries
          .where(
            (entry) =>
                entry.value is num &&
                (entry.value as num).isFinite &&
                (!nonZeroOnly || entry.value != 0),
          )
          .toList()
        ..sort((left, right) => left.key.compareTo(right.key));
  if (entries.isEmpty) return 'none';
  return entries.map((entry) => '${entry.key}=${entry.value}').join(', ');
}

Future<List<(String, String)>> _toolEntries(
  DaemonDiagnosticsOptions options,
) async {
  final values = await Future.wait([
    _checkTool(options, 'git', const ['--version']),
    _checkTool(options, 'gh', const ['--version']),
  ]);
  return [('git', values[0]), ('gh', values[1])];
}

Future<String> _checkTool(
  DaemonDiagnosticsOptions options,
  String executable,
  List<String> arguments,
) async {
  try {
    final runner =
        options.runTool ??
        (executable, arguments) => Process.run(executable, arguments);
    final result = await runner(
      executable,
      arguments,
    ).timeout(const Duration(seconds: 3));
    final raw = '${result.stdout}'.trim().isNotEmpty
        ? '${result.stdout}'.trim()
        : '${result.stderr}'.trim();
    final output = _truncate(raw, 512);
    return output.isEmpty ? 'ok' : output;
  } catch (error) {
    return 'error: ${_truncate('$error', 512)}';
  }
}

Future<String> _logTailSection(DaemonDiagnosticsOptions options) async {
  final file = File(p.join(options.home, 'daemon.log'));
  try {
    final bytes = await file.readAsBytes();
    final start = bytes.length > 64 * 1024 ? bytes.length - 64 * 1024 : 0;
    final tail = String.fromCharCodes(
      bytes.sublist(start),
    ).split('\n').where((line) => line.isNotEmpty).toList();
    final selected = tail.length > 80 ? tail.sublist(tail.length - 80) : tail;
    return [
      'Daemon log tail',
      '  Path: ${file.path}',
      if (selected.isEmpty)
        '  No log lines found'
      else
        for (final line in selected) '  $line',
    ].join('\n');
  } catch (error) {
    options.log?.call('diagnostic log tail failed: $error');
    return [
      'Daemon log tail',
      '  Path: ${file.path}',
      '  Error: $error',
    ].join('\n');
  }
}

String redactDiagnostic(
  String value, {
  String? listen,
  String? relayEndpoint,
  String? relayPublicEndpoint,
}) {
  var redacted = value;
  for (final sensitive in [listen, relayEndpoint, relayPublicEndpoint]) {
    if (sensitive?.isNotEmpty == true) {
      redacted = redacted.replaceAll(sensitive!, '[redacted]');
    }
  }
  return redacted
      .replaceAll(
        RegExp(r'coding-agent://\S+', caseSensitive: false),
        'coding-agent://[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''([?&](?:password|token|secret|key|publicKey|daemonPublicKeyB64)=)[^&\s"']+''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''((?:password|token|secret|authorization|api[_-]?key|daemonPublicKeyB64|relayKey)\s*[:=]\s*)("[^"]+"|'[^']+'|[^\s,}]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      );
}

String _counts(Iterable<String> values) {
  final counts = <String, int>{};
  for (final value in values) {
    final key = value.isEmpty ? 'unknown' : value;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'none';
  final keys = counts.keys.toList()..sort();
  return keys.map((key) => '$key=${counts[key]}').join(', ');
}

String _listenKind(String? listen) {
  if (listen == null || listen.isEmpty) return 'not configured';
  if (listen.startsWith('unix://') || listen.startsWith('/')) {
    return 'local socket';
  }
  if (listen.startsWith('pipe://') || listen.startsWith(r'\\.\pipe\')) {
    return 'local pipe';
  }
  return 'direct TCP';
}

String _duration(Duration duration) {
  var seconds = duration.inSeconds;
  if (seconds < 0) seconds = 0;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m ${remaining}s';
  if (minutes > 0) return '${minutes}m ${remaining}s';
  return '${remaining}s';
}

String _bytes(int bytes) {
  if (bytes < 0) return 'unknown';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _truncate(String value, int maxLength) {
  final trimmed = value.trim();
  if (trimmed.length <= maxLength) return trimmed;
  return '${trimmed.substring(0, maxLength)}...(truncated)';
}

String? _environmentValue(
  Map<String, String> environment,
  String first, [
  String? second,
]) {
  final names = {first.toLowerCase(), if (second != null) second.toLowerCase()};
  for (final entry in environment.entries) {
    if (names.contains(entry.key.toLowerCase()) && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
