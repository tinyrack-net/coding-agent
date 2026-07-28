import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../server/connection.dart';
import '../server/project_config_service.dart';
import '../terminal/terminal_manager.dart';
import 'script_health_monitor.dart';
import 'service_port_allocator.dart';
import 'service_proxy_route_registry.dart';
import 'workspace_service_env.dart';
import 'workspace_service_port_registry.dart';
import 'workspace_registry.dart';
import 'workspace_git_observer_service.dart';
import 'workspace_script_runtime_store.dart';

final class WorkspaceScriptsService {
  WorkspaceScriptsService({
    required this.workspaces,
    required this.terminals,
    required this.runtimeStore,
    required this.broadcast,
    this.configFiles = const ProjectConfigFile(),
    ServiceProxyRouteRegistry? serviceProxy,
    WorkspaceServicePortRegistry? portRegistry,
    int? Function()? daemonPort,
    this.daemonListenHost,
    this.serviceProxyPublicBaseUrl,
    ScriptHealthState? Function(String hostname)? resolveHealth,
    void Function(String workspaceId)? invalidateHealth,
    this.log,
    this.branchObserverBackend,
  }) : serviceProxy = serviceProxy ?? ServiceProxyRouteRegistry(),
       portRegistry = portRegistry ?? WorkspaceServicePortRegistry(),
       daemonPort = daemonPort ?? (() => null),
       resolveHealth = resolveHealth ?? ((_) => null),
       invalidateHealth = invalidateHealth ?? ((_) {});

  final FileBackedWorkspaceRegistry workspaces;
  final TerminalManager terminals;
  final WorkspaceScriptRuntimeStore runtimeStore;
  final void Function(Map<String, Object?> message) broadcast;
  final ProjectConfigFile configFiles;
  final ServiceProxyRouteRegistry serviceProxy;
  final WorkspaceServicePortRegistry portRegistry;
  final int? Function() daemonPort;
  final String? daemonListenHost;
  final String? serviceProxyPublicBaseUrl;
  final ScriptHealthState? Function(String hostname) resolveHealth;
  final void Function(String workspaceId) invalidateHealth;
  final void Function(String message)? log;
  final WorkspaceGitObserverBackend? branchObserverBackend;
  final Map<String, WorkspaceGitSubscription> _branchSubscriptions = {};
  final Map<String, String?> _observedBranches = {};

  Future<Object?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    final type = message['type'];
    if (type != 'start_workspace_script_request' &&
        type != 'workspace.script.list.request' &&
        type != 'workspace.script.start.request' &&
        type != 'workspace.script.stop.request') {
      return null;
    }
    final request = WorkspaceScriptRequest.fromJson(message);
    return switch (request) {
      StartWorkspaceScriptRequest value => _legacyStart(value),
      WorkspaceScriptListRequest value => _listResponse(value),
      WorkspaceScriptStartRequest value => _startResponse(value),
      WorkspaceScriptStopRequest value => _stopResponse(value),
    };
  }

  Future<void> onTerminalExited(String terminalId, int? exitCode) async {
    for (final workspace in await workspaces.list()) {
      for (final runtime in runtimeStore.listForWorkspace(
        workspace.workspaceId,
      )) {
        if (runtime.terminalId != terminalId ||
            runtime.lifecycle != WorkspaceScriptLifecycle.running) {
          continue;
        }
        runtimeStore.set(
          runtime.copyWith(
            lifecycle: WorkspaceScriptLifecycle.stopped,
            exitCode: exitCode,
          ),
        );
        serviceProxy.removeWorkspaceService(
          workspaceId: workspace.workspaceId,
          scriptName: runtime.scriptName,
        );
        _releaseBranchObserverIfUnused(workspace.workspaceId);
        invalidateHealth(workspace.workspaceId);
        await emitStatusUpdate(workspace.workspaceId);
      }
    }
  }

  Future<List<WorkspaceScript>> list(String workspaceId) async {
    final workspace = await _workspace(workspaceId);
    return _snapshot(workspace);
  }

  Future<WorkspaceScript> launch({
    required String workspaceId,
    required String scriptName,
  }) async {
    final workspace = await _workspace(workspaceId);
    final configuration = await _configuration(workspace.cwd);
    final config = configuration.scripts[scriptName];
    if (config == null) {
      throw StateError("Script '$scriptName' is not configured in paseo.json");
    }
    if (runtimeStore.isRunning(
      workspaceId: workspaceId,
      scriptName: scriptName,
    )) {
      throw StateError("Script '$scriptName' is already running");
    }
    var environment = const <String, String>{};
    if (config.type == WorkspaceScriptType.service) {
      final services = [
        for (final entry in configuration.scripts.entries)
          if (entry.value.type == WorkspaceScriptType.service)
            WorkspaceServicePortDeclaration(
              scriptName: entry.key,
              port: entry.value.port,
            ),
      ];
      final plan = await portRegistry.ensurePlan(
        workspaceId: workspaceId,
        services: services,
        allocatePort: (request) => allocateWorkspaceServicePort(
          allocation: configuration.portAllocation,
          cwd: workspace.cwd,
          scriptName: request.scriptName,
          workspaceId: workspace.workspaceId,
          branchName: workspace.branch,
          reservedPorts: request.reservedPorts,
        ),
      );
      final port = portRegistry.requirePlannedPort(plan, scriptName);
      final projectSlug = _projectSlug(workspace);
      serviceProxy.registerWorkspaceService(
        workspaceId: workspace.workspaceId,
        projectSlug: projectSlug,
        branchName: workspace.branch,
        scriptName: scriptName,
        port: port,
        publicBaseUrl: serviceProxyPublicBaseUrl,
      );
      try {
        _ensureBranchObserver(workspace);
      } catch (_) {
        serviceProxy.removeWorkspaceService(
          workspaceId: workspaceId,
          scriptName: scriptName,
        );
        _releaseBranchObserverIfUnused(workspaceId);
        rethrow;
      }
      environment = buildWorkspaceServiceEnv(
        scriptName: scriptName,
        projectSlug: projectSlug,
        branchName: workspace.branch,
        daemonPort: daemonPort(),
        daemonListenHost: daemonListenHost,
        serviceProxyPublicBaseUrl: serviceProxyPublicBaseUrl,
        peers: [
          for (final entry in plan.entries)
            WorkspaceServicePeer(scriptName: entry.key, port: entry.value),
        ],
      );
      invalidateHealth(workspaceId);
    }
    Map<String, Object?> terminal;
    try {
      terminal = terminals.create(
        cwd: workspace.cwd,
        workspaceId: workspace.workspaceId,
        environment: environment,
      );
    } catch (_) {
      serviceProxy.removeWorkspaceService(
        workspaceId: workspaceId,
        scriptName: scriptName,
      );
      _releaseBranchObserverIfUnused(workspaceId);
      invalidateHealth(workspaceId);
      rethrow;
    }
    final terminalId = terminal['terminalId']! as String;
    runtimeStore.set(
      WorkspaceScriptRuntimeEntry(
        workspaceId: workspaceId,
        scriptName: scriptName,
        type: config.type,
        lifecycle: WorkspaceScriptLifecycle.running,
        terminalId: terminalId,
        exitCode: null,
      ),
    );
    try {
      terminals.sendInput(terminalId, '${config.command}\r');
    } catch (_) {
      runtimeStore.remove(workspaceId: workspaceId, scriptName: scriptName);
      if (terminals.contains(terminalId)) terminals.kill(terminalId);
      serviceProxy.removeWorkspaceService(
        workspaceId: workspaceId,
        scriptName: scriptName,
      );
      _releaseBranchObserverIfUnused(workspaceId);
      invalidateHealth(workspaceId);
      rethrow;
    }
    final script = (await _snapshot(workspace)).firstWhere(
      (entry) => entry.scriptName == scriptName,
      orElse: () => throw StateError(
        "Script '$scriptName' did not produce a status record",
      ),
    );
    await emitStatusUpdate(workspaceId);
    return script;
  }

  Future<WorkspaceScript> stop({
    required String workspaceId,
    required String scriptName,
  }) async {
    final workspace = await _workspace(workspaceId);
    final runtime = runtimeStore.get(
      workspaceId: workspaceId,
      scriptName: scriptName,
    );
    if (runtime == null ||
        runtime.lifecycle != WorkspaceScriptLifecycle.running) {
      throw StateError("Script '$scriptName' is not running");
    }
    if (!terminals.contains(runtime.terminalId)) {
      throw StateError(
        "Terminal for script '$scriptName' is no longer available",
      );
    }
    final exitCode = await terminals.killAndWait(runtime.terminalId);
    final current = runtimeStore.get(
      workspaceId: workspaceId,
      scriptName: scriptName,
    );
    if (current?.lifecycle == WorkspaceScriptLifecycle.running) {
      runtimeStore.set(
        current!.copyWith(
          lifecycle: WorkspaceScriptLifecycle.stopped,
          exitCode: exitCode,
        ),
      );
    }
    serviceProxy.removeWorkspaceService(
      workspaceId: workspaceId,
      scriptName: scriptName,
    );
    _releaseBranchObserverIfUnused(workspaceId);
    invalidateHealth(workspaceId);
    final script = (await _snapshot(workspace)).firstWhere(
      (entry) => entry.scriptName == scriptName,
      orElse: () => throw StateError(
        "Script '$scriptName' did not produce a status record",
      ),
    );
    await emitStatusUpdate(workspaceId);
    return script;
  }

  Future<void> emitStatusUpdate(String workspaceId) async {
    try {
      final scripts = await list(workspaceId);
      broadcast(
        WorkspaceScriptStatusUpdate(
          workspaceId: workspaceId,
          scripts: scripts,
        ).toJson(),
      );
    } catch (_) {
      // Status projection is best-effort in Paseo.
    }
  }

  void dispose() {
    for (final subscription in _branchSubscriptions.values) {
      subscription.unsubscribe();
    }
    _branchSubscriptions.clear();
    _observedBranches.clear();
  }

  Future<Map<String, Object?>> _legacyStart(
    StartWorkspaceScriptRequest request,
  ) async {
    try {
      final script = await launch(
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
      );
      return StartWorkspaceScriptResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        terminalId: script.terminalId,
        error: null,
      ).toJson();
    } catch (error) {
      return StartWorkspaceScriptResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        terminalId: null,
        error: _message(error, 'Failed to start workspace script'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _listResponse(
    WorkspaceScriptListRequest request,
  ) async {
    try {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.list.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scripts: await list(request.workspaceId),
        error: null,
      ).toJson();
    } catch (error) {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.list.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scripts: const [],
        error: _message(error, 'Failed to list workspace scripts'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _startResponse(
    WorkspaceScriptStartRequest request,
  ) async {
    try {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.start.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        script: await launch(
          workspaceId: request.workspaceId,
          scriptName: request.scriptName,
        ),
        error: null,
      ).toJson();
    } catch (error) {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.start.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        error: _message(error, 'Failed to start workspace script'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _stopResponse(
    WorkspaceScriptStopRequest request,
  ) async {
    try {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.stop.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        script: await stop(
          workspaceId: request.workspaceId,
          scriptName: request.scriptName,
        ),
        error: null,
      ).toJson();
    } catch (error) {
      return WorkspaceScriptOperationResponse(
        type: 'workspace.script.stop.response',
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        scriptName: request.scriptName,
        error: _message(error, 'Failed to stop workspace script'),
      ).toJson();
    }
  }

  Future<PersistedWorkspaceRecord> _workspace(String workspaceId) async {
    final workspace = await workspaces.get(workspaceId);
    if (workspace == null || workspace.archivedAt != null) {
      throw StateError('Workspace not found: $workspaceId');
    }
    return workspace;
  }

  Future<List<WorkspaceScript>> _snapshot(
    PersistedWorkspaceRecord workspace,
  ) async {
    final configs = (await _configuration(workspace.cwd)).scripts;
    final runtimes = {
      for (final entry in runtimeStore.listForWorkspace(workspace.workspaceId))
        entry.scriptName: entry,
    };
    final scripts = <WorkspaceScript>[
      for (final config in configs.entries)
        _payload(
          workspace,
          config.key,
          config.value,
          runtimes.remove(config.key),
        ),
      for (final runtime in runtimes.values)
        if (runtime.lifecycle == WorkspaceScriptLifecycle.running)
          _payload(
            workspace,
            runtime.scriptName,
            _ScriptConfig(command: '', type: runtime.type),
            runtime,
          ),
    ];
    final insertionOrder = {
      for (var index = 0; index < scripts.length; index++)
        scripts[index]: index,
    };
    scripts.sort((left, right) {
      final comparison = _compareScriptNames(left.scriptName, right.scriptName);
      return comparison != 0
          ? comparison
          : insertionOrder[left]!.compareTo(insertionOrder[right]!);
    });
    return scripts;
  }

  Future<_WorkspaceScriptsConfiguration> _configuration(String cwd) async {
    final result = await configFiles.read(cwd);
    if (result['ok'] != true) {
      log?.call(
        'Failed to parse project config in $cwd; '
        'treating workspace as having no scripts',
      );
      return const _WorkspaceScriptsConfiguration(scripts: {});
    }
    final config = result['config'];
    if (config is! Map) {
      return const _WorkspaceScriptsConfiguration(scripts: {});
    }
    final rawScripts = config['scripts'];
    final scripts = <String, _ScriptConfig>{};
    if (rawScripts is Map) {
      for (final entry in rawScripts.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final value = entry.value as Map;
        final command = value['command'];
        if (command is! String || command.trim().isEmpty) continue;
        final type = value['type'] == 'service'
            ? WorkspaceScriptType.service
            : WorkspaceScriptType.script;
        final rawPort = value['port'];
        final port =
            type == WorkspaceScriptType.service &&
                rawPort is num &&
                rawPort.isFinite &&
                rawPort.toInt() == rawPort &&
                rawPort >= 1 &&
                rawPort <= 65535
            ? rawPort.toInt()
            : null;
        scripts[entry.key as String] = _ScriptConfig(
          command: command.trim(),
          type: type,
          port: port,
        );
      }
    }
    final worktree = config['worktree'];
    final rawAllocation = worktree is Map ? worktree['servicePorts'] : null;
    return _WorkspaceScriptsConfiguration(
      scripts: scripts,
      portAllocation: rawAllocation is Map
          ? ServicePortAllocation(
              range: rawAllocation['range'] as String?,
              portScript: rawAllocation['portScript'] as String?,
            )
          : null,
    );
  }

  WorkspaceScript _payload(
    PersistedWorkspaceRecord workspace,
    String scriptName,
    _ScriptConfig config,
    WorkspaceScriptRuntimeEntry? runtime,
  ) {
    if (config.type == WorkspaceScriptType.script) {
      return WorkspaceScript(
        scriptName: scriptName,
        type: config.type,
        hostname: scriptName,
        port: null,
        proxyUrl: null,
        lifecycle: runtime?.lifecycle ?? WorkspaceScriptLifecycle.stopped,
        health: null,
        exitCode: runtime?.exitCode,
        terminalId: runtime?.terminalId,
      );
    }
    final state = serviceProxy.projectWorkspaceServiceState(
      workspaceId: workspace.workspaceId,
      projectSlug: _projectSlug(workspace),
      branchName: workspace.branch,
      scriptName: scriptName,
      daemonPort: daemonPort(),
      publicBaseUrl: serviceProxyPublicBaseUrl,
    );
    final internalHealth = resolveHealth(state.hostname);
    return WorkspaceScript(
      scriptName: scriptName,
      type: config.type,
      hostname: state.hostname,
      port: state.port ?? config.port,
      localProxyUrl: state.urls.localProxyUrl,
      publicProxyUrl: state.urls.publicProxyUrl,
      proxyUrl: state.urls.proxyUrl,
      lifecycle: runtime?.lifecycle ?? WorkspaceScriptLifecycle.stopped,
      health: switch (internalHealth) {
        ScriptHealthState.healthy => WorkspaceScriptHealth.healthy,
        ScriptHealthState.unhealthy => WorkspaceScriptHealth.unhealthy,
        ScriptHealthState.pending || null => null,
      },
      exitCode: runtime?.exitCode,
      terminalId: runtime?.terminalId,
    );
  }

  void _ensureBranchObserver(PersistedWorkspaceRecord workspace) {
    final backend = branchObserverBackend;
    if (backend == null ||
        _branchSubscriptions.containsKey(workspace.workspaceId)) {
      return;
    }
    _observedBranches[workspace.workspaceId] = workspace.branch;
    _branchSubscriptions[workspace.workspaceId] = backend.registerWorkspace(
      workspace.cwd,
      (snapshot) {
        final previous = _observedBranches[workspace.workspaceId];
        final next = snapshot.currentBranch;
        if (previous == next) return;
        try {
          final changed = serviceProxy.replaceWorkspaceBranchRoutes(
            workspaceId: workspace.workspaceId,
            newBranch: next,
          );
          _observedBranches[workspace.workspaceId] = next;
          if (!changed) return;
          invalidateHealth(workspace.workspaceId);
          unawaited(_persistObservedBranch(workspace.workspaceId, next));
          unawaited(emitStatusUpdate(workspace.workspaceId));
        } catch (error) {
          log?.call(
            'Failed to update service proxy routes after branch change: '
            '$error',
          );
        }
      },
    );
  }

  Future<void> _persistObservedBranch(
    String workspaceId,
    String? branch,
  ) async {
    final current = await workspaces.get(workspaceId);
    if (current == null || current.archivedAt != null) return;
    await workspaces.upsert(current.copyWith(branch: branch));
  }

  void _releaseBranchObserverIfUnused(String workspaceId) {
    if (serviceProxy.listRoutesForWorkspace(workspaceId).isNotEmpty) return;
    _branchSubscriptions.remove(workspaceId)?.unsubscribe();
    _observedBranches.remove(workspaceId);
  }
}

final class _WorkspaceScriptsConfiguration {
  const _WorkspaceScriptsConfiguration({
    required this.scripts,
    this.portAllocation,
  });

  final Map<String, _ScriptConfig> scripts;
  final ServicePortAllocation? portAllocation;
}

final class _ScriptConfig {
  const _ScriptConfig({required this.command, required this.type, this.port});

  final String command;
  final WorkspaceScriptType type;
  final int? port;
}

String _projectSlug(PersistedWorkspaceRecord workspace) {
  final root = workspace.mainRepoRoot ?? workspace.cwd;
  final basename = p.basename(p.normalize(root));
  return basename.isEmpty ? workspace.projectId : basename;
}

int _compareScriptNames(String left, String right) {
  final leftTokens = _naturalTokens(left);
  final rightTokens = _naturalTokens(right);
  final length = leftTokens.length < rightTokens.length
      ? leftTokens.length
      : rightTokens.length;
  for (var index = 0; index < length; index++) {
    final leftToken = leftTokens[index];
    final rightToken = rightTokens[index];
    if (leftToken.isNumber && rightToken.isNumber) {
      final comparison = leftToken.number!.compareTo(rightToken.number!);
      if (comparison != 0) return comparison;
      continue;
    }
    final comparison = leftToken.value.compareTo(rightToken.value);
    if (comparison != 0) return comparison;
  }
  return leftTokens.length.compareTo(rightTokens.length);
}

List<_NaturalToken> _naturalTokens(String value) {
  final normalized = unorm
      .nfkd(value.toLowerCase())
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '');
  return [
    for (final match in RegExp(r'\d+|\D+').allMatches(normalized))
      _NaturalToken(match.group(0)!),
  ];
}

final class _NaturalToken {
  _NaturalToken(this.value)
    : isNumber = RegExp(r'^\d+$').hasMatch(value),
      number = RegExp(r'^\d+$').hasMatch(value) ? BigInt.parse(value) : null;

  final String value;
  final bool isNumber;
  final BigInt? number;
}

String _message(Object error, String fallback) {
  final message = '$error'.replaceFirst(RegExp(r'^[^:]+Error: '), '');
  return message.isEmpty ? fallback : message;
}
