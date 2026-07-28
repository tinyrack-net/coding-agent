import 'dart:async';

final class WorkspaceServicePortDeclaration {
  const WorkspaceServicePortDeclaration({required this.scriptName, this.port});

  final String scriptName;
  final int? port;
}

final class WorkspaceServicePortAllocationRequest {
  const WorkspaceServicePortAllocationRequest({
    required this.scriptName,
    required this.reservedPorts,
  });

  final String scriptName;
  final Set<int> reservedPorts;
}

typedef WorkspaceServicePortAllocator =
    Future<int> Function(WorkspaceServicePortAllocationRequest request);

final class WorkspaceServicePortRegistry {
  static const int maxDynamicPortAllocationAttempts = 10;

  final Map<String, Map<String, int>> _plans = {};
  final Map<String, Future<Map<String, int>>> _pendingPlans = {};
  final Map<String, _PendingPlanToken> _pendingTokens = {};
  final Map<int, String> _dynamicPortOwners = {};
  final Map<String, Map<String, int>> _dynamicPortsByWorkspace = {};

  Future<Map<String, int>> ensurePlan({
    required String workspaceId,
    required List<WorkspaceServicePortDeclaration> services,
    required WorkspaceServicePortAllocator allocatePort,
  }) async {
    final existing = _plans[workspaceId];
    if (existing != null) return Map.of(existing);
    var pending = _pendingPlans[workspaceId];
    if (pending == null) {
      final token = _PendingPlanToken();
      pending = _createPendingPlan(
        workspaceId: workspaceId,
        services: services,
        allocatePort: allocatePort,
        token: token,
      );
      _pendingPlans[workspaceId] = pending;
      _pendingTokens[workspaceId] = token;
    }
    return Map.of(await pending);
  }

  int requirePlannedPort(Map<String, int> plan, String scriptName) {
    final port = plan[scriptName];
    if (port == null) {
      throw StateError(
        "Service '$scriptName' is missing from workspace service port plan",
      );
    }
    return port;
  }

  void releasePlan(String workspaceId) {
    _pendingTokens[workspaceId]?.released = true;
    _plans.remove(workspaceId);
    final dynamicPorts = _dynamicPortsByWorkspace.remove(workspaceId);
    if (dynamicPorts == null) return;
    for (final entry in dynamicPorts.entries) {
      _releaseDynamicPort(
        workspaceId: workspaceId,
        scriptName: entry.key,
        port: entry.value,
      );
    }
  }

  Future<int> refreshPort({
    required String workspaceId,
    required WorkspaceServicePortDeclaration service,
    required WorkspaceServicePortAllocator allocatePort,
  }) async {
    final plan = _plans[workspaceId] ?? <String, int>{};
    final reserved = plan.values.toSet();
    final previous = plan[service.scriptName];
    if (previous != null) reserved.remove(previous);
    final oldDynamic =
        _dynamicPortsByWorkspace[workspaceId]?[service.scriptName];
    final port = await _resolvePort(
      workspaceId: workspaceId,
      service: service,
      allocatePort: allocatePort,
      reservedPorts: reserved,
    );
    if (oldDynamic != null && oldDynamic != port) {
      _releaseDynamicPort(
        workspaceId: workspaceId,
        scriptName: service.scriptName,
        port: oldDynamic,
      );
    }
    plan[service.scriptName] = port;
    _plans[workspaceId] = plan;
    return port;
  }

  Future<Map<String, int>> _createPendingPlan({
    required String workspaceId,
    required List<WorkspaceServicePortDeclaration> services,
    required WorkspaceServicePortAllocator allocatePort,
    required _PendingPlanToken token,
  }) async {
    try {
      final plan = await _buildPlan(
        workspaceId: workspaceId,
        services: services,
        allocatePort: allocatePort,
      );
      if (token.released) {
        throw StateError(
          'Workspace service port plan was released while being created '
          "for '$workspaceId'",
        );
      }
      _plans[workspaceId] = plan;
      return plan;
    } catch (_) {
      releasePlan(workspaceId);
      rethrow;
    } finally {
      _pendingPlans.remove(workspaceId);
      _pendingTokens.remove(workspaceId);
    }
  }

  Future<Map<String, int>> _buildPlan({
    required String workspaceId,
    required List<WorkspaceServicePortDeclaration> services,
    required WorkspaceServicePortAllocator allocatePort,
  }) async {
    final explicitOwners = <int, String>{};
    for (final service in services) {
      final port = service.port;
      if (port == null) continue;
      if (explicitOwners.containsKey(port)) {
        throw StateError(
          "Service '${service.scriptName}' has a duplicate port $port",
        );
      }
      explicitOwners[port] = service.scriptName;
    }
    final plan = <String, int>{};
    for (final service in services) {
      final explicitPort = service.port;
      if (explicitPort != null) {
        plan[service.scriptName] = explicitPort;
        continue;
      }
      plan[service.scriptName] = await _resolvePort(
        workspaceId: workspaceId,
        service: service,
        allocatePort: allocatePort,
        reservedPorts: {...explicitOwners.keys, ...plan.values},
      );
    }
    return plan;
  }

  Future<int> _resolvePort({
    required String workspaceId,
    required WorkspaceServicePortDeclaration service,
    required WorkspaceServicePortAllocator allocatePort,
    required Set<int> reservedPorts,
  }) async {
    final explicit = service.port;
    if (explicit != null) {
      if (reservedPorts.contains(explicit)) {
        throw StateError(
          "Service '${service.scriptName}' has a duplicate port $explicit",
        );
      }
      return explicit;
    }
    final serviceOwner = _owner(workspaceId, service.scriptName);
    for (
      var attempt = 0;
      attempt < maxDynamicPortAllocationAttempts;
      attempt++
    ) {
      final unavailable = Set<int>.of(reservedPorts);
      for (final entry in _dynamicPortOwners.entries) {
        if (entry.value != serviceOwner) unavailable.add(entry.key);
      }
      final port = await allocatePort(
        WorkspaceServicePortAllocationRequest(
          scriptName: service.scriptName,
          reservedPorts: unavailable,
        ),
      );
      if (reservedPorts.contains(port)) continue;
      final owner = _dynamicPortOwners[port];
      if (owner != null && owner != serviceOwner) continue;
      _reserveDynamicPort(
        workspaceId: workspaceId,
        scriptName: service.scriptName,
        port: port,
      );
      return port;
    }
    throw StateError(
      "Could not allocate a unique port for service '${service.scriptName}' "
      'after $maxDynamicPortAllocationAttempts attempts',
    );
  }

  void _reserveDynamicPort({
    required String workspaceId,
    required String scriptName,
    required int port,
  }) {
    _dynamicPortOwners[port] = _owner(workspaceId, scriptName);
    (_dynamicPortsByWorkspace[workspaceId] ??= {})[scriptName] = port;
  }

  void _releaseDynamicPort({
    required String workspaceId,
    required String scriptName,
    required int port,
  }) {
    final owner = _owner(workspaceId, scriptName);
    if (_dynamicPortOwners[port] == owner) _dynamicPortOwners.remove(port);
    final workspacePorts = _dynamicPortsByWorkspace[workspaceId];
    if (workspacePorts?[scriptName] == port) {
      workspacePorts!.remove(scriptName);
      if (workspacePorts.isEmpty) {
        _dynamicPortsByWorkspace.remove(workspaceId);
      }
    }
  }

  String _owner(String workspaceId, String scriptName) =>
      '$workspaceId\u0000$scriptName';
}

final class _PendingPlanToken {
  bool released = false;
}
