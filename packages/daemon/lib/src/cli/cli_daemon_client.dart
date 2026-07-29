import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_config.dart';
import 'cli_errors.dart';

const String defaultCliDaemonHost = 'localhost:6767';
const Duration defaultCliDaemonConnectTimeout = Duration(seconds: 15);

sealed class CliDaemonTarget {
  const CliDaemonTarget({required this.url});

  final String url;
}

final class CliTcpDaemonTarget extends CliDaemonTarget {
  const CliTcpDaemonTarget({required super.url});
}

final class CliIpcDaemonTarget extends CliDaemonTarget {
  const CliIpcDaemonTarget({required super.url, required this.socketPath});

  final String socketPath;
}

final class DaemonConnectionCommandError {
  const DaemonConnectionCommandError({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final String details;
}

final class CliAgentIdentity {
  const CliAgentIdentity({required this.id, this.title});

  final String id;
  final String? title;
}

typedef CliDirectDaemonConnector<T> =
    Future<T> Function({
      required String host,
      required CliDaemonTarget target,
      required String? password,
      required Duration timeout,
    });

String getDaemonHost({
  String? host,
  Map<String, String>? environment,
  String? home,
}) => resolveDaemonHostCandidates(
  host: host,
  environment: environment,
  home: home,
).first;

DaemonConnectionCommandError buildDaemonConnectionCommandError({
  String? host,
  required Object error,
  Map<String, String>? environment,
  String? home,
}) {
  final resolvedHost = getDaemonHost(
    host: host,
    environment: environment,
    home: home,
  );
  return DaemonConnectionCommandError(
    code: 'DAEMON_NOT_RUNNING',
    message:
        'Cannot connect to daemon at $resolvedHost: ${getErrorMessage(error)}',
    details: 'Start the daemon with: coding-agent daemon start',
  );
}

String? normalizeDaemonHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.startsWith('tcp://')) {
    try {
      final parsed = parseConnectionUri(trimmed);
      final endpoint = parsed.isIpv6
          ? '[${parsed.host}]:${parsed.port}'
          : '${parsed.host}:${parsed.port}';
      final query = <String, String>{
        if (parsed.useTls) 'ssl': 'true',
        if (parsed.password case final password?) 'password': password,
      };
      return Uri(
        scheme: 'tcp',
        host: parseHostPort(endpoint).host,
        port: parsed.port,
        queryParameters: query.isEmpty ? null : query,
      ).toString();
    } on FormatException {
      return null;
    }
  }

  if (trimmed.startsWith('unix://') ||
      trimmed.startsWith('pipe://') ||
      trimmed.startsWith(r'\\.\pipe\')) {
    return trimmed.startsWith(r'\\.\pipe\') ? 'pipe://$trimmed' : trimmed;
  }
  if (trimmed.startsWith('/') || trimmed.startsWith('~')) {
    return 'unix://$trimmed';
  }
  if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed)) return null;
  if (RegExp(r'^\d+$').hasMatch(trimmed)) return '127.0.0.1:$trimmed';
  return trimmed.contains(':') ? trimmed : null;
}

String resolveDefaultDaemonHost({
  Map<String, String>? environment,
  String? home,
}) => resolveDefaultDaemonHosts(environment: environment, home: home).first;

List<String> resolveDefaultDaemonHosts({
  Map<String, String>? environment,
  String? home,
}) {
  final env = environment ?? Platform.environment;
  final resolvedHome = p.normalize(
    p.absolute(home ?? resolveTinyrackHome(env)),
  );
  final config = loadDaemonRuntimeConfig(home: resolvedHome, environment: env);
  final candidates = <String>[];

  final direct = normalizeDaemonHost(env['TINYRACK_LISTEN'] ?? '');
  if (_isIpcDaemonHost(direct)) candidates.add(direct!);

  final pid = _readPidSocketTarget(resolvedHome);
  final pidHost = normalizeDaemonHost(pid ?? '');
  if (_isIpcDaemonHost(pidHost)) candidates.add(pidHost!);

  final configured = normalizeDaemonHost(config.listen);
  if (_isIpcDaemonHost(configured)) {
    candidates.add(configured!);
  } else if (_isTcpDaemonHost(configured) && configured != '127.0.0.1:6767') {
    candidates.add(configured!);
  }
  candidates.add(defaultCliDaemonHost);
  return candidates.toSet().toList(growable: false);
}

List<String> resolveDaemonHostCandidates({
  String? host,
  Map<String, String>? environment,
  String? home,
}) {
  final env = environment ?? Platform.environment;
  final explicit = host ?? env['TINYRACK_HOST'];
  if (explicit != null && explicit.isNotEmpty) return [explicit];
  return resolveDefaultDaemonHosts(environment: env, home: home);
}

Future<T> connectToDirectDaemon<T>({
  String? host,
  Map<String, String>? environment,
  String? home,
  Duration timeout = defaultCliDaemonConnectTimeout,
  required CliDirectDaemonConnector<T> connect,
}) async {
  final env = environment ?? Platform.environment;
  final hosts = resolveDaemonHostCandidates(
    host: host,
    environment: env,
    home: home,
  );
  Object? lastError;
  StackTrace? lastStackTrace;
  for (final candidate in hosts) {
    try {
      return await connect(
        host: candidate,
        target: resolveDaemonTarget(candidate),
        password: resolveDaemonPassword(candidate, environment: env),
        timeout: timeout,
      );
    } on Object catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
    }
  }
  if (lastError != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace!);
  }
  throw StateError(
    'Unable to connect to coding-agent daemon via ${hosts.join(', ')}',
  );
}

Future<T?> tryConnectToDirectDaemon<T>({
  String? host,
  Map<String, String>? environment,
  String? home,
  Duration timeout = defaultCliDaemonConnectTimeout,
  required CliDirectDaemonConnector<T> connect,
}) async {
  try {
    return await connectToDirectDaemon(
      host: host,
      environment: environment,
      home: home,
      timeout: timeout,
      connect: connect,
    );
  } on Object {
    return null;
  }
}

CliDaemonTarget resolveDaemonTarget(String host) {
  final trimmed = host.trim();
  if (trimmed.startsWith('unix://') ||
      trimmed.startsWith('pipe://') ||
      trimmed.startsWith(r'\\.\pipe\')) {
    final socketPath = _stripIpcPrefix(trimmed);
    if (socketPath.isEmpty) {
      throw StateError('Invalid IPC daemon target: missing socket path');
    }
    return CliIpcDaemonTarget(
      url: trimmed.startsWith('unix://')
          ? 'ws+unix://$socketPath:/ws'
          : 'ws://localhost/ws',
      socketPath: socketPath,
    );
  }
  if (trimmed.startsWith('tcp://')) {
    final parsed = parseConnectionUri(trimmed);
    final endpoint = parsed.isIpv6
        ? '[${parsed.host}]:${parsed.port}'
        : '${parsed.host}:${parsed.port}';
    return CliTcpDaemonTarget(
      url: buildDaemonWebSocketUrl(endpoint, useTls: parsed.useTls),
    );
  }
  return CliTcpDaemonTarget(url: 'ws://$trimmed/ws');
}

String? resolveDaemonPassword(String host, {Map<String, String>? environment}) {
  final trimmed = host.trim();
  if (trimmed.startsWith('tcp://')) {
    final fromUri = parseConnectionUri(trimmed).password;
    if (fromUri != null && fromUri.isNotEmpty) return fromUri;
  }
  final fromEnvironment =
      (environment ?? Platform.environment)['TINYRACK_PASSWORD'];
  return fromEnvironment == null || fromEnvironment.isEmpty
      ? null
      : fromEnvironment;
}

String? resolveAgentId(String idOrName, List<CliAgentIdentity> agents) {
  if (idOrName.isEmpty || agents.isEmpty) return null;
  final query = idOrName.toLowerCase();
  for (final agent in agents) {
    if (agent.id == idOrName) return agent.id;
  }
  final prefixMatches = agents
      .where((agent) => agent.id.toLowerCase().startsWith(query))
      .toList(growable: false);
  if (prefixMatches.length == 1) return prefixMatches.single.id;
  final titleMatches = agents
      .where((agent) => agent.title?.toLowerCase() == query)
      .toList(growable: false);
  if (titleMatches.length == 1) return titleMatches.single.id;
  final partialTitleMatches = agents
      .where((agent) => agent.title?.toLowerCase().contains(query) == true)
      .toList(growable: false);
  if (partialTitleMatches.length == 1) return partialTitleMatches.single.id;
  return prefixMatches.firstOrNull?.id;
}

bool _isIpcDaemonHost(String? host) =>
    host != null && (host.startsWith('unix://') || host.startsWith('pipe://'));

bool _isTcpDaemonHost(String? host) => host != null && !_isIpcDaemonHost(host);

String _stripIpcPrefix(String value) {
  if (value.startsWith('unix://')) {
    return value.substring('unix://'.length).trim();
  }
  if (value.startsWith('pipe://')) {
    return value.substring('pipe://'.length).trim();
  }
  return value;
}

String? _readPidSocketTarget(String home) {
  final file = File(p.join(home, 'daemon.pid'));
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final listen = decoded['listen'];
    if (listen is String) return listen;
    final socketPath = decoded['sockPath'];
    return socketPath is String ? socketPath : null;
  } on Object {
    return null;
  }
}
