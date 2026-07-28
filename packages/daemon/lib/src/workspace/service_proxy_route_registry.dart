import 'service_proxy_names.dart';

final class ServiceProxyRoute {
  const ServiceProxyRoute({required this.hostname, required this.port});

  final String hostname;
  final int port;
}

final class ServiceProxyRouteEntry {
  const ServiceProxyRouteEntry({
    required this.hostname,
    required this.port,
    required this.workspaceId,
    required this.projectSlug,
    required this.scriptName,
    this.publicHostname,
    this.publicBaseUrl,
  });

  final String hostname;
  final int port;
  final String workspaceId;
  final String projectSlug;
  final String scriptName;
  final String? publicHostname;
  final String? publicBaseUrl;

  ServiceProxyRouteEntry copyWith({
    String? hostname,
    int? port,
    String? workspaceId,
    String? projectSlug,
    String? scriptName,
    String? publicHostname,
    String? publicBaseUrl,
    bool clearPublicHostname = false,
    bool clearPublicBaseUrl = false,
  }) => ServiceProxyRouteEntry(
    hostname: hostname ?? this.hostname,
    port: port ?? this.port,
    workspaceId: workspaceId ?? this.workspaceId,
    projectSlug: projectSlug ?? this.projectSlug,
    scriptName: scriptName ?? this.scriptName,
    publicHostname: clearPublicHostname
        ? null
        : publicHostname ?? this.publicHostname,
    publicBaseUrl: clearPublicBaseUrl
        ? null
        : publicBaseUrl ?? this.publicBaseUrl,
  );
}

final class ServiceProxyHealthTarget {
  const ServiceProxyHealthTarget({
    required this.workspaceId,
    required this.scriptName,
    required this.hostname,
    required this.port,
  });

  final String workspaceId;
  final String scriptName;
  final String hostname;
  final int port;
}

enum ServiceProxyHostClassificationType {
  registeredService,
  knownServiceMiss,
  daemon,
}

final class ServiceProxyHostClassification {
  const ServiceProxyHostClassification._(this.type, this.route);

  const ServiceProxyHostClassification.registered(ServiceProxyRoute route)
    : this._(ServiceProxyHostClassificationType.registeredService, route);
  const ServiceProxyHostClassification.knownMiss()
    : this._(ServiceProxyHostClassificationType.knownServiceMiss, null);
  const ServiceProxyHostClassification.daemon()
    : this._(ServiceProxyHostClassificationType.daemon, null);

  final ServiceProxyHostClassificationType type;
  final ServiceProxyRoute? route;
}

final class ServiceProxyWorkspaceState {
  const ServiceProxyWorkspaceState({
    required this.hostname,
    required this.port,
    required this.urls,
  });

  final String hostname;
  final int? port;
  final ServiceProxyUrls urls;
}

final class ServiceProxyRouteCollisionError implements Exception {
  ServiceProxyRouteCollisionError({
    required this.hostname,
    required this.existing,
    required this.incoming,
  });

  final String hostname;
  final ServiceProxyRouteEntry existing;
  final ServiceProxyRouteEntry incoming;

  @override
  String toString() =>
      'Another workspace is already serving "${incoming.scriptName}" at '
      '$hostname. Stop that service or run this one on a different branch '
      'to free the address.';
}

final class ServiceProxyRouteRegistry {
  ServiceProxyRouteRegistry({String? publicBaseUrl}) {
    if (publicBaseUrl != null) {
      final hostname = _baseHostname(publicBaseUrl);
      _configuredPublicBaseHostnames.add(hostname);
      _publicBaseHostnames.add(hostname);
    }
  }

  final Map<String, ServiceProxyRouteEntry> _routes = {};
  final Map<String, String> _hostnameAliases = {};
  final Map<String, Set<String>> _workspaceHostnames = {};
  final Set<String> _configuredPublicBaseHostnames = {};
  final Set<String> _publicBaseHostnames = {};

  ServiceProxyRouteEntry registerWorkspaceService({
    required String workspaceId,
    required String projectSlug,
    required String? branchName,
    required String scriptName,
    required int port,
    String? publicBaseUrl,
  }) {
    final localHostname = buildLocalServiceHostname(
      projectSlug: projectSlug,
      branchName: branchName,
      scriptName: scriptName,
    );
    final publicHostname = publicBaseUrl == null
        ? null
        : buildPublicServiceHostname(
            publicBaseUrl: publicBaseUrl,
            projectSlug: projectSlug,
            branchName: branchName,
            scriptName: scriptName,
          );
    final entry = ServiceProxyRouteEntry(
      hostname: localHostname,
      publicHostname: publicHostname,
      publicBaseUrl: publicBaseUrl,
      port: port,
      workspaceId: workspaceId,
      projectSlug: projectSlug,
      scriptName: scriptName,
    );
    registerRoute(entry);
    return entry;
  }

  void registerRoute(ServiceProxyRouteEntry entry) {
    final stored = _storedEntry(entry);
    _assertCanRegister(stored);
    if (_routes.containsKey(stored.hostname)) {
      removeRoute(stored.hostname);
    }
    _routes[stored.hostname] = stored;
    for (final alias in _routeHostnames(stored)) {
      _hostnameAliases[alias] = stored.hostname;
    }
    final publicBaseUrl = stored.publicBaseUrl;
    if (publicBaseUrl != null) {
      _publicBaseHostnames.add(_baseHostname(publicBaseUrl));
    }
    (_workspaceHostnames[stored.workspaceId] ??= {}).add(stored.hostname);
  }

  bool replaceWorkspaceBranchRoutes({
    required String workspaceId,
    required String? newBranch,
  }) {
    final routes = listRoutesForWorkspace(workspaceId);
    if (routes.isEmpty) return false;
    final updates = <({String oldHostname, ServiceProxyRouteEntry entry})>[];
    for (final route in routes) {
      final publicBaseUrl = route.publicBaseUrl;
      updates.add((
        oldHostname: route.hostname,
        entry: route.copyWith(
          hostname: buildLocalServiceHostname(
            projectSlug: route.projectSlug,
            branchName: newBranch,
            scriptName: route.scriptName,
          ),
          publicHostname: publicBaseUrl == null
              ? null
              : buildPublicServiceHostname(
                  publicBaseUrl: publicBaseUrl,
                  projectSlug: route.projectSlug,
                  branchName: newBranch,
                  scriptName: route.scriptName,
                ),
          clearPublicHostname: publicBaseUrl == null,
        ),
      ));
    }
    if (updates.every((update) {
      final current = _routes[update.oldHostname];
      return update.oldHostname == update.entry.hostname &&
          current?.publicHostname == update.entry.publicHostname;
    })) {
      return false;
    }
    final replacing = routes.map((route) => route.hostname).toSet();
    _assertNoInternalCollisions(updates.map((update) => update.entry));
    for (final update in updates) {
      _assertCanRegister(update.entry, replacingHostnames: replacing);
    }
    for (final update in updates) {
      removeRoute(update.oldHostname);
    }
    for (final update in updates) {
      registerRoute(update.entry);
    }
    return true;
  }

  void removeRoute(String hostname) {
    final normalized = _normalizeHostHeader(hostname);
    final canonical = _hostnameAliases[normalized] ?? normalized;
    final entry = _routes.remove(canonical);
    if (entry == null) return;
    for (final alias in _routeHostnames(entry)) {
      _hostnameAliases.remove(alias);
    }
    final workspaceRoutes = _workspaceHostnames[entry.workspaceId];
    workspaceRoutes?.remove(canonical);
    if (workspaceRoutes?.isEmpty ?? false) {
      _workspaceHostnames.remove(entry.workspaceId);
    }
    _rebuildPublicBaseHostnames();
  }

  void removeWorkspaceService({
    required String workspaceId,
    required String scriptName,
  }) {
    for (final route in listRoutesForWorkspace(workspaceId)) {
      if (route.scriptName == scriptName) {
        removeRoute(route.hostname);
        return;
      }
    }
  }

  void removeServiceRoutesByHostnames(Iterable<String> hostnames) {
    for (final hostname in hostnames) {
      removeRoute(hostname);
    }
  }

  void removeRoutesForPort(int port) {
    final hostnames = _routes.entries
        .where((entry) => entry.value.port == port)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final hostname in hostnames) {
      removeRoute(hostname);
    }
  }

  ServiceProxyWorkspaceState projectWorkspaceServiceState({
    required String workspaceId,
    required String projectSlug,
    required String? branchName,
    required String scriptName,
    required int? daemonPort,
    String? publicBaseUrl,
  }) {
    final route = listRoutesForWorkspace(
      workspaceId,
    ).where((entry) => entry.scriptName == scriptName).firstOrNull;
    if (route != null) {
      return ServiceProxyWorkspaceState(
        hostname: route.hostname,
        port: route.port,
        urls: _projectRegisteredUrls(route, daemonPort),
      );
    }
    return ServiceProxyWorkspaceState(
      hostname: buildLocalServiceHostname(
        projectSlug: projectSlug,
        branchName: branchName,
        scriptName: scriptName,
      ),
      port: null,
      urls: projectServiceProxyUrls(
        projectSlug: projectSlug,
        branchName: branchName,
        scriptName: scriptName,
        daemonPort: daemonPort,
        publicBaseUrl: publicBaseUrl,
      ),
    );
  }

  List<ServiceProxyHealthTarget> getHealthCheckTargets() =>
      listRoutes().map(_healthTarget).toList(growable: false);

  List<ServiceProxyHealthTarget> getWorkspaceHealthTargets(
    String workspaceId,
  ) => listRoutesForWorkspace(
    workspaceId,
  ).map(_healthTarget).toList(growable: false);

  ServiceProxyHealthTarget? getHealthTargetForHostname(String hostname) {
    final entry = getRouteEntry(hostname);
    return entry == null ? null : _healthTarget(entry);
  }

  ServiceProxyHostClassification classifyHost(String? host) {
    if (host == null || host.isEmpty) {
      return const ServiceProxyHostClassification.daemon();
    }
    final hostname = _normalizeHostHeader(host);
    final exact = _routeByHostname(hostname);
    if (exact != null) {
      return ServiceProxyHostClassification.registered(
        ServiceProxyRoute(hostname: exact.hostname, port: exact.port),
      );
    }
    if (hostname.endsWith('.localhost') &&
        hostname.split('.').first.contains('--')) {
      return const ServiceProxyHostClassification.knownMiss();
    }
    for (final base in _publicBaseHostnames) {
      if (hostname == base || hostname.endsWith('.$base')) {
        return const ServiceProxyHostClassification.knownMiss();
      }
    }
    return const ServiceProxyHostClassification.daemon();
  }

  ServiceProxyRoute? findRoute(String host) {
    final classification = classifyHost(host);
    return classification.type ==
            ServiceProxyHostClassificationType.registeredService
        ? classification.route
        : null;
  }

  ServiceProxyRouteEntry? getRouteEntry(String hostname) =>
      _routeByHostname(_normalizeHostHeader(hostname));

  List<ServiceProxyRouteEntry> listRoutes() =>
      List.unmodifiable(_routes.values);

  List<ServiceProxyRouteEntry> listRoutesForWorkspace(String workspaceId) {
    final hostnames = _workspaceHostnames[workspaceId];
    if (hostnames == null) return const [];
    return List.unmodifiable(
      hostnames.map((hostname) => _routes[hostname]).whereType(),
    );
  }

  void _assertCanRegister(
    ServiceProxyRouteEntry entry, {
    Set<String> replacingHostnames = const {},
  }) {
    for (final hostname in _routeHostnames(entry)) {
      final canonical = _hostnameAliases[hostname] ?? hostname;
      if (replacingHostnames.contains(canonical)) continue;
      final existing = _routes[canonical];
      if (existing != null && !_sameOwner(existing, entry)) {
        throw ServiceProxyRouteCollisionError(
          hostname: hostname,
          existing: existing,
          incoming: entry,
        );
      }
    }
  }

  void _assertNoInternalCollisions(Iterable<ServiceProxyRouteEntry> entries) {
    final owners = <String, ServiceProxyRouteEntry>{};
    for (final entry in entries) {
      for (final hostname in _routeHostnames(entry)) {
        final existing = owners[hostname];
        if (existing != null) {
          throw ServiceProxyRouteCollisionError(
            hostname: hostname,
            existing: existing,
            incoming: entry,
          );
        }
        owners[hostname] = entry;
      }
    }
  }

  ServiceProxyRouteEntry _storedEntry(ServiceProxyRouteEntry entry) =>
      ServiceProxyRouteEntry(
        hostname: entry.hostname.toLowerCase(),
        port: entry.port,
        workspaceId: entry.workspaceId,
        projectSlug: entry.projectSlug,
        scriptName: entry.scriptName,
        publicHostname: entry.publicHostname?.toLowerCase(),
        publicBaseUrl: entry.publicBaseUrl,
      );

  ServiceProxyRouteEntry? _routeByHostname(String hostname) {
    final canonical = _hostnameAliases[hostname] ?? hostname;
    return _routes[canonical];
  }

  List<String> _routeHostnames(ServiceProxyRouteEntry entry) => [
    entry.hostname.toLowerCase(),
    if (entry.publicHostname case final publicHostname?)
      publicHostname.toLowerCase(),
  ];

  void _rebuildPublicBaseHostnames() {
    _publicBaseHostnames
      ..clear()
      ..addAll(_configuredPublicBaseHostnames);
    for (final entry in _routes.values) {
      if (entry.publicBaseUrl case final url?) {
        _publicBaseHostnames.add(_baseHostname(url));
      }
    }
  }
}

ServiceProxyHealthTarget _healthTarget(ServiceProxyRouteEntry route) =>
    ServiceProxyHealthTarget(
      workspaceId: route.workspaceId,
      scriptName: route.scriptName,
      hostname: route.hostname,
      port: route.port,
    );

ServiceProxyUrls _projectRegisteredUrls(
  ServiceProxyRouteEntry route,
  int? daemonPort,
) {
  final local = daemonPort == null
      ? null
      : Uri(scheme: 'http', host: route.hostname, port: daemonPort).toString();
  String? public;
  if (route.publicHostname != null && route.publicBaseUrl != null) {
    final base = Uri.parse(route.publicBaseUrl!);
    public = Uri(
      scheme: base.scheme,
      host: route.publicHostname,
      port: base.hasPort ? base.port : null,
    ).toString();
  }
  return ServiceProxyUrls(localProxyUrl: local, publicProxyUrl: public);
}

String _normalizeHostHeader(String host) =>
    host.trim().toLowerCase().replaceFirst(RegExp(r':\d+$'), '');

String _baseHostname(String publicBaseUrl) {
  final uri = Uri.parse(publicBaseUrl);
  if (!uri.hasScheme || uri.host.isEmpty) {
    throw FormatException('Invalid public service base URL: $publicBaseUrl');
  }
  return uri.host.toLowerCase();
}

bool _sameOwner(ServiceProxyRouteEntry left, ServiceProxyRouteEntry right) =>
    left.workspaceId == right.workspaceId &&
    left.scriptName == right.scriptName;
