import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_runner.dart';
import 'forge_models.dart';
import 'workspace_forge_status_service.dart';

typedef CheckoutPrStatusGitRunner =
    Future<GitResult> Function(
      List<String> args, {
      required String cwd,
      bool check,
    });

final class CheckoutPrStatusService {
  CheckoutPrStatusService({
    required this.statusService,
    CheckoutPrStatusGitRunner? runGit,
  }) : _runGit = runGit ?? const GitRunner().run;

  final WorkspaceForgeStatusService statusService;
  final CheckoutPrStatusGitRunner _runGit;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != CheckoutPrStatusRequest.type) return null;
    final request = CheckoutPrStatusRequest.fromJson(message);
    try {
      final values = await Future.wait([
        _runGit(
          ['config', '--get', 'remote.origin.url'],
          cwd: request.cwd,
          check: false,
        ),
        _runGit(
          ['symbolic-ref', '--quiet', '--short', 'HEAD'],
          cwd: request.cwd,
          check: false,
        ),
        _runGit(['rev-parse', 'HEAD'], cwd: request.cwd, check: false),
      ]);
      final remoteUrl = _outputOrNull(values[0]);
      final headRef = _outputOrNull(values[1]);
      final headSha = _outputOrNull(values[2]);
      final snapshot = await statusService.load(
        cwd: request.cwd,
        remoteUrl: remoteUrl,
        headRef: headRef,
        headSha: headSha,
      );
      return CheckoutPrStatusResponse(
        cwd: request.cwd,
        status: _status(snapshot.pullRequest, snapshot.forge),
        githubFeaturesEnabled: snapshot.featuresEnabled,
        authState: snapshot.authState.wireName,
        forge: snapshot.forge,
        error: snapshot.error == null
            ? null
            : CheckoutError(
                code: CheckoutErrorCode.unknown,
                message: snapshot.error!,
              ),
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return CheckoutPrStatusResponse(
        cwd: request.cwd,
        status: null,
        githubFeaturesEnabled: true,
        authState: ForgeAuthState.error.wireName,
        forge: null,
        error: CheckoutError(
          code: CheckoutErrorCode.unknown,
          message: _errorMessage(error),
        ),
        requestId: request.requestId,
      ).toJson();
    }
  }
}

String? _outputOrNull(GitResult result) {
  if (!result.ok) return null;
  final value = result.stdout.trim();
  return value.isEmpty ? null : value;
}

CheckoutPrStatus? _status(ForgePullRequestStatus? status, String? forge) {
  if (status == null) return null;
  final facts = status.forgeSpecific;
  final legacyGithub = facts?['forge'] == 'github'
      ? (Map<String, Object?>.from(facts!)..remove('forge'))
      : null;
  final projectPath =
      status.projectPath ??
      (status.repoOwner != null && status.repoName != null
          ? '${status.repoOwner}/${status.repoName}'
          : null);
  return CheckoutPrStatus(
    forge: forge ?? 'github',
    projectPath: projectPath,
    number: status.number,
    url: status.url,
    title: status.title,
    state: status.state,
    baseRefName: status.baseRefName,
    headRefName: status.headRefName,
    isMerged: status.isMerged,
    isDraft: status.isDraft ?? false,
    mergeable: status.mergeable.wireName,
    checks: [
      for (final check in status.checks)
        CheckoutPrCheck(
          name: check.name,
          status: check.status.wireName,
          url: check.url,
          workflow: check.workflow,
          duration: check.duration,
        ),
    ],
    checksStatus: status.checksStatus.wireName,
    reviewDecision: status.reviewDecision?.wireName,
    repoOwner: status.repoOwner,
    repoName: status.repoName,
    github: legacyGithub,
    forgeSpecific: facts,
  );
}

String _errorMessage(Object error) => switch (error) {
  GitException() => error.message,
  _ => error.toString(),
};
