import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_runner.dart';
import 'forge_cli.dart';
import 'forge_resolver.dart';

typedef ForgeCheckDetailsGitRunner =
    Future<GitResult> Function(
      List<String> args, {
      required String cwd,
      bool check,
    });

final class ForgeCheckDetailsService {
  ForgeCheckDetailsService({
    required this.resolver,
    ForgeCheckDetailsGitRunner? runGit,
  }) : _runGit = runGit ?? const GitRunner().run;

  final ForgeResolver resolver;
  final ForgeCheckDetailsGitRunner _runGit;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final type = message['type'];
    if (type != CheckoutForgeGetCheckDetailsRequest.modernType &&
        type != CheckoutForgeGetCheckDetailsRequest.legacyGithubType) {
      return null;
    }
    final request = CheckoutForgeGetCheckDetailsRequest.fromJson(message);
    if (request.checkRunId == null && request.workflowRunId == null) {
      return _failure(
        request,
        'Check details request must address a check by checkRunId or workflowRunId',
      );
    }

    try {
      final remote = await _runGit(
        ['config', '--get', 'remote.origin.url'],
        cwd: request.cwd,
        check: false,
      );
      final remoteUrl = remote.ok && remote.stdout.trim().isNotEmpty
          ? remote.stdout.trim()
          : null;
      final resolution = await resolver.resolveFromRemoteUrlAsync(
        remoteUrl,
        cwd: request.cwd,
      );
      if (resolution == null) {
        throw StateError(
          'No supported forge remote is configured for this workspace',
        );
      }
      final details = await resolution.adapter.getCheckDetails(
        cwd: request.cwd,
        repositoryOwner: request.repoOwner,
        repositoryName: request.repoName,
        checkRunId: request.checkRunId,
        workflowRunId: request.workflowRunId,
        changeRequestNumber: request.changeRequestNumber,
      );
      return CheckoutForgeGetCheckDetailsResponse(
        type: request.responseType,
        cwd: request.cwd,
        success: true,
        details: details,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return _failure(request, _errorMessage(error));
    }
  }
}

Map<String, Object?> _failure(
  CheckoutForgeGetCheckDetailsRequest request,
  String message,
) => CheckoutForgeGetCheckDetailsResponse(
  type: request.responseType,
  cwd: request.cwd,
  success: false,
  details: null,
  error: CheckoutError(code: CheckoutErrorCode.unknown, message: message),
  requestId: request.requestId,
).toJson();

String _errorMessage(Object error) => switch (error) {
  StateError() => error.message.toString(),
  ForgeCommandException() when error.stderr.trim().isNotEmpty =>
    error.stderr.trim(),
  ForgeCliException() => error.message,
  GitException() => error.message,
  _ => error.toString(),
};
