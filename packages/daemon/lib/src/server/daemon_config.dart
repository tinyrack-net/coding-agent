import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'daemon_auth.dart';
import 'hostnames.dart';
import 'trusted_proxies.dart';

const defaultTinyrackListen = '127.0.0.1:6868';
const defaultTinyrackRelayEndpoint = 'relay.tinyrack.dev:443';
const defaultTinyrackAppBaseUrl = 'https://app.tinyrack.dev';

class DaemonAuthConfig {
  const DaemonAuthConfig({required this.passwordHash});
  final String passwordHash;
}

class DaemonRelayConfig {
  const DaemonRelayConfig({
    required this.enabled,
    required this.endpoint,
    required this.publicEndpoint,
    required this.useTls,
    required this.publicUseTls,
  });

  final bool enabled;
  final String endpoint;
  final String publicEndpoint;
  final bool useTls;
  final bool publicUseTls;
}

class DaemonServiceProxyConfig {
  const DaemonServiceProxyConfig({
    required this.publicBaseUrl,
    required this.standaloneListen,
  });

  final String? publicBaseUrl;
  final String? standaloneListen;
}

class DaemonRuntimeConfig {
  const DaemonRuntimeConfig({
    required this.home,
    required this.listen,
    required this.corsAllowedOrigins,
    this.hostnames,
    required this.trustedProxies,
    required this.relay,
    this.serviceProxy = const DaemonServiceProxyConfig(
      publicBaseUrl: null,
      standaloneListen: null,
    ),
    required this.appBaseUrl,
    required this.webUiEnabled,
    this.webUiDistDir = '',
    required this.logLevel,
    required this.logFormat,
    required this.enableTerminalAgentHooks,
    this.auth,
  });

  final String home;
  final String listen;
  final List<String> corsAllowedOrigins;
  final HostnamesConfig hostnames;
  final TrustedProxiesConfig trustedProxies;
  final DaemonRelayConfig relay;
  final DaemonServiceProxyConfig serviceProxy;
  final String appBaseUrl;
  final bool webUiEnabled;
  final String webUiDistDir;
  final String logLevel;
  final String logFormat;
  final bool enableTerminalAgentHooks;
  final DaemonAuthConfig? auth;

  String get host {
    final value = listen.trim();
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end <= 1) throw FormatException('Invalid TINYRACK_LISTEN: $listen');
      return value.substring(1, end);
    }
    final separator = value.lastIndexOf(':');
    if (separator <= 0)
      throw FormatException('Invalid TINYRACK_LISTEN: $listen');
    return value.substring(0, separator);
  }

  int get port {
    final separator = listen.lastIndexOf(':');
    final parsed = separator < 0
        ? null
        : int.tryParse(listen.substring(separator + 1));
    if (parsed == null || parsed < 0 || parsed > 65535) {
      throw FormatException('Invalid TINYRACK_LISTEN: $listen');
    }
    return parsed;
  }
}

DaemonRuntimeConfig loadDaemonRuntimeConfig({
  String? home,
  Map<String, String>? environment,
  String? cliListen,
  bool? cliRelayEnabled,
  bool? cliRelayUseTls,
  bool? cliWebUiEnabled,
  String? cliWebUiDistDir,
  String? cliHostnames,
}) {
  final env = environment ?? Platform.environment;
  final resolvedHome = p.normalize(
    p.absolute(home ?? resolveTinyrackHome(env)),
  );
  final persisted = _loadPersistedConfig(resolvedHome);
  final daemon = _map(persisted['daemon'], 'daemon');
  final relay = _map(daemon['relay'], 'daemon.relay');
  final persistedServiceProxy = _map(
    daemon['serviceProxy'],
    'daemon.serviceProxy',
  );
  final cors = _map(daemon['cors'], 'daemon.cors');
  final auth = _map(daemon['auth'], 'daemon.auth');
  final features = _map(persisted['features'], 'features');
  final webUi = _map(features['webUi'], 'features.webUi');
  final app = _map(persisted['app'], 'app');
  final log = _map(persisted['log'], 'log');
  final hub = _parseHubUrl(env['TINYRACK_HUB_URL']);
  final optionalServiceProxyLayers =
      _booleanEnv(env['TINYRACK_SERVICE_PROXY_ENABLED']) ??
      _bool(persistedServiceProxy['enabled']) ??
      true;

  final envPassword = env['TINYRACK_PASSWORD']?.trim();
  final persistedHash = auth['password'];
  if (persistedHash != null &&
      (persistedHash is! String || !isDaemonPasswordHash(persistedHash))) {
    throw const FormatException('daemon.auth.password must be a bcrypt hash');
  }
  final authConfig = envPassword != null && envPassword.isNotEmpty
      ? DaemonAuthConfig(passwordHash: hashDaemonPassword(envPassword))
      : persistedHash is String
      ? DaemonAuthConfig(passwordHash: persistedHash)
      : null;

  final endpoint =
      env['TINYRACK_RELAY_ENDPOINT'] ??
      hub?.endpoint ??
      _string(relay['endpoint']) ??
      defaultTinyrackRelayEndpoint;
  final useTls =
      cliRelayUseTls ??
      _booleanEnv(env['TINYRACK_RELAY_USE_TLS']) ??
      hub?.useTls ??
      _bool(relay['useTls']) ??
      endpoint == defaultTinyrackRelayEndpoint;
  final publicEndpoint =
      env['TINYRACK_RELAY_PUBLIC_ENDPOINT'] ??
      hub?.endpoint ??
      _string(relay['publicEndpoint']) ??
      endpoint;
  final publicUseTls =
      _booleanEnv(env['TINYRACK_RELAY_PUBLIC_USE_TLS']) ??
      hub?.useTls ??
      _bool(relay['publicUseTls']) ??
      useTls;

  final origins = <String>{
    ..._stringList(cors['allowedOrigins'], 'daemon.cors.allowedOrigins'),
    ...?env['TINYRACK_CORS_ORIGINS']
        ?.split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty),
  };
  final persistedHostnames = parsePersistedHostnames(
    daemon['hostnames'] ?? daemon['allowedHosts'],
    daemon['hostnames'] != null ? 'daemon.hostnames' : 'daemon.allowedHosts',
  );
  final hostnames = mergeHostnames([
    persistedHostnames,
    parseHostnamesEnv(
      env['TINYRACK_HOSTNAMES'] ?? env['TINYRACK_ALLOWED_HOSTS'],
    ),
    parseHostnamesEnv(cliHostnames),
  ]);
  final config = DaemonRuntimeConfig(
    home: resolvedHome,
    listen:
        cliListen ??
        env['TINYRACK_LISTEN'] ??
        _string(daemon['listen']) ??
        defaultTinyrackListen,
    corsAllowedOrigins: List.unmodifiable(origins),
    hostnames: hostnames,
    trustedProxies: env.containsKey('TINYRACK_TRUSTED_PROXIES')
        ? parseTrustedProxiesEnv(env['TINYRACK_TRUSTED_PROXIES'])
        : parsePersistedTrustedProxies(daemon['trustedProxies']),
    relay: DaemonRelayConfig(
      enabled:
          cliRelayEnabled ??
          _booleanEnv(env['TINYRACK_RELAY_ENABLED']) ??
          _bool(relay['enabled']) ??
          true,
      endpoint: endpoint,
      publicEndpoint: publicEndpoint,
      useTls: useTls,
      publicUseTls: publicUseTls,
    ),
    serviceProxy: DaemonServiceProxyConfig(
      publicBaseUrl: optionalServiceProxyLayers
          ? _serviceProxyPublicBaseUrl(
              env['TINYRACK_SERVICE_PROXY_PUBLIC_BASE_URL'] ??
                  _string(persistedServiceProxy['publicBaseUrl']),
            )
          : null,
      standaloneListen: optionalServiceProxyLayers
          ? _nonEmptyTrimmed(
              env['TINYRACK_SERVICE_PROXY_LISTEN'] ??
                  _string(persistedServiceProxy['listen']),
            )
          : null,
    ),
    appBaseUrl:
        env['TINYRACK_APP_BASE_URL'] ??
        _string(app['baseUrl']) ??
        defaultTinyrackAppBaseUrl,
    webUiEnabled:
        cliWebUiEnabled ??
        _booleanEnv(env['TINYRACK_WEB_UI_ENABLED']) ??
        _bool(webUi['enabled']) ??
        false,
    webUiDistDir: _resolveWebUiDistDir(
      resolvedHome,
      cliWebUiDistDir ??
          env['TINYRACK_WEB_UI_DIST_DIR'] ??
          _string(webUi['distDir']),
    ),
    logLevel:
        env['TINYRACK_LOG_LEVEL']?.trim().toLowerCase() ??
        _string(log['level']) ??
        'info',
    logFormat:
        env['TINYRACK_LOG_FORMAT']?.trim().toLowerCase() ??
        _string(log['format']) ??
        'pretty',
    enableTerminalAgentHooks:
        _booleanEnv(env['TINYRACK_ENABLE_TERMINAL_AGENT_HOOKS']) ??
        _bool(daemon['enableTerminalAgentHooks']) ??
        false,
    auth: authConfig,
  );
  config.host;
  config.port;
  return config;
}

Map<String, Object?> _loadPersistedConfig(String home) {
  final file = File(p.join(home, 'config.json'));
  try {
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      final defaults = <String, Object?>{
        'version': 1,
        'daemon': {
          'listen': defaultTinyrackListen,
          'cors': {
            'allowedOrigins': [defaultTinyrackAppBaseUrl],
          },
          'relay': {'enabled': true},
        },
        'app': {'baseUrl': defaultTinyrackAppBaseUrl},
      };
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(defaults),
        flush: true,
      );
      // coverage:ignore-start
      // POSIX permission enforcement is exercised by Linux/macOS CI.
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['600', file.path]);
      }
      // coverage:ignore-end
      return defaults;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('config.json must contain a JSON object');
    }
    final version = decoded['version'];
    if (version != null && version != 1) {
      throw FormatException('Unsupported config version: $version');
    }
    return decoded;
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Unable to read config.json: $error');
  }
}

Map<String, Object?> _map(Object? value, String path) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  throw FormatException('$path must be an object');
}

String? _string(Object? value) => value is String ? value : null;
bool? _bool(Object? value) => value is bool ? value : null;

List<String> _stringList(Object? value, String path) {
  if (value == null) return const [];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$path must be a string array');
  }
  return value.cast<String>();
}

bool? _booleanEnv(String? value) {
  switch (value?.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return null;
  }
}

String _resolveWebUiDistDir(String home, String? configured) {
  final trimmed = configured?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return p.join(File(Platform.resolvedExecutable).parent.path, 'web-ui');
  }
  return p.normalize(
    p.absolute(p.isAbsolute(trimmed) ? trimmed : p.join(home, trimmed)),
  );
}

String? _serviceProxyPublicBaseUrl(String? raw) {
  final value = _nonEmptyTrimmed(raw);
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw FormatException(
      'Invalid TINYRACK_SERVICE_PROXY_PUBLIC_BASE_URL: $value',
    );
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

String? _nonEmptyTrimmed(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String resolveTinyrackHome(Map<String, String> env) =>
    env['TINYRACK_HOME'] ??
    p.join(
      env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path,
      '.tinyrack-agent',
    );

({String endpoint, bool useTls})? _parseHubUrl(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'http', 'https', 'ws', 'wss'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      (uri.path.isNotEmpty && uri.path != '/' && uri.path != '/ws')) {
    throw const FormatException(
      'TINYRACK_HUB_URL must be an http(s) or ws(s) URL with /ws or no path',
    );
  }
  final useTls = uri.scheme == 'https' || uri.scheme == 'wss';
  final port = uri.hasPort ? uri.port : (useTls ? 443 : 80);
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return (endpoint: '$host:$port', useTls: useTls);
}
