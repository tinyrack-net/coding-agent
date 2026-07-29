import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../git/git_runner.dart';
import 'workspace_forge_status_service.dart';

typedef CheckoutRefreshGitRunner =
    Future<GitResult> Function(
      List<String> args, {
      required String cwd,
      bool check,
    });

typedef CheckoutRefreshObserver = Future<void> Function(String cwd);

/// Implements Paseo's manual checkout refresh wire contract.
final class CheckoutRefreshService {
  CheckoutRefreshService({
    required this.statusService,
    required CheckoutRefreshObserver refreshObserver,
    CheckoutRefreshGitRunner? runGit,
  }) : _refreshObserver = refreshObserver,
       _runGit = runGit ?? const GitRunner().run;

  final WorkspaceForgeStatusService statusService;
  final CheckoutRefreshObserver _refreshObserver;
  final CheckoutRefreshGitRunner _runGit;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != CheckoutRefreshRequest.type) return null;
    final request = CheckoutRefreshRequest.fromJson(message);
    final resolvedCwd = _expandTilde(request.cwd);
    try {
      statusService.invalidate(resolvedCwd);
      await _runGit(['rev-parse', '--is-inside-work-tree'], cwd: resolvedCwd);
      await _refreshObserver(resolvedCwd);
      return CheckoutRefreshResponse(
        cwd: request.cwd,
        success: true,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } on Object catch (error) {
      final message = _errorMessage(error);
      return CheckoutRefreshResponse(
        cwd: request.cwd,
        success: false,
        error: CheckoutError(
          code: message.toLowerCase().contains('not a git repository')
              ? CheckoutErrorCode.notGitRepo
              : CheckoutErrorCode.unknown,
          message: message,
        ),
        requestId: request.requestId,
      ).toJson();
    }
  }
}

String _errorMessage(Object error) => switch (error) {
  GitException() => error.message,
  _ => '$error',
};

String _expandTilde(String value) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) return value;
  if (value == '~') return home;
  return p.join(home, value.substring(2));
}
