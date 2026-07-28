import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_manager.dart';
import '../agent/create_agent_mode.dart';
import '../agent/create_agent_title.dart';
import '../workspace/workspace_v2_service.dart';
import 'schedule_service.dart';

final class ScheduleAgentRunner {
  const ScheduleAgentRunner(
    this.manager,
    this.workspaces, {
    required this.recordWorkspace,
    required this.resolveCreateMode,
  });

  final AgentManager manager;
  final WorkspaceV2Service workspaces;
  final Future<void> Function({
    required String scheduleId,
    required String runId,
    required String workspaceId,
    required String? agentId,
  })
  recordWorkspace;
  final AgentCreateModeResolver resolveCreateMode;

  Future<ScheduleExecutionResult> call(
    StoredSchedule schedule,
    String runId,
  ) async {
    return switch (schedule.summary.target) {
      AgentScheduleTarget(agentId: final agentId) => _runExisting(
        schedule,
        runId,
        agentId,
      ),
      NewAgentScheduleTarget(config: final config) => _runNew(
        schedule,
        runId,
        config,
      ),
      SelfScheduleTarget() => throw StateError(
        'Self targets must be normalized before persistence',
      ),
    };
  }

  Future<ScheduleExecutionResult> _runExisting(
    StoredSchedule schedule,
    String runId,
    String agentId,
  ) async {
    if (!manager.list().any((agent) => agent.agentId == agentId)) {
      throw ScheduleTargetGoneError('Agent $agentId no longer exists');
    }
    final heading = schedule.summary.name == null
        ? 'Schedule fired (id=${schedule.summary.id}, run=$runId).'
        : 'Schedule "${schedule.summary.name}" fired '
              '(id=${schedule.summary.id}, run=$runId).';
    final prompt =
        '<paseo-system>\n$heading\n${schedule.summary.prompt}\n</paseo-system>';
    final outcome = await manager.runAndWait(agentId, prompt);
    return ScheduleExecutionResult(agentId: agentId, output: outcome.output);
  }

  Future<ScheduleExecutionResult> _runNew(
    StoredSchedule schedule,
    String runId,
    ScheduleNewAgentConfig config,
  ) async {
    final cwd = p.normalize(p.absolute(config.cwd));
    if (!Directory(cwd).existsSync()) {
      throw ScheduleTargetGoneError(
        'Working directory ${config.cwd} no longer exists',
      );
    }
    final workspace = await workspaces.createScheduleRunWorkspace(
      cwd: cwd,
      isolation: config.isolation ?? 'local',
      prompt: schedule.summary.prompt,
      runId: runId,
    );
    await recordWorkspace(
      scheduleId: schedule.summary.id,
      runId: runId,
      workspaceId: workspace.workspaceId,
      agentId: null,
    );
    AgentSummary? agent;
    try {
      final resolvedModeId = await resolveCreateMode(
        AgentCreateModeRequest(
          cwd: workspace.cwd,
          targetProvider: config.provider,
          requestedMode: config.modeId,
          parent: null,
          unattended: true,
        ),
      );
      agent = await manager.createAgent(
        cwd: workspace.cwd,
        provider: config.provider,
        model: config.model ?? '',
        mode: _mode(resolvedModeId),
        modeId: resolvedModeId,
        thinkingOptionId: config.thinkingOptionId,
        featureValues: config.featureValues ?? const {},
        mcpServers: config.mcpServers ?? const {},
        title: resolveCreateAgentTitles(
          configTitle: config.title,
          initialPrompt: schedule.summary.prompt,
        ).provisionalTitle,
        workspaceId: workspace.workspaceId,
        projectPath: workspace.mainRepoRoot,
        branch: workspace.branch,
        isWorktree: workspace.isPaseoOwnedWorktree,
      );
      await recordWorkspace(
        scheduleId: schedule.summary.id,
        runId: runId,
        workspaceId: workspace.workspaceId,
        agentId: agent.agentId,
      );
      final outcome = await manager.runAndWait(
        agent.agentId,
        schedule.summary.prompt,
      );
      return ScheduleExecutionResult(
        agentId: agent.agentId,
        workspaceId: workspace.workspaceId,
        output: outcome.output,
      );
    } finally {
      if (agent == null || (config.archiveOnFinish ?? true)) {
        try {
          if (agent != null) await manager.archive(agent.agentId);
        } finally {
          await workspaces.archiveScheduleRunWorkspace(workspace.workspaceId);
        }
      }
    }
  }
}

AgentMode _mode(String? modeId) => switch (modeId) {
  'plan' => AgentMode.plan,
  'full-access' || 'fullAccess' => AgentMode.fullAccess,
  _ => AgentMode.normal,
};
