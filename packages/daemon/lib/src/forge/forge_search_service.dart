import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_runner.dart';
import 'forge_cli.dart';
import 'forge_models.dart';
import 'forge_resolver.dart';

final class ForgeSearchService {
  ForgeSearchService({required this.resolver, GitRunner? git})
    : _git = git ?? const GitRunner();

  final ForgeResolver resolver;
  final GitRunner _git;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != ForgeSearchRequest.type) return null;
    final request = ForgeSearchRequest.fromJson(message);
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
      return ForgeSearchResponse(
        items: const [],
        authState: ForgeAuthState.noRemote.wireName,
        error: null,
        requestId: request.requestId,
      ).toJson();
    }
    try {
      final result = await resolution.adapter.searchIssuesAndPullRequests(
        cwd: request.cwd,
        query: request.query,
        limit: request.limit,
        kinds: request.kinds,
      );
      return ForgeSearchResponse(
        items: [
          for (final item in result.items)
            ForgeSearchItem(
              kind: item.kind,
              forge: item.forge ?? resolution.forge,
              number: item.number,
              title: item.title,
              url: item.url,
              state: item.state,
              body: item.body,
              labels: item.labels,
              projectPath: item.projectPath,
              baseRefName: item.baseRefName,
              headRefName: item.headRefName,
              updatedAt: item.updatedAt,
            ),
        ],
        authState: result.authState.wireName,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      final authState = switch (error) {
        ForgeCliMissingException() => ForgeAuthState.cliMissing,
        ForgeAuthenticationException() => ForgeAuthState.unauthenticated,
        _ => ForgeAuthState.error,
      };
      return ForgeSearchResponse(
        items: const [],
        authState: authState.wireName,
        error: error.toString(),
        requestId: request.requestId,
      ).toJson();
    }
  }
}
