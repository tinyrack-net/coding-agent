import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_runner.dart';
import 'forge_cli.dart';
import 'forge_models.dart';
import 'forge_resolver.dart';

typedef PullRequestTimelineLoader =
    Future<ForgePullRequestTimeline> Function(
      ForgeResolution resolution,
      PullRequestTimelineRequest request,
    );

final class PullRequestTimelineService {
  PullRequestTimelineService({
    required this.resolver,
    GitRunner? git,
    PullRequestTimelineLoader? loadTimeline,
  }) : _git = git ?? const GitRunner(),
       _loadTimeline = loadTimeline;

  final ForgeResolver resolver;
  final GitRunner _git;
  final PullRequestTimelineLoader? _loadTimeline;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != PullRequestTimelineRequest.type) return null;
    final request = PullRequestTimelineRequest.fromJson(message);
    final number = request.prNumber;
    if (number != number.toInt() ||
        number <= 0 ||
        !_validRepositorySegment(request.repoOwner) ||
        !_validRepositorySegment(request.repoName)) {
      return _response(
        request,
        error: const PullRequestTimelineError(
          kind: PullRequestTimelineErrorKind.unknown,
          message: 'Pull request timeline request has invalid PR identity',
        ),
      ).toJson();
    }

    final remote = await _git.run(
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
      return _response(
        request,
        githubFeaturesEnabled: false,
        authState: ForgeAuthState.noRemote.wireName,
        error: const PullRequestTimelineError(
          kind: PullRequestTimelineErrorKind.unknown,
          message: 'No supported forge remote is configured for this workspace',
        ),
      ).toJson();
    }

    bool authenticated;
    String? probeAuthState;
    try {
      authenticated = await resolution.adapter.isAuthenticated(
        cwd: request.cwd,
        host: resolution.host,
      );
    } catch (error) {
      authenticated = false;
      probeAuthState = _authStateFor(error).wireName;
    }
    if (!authenticated) {
      return _response(
        request,
        githubFeaturesEnabled: false,
        authState: probeAuthState,
        error: PullRequestTimelineError(
          kind: PullRequestTimelineErrorKind.unknown,
          message:
              '${_forgeDisplayName(resolution.forge)} CLI is unavailable or not authenticated',
        ),
      ).toJson();
    }

    try {
      final timeline =
          await (_loadTimeline?.call(resolution, request) ??
              resolution.adapter.getPullRequestTimeline(
                cwd: request.cwd,
                prNumber: number.toInt(),
                repositoryOwner: request.repoOwner,
                repositoryName: request.repoName,
              ));
      return PullRequestTimelineResponse(
        cwd: request.cwd,
        prNumber: timeline.prNumber,
        items: timeline.items,
        truncated: timeline.truncated,
        error: timeline.error,
        requestId: request.requestId,
        githubFeaturesEnabled: true,
        authState: null,
      ).toJson();
    } catch (error) {
      final authError =
          error is ForgeAuthenticationException ||
          error is ForgeCliMissingException;
      return _response(
        request,
        githubFeaturesEnabled: !authError,
        authState: authError
            ? _authStateFor(error).wireName
            : ForgeAuthState.error.wireName,
        error: PullRequestTimelineError(
          kind: PullRequestTimelineErrorKind.unknown,
          message: _errorMessage(error),
        ),
      ).toJson();
    }
  }
}

PullRequestTimelineResponse _response(
  PullRequestTimelineRequest request, {
  bool githubFeaturesEnabled = true,
  String? authState,
  required PullRequestTimelineError error,
}) => PullRequestTimelineResponse(
  cwd: request.cwd,
  prNumber: request.prNumber,
  items: const [],
  truncated: false,
  error: error,
  requestId: request.requestId,
  githubFeaturesEnabled: githubFeaturesEnabled,
  authState: authState,
);

bool _validRepositorySegment(String value) =>
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

ForgeAuthState _authStateFor(Object error) => switch (error) {
  ForgeCliMissingException() => ForgeAuthState.cliMissing,
  ForgeAuthenticationException() => ForgeAuthState.unauthenticated,
  _ => ForgeAuthState.error,
};

String _forgeDisplayName(String forge) => switch (forge) {
  'github' => 'GitHub',
  'gitlab' => 'GitLab',
  'gitea' => 'Gitea',
  'forgejo' => 'Forgejo',
  'codeberg' => 'Codeberg',
  _ => forge,
};

String _errorMessage(Object error) => switch (error) {
  ForgeCliException() => error.message,
  _ => error.toString(),
};
