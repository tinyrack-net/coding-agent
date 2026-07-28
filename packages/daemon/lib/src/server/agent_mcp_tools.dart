import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_manager.dart';
import '../agent/create_agent_intent.dart';
import '../agent/create_agent_mode.dart';
import '../agent/create_agent_title.dart';
import '../agent/timeline_projection.dart';
import '../agent/timeline_store.dart';
import '../providers/paseo/provider_catalog_registry.dart';
import '../schedule/schedule_service.dart';
import '../terminal/terminal_manager.dart';
import '../voice/voice_bridge_registry.dart';
import '../voice/voice_types.dart';
import '../workspace/workspace_registry.dart';
import '../workspace/workspace_scripts_service.dart';
import '../workspace/workspace_v2_service.dart';
import 'create_agent_input_validator.dart';

final class AgentMcpTools {
  AgentMcpTools({
    required AgentManager manager,
    required PaseoProviderCatalogRegistry providerCatalog,
    required WorkspaceV2Service Function() workspaceService,
    required WorkspaceScriptsService Function() workspaceScripts,
    required ScheduleService Function() schedules,
    required TerminalManager terminals,
    required VoiceBridgeRegistry voiceBridge,
    this.agentWaitTimeout = const Duration(seconds: 30),
  }) : _manager = manager,
       _providerCatalog = providerCatalog,
       _workspaceService = workspaceService,
       _workspaceScripts = workspaceScripts,
       _schedules = schedules,
       _terminals = terminals,
       _voiceBridge = voiceBridge;

  final AgentManager _manager;
  final PaseoProviderCatalogRegistry _providerCatalog;
  final WorkspaceV2Service Function() _workspaceService;
  final WorkspaceScriptsService Function() _workspaceScripts;
  final ScheduleService Function() _schedules;
  final TerminalManager _terminals;
  final VoiceBridgeRegistry _voiceBridge;
  final Duration agentWaitTimeout;

  Future<Map<String, Object?>> execute(
    String name,
    Map<String, Object?> arguments,
    String? callerAgentId, {
    VoiceAbortSignal? signal,
  }) async {
    switch (name) {
      case 'speak':
        return _speak(arguments, callerAgentId, signal);
      case 'create_workspace':
        return _createWorkspace(arguments, callerAgentId);
      case 'list_workspaces':
        return _listWorkspaces();
      case 'archive_workspace':
        return _archiveWorkspace(arguments);
      case 'create_agent':
        return _createAgent(arguments, callerAgentId);
      case 'rename_workspace':
        return _renameWorkspace(arguments, callerAgentId);
      case 'list_workspace_scripts':
        return _listWorkspaceScripts(arguments);
      case 'start_workspace_script':
        return _startWorkspaceScript(arguments);
      case 'stop_workspace_script':
        return _stopWorkspaceScript(arguments);
      case 'list_terminals':
        return _listTerminals(arguments, callerAgentId);
      case 'create_terminal':
        return _createTerminal(arguments, callerAgentId);
      case 'kill_terminal':
        return _killTerminal(arguments);
      case 'capture_terminal':
        return _captureTerminal(arguments);
      case 'send_terminal_keys':
        return _sendTerminalKeys(arguments);
      case 'create_schedule':
        return _createSchedule(arguments, callerAgentId);
      case 'create_heartbeat':
        return _createHeartbeat(arguments, callerAgentId);
      case 'delete_heartbeat':
        return _deleteHeartbeat(arguments, callerAgentId);
      case 'list_schedules':
        return _listSchedules();
      case 'inspect_schedule':
        return _inspectSchedule(arguments);
      case 'pause_schedule':
        return _pauseSchedule(arguments);
      case 'resume_schedule':
        return _resumeSchedule(arguments);
      case 'delete_schedule':
        return _deleteSchedule(arguments);
      case 'update_schedule':
        return _updateSchedule(arguments);
      case 'schedule_logs':
        return _scheduleLogs(arguments);
      case 'run_schedule_once':
        return _runScheduleOnce(arguments);
      case 'list_agents':
        return _listAgents(arguments, callerAgentId);
      case 'get_agent_status':
        final agentId = _requiredString(arguments, 'agentId');
        final snapshot = _snapshot(agentId);
        return {'status': snapshot['status'], 'snapshot': snapshot};
      case 'send_agent_prompt':
        final agentId = _requiredString(arguments, 'agentId');
        if (arguments['sessionMode'] case final String sessionMode) {
          await _manager.setModeId(agentId, sessionMode);
        } else if (arguments.containsKey('sessionMode')) {
          throw const FormatException('sessionMode must be a string');
        }
        await _manager.prompt(agentId, _requiredString(arguments, 'prompt'));
        final background =
            arguments['background'] as bool? ?? callerAgentId != null;
        final notifyOnFinish =
            arguments['notifyOnFinish'] as bool? ?? callerAgentId != null;
        final shouldNotify =
            callerAgentId != null && background && notifyOnFinish;
        if (shouldNotify) {
          unawaited(_notifyCallerWhenAgentStops(agentId, callerAgentId));
        }
        if (!background) {
          return _waitForAgent(agentId);
        }
        final snapshot = _snapshot(agentId);
        return {
          'success': true,
          'status': snapshot['status'],
          'lastMessage': null,
          'permission': null,
          if (shouldNotify)
            'guidance':
                'You will get notified when the prompted agent finishes, '
                'errors, or needs permission. Do not poll for status; continue '
                'with other work until the notification arrives.',
        };
      case 'cancel_agent':
        final agentId = _requiredString(arguments, 'agentId');
        final agent = _manager.get(agentId);
        if (agent == null) throw StateError('Agent $agentId not found');
        final running =
            agent.runState == AgentRunState.running ||
            agent.runState == AgentRunState.awaitingPermission;
        if (running) await _manager.interrupt(agentId);
        return {'success': running};
      case 'archive_agent':
        await _manager.archive(_requiredString(arguments, 'agentId'));
        return {'success': true};
      case 'kill_agent':
        await _manager.close(_requiredString(arguments, 'agentId'));
        return {'success': true};
      case 'update_agent':
        return _updateAgent(arguments);
      case 'get_agent_activity':
        return _getAgentActivity(arguments);
      case 'set_agent_mode':
        final agentId = _requiredString(arguments, 'agentId');
        final modeId = _requiredString(arguments, 'modeId');
        await _manager.setModeId(agentId, modeId);
        return {'success': true, 'newMode': modeId};
      case 'list_pending_permissions':
        return _listPendingPermissions();
      case 'respond_to_permission':
        return _respondToPermission(arguments);
      case 'list_providers':
        final entries = await _providerCatalog.snapshot();
        return {
          'providers': [for (final entry in entries) _providerSummary(entry)],
        };
      case 'list_models':
        final provider = _requiredString(arguments, 'provider');
        final entries = await _providerCatalog.snapshot(providers: [provider]);
        if (entries.isEmpty) throw StateError("Provider '$provider' not found");
        return {
          'provider': provider,
          'models': [
            for (final model in entries.single.models ?? const [])
              model.toJson(),
          ],
        };
      case 'inspect_provider':
        return _inspectProvider(arguments);
      default:
        throw StateError('Unknown tool: $name');
    }
  }

  Future<Map<String, Object?>> _speak(
    Map<String, Object?> arguments,
    String? callerAgentId,
    VoiceAbortSignal? signal,
  ) async {
    if (callerAgentId == null) {
      throw StateError('speak is only available to agent-scoped tool sessions');
    }
    final text = _requiredString(arguments, 'text');
    if (text.length > 4000) {
      throw const FormatException('text must be 4000 characters or fewer');
    }
    final handler = _voiceBridge.resolveSpeakHandler(callerAgentId);
    if (handler == null) {
      throw StateError(
        "No speak handler registered for your session '$callerAgentId'",
      );
    }
    await handler(text: text, callerAgentId: callerAgentId, signal: signal);
    return {'ok': true};
  }

  Future<Map<String, Object?>> _renameWorkspace(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    final requestedWorkspaceId = _nullableString(arguments, 'workspaceId');
    late final String workspaceId;
    if (requestedWorkspaceId != null) {
      workspaceId = requestedWorkspaceId;
    } else if (callerAgentId != null) {
      final caller = _manager.get(callerAgentId);
      if (caller == null || caller.archivedAt != null) {
        throw StateError('Caller agent $callerAgentId not found');
      }
      final currentWorkspaceId = caller.workspaceId;
      if (currentWorkspaceId == null) {
        throw StateError(
          'Caller agent $callerAgentId has no current workspace',
        );
      }
      workspaceId = currentWorkspaceId;
    } else {
      throw StateError(
        'workspaceId is required outside an agent-scoped session',
      );
    }
    final title = _requiredString(arguments, 'title');
    await _workspaceService().renameAutomationWorkspace(workspaceId, title);
    return {'success': true, 'workspaceId': workspaceId, 'title': title};
  }

  Future<Map<String, Object?>> _listWorkspaceScripts(
    Map<String, Object?> arguments,
  ) async {
    final scripts = await _workspaceScripts().list(
      _requiredString(arguments, 'workspaceId'),
    );
    return {
      'scripts': [for (final script in scripts) script.toJson()],
    };
  }

  Future<Map<String, Object?>> _startWorkspaceScript(
    Map<String, Object?> arguments,
  ) async {
    final script = await _workspaceScripts().launch(
      workspaceId: _requiredString(arguments, 'workspaceId'),
      scriptName: _requiredString(arguments, 'scriptName'),
    );
    return {'script': script.toJson()};
  }

  Future<Map<String, Object?>> _stopWorkspaceScript(
    Map<String, Object?> arguments,
  ) async {
    final script = await _workspaceScripts().stop(
      workspaceId: _requiredString(arguments, 'workspaceId'),
      scriptName: _requiredString(arguments, 'scriptName'),
    );
    return {'script': script.toJson()};
  }

  Map<String, Object?> _listTerminals(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) {
    final all = _optionalBool(arguments, 'all') ?? false;
    if (all) _optionalTrimmedString(arguments, 'cwd');
    final terminals = all
        ? _terminals.listV2()
        : _terminals.listV2(cwd: _resolveScopedCwd(arguments, callerAgentId));
    return {
      'terminals': [
        for (final terminal in terminals) _terminalSummary(terminal),
      ],
    };
  }

  Future<Map<String, Object?>> _createTerminal(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    final cwd = _resolveScopedCwd(arguments, callerAgentId);
    final caller = callerAgentId == null
        ? null
        : _requireCallerAgent(callerAgentId);
    final workspaceId =
        caller?.workspaceId ??
        (await _workspaceService().createAutomationWorkspace(
          DirectoryWorkspaceCreateSource(path: cwd),
        )).workspaceId;
    final created = _terminals.create(
      cwd: cwd,
      workspaceId: workspaceId,
      name: _optionalTrimmedString(arguments, 'name'),
    );
    final terminalId = created['terminalId']! as String;
    final terminal = _terminals.listV2().singleWhere(
      (candidate) => candidate['id'] == terminalId,
    );
    return _terminalSummary(terminal);
  }

  Map<String, Object?> _killTerminal(Map<String, Object?> arguments) {
    final terminalId = _requiredRawString(arguments, 'terminalId');
    _requireTerminal(terminalId);
    _terminals.kill(terminalId);
    return {'success': true};
  }

  Map<String, Object?> _captureTerminal(Map<String, Object?> arguments) {
    final terminalId = _requiredRawString(arguments, 'terminalId');
    _requireTerminal(terminalId);
    final start = _optionalLineIndex(arguments, 'start');
    final end = _optionalLineIndex(arguments, 'end');
    final scrollback = _optionalBool(arguments, 'scrollback') ?? false;
    final capture = _terminals.capture(
      terminalId,
      start: scrollback ? 0 : start,
      end: end,
      stripAnsi: _optionalBool(arguments, 'stripAnsi') ?? true,
    );
    return {
      'terminalId': terminalId,
      'lines': capture.lines,
      'totalLines': capture.totalLines,
    };
  }

  Map<String, Object?> _sendTerminalKeys(Map<String, Object?> arguments) {
    final terminalId = _requiredRawString(arguments, 'terminalId');
    _requireTerminal(terminalId);
    final literal = _optionalBool(arguments, 'literal') ?? false;
    _terminals.sendInput(
      terminalId,
      _resolveTerminalKeyToken(_requiredRawString(arguments, 'keys'), literal),
    );
    return {'success': true};
  }

  Future<Map<String, Object?>> _createSchedule(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    final prompt = _requiredString(arguments, 'prompt');
    final cron = _requiredString(arguments, 'cron');
    final timezone = _optionalTrimmedString(arguments, 'timezone');
    final name = _optionalTrimmedString(arguments, 'name');
    final maxRuns = _optionalPositiveInt(arguments, 'maxRuns');
    final expiresAt = _expiresAt(arguments);
    final isolation = _optionalTrimmedString(arguments, 'isolation');
    if (isolation != null && isolation != 'local' && isolation != 'worktree') {
      throw const FormatException('isolation must be local or worktree');
    }

    late final ScheduleNewAgentConfig config;
    if (callerAgentId != null) {
      final caller = _requireCallerAgent(callerAgentId);
      final providerInput = _optionalTrimmedString(arguments, 'provider');
      final pair = providerInput == null
          ? (provider: caller.provider, model: caller.model as String?)
          : _parseProvider(providerInput);
      config = ScheduleNewAgentConfig(
        provider: pair.provider,
        cwd: arguments.containsKey('cwd')
            ? _expandUserPath(_requiredString(arguments, 'cwd'))
            : caller.cwd,
        model: pair.model,
        modeId: pair.provider == caller.provider ? caller.currentModeId : null,
        thinkingOptionId: caller.thinkingOptionId,
        isolation: isolation,
        featureValues: caller.featureValues.isEmpty
            ? null
            : caller.featureValues,
        mcpServers: _manager.mcpServersFor(callerAgentId).isEmpty
            ? null
            : _manager.mcpServersFor(callerAgentId),
      );
    } else {
      final providerInput = _optionalTrimmedString(arguments, 'provider');
      if (providerInput == null) {
        throw const FormatException('provider is required');
      }
      final pair = _parseProvider(providerInput);
      config = ScheduleNewAgentConfig(
        provider: pair.provider,
        cwd: arguments.containsKey('cwd')
            ? _expandUserPath(_requiredString(arguments, 'cwd'))
            : Directory.current.path,
        model: pair.model,
        isolation: isolation,
      );
    }
    final schedule = await _schedules().createOrReplace(
      ScheduleCreateRequest(
        requestId: 'mcp',
        prompt: prompt,
        name: name,
        cadence: CronScheduleCadence(expression: cron, timezone: timezone),
        target: NewAgentScheduleTarget(config: config),
        maxRuns: maxRuns,
        expiresAt: expiresAt,
      ),
    );
    return schedule.summary.toJson();
  }

  Future<Map<String, Object?>> _createHeartbeat(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    if (callerAgentId == null) {
      throw StateError('create_heartbeat requires an agent-scoped session');
    }
    _requireCallerAgent(callerAgentId);
    final schedule = await _schedules().createOrReplace(
      ScheduleCreateRequest(
        requestId: 'mcp',
        prompt: _requiredString(arguments, 'prompt'),
        name: _optionalTrimmedString(arguments, 'name'),
        cadence: CronScheduleCadence(
          expression: _requiredString(arguments, 'cron'),
          timezone: _optionalTrimmedString(arguments, 'timezone'),
        ),
        target: AgentScheduleTarget(agentId: callerAgentId),
        maxRuns: _optionalPositiveInt(arguments, 'maxRuns'),
        expiresAt: _expiresAt(arguments),
      ),
    );
    return schedule.summary.toJson();
  }

  Future<Map<String, Object?>> _deleteHeartbeat(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    if (callerAgentId == null) {
      throw StateError('Heartbeat operations require an agent-scoped session');
    }
    final id = _requiredString(arguments, 'id');
    final schedule = await _schedules().inspect(id);
    final target = schedule.summary.target;
    if (target is! AgentScheduleTarget) {
      throw StateError('Heartbeat not found: $id');
    }
    if (target.agentId != callerAgentId) {
      throw StateError(
        'Heartbeat $id does not belong to caller $callerAgentId',
      );
    }
    await _schedules().delete(id);
    return {'success': true};
  }

  Future<Map<String, Object?>> _listSchedules() async => {
    'schedules': [
      for (final schedule in await _schedules().list())
        if (schedule.summary.target is NewAgentScheduleTarget)
          schedule.summary.toJson(),
    ],
  };

  Future<Map<String, Object?>> _inspectSchedule(
    Map<String, Object?> arguments,
  ) async => (await _requireNewAgentSchedule(arguments)).toJson();

  Future<Map<String, Object?>> _pauseSchedule(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    await _schedules().pause(schedule.summary.id);
    return {'success': true};
  }

  Future<Map<String, Object?>> _resumeSchedule(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    await _schedules().resume(schedule.summary.id);
    return {'success': true};
  }

  Future<Map<String, Object?>> _deleteSchedule(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    await _schedules().delete(schedule.summary.id);
    return {'success': true};
  }

  Future<Map<String, Object?>> _scheduleLogs(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    return {
      'runs': [
        for (final run in await _schedules().logs(schedule.summary.id))
          run.toJson(),
      ],
    };
  }

  Future<Map<String, Object?>> _runScheduleOnce(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    return (await _schedules().runOnce(schedule.summary.id)).toJson();
  }

  Future<Map<String, Object?>> _updateSchedule(
    Map<String, Object?> arguments,
  ) async {
    final schedule = await _requireNewAgentSchedule(arguments);
    final changes = <String, Object?>{};
    if (arguments.containsKey('name')) {
      final value = arguments['name'];
      if (value != null && value is! String) {
        throw const FormatException('name must be a string or null');
      }
      changes['name'] = value == null ? null : (value as String).trim();
    }
    if (arguments.containsKey('prompt')) {
      changes['prompt'] = _requiredString(arguments, 'prompt');
    }
    final hasEvery = arguments.containsKey('every');
    final hasCron = arguments.containsKey('cron');
    if (hasEvery && hasCron) {
      throw const FormatException('Specify at most one of every or cron');
    }
    if (arguments.containsKey('timezone') && !hasCron) {
      throw const FormatException('timezone requires cron');
    }
    if (hasEvery) {
      final every = _requiredString(arguments, 'every');
      final cron = everyMsToFiveFieldCron(_parseDurationMs(every));
      if (cron == null) {
        throw FormatException(
          'Interval $every cannot be represented by a five-field cron',
        );
      }
      changes['cadence'] = CronScheduleCadence(expression: cron).toJson();
    } else if (hasCron) {
      changes['cadence'] = CronScheduleCadence(
        expression: _requiredString(arguments, 'cron'),
        timezone: _optionalTrimmedString(arguments, 'timezone'),
      ).toJson();
    }
    if (arguments.containsKey('maxRuns')) {
      changes['maxRuns'] = _nullablePositiveInt(arguments, 'maxRuns');
    }
    final clearExpires = _optionalBool(arguments, 'clearExpires') ?? false;
    if (arguments.containsKey('expiresIn') && clearExpires) {
      throw const FormatException(
        'expiresIn and clearExpires cannot be used together',
      );
    }
    if (arguments.containsKey('expiresIn')) {
      changes['expiresAt'] = _expiresAt(arguments);
    } else if (clearExpires) {
      changes['expiresAt'] = null;
    }
    final config = <String, Object?>{};
    _applyProviderUpdate(arguments, config);
    for (final entry in const {'mode': 'modeId', 'cwd': 'cwd'}.entries) {
      if (!arguments.containsKey(entry.key)) continue;
      final value = arguments[entry.key];
      if (value == null && entry.key == 'mode') {
        config[entry.value] = null;
      } else {
        config[entry.value] = _requiredString(arguments, entry.key);
      }
    }
    if (config.isNotEmpty) changes['newAgentConfig'] = config;
    final updated = await _schedules().update(
      ScheduleUpdateRequest(
        requestId: 'mcp',
        scheduleId: schedule.summary.id,
        changes: changes,
      ),
    );
    return updated.toJson();
  }

  Future<StoredSchedule> _requireNewAgentSchedule(
    Map<String, Object?> arguments,
  ) async {
    final id = _requiredString(arguments, 'id');
    final schedule = await _schedules().inspect(id);
    if (schedule.summary.target is! NewAgentScheduleTarget) {
      throw StateError('Schedule not found: $id');
    }
    return schedule;
  }

  String? _expiresAt(Map<String, Object?> arguments) {
    final value = _optionalTrimmedString(arguments, 'expiresIn');
    if (value == null) return null;
    return DateTime.now()
        .toUtc()
        .add(Duration(milliseconds: _parseDurationMs(value)))
        .toIso8601String();
  }

  void _applyProviderUpdate(
    Map<String, Object?> arguments,
    Map<String, Object?> config,
  ) {
    final hasProvider = arguments.containsKey('provider');
    final hasModel = arguments.containsKey('model');
    final modelValue = arguments['model'];
    if (hasModel && modelValue != null) {
      config['model'] = _requiredString(arguments, 'model');
    } else if (hasModel) {
      config['model'] = null;
    }
    if (!hasProvider) return;
    final providerInput = _requiredString(arguments, 'provider');
    final slash = providerInput.indexOf('/');
    if (slash < 0) {
      config['provider'] = providerInput;
      return;
    }
    final pair = _parseProvider(providerInput);
    if (hasModel && modelValue == null) {
      throw const FormatException(
        'model cannot be null when provider includes a model',
      );
    }
    if (hasModel && config['model'] != pair.model) {
      throw const FormatException('provider model conflicts with model');
    }
    config['provider'] = pair.provider;
    config['model'] = pair.model;
  }

  String _resolveScopedCwd(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) {
    final requested = _optionalTrimmedString(arguments, 'cwd');
    if (callerAgentId != null) {
      final caller = _requireCallerAgent(callerAgentId);
      return requested == null
          ? caller.cwd
          : _resolvePathFromBase(caller.cwd, requested);
    }
    if (requested == null) {
      throw const FormatException('cwd is required');
    }
    return _expandUserPath(requested);
  }

  AgentSummary _requireCallerAgent(String callerAgentId) {
    final caller = _manager.get(callerAgentId);
    if (caller == null || caller.archivedAt != null) {
      throw StateError('Parent agent $callerAgentId not found');
    }
    return caller;
  }

  void _requireTerminal(String terminalId) {
    if (!_terminals.contains(terminalId)) {
      throw StateError('Terminal $terminalId not found');
    }
  }

  Future<Map<String, Object?>> _createWorkspace(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    final isolation = _requiredString(arguments, 'isolation');
    if (isolation != 'local' && isolation != 'worktree') {
      throw const FormatException('isolation must be local or worktree');
    }
    final caller = callerAgentId == null ? null : _manager.get(callerAgentId);
    if (callerAgentId != null && caller == null) {
      throw StateError('Caller agent $callerAgentId not found');
    }
    final path = _nullableString(arguments, 'path') ?? caller?.cwd;
    final projectId = _nullableString(arguments, 'projectId');
    final title = _nullableString(arguments, 'title');
    final workspaces = _workspaceService();
    late final PersistedWorkspaceRecord workspace;
    if (isolation == 'local') {
      _requireAbsent(arguments, const [
        'mode',
        'worktreeSlug',
        'branchName',
        'baseBranch',
        'branch',
        'prNumber',
        'forge',
      ], 'Worktree options require isolation worktree');
      workspace = await workspaces.createAutomationWorkspace(
        DirectoryWorkspaceCreateSource(
          path: path ?? p.current,
          projectId: projectId,
        ),
        title: title,
      );
    } else {
      final mode = _nullableString(arguments, 'mode') ?? 'branch-off';
      if (!const {
        'branch-off',
        'checkout-branch',
        'checkout-pr',
      }.contains(mode)) {
        throw const FormatException(
          'mode must be branch-off, checkout-branch, or checkout-pr',
        );
      }
      final worktreeSlug = _nullableString(arguments, 'worktreeSlug');
      final branchName = _nullableString(arguments, 'branchName');
      final baseBranch = _nullableString(arguments, 'baseBranch');
      final branch = _nullableString(arguments, 'branch');
      final prNumber = mode == 'checkout-pr'
          ? _boundedInt(arguments, 'prNumber', 0, 1, 0x7fffffff)
          : null;
      final forge = _nullableString(arguments, 'forge');
      if (mode == 'checkout-branch' && branch == null) {
        throw const FormatException(
          'branch is required for checkout-branch mode',
        );
      }
      workspace = await workspaces.createAutomationWorkspace(
        WorktreeWorkspaceCreateSource(
          cwd: path ?? (projectId == null ? p.current : null),
          projectId: projectId,
          action: mode == 'branch-off'
              ? WorktreeCreateAction.branchOff
              : WorktreeCreateAction.checkout,
          refName: mode == 'checkout-branch' ? branch : baseBranch,
          baseBranch: baseBranch,
          branchName: mode == 'checkout-pr'
              ? null
              : mode == 'checkout-branch'
              ? branch
              : branchName,
          checkoutSource: prNumber == null
              ? null
              : {
                  'kind': 'change_request',
                  if (forge != null) 'forge': forge,
                  'number': prNumber,
                },
          worktreeSlug: worktreeSlug,
        ),
        title: title,
      );
    }
    return _workspaceSummary(workspace);
  }

  Future<Map<String, Object?>> _listWorkspaces() async => {
    'workspaces': [
      for (final workspace
          in await _workspaceService().listActiveAutomationWorkspaces())
        _workspaceSummary(workspace),
    ],
  };

  Future<Map<String, Object?>> _archiveWorkspace(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspaceId');
    await _workspaceService().requireActiveAutomationWorkspace(workspaceId);
    final archivedAgentIds = await _manager.archiveWorkspaceAgents(workspaceId);
    final terminalIds = [
      for (final terminal in _terminals.listV2(workspaceId: workspaceId))
        terminal['id']! as String,
    ];
    for (final terminalId in terminalIds) {
      try {
        await _terminals.killAndWait(terminalId);
      } on Object {
        // Paseo treats owned-content teardown as best effort and still
        // archives the durable workspace record.
      }
    }
    final result = await _workspaceService().archiveAutomationWorkspace(
      workspaceId,
    );
    return {
      'workspaceId': workspaceId,
      'archivedAgentIds': archivedAgentIds,
      'removedDirectory': result.removedDirectory,
    };
  }

  Future<Map<String, Object?>> _createAgent(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    validateCreateAgentArguments(arguments, agentScoped: callerAgentId != null);
    final title = _requiredString(arguments, 'title');
    if (title.length > 60) {
      throw const FormatException('title must be at most 60 characters');
    }
    final providerPair = _requiredString(arguments, 'provider');
    final separator = providerPair.indexOf('/');
    if (separator <= 0 || separator == providerPair.length - 1) {
      throw const FormatException('provider must be <provider>/<model>');
    }
    final provider = providerPair.substring(0, separator);
    final model = providerPair.substring(separator + 1);
    final initialPrompt = _requiredString(arguments, 'initialPrompt');
    final labelsRaw = _optionalMap(arguments, 'labels') ?? const {};
    if (labelsRaw.values.any((value) => value is! String)) {
      throw const FormatException('labels must contain string values');
    }
    final caller = callerAgentId == null ? null : _manager.get(callerAgentId);
    if (callerAgentId != null && caller == null) {
      throw StateError('Caller agent $callerAgentId not found');
    }
    final placement = await _resolveMcpCreatePlacement(
      arguments,
      callerAgentId: callerAgentId,
      caller: caller,
      initialPrompt: initialPrompt,
    );
    final settings = placement.settings;
    final features = _optionalMap(settings, 'features') ?? const {};
    final modeId = _nullableString(settings, 'modeId');
    final thinkingOptionId = _nullableString(settings, 'thinkingOptionId');
    final workspaces = _workspaceService();
    final intent = await resolveCreateAgentIntent(
      explicitWorkspaceId: placement.workspace.workspaceId,
      caller: caller == null
          ? null
          : CreateAgentCaller(
              id: caller.agentId,
              cwd: caller.cwd,
              workspaceId: caller.workspaceId,
            ),
      labels: labelsRaw.cast<String, String>(),
      childAgentDefaultLabels: callerAgentId == null
          ? null
          : _voiceBridge
                .resolveCallerContext(callerAgentId)
                ?.childAgentDefaultLabels,
      resolveWorkspace: (workspaceId) async {
        final workspace = workspaceId == placement.workspace.workspaceId
            ? placement.workspace
            : await workspaces.requireActiveAutomationWorkspace(workspaceId);
        return CreateAgentPlacement(
          workspaceId: workspace.workspaceId,
          cwd: placement.runtimeCwd,
        );
      },
      createWorkspace: () => throw StateError(
        'create_agent placement must resolve before agent creation',
      ),
      legacyDetached: placement.detached,
    );
    final workspace = placement.workspace;
    final requestedBackground = _nullableBool(arguments, 'background') ?? false;
    final background = callerAgentId != null || requestedBackground;
    final notifyOnFinish =
        _nullableBool(arguments, 'notifyOnFinish') ?? callerAgentId != null;
    String? createdAgentId;
    late final AgentSummary agent;
    try {
      final resolvedConfig = await _providerCatalog.resolveCreateAgentConfig(
        AgentCreateConfigRequest(
          cwd: intent.cwd,
          targetProvider: provider,
          requestedMode: modeId,
          featureValues: features,
          parent: caller == null
              ? null
              : _providerCatalog.createAgentModeParent(caller),
          unattended: false,
        ),
      );
      agent = await _manager.createAgent(
        cwd: intent.cwd,
        provider: provider,
        model: model,
        mode: _agentMode(resolvedConfig.modeId),
        modeId: resolvedConfig.modeId,
        thinkingOptionId: thinkingOptionId,
        featureValues: resolvedConfig.featureValues,
        title: title,
        workspaceId: intent.workspaceId,
        projectPath: workspace.mainRepoRoot,
        branch: workspace.branch,
        isWorktree: workspace.isPaseoOwnedWorktree,
        parentAgentId: intent.parentAgentId,
        labels: intent.labels,
      );
      createdAgentId = agent.agentId;
      if (placement.createdWorktree) {
        workspaces.startAgentContinuation(agent);
      }
      unawaited(_manager.prompt(agent.agentId, initialPrompt));
    } catch (_) {
      if (placement.createdWorktree && createdAgentId == null) {
        await workspaces.cancelAgentContinuation(workspace.workspaceId);
      }
      rethrow;
    }
    final notificationParentId = intent.parentAgentId;
    final shouldNotify =
        notificationParentId != null && background && notifyOnFinish;
    if (shouldNotify) {
      unawaited(
        _notifyCallerWhenAgentStops(agent.agentId, notificationParentId),
      );
    }
    if (!background) {
      final waited = await _waitForAgent(agent.agentId);
      final snapshot = _snapshot(agent.agentId);
      return _createdAgentResult(
        snapshot,
        lastMessage: waited['lastMessage'],
        permission: waited['permission'],
      );
    }
    final snapshot = _snapshot(agent.agentId);
    return _createdAgentResult(
      snapshot,
      guidance: shouldNotify
          ? 'You will get notified when the created agent finishes, errors, '
                'or needs permission. Do not poll for status; continue with '
                'other work until the notification arrives.'
          : null,
    );
  }

  Future<_ResolvedMcpCreatePlacement> _resolveMcpCreatePlacement(
    Map<String, Object?> arguments, {
    required String? callerAgentId,
    required AgentSummary? caller,
    required String initialPrompt,
  }) async {
    final legacy = hasLegacyCreateAgentPlacement(arguments);
    final settings = _normalizedCreateAgentSettings(arguments, legacy: legacy);
    if (!legacy) {
      final requestedWorkspaceId = _nullableString(arguments, 'workspaceId');
      if (requestedWorkspaceId != null) {
        final workspace = await _workspaceService()
            .requireActiveAutomationWorkspace(requestedWorkspaceId);
        return _ResolvedMcpCreatePlacement(
          workspace: workspace,
          runtimeCwd: workspace.cwd,
          detached: false,
          settings: settings,
          createdWorktree: false,
        );
      }
      if (caller != null) {
        final workspaceId = caller.workspaceId;
        if (workspaceId == null || workspaceId.isEmpty) {
          throw StateError(
            'Caller agent ${caller.agentId} has no current workspace',
          );
        }
        final workspace = await _workspaceService()
            .requireActiveAutomationWorkspace(workspaceId);
        return _ResolvedMcpCreatePlacement(
          workspace: workspace,
          runtimeCwd: caller.cwd,
          detached: false,
          settings: settings,
          createdWorktree: false,
        );
      }
      final workspace = await _createMcpDirectoryWorkspace(
        Directory.current.path,
        initialPrompt,
      );
      return _ResolvedMcpCreatePlacement(
        workspace: workspace,
        runtimeCwd: workspace.cwd,
        detached: false,
        settings: settings,
        createdWorktree: false,
      );
    }

    Map<String, Object?> relationship;
    Map<String, Object?> workspaceInput;
    if (arguments.containsKey('relationship') ||
        arguments.containsKey('workspace')) {
      if (!arguments.containsKey('relationship') ||
          !arguments.containsKey('workspace')) {
        throw StateError(
          'relationship and workspace must be provided together',
        );
      }
      relationship = _requiredMap(arguments, 'relationship');
      workspaceInput = _requiredMap(arguments, 'workspace');
    } else {
      if (callerAgentId != null) {
        throw StateError(
          'relationship and workspace must be provided together',
        );
      }
      final cwd = _nullableString(arguments, 'cwd');
      if (cwd == null) {
        throw StateError(
          'cwd is required for legacy top-level create_agent calls',
        );
      }
      relationship = const {'kind': 'detached'};
      workspaceInput = _legacyFlatWorkspaceInput(arguments, cwd);
    }

    final relationshipKind = _requiredString(relationship, 'kind');
    final detached = switch (relationshipKind) {
      'detached' => true,
      'subagent' when callerAgentId != null => false,
      'subagent' => throw StateError(
        'relationship subagent requires an agent-scoped tool session',
      ),
      _ => throw FormatException(
        'Unknown agent relationship: $relationshipKind',
      ),
    };
    return _resolveLegacyWorkspacePlacement(
      workspaceInput,
      callerAgentId: callerAgentId,
      caller: caller,
      detached: detached,
      settings: settings,
      initialPrompt: initialPrompt,
    );
  }

  Future<_ResolvedMcpCreatePlacement> _resolveLegacyWorkspacePlacement(
    Map<String, Object?> workspaceInput, {
    required String? callerAgentId,
    required AgentSummary? caller,
    required bool detached,
    required Map<String, Object?> settings,
    required String initialPrompt,
  }) async {
    final kind = _requiredString(workspaceInput, 'kind');
    final callerContext = callerAgentId == null
        ? null
        : _voiceBridge.resolveCallerContext(callerAgentId);
    switch (kind) {
      case 'current':
        if (caller == null) {
          throw StateError(
            'workspace current requires an agent-scoped tool session',
          );
        }
        final workspaceId = caller.workspaceId;
        if (workspaceId == null || workspaceId.isEmpty) {
          throw StateError(
            'Caller agent ${caller.agentId} has no current workspace',
          );
        }
        final workspace = await _workspaceService()
            .requireActiveAutomationWorkspace(workspaceId);
        return _ResolvedMcpCreatePlacement(
          workspace: workspace,
          runtimeCwd: _resolveCreateAgentRuntimeCwd(
            workspaceInput,
            caller: caller,
            callerContext: callerContext,
            fallback: caller.cwd,
          ),
          detached: detached,
          settings: settings,
          createdWorktree: false,
        );
      case 'existing':
        final workspaceId = _requiredString(workspaceInput, 'workspaceId');
        final workspace = await _workspaceService()
            .requireActiveAutomationWorkspace(workspaceId);
        final runtimeCwd = _resolveCreateAgentRuntimeCwd(
          workspaceInput,
          caller: caller,
          callerContext: callerContext,
          fallback: workspace.cwd,
        );
        _requireAllowedCreateAgentCwd(runtimeCwd, callerContext?.lockedCwd);
        return _ResolvedMcpCreatePlacement(
          workspace: workspace,
          runtimeCwd: runtimeCwd,
          detached: detached,
          settings: settings,
          createdWorktree: false,
        );
      case 'create':
        final source = _requiredMap(workspaceInput, 'source');
        final sourceKind = _requiredString(source, 'kind');
        if (sourceKind == 'directory') {
          final path = _resolveCreateAgentSourceCwd(
            _nullableString(source, 'path'),
            caller: caller,
            callerContext: callerContext,
          );
          final workspace = await _createMcpDirectoryWorkspace(
            path,
            initialPrompt,
          );
          return _ResolvedMcpCreatePlacement(
            workspace: workspace,
            runtimeCwd: workspace.cwd,
            detached: detached,
            settings: settings,
            createdWorktree: false,
          );
        }
        if (sourceKind != 'worktree') {
          throw FormatException(
            'Unknown create_agent workspace source: $sourceKind',
          );
        }
        final cwd = _resolveCreateAgentSourceCwd(
          _nullableString(source, 'cwd'),
          caller: caller,
          callerContext: callerContext,
        );
        final worktreeSource = _createAgentWorktreeSource(
          cwd,
          _requiredMap(source, 'target'),
          initialPrompt,
        );
        final workspace = await _workspaceService().createAutomationWorkspace(
          worktreeSource,
          title: resolveFirstAgentPromptTitle({'prompt': initialPrompt}),
          firstAgentContext: {'prompt': initialPrompt},
        );
        return _ResolvedMcpCreatePlacement(
          workspace: workspace,
          runtimeCwd: workspace.cwd,
          detached: detached,
          settings: settings,
          createdWorktree: true,
        );
      default:
        throw FormatException('Unknown create_agent workspace kind: $kind');
    }
  }

  Future<PersistedWorkspaceRecord> _createMcpDirectoryWorkspace(
    String cwd,
    String initialPrompt,
  ) => _workspaceService().createAutomationWorkspace(
    DirectoryWorkspaceCreateSource(path: cwd),
    title: resolveFirstAgentPromptTitle({'prompt': initialPrompt}),
    firstAgentContext: {'prompt': initialPrompt},
  );

  String _resolveCreateAgentRuntimeCwd(
    Map<String, Object?> input, {
    required AgentSummary? caller,
    required VoiceCallerContext? callerContext,
    required String fallback,
  }) {
    final requested = _nullableString(input, 'cwd');
    if (caller == null) {
      return requested == null ? fallback : _expandUserPath(requested);
    }
    final locked = callerContext?.lockedCwd?.trim();
    if (locked?.isNotEmpty == true) return _expandUserPath(locked!);
    if (requested == null || callerContext?.allowCustomCwd == false) {
      return fallback;
    }
    return _resolvePathFromBase(caller.cwd, requested);
  }

  String _resolveCreateAgentSourceCwd(
    String? requested, {
    required AgentSummary? caller,
    required VoiceCallerContext? callerContext,
  }) {
    final resolved = caller == null
        ? _expandUserPath(requested ?? Directory.current.path)
        : _resolveCreateAgentRuntimeCwd(
            {'cwd': requested},
            caller: caller,
            callerContext: callerContext,
            fallback: caller.cwd,
          );
    _requireAllowedCreateAgentCwd(resolved, callerContext?.lockedCwd);
    return resolved;
  }

  WorktreeWorkspaceCreateSource _createAgentWorktreeSource(
    String cwd,
    Map<String, Object?> target,
    String _,
  ) {
    final kind = _requiredString(target, 'kind');
    return switch (kind) {
      'branch-off' => WorktreeWorkspaceCreateSource(
        cwd: cwd,
        action: WorktreeCreateAction.branchOff,
        branchName: _nullableString(target, 'branchName'),
        baseBranch: _nullableString(target, 'baseBranch'),
        refName: _nullableString(target, 'baseBranch'),
        worktreeSlug: _nullableString(target, 'worktreeSlug'),
      ),
      'checkout-branch' => WorktreeWorkspaceCreateSource(
        cwd: cwd,
        action: WorktreeCreateAction.checkout,
        branchName: _requiredString(target, 'branch'),
        refName: _requiredString(target, 'branch'),
      ),
      'checkout-pr' => WorktreeWorkspaceCreateSource(
        cwd: cwd,
        action: WorktreeCreateAction.checkout,
        githubPrNumber: _positiveInt(target, 'githubPrNumber'),
      ),
      _ => throw FormatException('Unknown create_agent worktree target: $kind'),
    };
  }

  Future<Map<String, Object?>> _waitForAgent(String agentId) async {
    try {
      final result = await _manager.waitForAgentEvent(
        agentId,
        waitForActive: true,
        timeout: agentWaitTimeout,
      );
      return {
        'success': true,
        'status': _status(result.summary),
        'lastMessage': result.lastMessage,
        'permission': result.permission == null
            ? null
            : _permissionRequest(result.summary, result.permission!),
      };
    } on TimeoutException {
      final canonical = _manager.fetchCanonicalTimeline(agentId);
      final items = [for (final row in canonical.rows) row.item];
      final recent = selectTimelineItemsByProjectedLimit(
        items: items,
        direction: 'tail',
        limit: 5,
      );
      final waitedSeconds = agentWaitTimeout.inSeconds;
      return {
        'success': true,
        'status': _status(canonical.agent),
        'lastMessage':
            'Awaiting the agent timed out after ${waitedSeconds}s. '
            'This does not mean the agent failed - it is still running. '
            'Call get_agent_status to check on it, or continue with other '
            'work if you will receive a finish notification.\n\n'
            'Recent activity:\n${curateAgentActivity(recent.items)}',
        'permission': null,
      };
    }
  }

  Future<void> _notifyCallerWhenAgentStops(
    String childAgentId,
    String callerAgentId,
  ) async {
    try {
      final result = await _manager.waitForAgentEvent(
        childAgentId,
        waitForActive: true,
      );
      final caller = _manager.get(callerAgentId);
      if (caller == null || caller.archivedAt != null) return;
      final child = result.summary;
      final reason = result.permission != null
          ? 'needs permission'
          : child.runState == AgentRunState.error
          ? 'errored'
          : child.runState == AgentRunState.closed
          ? null
          : 'finished';
      if (reason == null) return;
      final statusLine = 'Agent $childAgentId (${child.title}) $reason.';
      final response = result.lastMessage?.trim();
      final body = response == null || response.isEmpty
          ? statusLine
          : '$statusLine\n\n<agent-response>\n$response\n</agent-response>';
      await _manager.prompt(
        callerAgentId,
        '<paseo-system>\n$body\n</paseo-system>',
      );
    } on Object {
      // Finish notifications are best-effort and must not fail the MCP call.
    }
  }

  Map<String, Object?> _listAgents(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) {
    final includeArchived = arguments['includeArchived'] as bool? ?? false;
    final explicitCwd = arguments['cwd'] as String?;
    final callerCwd = callerAgentId == null
        ? null
        : _manager.get(callerAgentId)?.cwd;
    final cwd = explicitCwd?.trim().isNotEmpty == true
        ? explicitCwd!.trim()
        : callerCwd;
    final sinceHours = _boundedInt(arguments, 'sinceHours', 48, 1, 720);
    final limit = _boundedInt(arguments, 'limit', 50, 1, 200);
    final statuses = arguments['statuses'];
    if (statuses != null &&
        (statuses is! List || statuses.any((value) => value is! String))) {
      throw const FormatException('statuses must be an array of strings');
    }
    final statusFilter = statuses == null
        ? null
        : Set<String>.from((statuses as List).cast<String>());
    final since = DateTime.now()
        .subtract(Duration(hours: sinceHours))
        .millisecondsSinceEpoch;
    final agents = <Map<String, Object?>>[];
    for (final agent in _manager.list(includeArchived: includeArchived)) {
      final snapshot = _encodeSnapshot(agent);
      if (cwd != null && !_sameOrDescendant(cwd, agent.cwd)) continue;
      if (statusFilter != null &&
          statusFilter.isNotEmpty &&
          !statusFilter.contains(snapshot['status'])) {
        continue;
      }
      if (agent.archivedAt != null && _activityTime(agent) < since) continue;
      agents.add(_listItem(snapshot));
    }
    agents.sort(_compareListItems);
    return {'agents': agents.take(limit).toList(growable: false)};
  }

  Future<Map<String, Object?>> _updateAgent(
    Map<String, Object?> arguments,
  ) async {
    final agentId = _requiredString(arguments, 'agentId');
    final settings = _optionalMap(arguments, 'settings');
    if (settings != null) {
      if (settings.containsKey('modeId')) {
        await _manager.setModeId(agentId, _requiredString(settings, 'modeId'));
      }
      if (settings.containsKey('model')) {
        await _manager.setModelId(agentId, _nullableString(settings, 'model'));
      }
      if (settings.containsKey('thinkingOptionId')) {
        await _manager.setThinkingOption(
          agentId,
          _nullableString(settings, 'thinkingOptionId'),
        );
      }
      final features = _optionalMap(settings, 'features');
      if (features != null) {
        for (final entry in features.entries) {
          await _manager.setFeature(agentId, entry.key, entry.value);
        }
      }
    }
    if (arguments['name'] case final String name) {
      await _manager.rename(agentId, name);
    } else if (arguments.containsKey('name')) {
      throw const FormatException('name must be a string');
    }
    final labels = _optionalMap(arguments, 'labels');
    if (labels != null) {
      if (labels.values.any((value) => value is! String)) {
        throw const FormatException('labels must contain string values');
      }
      await _manager.setLabels(agentId, labels.cast<String, String>());
    }
    return {'success': true};
  }

  Map<String, Object?> _getAgentActivity(Map<String, Object?> arguments) {
    final agentId = _requiredString(arguments, 'agentId');
    final canonical = _manager.fetchCanonicalTimeline(agentId);
    final rawItems = [for (final row in canonical.rows) row.item];
    final limit = arguments['limit'] == null
        ? 0
        : _boundedInt(arguments, 'limit', 0, 0, 1000000);
    final selection = selectTimelineItemsByProjectedLimit(
      items: rawItems,
      direction: 'tail',
      limit: limit,
    );
    final total = selection.totalProjected;
    final noun = total == 1 ? 'activity' : 'activities';
    final header = limit > 0 && selection.shownProjected < total
        ? 'Showing ${selection.shownProjected} of $total $noun '
              '(limited to $limit)'
        : 'Showing all $total $noun';
    return {
      'agentId': agentId,
      'updateCount': rawItems.length,
      'currentModeId': canonical.agent.currentModeId,
      'content': '$header\n\n${curateAgentActivity(selection.items)}',
    };
  }

  Map<String, Object?> _listPendingPermissions() {
    final permissions = <Map<String, Object?>>[];
    for (final agent in _manager.list(includeArchived: false)) {
      final snapshot = _encodeSnapshot(agent);
      for (final request in snapshot['pendingPermissions']! as List) {
        permissions.add({
          'agentId': agent.agentId,
          'status': snapshot['status'],
          'request': request,
        });
      }
    }
    return {'permissions': permissions};
  }

  Future<Map<String, Object?>> _respondToPermission(
    Map<String, Object?> arguments,
  ) async {
    final agentId = _requiredString(arguments, 'agentId');
    final requestId = _requiredString(arguments, 'requestId');
    if (_manager.get(agentId) == null) {
      throw StateError('Agent $agentId not found');
    }
    final ownsPendingRequest = _manager
        .fetchCanonicalTimeline(agentId)
        .rows
        .map((row) => row.item)
        .whereType<PermissionItem>()
        .any(
          (permission) =>
              permission.permissionId == requestId &&
              permission.status == PermissionStatus.pending,
        );
    if (!ownsPendingRequest) {
      throw StateError(
        'Pending permission $requestId not found for agent $agentId',
      );
    }
    final response = _requiredMap(arguments, 'response');
    final behavior = _requiredString(response, 'behavior');
    if (behavior != 'allow' && behavior != 'deny') {
      throw const FormatException('response.behavior must be allow or deny');
    }
    if (behavior == 'allow' &&
        (response.containsKey('message') ||
            response.containsKey('interrupt'))) {
      throw const FormatException(
        'allow response cannot contain message or interrupt',
      );
    }
    if (behavior == 'deny' &&
        (response.containsKey('updatedInput') ||
            response.containsKey('updatedPermissions'))) {
      throw const FormatException(
        'deny response cannot contain updatedInput or updatedPermissions',
      );
    }
    final updatedPermissions = response['updatedPermissions'];
    if (updatedPermissions != null &&
        (updatedPermissions is! List ||
            updatedPermissions.any((value) => value is! Map))) {
      throw const FormatException(
        'response.updatedPermissions must be an array of objects',
      );
    }
    await _manager.respondPermissionDetailed(
      agentId: agentId,
      permissionId: requestId,
      behavior: behavior,
      message: _nullableString(response, 'message'),
      selectedActionId: _nullableString(response, 'selectedActionId'),
      updatedInput: _optionalMap(response, 'updatedInput'),
      updatedPermissions: updatedPermissions == null
          ? null
          : [
              for (final value in updatedPermissions as List)
                Map<String, Object?>.from(value as Map),
            ],
      interrupt: _nullableBool(response, 'interrupt'),
    );
    return {'success': true};
  }

  Future<Map<String, Object?>> _inspectProvider(
    Map<String, Object?> arguments,
  ) async {
    final rawProvider = _requiredString(arguments, 'provider');
    final slash = rawProvider.indexOf('/');
    final provider = slash < 0 ? rawProvider : rawProvider.substring(0, slash);
    final providerModel = slash < 0 ? null : rawProvider.substring(slash + 1);
    if (provider.isEmpty || providerModel?.isEmpty == true) {
      throw const FormatException(
        'provider must be <provider> or <provider>/<model>',
      );
    }
    final cwd = arguments['cwd'] as String?;
    final entries = await _providerCatalog.snapshot(
      providers: [provider],
      cwd: cwd,
    );
    if (entries.isEmpty) throw StateError("Provider '$provider' not found");
    final entry = entries.single;
    if (!entry.enabled) throw StateError("Provider '$provider' is disabled");
    if (entry.status != ProviderCatalogStatus.ready) {
      throw StateError(entry.error ?? "Provider '$provider' is unavailable");
    }
    final settings = _optionalMap(arguments, 'settings');
    final selectedModel =
        _nullableString(settings ?? const {}, 'model') ?? providerModel;
    final features = await _manager.listFeatures(
      ListCommandsDraftConfig(
        provider: provider,
        cwd: cwd ?? p.current,
        modeId: _nullableString(settings ?? const {}, 'modeId'),
        model: selectedModel,
        thinkingOptionId: _nullableString(
          settings ?? const {},
          'thinkingOptionId',
        ),
        featureValues:
            _optionalMap(settings ?? const {}, 'features') ?? const {},
      ),
    );
    return {
      'provider': provider,
      'label': entry.label,
      'description': entry.description,
      'enabled': entry.enabled,
      'status': entry.status == ProviderCatalogStatus.ready
          ? 'available'
          : entry.status.name,
      'modes': entry.modes?.map((mode) => mode.toJson()).toList(),
      'selectedModel': selectedModel,
      'features': features.map((feature) => feature.toJson()).toList(),
    };
  }

  Map<String, Object?> _snapshot(String agentId) {
    final agent = _manager.get(agentId);
    if (agent == null) throw StateError('Agent $agentId not found');
    return _encodeSnapshot(agent);
  }

  Map<String, Object?> _encodeSnapshot(AgentSummary agent) {
    final timeline = _manager.fetchCanonicalTimeline(agent.agentId);
    return PaseoAgentSnapshotCodec.encode(
      agent,
      pendingPermissions: timeline.rows
          .map((row) => row.item)
          .whereType<PermissionItem>(),
    );
  }
}

String _status(AgentSummary agent) => agent.archivedAt != null
    ? 'closed'
    : switch (agent.runState) {
        AgentRunState.initializing => 'initializing',
        AgentRunState.idle => 'idle',
        AgentRunState.running || AgentRunState.awaitingPermission => 'running',
        AgentRunState.error => 'error',
        AgentRunState.closed => 'closed',
      };

Map<String, Object?> _permissionRequest(
  AgentSummary agent,
  PermissionItem permission,
) => {
  'id': permission.permissionId,
  'provider': agent.provider,
  'name': permission.toolName,
  'kind': 'tool',
  'detail': permission.detail.toPaseoJson(),
};

Map<String, Object?> _providerSummary(ProviderSnapshotEntry entry) => {
  'id': entry.provider,
  'label': entry.label ?? entry.provider,
  'description': entry.description ?? '',
  'enabled': entry.enabled,
  'modes': entry.modes?.map((mode) => mode.toJson()).toList() ?? const [],
  'status': entry.status == ProviderCatalogStatus.ready
      ? 'available'
      : entry.status.name,
  if (entry.error != null) 'error': entry.error,
};

Map<String, Object?> _workspaceSummary(PersistedWorkspaceRecord workspace) => {
  'workspaceId': workspace.workspaceId,
  'projectId': workspace.projectId,
  'cwd': workspace.cwd,
  'isolation': workspace.kind == PersistedWorkspaceKind.worktree
      ? 'worktree'
      : 'local',
  'kind': workspace.kind.wireName,
  'title': workspace.title,
};

final class _ResolvedMcpCreatePlacement {
  const _ResolvedMcpCreatePlacement({
    required this.workspace,
    required this.runtimeCwd,
    required this.detached,
    required this.settings,
    required this.createdWorktree,
  });

  final PersistedWorkspaceRecord workspace;
  final String runtimeCwd;
  final bool detached;
  final Map<String, Object?> settings;
  final bool createdWorktree;
}

Map<String, Object?> _normalizedCreateAgentSettings(
  Map<String, Object?> arguments, {
  required bool legacy,
}) {
  final settings = <String, Object?>{...?_optionalMap(arguments, 'settings')};
  if (!legacy) return settings;
  final mode = _nullableString(arguments, 'mode');
  final thinking = _nullableString(arguments, 'thinking');
  final features = _optionalMap(arguments, 'features');
  if (mode != null) settings['modeId'] = mode;
  if (thinking != null) settings['thinkingOptionId'] = thinking;
  if (features != null) settings['features'] = features;
  return settings;
}

Map<String, Object?> _legacyFlatWorkspaceInput(
  Map<String, Object?> arguments,
  String cwd,
) {
  final worktreeName = _nullableString(arguments, 'worktreeName');
  final branchName = _nullableString(arguments, 'branchName');
  final baseBranch = _nullableString(arguments, 'baseBranch');
  final refName = _nullableString(arguments, 'refName');
  final githubPrNumber = arguments['githubPrNumber'];
  Map<String, Object?>? target;
  if (githubPrNumber != null) {
    target = {
      'kind': 'checkout-pr',
      'githubPrNumber': _positiveInt(arguments, 'githubPrNumber'),
    };
  } else if (refName != null) {
    target = {'kind': 'checkout-branch', 'branch': refName};
  } else if (worktreeName != null || branchName != null || baseBranch != null) {
    target = {
      'kind': 'branch-off',
      if (worktreeName != null) 'worktreeSlug': worktreeName,
      if (branchName != null) 'branchName': branchName,
      if (baseBranch != null) 'baseBranch': baseBranch,
    };
  }
  return {
    'kind': 'create',
    'source': target == null
        ? {'kind': 'directory', 'path': cwd}
        : {'kind': 'worktree', 'cwd': cwd, 'target': target},
  };
}

void _requireAllowedCreateAgentCwd(String candidate, String? lockedCwd) {
  final locked = lockedCwd?.trim();
  if (locked == null || locked.isEmpty) return;
  final root = _normalizedComparablePath(_expandUserPath(locked));
  final path = _normalizedComparablePath(candidate);
  if (path != root && !path.startsWith('$root/')) {
    throw StateError('Workspace is outside the allowed cwd');
  }
}

String _normalizedComparablePath(String value) {
  final normalized = p
      .normalize(p.absolute(value))
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

int _positiveInt(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! num ||
      value != value.roundToDouble() ||
      value <= 0 ||
      value > 0x7fffffff) {
    throw FormatException('$key must be a positive integer');
  }
  return value.toInt();
}

Map<String, Object?> _createdAgentResult(
  Map<String, Object?> snapshot, {
  Object? lastMessage,
  Object? permission,
  String? guidance,
}) => {
  'agentId': snapshot['id'],
  'type': snapshot['provider'],
  'status': snapshot['status'],
  'cwd': snapshot['cwd'],
  if (snapshot['workspaceId'] != null) 'workspaceId': snapshot['workspaceId'],
  'currentModeId': snapshot['currentModeId'],
  'availableModes': snapshot['availableModes'],
  'lastMessage': lastMessage,
  'permission': permission,
  if (guidance != null) 'guidance': guidance,
};

AgentMode _agentMode(String? modeId) => switch (modeId) {
  'plan' ||
  'read-only' ||
  'https://agentclientprotocol.com/protocol/session-modes#plan' =>
    AgentMode.plan,
  'full-access' ||
  'fullAccess' ||
  'bypassPermissions' ||
  'allow-all' ||
  'full' => AgentMode.fullAccess,
  _ => AgentMode.normal,
};

Map<String, Object?> _listItem(Map<String, Object?> snapshot) => {
  'id': snapshot['id'],
  'shortId': (snapshot['id']! as String).substring(
    0,
    (snapshot['id']! as String).length.clamp(0, 7),
  ),
  'title': snapshot['title'],
  'provider': snapshot['provider'],
  'model': (snapshot['runtimeInfo'] as Map?)?['model'] ?? snapshot['model'],
  'thinkingOptionId': snapshot['thinkingOptionId'],
  'effectiveThinkingOptionId': snapshot['effectiveThinkingOptionId'],
  'status': snapshot['status'],
  'cwd': snapshot['cwd'],
  'createdAt': snapshot['createdAt'],
  'updatedAt': snapshot['updatedAt'],
  'lastUserMessageAt': snapshot['lastUserMessageAt'],
  'archivedAt': snapshot['archivedAt'],
  'requiresAttention': snapshot['requiresAttention'] ?? false,
  'attentionReason': snapshot['attentionReason'],
  'attentionTimestamp': snapshot['attentionTimestamp'],
  'labels': snapshot['labels'],
  if (snapshot['providerUnavailable'] == true) 'providerUnavailable': true,
};

int _compareListItems(Map<String, Object?> left, Map<String, Object?> right) {
  final attention =
      (right['requiresAttention'] == true ? 1 : 0) -
      (left['requiresAttention'] == true ? 1 : 0);
  if (attention != 0) return attention;
  const order = {
    'running': 0,
    'initializing': 1,
    'idle': 2,
    'error': 3,
    'closed': 4,
  };
  final status =
      (order[left['status']] ?? 999) - (order[right['status']] ?? 999);
  if (status != 0) return status;
  return _jsonTime(right['updatedAt']).compareTo(_jsonTime(left['updatedAt']));
}

int _activityTime(AgentSummary agent) {
  for (final value in [
    agent.attentionTimestamp,
    agent.lastUserMessageAt,
    agent.updatedAt,
    agent.archivedAt,
  ]) {
    final parsed = value == null ? null : DateTime.tryParse(value);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
  }
  return agent.createdAtMs;
}

int _jsonTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0 : 0;

bool _sameOrDescendant(String parent, String candidate) {
  final root = p.normalize(p.absolute(parent));
  final child = p.normalize(p.absolute(candidate));
  final insensitive = p.style == p.Style.windows;
  final normalizedRoot = insensitive ? root.toLowerCase() : root;
  final normalizedChild = insensitive ? child.toLowerCase() : child;
  return normalizedChild == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedChild);
}

Map<String, Object?> _terminalSummary(Map<String, Object?> terminal) => {
  'id': terminal['id'],
  'name': terminal['name'],
  'cwd': terminal['cwd'],
};

int? _optionalLineIndex(Map<String, Object?> values, String key) {
  if (!values.containsKey(key)) return null;
  final value = values[key];
  if (value is! num) throw FormatException('$key must be a number');
  return value.toInt();
}

String _expandUserPath(String value) {
  final trimmed = value.trim();
  if (trimmed == '~' || trimmed.startsWith('~/') || trimmed.startsWith(r'~\')) {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final suffix = trimmed.length == 1 ? '' : trimmed.substring(2);
    return p.normalize(p.absolute(p.join(home, suffix)));
  }
  return p.normalize(p.absolute(trimmed));
}

String _resolvePathFromBase(String baseCwd, String requestedPath) {
  final trimmed = requestedPath.trim();
  if (trimmed == '~' ||
      trimmed.startsWith('~/') ||
      trimmed.startsWith(r'~\') ||
      p.isAbsolute(trimmed)) {
    return _expandUserPath(trimmed);
  }
  return p.normalize(p.absolute(p.join(baseCwd, trimmed)));
}

String _resolveTerminalKeyToken(String key, bool literal) {
  if (literal) return key;
  return switch (key) {
    'Enter' => '\r',
    'Tab' => '\t',
    'Escape' => '\u001b',
    'Space' => ' ',
    'BSpace' => '\u007f',
    'C-c' => '\u0003',
    'C-d' => '\u0004',
    'C-z' => '\u001a',
    'C-l' => '\u000c',
    'C-a' => '\u0001',
    'C-e' => '\u0005',
    _ => key,
  };
}

String curateAgentActivity(List<TimelineItem> items, {int? maxItems}) {
  final projected = projectTimelineRows([
    for (var index = 0; index < items.length; index++)
      TimelineRow(seq: index + 1, timestamp: '', item: items[index]),
  ], projected: true).map((entry) => entry.item).toList(growable: false);
  final recent = maxItems != null && maxItems > 0 && projected.length > maxItems
      ? projected.sublist(projected.length - maxItems)
      : projected;
  final lines = <String>[];
  var messageBuffer = '';
  var thoughtBuffer = '';

  void appendText(String text, {required bool thought}) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    if (thought) {
      thoughtBuffer = thoughtBuffer.isEmpty
          ? normalized
          : '$thoughtBuffer\n$normalized';
    } else {
      messageBuffer = messageBuffer.isEmpty
          ? normalized
          : '$messageBuffer\n$normalized';
    }
  }

  void flushBuffers() {
    if (messageBuffer.trim().isNotEmpty) lines.add(messageBuffer.trim());
    if (thoughtBuffer.trim().isNotEmpty) {
      lines.add('[Thought] ${thoughtBuffer.trim()}');
    }
    messageBuffer = '';
    thoughtBuffer = '';
  }

  for (final item in recent) {
    switch (item) {
      case UserMessageItem(:final text):
        flushBuffers();
        lines.add('[User] ${text.trim()}');
      case AssistantMessageItem(:final text):
        appendText(text, thought: false);
      case ReasoningItem(:final text):
        appendText(text, thought: true);
      case ToolCallItem(:final toolName, :final detail):
        flushBuffers();
        lines.add(_toolSummary(toolName, detail));
      case TodoItem(:final items):
        flushBuffers();
        lines.add('[Tasks]');
        for (final item in items) {
          lines.add('- [${item.completed ? 'x' : ' '}] ${item.text}');
        }
      case ErrorItem(:final message):
        flushBuffers();
        lines.add('[Error] $message');
      case CompactionItem():
        flushBuffers();
        lines.add('[Compacted]');
      default:
        break;
    }
  }
  flushBuffers();
  return lines.isEmpty ? 'No activity to display.' : lines.join('\n');
}

String _toolSummary(String toolName, ToolCallDetail detail) {
  switch (detail) {
    case ShellDetail(:final command):
      return '[Shell] $command';
    case ReadDetail(:final path):
      return '[Read] $path';
    case EditDetail(:final path):
      return '[Edit] $path';
    case WriteDetail(:final path):
      return '[Write] $path';
    case SearchDetail(:final query, :final path):
      return '[Search] $query${path == null ? '' : ' in $path'}';
    case FetchDetail(:final url):
      return '[Fetch] $url';
    case PlainTextDetail(:final label, :final text):
      return '[${label?.trim().isNotEmpty == true ? label : toolName}] ${text ?? ''}'
          .trimRight();
    case SubAgentDetail(:final subAgentType, :final description, :final log):
      final summary =
          '[${subAgentType?.trim().isNotEmpty == true ? subAgentType : toolName}] '
                  '${description ?? ''}'
              .trimRight();
      return log.trim().isEmpty ? summary : '$summary\n${log.trim()}';
    default:
      return '[${_displayToolName(toolName)}]';
  }
}

String _displayToolName(String value) => value
    .replaceAll(RegExp(r'[_-]+'), ' ')
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

String _requiredString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key is required');
  }
  return value.trim();
}

String _requiredRawString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! String) throw FormatException('$key is required');
  return value;
}

String? _nullableString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value.trim().isEmpty ? null : value.trim();
}

String? _optionalTrimmedString(Map<String, Object?> values, String key) {
  if (!values.containsKey(key)) return null;
  final value = values[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value.trim().isEmpty ? null : value.trim();
}

Map<String, Object?> _requiredMap(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?>? _optionalMap(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

bool? _nullableBool(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> values, String key) {
  if (!values.containsKey(key)) return null;
  final value = values[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

int _boundedInt(
  Map<String, Object?> values,
  String key,
  int fallback,
  int minimum,
  int maximum,
) {
  final value = values[key];
  if (value == null) return fallback;
  if (value is! num || value != value.roundToDouble()) {
    throw FormatException('$key must be an integer');
  }
  final integer = value.toInt();
  if (integer < minimum || integer > maximum) {
    throw FormatException('$key must be between $minimum and $maximum');
  }
  return integer;
}

int? _optionalPositiveInt(Map<String, Object?> values, String key) {
  if (!values.containsKey(key)) return null;
  return _nullablePositiveInt(values, key);
}

int? _nullablePositiveInt(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! num || value != value.roundToDouble() || value <= 0) {
    throw FormatException('$key must be a positive integer');
  }
  return value.toInt();
}

({String provider, String? model}) _parseProvider(
  String? input, {
  String? defaultProvider,
  String? defaultModel,
}) {
  final value = input?.trim() ?? defaultProvider?.trim();
  if (value == null || value.isEmpty) {
    throw const FormatException(
      'provider must be <provider> or <provider>/<model>',
    );
  }
  final slash = value.indexOf('/');
  if (slash < 0) {
    return (provider: value, model: defaultModel);
  }
  final provider = value.substring(0, slash).trim();
  final model = value.substring(slash + 1).trim();
  if (provider.isEmpty || model.isEmpty) {
    throw const FormatException(
      'provider must be <provider> or <provider>/<model>',
    );
  }
  return (provider: provider, model: model);
}

int _parseDurationMs(String input) {
  final value = input.trim();
  if (RegExp(r'^\d+$').hasMatch(value)) {
    return int.parse(value) * 1000;
  }
  var total = 0;
  var matched = false;
  for (final match in RegExp(r'(\d+)([smh])').allMatches(value)) {
    matched = true;
    final amount = int.parse(match.group(1)!);
    total += switch (match.group(2)) {
      's' => amount * 1000,
      'm' => amount * 60 * 1000,
      'h' => amount * 60 * 60 * 1000,
      _ => 0,
    };
  }
  if (!matched) {
    throw FormatException(
      'Invalid duration format: $input. '
      'Use formats like: 5m, 30s, 1h, 2h30m',
    );
  }
  return total;
}

void _requireAbsent(
  Map<String, Object?> values,
  List<String> keys,
  String message,
) {
  if (keys.any((key) => values.containsKey(key) && values[key] != null)) {
    throw FormatException(message);
  }
}
