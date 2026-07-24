/// RPC handlers for M4 workspace features: projects, worktrees and diffs.
library;

import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../server/rpc_router.dart';
import '../store/project_store.dart';
import 'git_runner.dart';
import 'git_service.dart';

/// Wires project/worktree/diff request types into [router].
void registerWorkspaceHandlers(
  RpcRouter router, {
  required ProjectStore projects,
  required GitService git,
}) {
  router.on(MessageTypes.projectListRequest, (connection, payload) async {
    final list = await projects.list();
    return {'projects': [for (final project in list) project.toJson()]};
  });

  router.on(MessageTypes.projectAddRequest, (connection, payload) async {
    final path = _requireString(payload, 'path');
    if (!Directory(path).existsSync()) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'directory does not exist: $path',
      );
    }
    final normalized = p.normalize(p.absolute(path));
    final isGitRepo = await git.isGitRepo(normalized);
    final project = await projects.add(ProjectInfo(
      path: normalized,
      name: p.basename(normalized),
      isGitRepo: isGitRepo,
    ));
    return {'project': project.toJson()};
  });

  router.on(MessageTypes.worktreeListRequest, (connection, payload) async {
    final projectPath = _requireString(payload, 'projectPath');
    if (!Directory(projectPath).existsSync()) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'directory does not exist: $projectPath',
      );
    }
    final worktrees = await _git(() => git.listWorktrees(projectPath));
    return {'worktrees': [for (final w in worktrees) w.toJson()]};
  });

  router.on(MessageTypes.worktreeCreateRequest, (connection, payload) async {
    final projectPath = _requireString(payload, 'projectPath');
    final branch = _requireString(payload, 'branch');
    if (!Directory(projectPath).existsSync()) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'directory does not exist: $projectPath',
      );
    }
    final baseRef = payload['baseRef'];
    if (baseRef != null && baseRef is! String) {
      throw RpcException(RpcErrorCodes.invalidPayload, 'baseRef must be a string');
    }
    final worktree = await _git(
      () => git.createWorktree(projectPath, branch, baseRef: baseRef as String?),
    );
    return {'worktree': worktree.toJson()};
  });

  router.on(MessageTypes.branchListRequest, (connection, payload) async {
    final projectPath = _requireString(payload, 'projectPath');
    if (!Directory(projectPath).existsSync()) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'directory does not exist: $projectPath',
      );
    }
    final branches = await _git(() => git.listBranches(projectPath));
    final current = await _git(() => git.currentBranch(projectPath));
    return BranchListResponse(branches: branches, currentBranch: current)
        .toJson();
  });

  router.on(MessageTypes.worktreeArchiveRequest, (connection, payload) async {
    final path = _requireString(payload, 'path');
    final force = payload['force'] == true;
    try {
      await git.archiveWorktree(path, force: force);
    } on StateError catch (e) {
      throw RpcException(RpcErrorCodes.invalidPayload, e.message);
    } on GitDirtyWorktreeException catch (e) {
      throw RpcException(RpcErrorCodes.conflict, e.message);
    } on GitException catch (e) {
      throw RpcException(RpcErrorCodes.notFound, e.message);
    }
    return {};
  });

  router.on(MessageTypes.diffGetRequest, (connection, payload) async {
    final cwd = _requireString(payload, 'cwd');
    if (!Directory(cwd).existsSync()) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'directory does not exist: $cwd',
      );
    }
    final baseRef = payload['baseRef'];
    if (baseRef != null && baseRef is! String) {
      throw RpcException(RpcErrorCodes.invalidPayload, 'baseRef must be a string');
    }
    final response =
        await _git(() => git.diff(cwd, baseRef: baseRef as String?));
    return response.toJson();
  });
}

String _requireString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw RpcException(
      RpcErrorCodes.invalidPayload,
      'missing or invalid "$key"',
    );
  }
  return value;
}

/// Converts [GitException]s into typed RPC errors.
Future<T> _git<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on GitException catch (e) {
    throw RpcException(RpcErrorCodes.internal, e.message);
  }
}
