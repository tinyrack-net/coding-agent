import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'service_proxy_route_registry.dart';

enum ScriptHealthState { pending, healthy, unhealthy }

final class ScriptHealthEntry {
  const ScriptHealthEntry({
    required this.scriptName,
    required this.hostname,
    required this.port,
    required this.health,
  });

  final String scriptName;
  final String hostname;
  final int port;
  final ScriptHealthState health;

  Map<String, Object?> toJson() => {
    'scriptName': scriptName,
    'hostname': hostname,
    'port': port,
    'health': health.name,
  };
}

typedef ScriptHealthProbe = Future<bool> Function(int port, Duration timeout);
typedef ScriptHealthChange =
    void Function(String workspaceId, List<ScriptHealthEntry> scripts);

final class ScriptHealthMonitor {
  ScriptHealthMonitor({
    required this.serviceProxy,
    required this.onChange,
    this.pollInterval = const Duration(seconds: 3),
    this.probeTimeout = const Duration(milliseconds: 500),
    this.grace = const Duration(seconds: 5),
    this.failuresBeforeStopped = 2,
    ScriptHealthProbe? probe,
    DateTime Function()? clock,
  }) : _probe = probe ?? _probeTcpPort,
       _clock = clock ?? DateTime.now {
    if (failuresBeforeStopped < 1) {
      throw ArgumentError.value(
        failuresBeforeStopped,
        'failuresBeforeStopped',
        'must be at least 1',
      );
    }
  }

  final ServiceProxyRouteRegistry serviceProxy;
  final ScriptHealthChange onChange;
  final Duration pollInterval;
  final Duration probeTimeout;
  final Duration grace;
  final int failuresBeforeStopped;
  final ScriptHealthProbe _probe;
  final DateTime Function() _clock;
  final Map<String, _RouteHealthState> _routeStates = {};
  final Map<String, String> _lastEmittedSnapshots = {};

  Timer? _timer;
  bool _pollInFlight = false;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    final now = _clock();
    for (final route in serviceProxy.getHealthCheckTargets()) {
      _getOrCreateState(route, now);
    }
    _timer = Timer.periodic(pollInterval, (_) => unawaited(pollNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void invalidateWorkspace(String workspaceId) {
    _emitIfChanged(workspaceId);
  }

  Future<void> pollNow() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final routes = serviceProxy.getHealthCheckTargets();
      final activeHostnames = routes.map((route) => route.hostname).toSet();
      final changedWorkspaces = <String>{};
      final now = _clock();
      final probeTargets =
          <({ServiceProxyHealthTarget route, _RouteHealthState state})>[];
      for (final route in routes) {
        final state = _getOrCreateState(route, now);
        if (now.difference(state.registeredAt) >= grace) {
          probeTargets.add((route: route, state: state));
        }
      }
      final results = await Future.wait(
        probeTargets.map((target) => _probe(target.route.port, probeTimeout)),
      );
      for (var index = 0; index < probeTargets.length; index++) {
        final target = probeTargets[index];
        final previous = target.state.health;
        if (results[index]) {
          target.state
            ..consecutiveFailures = 0
            ..health = ScriptHealthState.healthy;
        } else {
          target.state.consecutiveFailures++;
          if (target.state.consecutiveFailures >= failuresBeforeStopped) {
            target.state.health = ScriptHealthState.unhealthy;
          }
        }
        if (target.state.health != previous) {
          changedWorkspaces.add(target.route.workspaceId);
        }
      }
      _pruneRemovedRoutes(activeHostnames);
      for (final workspaceId in changedWorkspaces) {
        _emitIfChanged(workspaceId);
      }
    } finally {
      _pollInFlight = false;
    }
  }

  ScriptHealthState? getHealthForHostname(String hostname) {
    final existing = _routeStates[hostname];
    if (existing != null) return existing.health;
    final route = serviceProxy.getHealthTargetForHostname(hostname);
    if (route == null) return null;
    return _getOrCreateState(route, _clock()).health;
  }

  List<ScriptHealthEntry> _workspaceScriptList(String workspaceId) => [
    for (final route in serviceProxy.getWorkspaceHealthTargets(workspaceId))
      if (_routeStates[route.hostname] case final state?)
        ScriptHealthEntry(
          scriptName: route.scriptName,
          hostname: route.hostname,
          port: route.port,
          health: state.health,
        ),
  ];

  _RouteHealthState _getOrCreateState(
    ServiceProxyHealthTarget route,
    DateTime registeredAt,
  ) => _routeStates.putIfAbsent(
    route.hostname,
    () => _RouteHealthState(
      workspaceId: route.workspaceId,
      registeredAt: registeredAt,
    ),
  );

  void _pruneRemovedRoutes(Set<String> activeHostnames) {
    for (final entry in _routeStates.entries.toList(growable: false)) {
      if (activeHostnames.contains(entry.key)) continue;
      _routeStates.remove(entry.key);
      _lastEmittedSnapshots.remove(entry.value.workspaceId);
    }
  }

  void _emitIfChanged(String workspaceId) {
    final scripts = _workspaceScriptList(workspaceId);
    final snapshot = jsonEncode(
      scripts.map((script) => script.toJson()).toList(),
    );
    if (_lastEmittedSnapshots[workspaceId] == snapshot) return;
    _lastEmittedSnapshots[workspaceId] = snapshot;
    onChange(workspaceId, List.unmodifiable(scripts));
  }
}

final class _RouteHealthState {
  _RouteHealthState({required this.workspaceId, required this.registeredAt});

  final String workspaceId;
  final DateTime registeredAt;
  ScriptHealthState health = ScriptHealthState.pending;
  int consecutiveFailures = 0;
}

Future<bool> _probeTcpPort(int port, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } finally {
    socket?.destroy();
  }
}
