import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import 'forge_cli.dart';
import 'forge_models.dart';

const _githubPullRequestStatusFactsQuery = r'''
query PullRequestStatusFacts($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    autoMergeAllowed
    mergeCommitAllowed
    squashMergeAllowed
    rebaseMergeAllowed
    viewerDefaultMergeMethod
    pullRequest(number: $number) {
      mergeStateStatus
      autoMergeRequest {
        enabledAt
        mergeMethod
        enabledBy {
          login
        }
      }
      viewerCanEnableAutoMerge
      viewerCanDisableAutoMerge
      viewerCanMergeAsAdmin
      viewerCanUpdateBranch
      isMergeQueueEnabled
      isInMergeQueue
    }
  }
}''';

const _githubPullRequestTimelineQuery = r'''
query PullRequestTimeline($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      reviews(first: 100) {
        nodes {
          id
          state
          body
          bodyHTML
          url
          submittedAt
          author { login url avatarUrl }
        }
        pageInfo { hasNextPage }
      }
      comments(first: 100) {
        nodes {
          id
          body
          bodyHTML
          url
          createdAt
          author { login url avatarUrl }
        }
        pageInfo { hasNextPage }
      }
      reviewThreads(first: 100) {
        nodes {
          id
          path
          line
          startLine
          isResolved
          isOutdated
          comments(first: 100) {
            nodes {
              id
              body
              bodyHTML
              url
              createdAt
              author { login url avatarUrl }
              pullRequestReview { id }
            }
            pageInfo { hasNextPage }
          }
        }
        pageInfo { hasNextPage }
      }
    }
  }
}''';

abstract interface class ForgeStatusAdapter {
  String get forge;

  Future<bool> isAuthenticated({required String cwd, required String host});

  Future<ForgePullRequestStatus?> getCurrentPullRequestStatus({
    required String cwd,
    required String headRef,
    String? headSha,
    String? headRepositoryOwner,
    String? repositoryOwner,
    String? repositoryName,
  });

  Future<ForgeSearchResult> searchIssuesAndPullRequests({
    required String cwd,
    required String query,
    int? limit,
    List<ForgeSearchKind>? kinds,
  });

  Future<ForgePullRequestTimeline> getPullRequestTimeline({
    required String cwd,
    required int prNumber,
    required String repositoryOwner,
    required String repositoryName,
  });

  Future<CheckoutCheckDetails> getCheckDetails({
    required String cwd,
    String? repositoryOwner,
    String? repositoryName,
    int? checkRunId,
    int? workflowRunId,
    int? changeRequestNumber,
  });

  Future<ForgePullRequestCreateResult> createPullRequest({
    required String cwd,
    required String title,
    required String body,
    required String head,
    required String base,
    required String repositoryOwner,
    required String repositoryName,
  });

  Future<void> mergePullRequest({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  });

  Future<void> enablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  });

  Future<void> disablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required ForgePullRequestStatus status,
  });
}

ForgeStatusAdapter createForgeStatusAdapter(
  String forge, {
  ForgeCommandTransport transport = const ProcessForgeCommandTransport(),
}) => switch (forge) {
  'github' => GitHubForgeStatusAdapter(transport),
  'gitlab' => GitLabForgeStatusAdapter(transport),
  'gitea' ||
  'forgejo' ||
  'codeberg' => GiteaForgeStatusAdapter(transport, forge: forge),
  _ => throw ArgumentError.value(forge, 'forge', 'unsupported forge'),
};

final class GitHubForgeStatusAdapter implements ForgeStatusAdapter {
  GitHubForgeStatusAdapter(this.transport);

  final ForgeCommandTransport transport;

  @override
  String get forge => 'github';

  @override
  Future<bool> isAuthenticated({
    required String cwd,
    required String host,
  }) async {
    await runForgeCli(
      transport,
      'gh',
      ['auth', 'status', '--hostname', host],
      cwd: cwd,
      environment: const {'GH_PROMPT_DISABLED': '1'},
    );
    return true;
  }

  @override
  Future<ForgePullRequestStatus?> getCurrentPullRequestStatus({
    required String cwd,
    required String headRef,
    String? headSha,
    String? headRepositoryOwner,
    String? repositoryOwner,
    String? repositoryName,
  }) async {
    const baseFields =
        'number,url,title,state,isDraft,baseRefName,headRefName,headRefOid,'
        'mergedAt,reviewDecision,mergeable,headRepositoryOwner';
    const fullFields = '$baseFields,statusCheckRollup';
    final args = [
      'pr',
      'list',
      '--state',
      'all',
      '--head',
      headRef,
      '--limit',
      '10',
      '--json',
      fullFields,
    ];
    String stdout;
    try {
      stdout = await runForgeCli(
        transport,
        'gh',
        args,
        cwd: cwd,
        environment: const {'GH_PROMPT_DISABLED': '1'},
      );
    } on ForgeCommandException catch (error) {
      if (!_isStatusRollupPermissionError(error.stderr)) rethrow;
      final fallback = [...args];
      fallback[fallback.length - 1] = baseFields;
      stdout = await runForgeCli(
        transport,
        'gh',
        fallback,
        cwd: cwd,
        environment: const {'GH_PROMPT_DISABLED': '1'},
      );
    }
    final rows = _jsonMapList(
      decodeForgeJson(stdout, executable: 'gh', args: args, cwd: cwd),
      executable: 'gh',
      args: args,
      cwd: cwd,
    );
    final candidates = [
      for (final row in rows)
        if (_string(row, 'headRefName') == headRef) row,
    ];
    final selected =
        candidates.where((row) => _githubState(row) == 'open').firstOrNull ??
        candidates
            .where(
              (row) =>
                  headSha != null &&
                  _string(row, 'headRefOid', nullable: true) == headSha,
            )
            .firstOrNull;
    if (selected == null) return null;
    final owner = _nestedString(
      selected,
      'headRepositoryOwner',
      'login',
      nullable: true,
    );
    if (headRepositoryOwner != null &&
        owner != null &&
        owner != headRepositoryOwner) {
      return null;
    }
    final status = _githubStatus(selected);
    final statusOwner = status.repoOwner;
    final name = status.repoName;
    final number = status.number;
    if (statusOwner == null || name == null || number == null) return status;
    final facts = await _loadGitHubPullRequestStatusFacts(
      transport: transport,
      cwd: cwd,
      owner: statusOwner,
      name: name,
      number: number,
    );
    return _githubStatus(selected, forgeSpecific: facts);
  }

  @override
  Future<ForgeSearchResult> searchIssuesAndPullRequests({
    required String cwd,
    required String query,
    int? limit,
    List<ForgeSearchKind>? kinds,
  }) => _searchForge(
    transport: transport,
    forge: forge,
    cwd: cwd,
    query: query,
    limit: limit,
    kinds: kinds,
  );

  @override
  Future<ForgePullRequestTimeline> getPullRequestTimeline({
    required String cwd,
    required int prNumber,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    final args = [
      'api',
      'graphql',
      '-f',
      'query=$_githubPullRequestTimelineQuery',
      '-F',
      'owner=$repositoryOwner',
      '-F',
      'name=$repositoryName',
      '-F',
      'number=$prNumber',
    ];
    try {
      final parsed = _jsonMap(
        decodeForgeJson(
          await runForgeCli(
            transport,
            'gh',
            args,
            cwd: cwd,
            environment: const {'GH_PROMPT_DISABLED': '1'},
          ),
          executable: 'gh',
          args: args,
          cwd: cwd,
        ),
        executable: 'gh',
        args: args,
        cwd: cwd,
      );
      return _githubTimeline(parsed, fallbackNumber: prNumber);
    } catch (error) {
      return ForgePullRequestTimeline(
        prNumber: prNumber,
        items: const [],
        truncated: false,
        error: _timelineError(error),
      );
    }
  }

  @override
  Future<CheckoutCheckDetails> getCheckDetails({
    required String cwd,
    String? repositoryOwner,
    String? repositoryName,
    int? checkRunId,
    int? workflowRunId,
    int? changeRequestNumber,
  }) async {
    if (repositoryOwner == null || repositoryName == null) {
      throw StateError(
        'GitHub getCheckDetails requires repoOwner and repoName',
      );
    }
    if (checkRunId == null) {
      throw StateError('GitHub getCheckDetails requires checkRunId');
    }
    final repoPath = 'repos/$repositoryOwner/$repositoryName';
    final checkArgs = ['api', '$repoPath/check-runs/$checkRunId'];
    final check = _jsonMap(
      decodeForgeJson(
        await runForgeCli(
          transport,
          'gh',
          checkArgs,
          cwd: cwd,
          environment: const {'GH_PROMPT_DISABLED': '1'},
        ),
        executable: 'gh',
        args: checkArgs,
        cwd: cwd,
      ),
      executable: 'gh',
      args: checkArgs,
      cwd: cwd,
    );
    final annotationArgs = [
      'api',
      '$repoPath/check-runs/$checkRunId/annotations',
      '-f',
      'per_page=20',
    ];
    final annotations = _jsonMapList(
      decodeForgeJson(
        await runForgeCli(
          transport,
          'gh',
          annotationArgs,
          cwd: cwd,
          environment: const {'GH_PROMPT_DISABLED': '1'},
        ),
        executable: 'gh',
        args: annotationArgs,
        cwd: cwd,
      ),
      executable: 'gh',
      args: annotationArgs,
      cwd: cwd,
    ).map(_githubCheckAnnotation).toList(growable: false);
    final resolvedWorkflowRunId =
        workflowRunId ??
        _num(_map(_map(check['check_suite'])['workflow_run']), 'id')?.toInt();
    final failedJobs = <CheckoutCheckFailedJob>[];
    var truncated = annotations.length >= 20;
    if (resolvedWorkflowRunId != null) {
      final jobsArgs = [
        'api',
        '$repoPath/actions/runs/$resolvedWorkflowRunId/jobs',
        '-f',
        'per_page=100',
      ];
      final jobsDocument = _jsonMap(
        decodeForgeJson(
          await runForgeCli(
            transport,
            'gh',
            jobsArgs,
            cwd: cwd,
            environment: const {'GH_PROMPT_DISABLED': '1'},
          ),
          executable: 'gh',
          args: jobsArgs,
          cwd: cwd,
        ),
        executable: 'gh',
        args: jobsArgs,
        cwd: cwd,
      );
      final jobs = _mapList(jobsDocument['jobs']);
      final failed = jobs.where(_isFailedGitHubJob).toList(growable: false);
      truncated = truncated || jobs.length >= 100 || failed.length > 5;
      for (final job in failed.take(5)) {
        final jobId = _int(job, 'id');
        final logArgs = ['api', '$repoPath/actions/jobs/$jobId/logs'];
        final log = _capCheckLogTail(
          await runForgeCli(
            transport,
            'gh',
            logArgs,
            cwd: cwd,
            environment: const {'GH_PROMPT_DISABLED': '1'},
            classifyAuthentication: true,
          ),
        );
        truncated = truncated || log.truncated;
        failedJobs.add(
          CheckoutCheckFailedJob(
            jobId: jobId,
            name: _string(job, 'name', nullable: true) ?? '',
            status: _string(job, 'status', nullable: true),
            conclusion: _string(job, 'conclusion', nullable: true),
            url: _string(job, 'html_url', nullable: true),
            logTail: log.tail,
            logTruncated: log.truncated,
          ),
        );
      }
    }
    final rawOutput = check['output'];
    return CheckoutCheckDetails(
      checkRunId: _int(check, 'id'),
      workflowRunId: resolvedWorkflowRunId,
      name: _string(check, 'name', nullable: true) ?? '',
      status: _string(check, 'status', nullable: true),
      conclusion: _string(check, 'conclusion', nullable: true),
      url: _string(check, 'html_url', nullable: true),
      detailsUrl: _string(check, 'details_url', nullable: true),
      output: rawOutput is Map ? Map<String, Object?>.from(rawOutput) : null,
      annotations: annotations,
      failedJobs: List.unmodifiable(failedJobs),
      truncated: truncated,
    );
  }

  @override
  Future<ForgePullRequestCreateResult> createPullRequest({
    required String cwd,
    required String title,
    required String body,
    required String head,
    required String base,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    final args = [
      'api',
      '-X',
      'POST',
      'repos/$repositoryOwner/$repositoryName/pulls',
      '-f',
      'title=$title',
      '-f',
      'head=$head',
      '-f',
      'base=$base',
      if (body.isNotEmpty) ...['-f', 'body=$body'],
    ];
    final row = _jsonMap(
      decodeForgeJson(
        await runForgeCli(
          transport,
          'gh',
          args,
          cwd: cwd,
          environment: const {'GH_PROMPT_DISABLED': '1'},
        ),
        executable: 'gh',
        args: args,
        cwd: cwd,
      ),
      executable: 'gh',
      args: args,
      cwd: cwd,
    );
    return ForgePullRequestCreateResult(
      url: _string(row, 'url')!,
      number: _int(row, 'number'),
    );
  }

  @override
  Future<void> mergePullRequest({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) async {
    _assertGitHubDirectMergeReady(status, mergeMethod);
    await runForgeCli(
      transport,
      'gh',
      ['pr', 'merge', '$number', '--${mergeMethod.name}'],
      cwd: cwd,
      environment: const {'GH_PROMPT_DISABLED': '1'},
    );
  }

  @override
  Future<void> enablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) async {
    _assertGitHubAutoMergeEnableReady(status, mergeMethod);
    await runForgeCli(
      transport,
      'gh',
      ['pr', 'merge', '$number', '--auto', '--${mergeMethod.name}'],
      cwd: cwd,
      environment: const {'GH_PROMPT_DISABLED': '1'},
    );
  }

  @override
  Future<void> disablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required ForgePullRequestStatus status,
  }) async {
    _assertGitHubAutoMergeDisableReady(status);
    await runForgeCli(
      transport,
      'gh',
      ['pr', 'merge', '$number', '--disable-auto'],
      cwd: cwd,
      environment: const {'GH_PROMPT_DISABLED': '1'},
    );
  }
}

final class GitLabForgeStatusAdapter implements ForgeStatusAdapter {
  GitLabForgeStatusAdapter(this.transport);

  final ForgeCommandTransport transport;

  @override
  String get forge => 'gitlab';

  @override
  Future<bool> isAuthenticated({
    required String cwd,
    required String host,
  }) async {
    try {
      await runForgeCli(transport, 'glab', [
        'auth',
        'status',
        '--hostname',
        host,
      ], cwd: cwd);
      return true;
    } on ForgeCliMissingException {
      rethrow;
    } on ForgeCliException {
      return false;
    }
  }

  @override
  Future<ForgePullRequestStatus?> getCurrentPullRequestStatus({
    required String cwd,
    required String headRef,
    String? headSha,
    String? headRepositoryOwner,
    String? repositoryOwner,
    String? repositoryName,
  }) async {
    if (headRef.startsWith('-')) {
      throw ArgumentError.value(headRef, 'headRef', 'must not begin with -');
    }
    final listArgs = [
      'mr',
      'list',
      '--all',
      '--source-branch',
      headRef,
      '--order',
      'updated_at',
      '--sort',
      'desc',
      '--per-page',
      '100',
      '-F',
      'json',
    ];
    final stdout = await runForgeCli(transport, 'glab', listArgs, cwd: cwd);
    final rows = _jsonMapList(
      decodeForgeJson(stdout, executable: 'glab', args: listArgs, cwd: cwd),
      executable: 'glab',
      args: listArgs,
      cwd: cwd,
    );
    final candidates = [
      for (final row in rows)
        if (_string(row, 'source_branch') == headRef) row,
    ];
    final selected =
        candidates.where((row) => _gitLabState(row) == 'open').firstOrNull ??
        candidates
            .where(
              (row) =>
                  headSha != null &&
                  _string(row, 'sha', nullable: true) == headSha,
            )
            .firstOrNull;
    if (selected == null) return null;
    final iid = _int(selected, 'iid');
    final viewArgs = ['mr', 'view', '$iid', '-F', 'json'];
    final view = _jsonMap(
      decodeForgeJson(
        await runForgeCli(transport, 'glab', viewArgs, cwd: cwd),
        executable: 'glab',
        args: viewArgs,
        cwd: cwd,
      ),
      executable: 'glab',
      args: viewArgs,
      cwd: cwd,
    );
    return _gitLabStatus(view);
  }

  @override
  Future<ForgeSearchResult> searchIssuesAndPullRequests({
    required String cwd,
    required String query,
    int? limit,
    List<ForgeSearchKind>? kinds,
  }) => _searchForge(
    transport: transport,
    forge: forge,
    cwd: cwd,
    query: query,
    limit: limit,
    kinds: kinds,
  );

  @override
  Future<ForgePullRequestTimeline> getPullRequestTimeline({
    required String cwd,
    required int prNumber,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    try {
      final viewArgs = ['mr', 'view', '$prNumber', '-F', 'json'];
      final mergeRequest = _jsonMap(
        decodeForgeJson(
          await runForgeCli(transport, 'glab', viewArgs, cwd: cwd),
          executable: 'glab',
          args: viewArgs,
          cwd: cwd,
        ),
        executable: 'glab',
        args: viewArgs,
        cwd: cwd,
      );
      final iid = _int(mergeRequest, 'iid');
      final projectPath = _gitLabProjectPath(mergeRequest);
      if (projectPath == null) {
        return ForgePullRequestTimeline(
          prNumber: prNumber,
          items: const [],
          truncated: false,
          error: const PullRequestTimelineError(
            kind: PullRequestTimelineErrorKind.notFound,
            message: 'GitLab merge request project path is unavailable',
          ),
        );
      }
      final apiPath =
          'projects/${Uri.encodeComponent(projectPath)}/merge_requests/$iid/discussions?per_page=100';
      final args = ['api', apiPath];
      final discussions = _jsonMapList(
        decodeForgeJson(
          await runForgeCli(transport, 'glab', args, cwd: cwd),
          executable: 'glab',
          args: args,
          cwd: cwd,
        ),
        executable: 'glab',
        args: args,
        cwd: cwd,
      );
      final items = <PullRequestTimelineItem>[
        for (final discussion in discussions)
          for (final note in _mapList(discussion['notes']))
            if (_gitLabTimelineComment(
                  note,
                  discussion,
                  _string(mergeRequest, 'web_url')!,
                )
                case final item?)
              item,
      ]..sort(_compareTimelineItems);
      var truncated = false;
      if (discussions.length >= 100) {
        final probeArgs = [
          'api',
          'projects/${Uri.encodeComponent(projectPath)}/merge_requests/$iid/discussions?per_page=1&page=101',
        ];
        try {
          final probe = _jsonMapList(
            decodeForgeJson(
              await runForgeCli(transport, 'glab', probeArgs, cwd: cwd),
              executable: 'glab',
              args: probeArgs,
              cwd: cwd,
            ),
            executable: 'glab',
            args: probeArgs,
            cwd: cwd,
          );
          truncated = probe.isNotEmpty;
        } catch (_) {
          truncated = true;
        }
      }
      return ForgePullRequestTimeline(
        prNumber: iid,
        items: List.unmodifiable(items),
        truncated: truncated,
        error: null,
      );
    } catch (error) {
      return ForgePullRequestTimeline(
        prNumber: prNumber,
        items: const [],
        truncated: false,
        error: _timelineError(error),
      );
    }
  }

  @override
  Future<CheckoutCheckDetails> getCheckDetails({
    required String cwd,
    String? repositoryOwner,
    String? repositoryName,
    int? checkRunId,
    int? workflowRunId,
    int? changeRequestNumber,
  }) async {
    if (changeRequestNumber == null && checkRunId == null) {
      throw StateError(
        'GitLab getCheckDetails requires changeRequestNumber or checkRunId',
      );
    }
    final args = [
      'ci',
      'get',
      if (changeRequestNumber != null) ...[
        '--merge-request',
        '$changeRequestNumber',
      ] else ...[
        '--pipeline-id',
        '$checkRunId',
      ],
      '--with-job-details',
      '-F',
      'json',
    ];
    final pipeline = _jsonMap(
      decodeForgeJson(
        await runForgeCli(transport, 'glab', args, cwd: cwd),
        executable: 'glab',
        args: args,
        cwd: cwd,
      ),
      executable: 'glab',
      args: args,
      cwd: cwd,
    );
    return _gitLabCheckDetails(pipeline);
  }

  @override
  Future<ForgePullRequestCreateResult> createPullRequest({
    required String cwd,
    required String title,
    required String body,
    required String head,
    required String base,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    final args = [
      'mr',
      'create',
      '--title',
      title,
      '--description',
      body,
      '--source-branch',
      head,
      '--target-branch',
      base,
      '--yes',
    ];
    final output = await runForgeCli(transport, 'glab', args, cwd: cwd);
    return _createResultFromUrl(
      output,
      RegExp(r'https?://\S+/-/merge_requests/(\d+)'),
      executable: 'glab',
      args: args,
      cwd: cwd,
    );
  }

  @override
  Future<void> mergePullRequest({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) async {
    _assertGitLabDirectMergeReady(status);
    final args = [
      'mr',
      'merge',
      '$number',
      '--auto-merge=false',
      '--yes',
      if (mergeMethod == CheckoutPrMergeMethod.squash) '--squash',
      if (mergeMethod == CheckoutPrMergeMethod.rebase) '--rebase',
    ];
    await runForgeCli(transport, 'glab', args, cwd: cwd);
  }

  @override
  Future<void> enablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) async {
    _assertGitLabAutoMergeEnableReady(status);
    final args = [
      'mr',
      'merge',
      '$number',
      '--auto-merge',
      '--yes',
      if (mergeMethod == CheckoutPrMergeMethod.squash) '--squash',
      if (mergeMethod == CheckoutPrMergeMethod.rebase) '--rebase',
    ];
    await runForgeCli(transport, 'glab', args, cwd: cwd);
  }

  @override
  Future<void> disablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required ForgePullRequestStatus status,
  }) async {
    await runForgeCli(transport, 'glab', [
      'api',
      '--method',
      'POST',
      'projects/:fullpath/merge_requests/$number/cancel_merge_when_pipeline_succeeds',
    ], cwd: cwd);
  }
}

final class GiteaForgeStatusAdapter implements ForgeStatusAdapter {
  GiteaForgeStatusAdapter(this.transport, {required this.forge});

  final ForgeCommandTransport transport;

  @override
  final String forge;

  @override
  Future<bool> isAuthenticated({
    required String cwd,
    required String host,
  }) async {
    final args = ['login', 'list', '-o', 'json'];
    late final String stdout;
    try {
      stdout = await runForgeCli(transport, 'tea', args, cwd: cwd);
    } on ForgeCliMissingException {
      rethrow;
    } on ForgeCliException {
      return false;
    }
    final rows = _jsonMapList(
      decodeForgeJson(stdout, executable: 'tea', args: args, cwd: cwd),
      executable: 'tea',
      args: args,
      cwd: cwd,
    );
    final target = normalizeGitRemoteHost(host);
    return rows.any((row) {
      final candidates = <String?>[
        _string(row, 'ssh_host', nullable: true),
        _string(row, 'name', nullable: true),
      ];
      final url = _string(row, 'url', nullable: true);
      if (url != null) candidates.add(Uri.tryParse(url)?.host);
      return candidates.whereType<String>().any(
        (candidate) => normalizeGitRemoteHost(candidate) == target,
      );
    });
  }

  @override
  Future<ForgePullRequestStatus?> getCurrentPullRequestStatus({
    required String cwd,
    required String headRef,
    String? headSha,
    String? headRepositoryOwner,
    String? repositoryOwner,
    String? repositoryName,
  }) async {
    final args = [
      'pr',
      'list',
      '--fields',
      'index,state,author,url,title,body,mergeable,base,head,created,updated,labels,comments,ci',
      '--state',
      'open',
      '--limit',
      '100',
      '-o',
      'json',
    ];
    final rows = _jsonMapList(
      decodeForgeJson(
        await runForgeCli(transport, 'tea', args, cwd: cwd),
        executable: 'tea',
        args: args,
        cwd: cwd,
      ),
      executable: 'tea',
      args: args,
      cwd: cwd,
    );
    final openPullRequest = [
      for (final row in rows)
        if (_giteaHead(row) == headRef &&
            _matchesGiteaOwner(row, headRepositoryOwner))
          row,
    ].firstOrNull;
    if (openPullRequest != null) return _giteaStatus(openPullRequest);
    if (headSha == null || repositoryOwner == null || repositoryName == null) {
      return null;
    }

    final recentArgs = [
      'api',
      'repos/$repositoryOwner/$repositoryName/pulls?state=all&sort=recentupdate&page=1&limit=50',
    ];
    final recentRows = _jsonMapList(
      decodeForgeJson(
        await runForgeCli(transport, 'tea', recentArgs, cwd: cwd),
        executable: 'tea',
        args: recentArgs,
        cwd: cwd,
      ),
      executable: 'tea',
      args: recentArgs,
      cwd: cwd,
    );
    final terminalPullRequest = recentRows
        .map(_giteaApiToListRow)
        .where(
          (row) =>
              _giteaHead(row) == headRef &&
              _matchesGiteaOwner(row, headRepositoryOwner) &&
              _string(row, 'head_sha', nullable: true) == headSha,
        )
        .firstOrNull;
    return terminalPullRequest == null
        ? null
        : _giteaStatus(terminalPullRequest);
  }

  @override
  Future<ForgeSearchResult> searchIssuesAndPullRequests({
    required String cwd,
    required String query,
    int? limit,
    List<ForgeSearchKind>? kinds,
  }) => _searchForge(
    transport: transport,
    forge: forge,
    cwd: cwd,
    query: query,
    limit: limit,
    kinds: kinds,
  );

  @override
  Future<ForgePullRequestTimeline> getPullRequestTimeline({
    required String cwd,
    required int prNumber,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    try {
      final viewArgs = ['pr', '$prNumber', '-o', 'json'];
      final pullRequest = _jsonMap(
        decodeForgeJson(
          await runForgeCli(transport, 'tea', viewArgs, cwd: cwd),
          executable: 'tea',
          args: viewArgs,
          cwd: cwd,
        ),
        executable: 'tea',
        args: viewArgs,
        cwd: cwd,
      );
      final commentsFuture = _loadGiteaTimelinePages(
        transport: transport,
        cwd: cwd,
        owner: repositoryOwner,
        repository: repositoryName,
        suffix: 'issues/$prNumber/comments',
      );
      final reviewsFuture = _loadGiteaTimelinePages(
        transport: transport,
        cwd: cwd,
        owner: repositoryOwner,
        repository: repositoryName,
        suffix: 'pulls/$prNumber/reviews',
      );
      final results = await Future.wait([
        _captureTimelineBucket(commentsFuture),
        _captureTimelineBucket(reviewsFuture),
      ]);
      final commentsResult = results[0];
      final reviewsResult = results[1];
      if (commentsResult.error != null && reviewsResult.error != null) {
        return ForgePullRequestTimeline(
          prNumber: prNumber,
          items: const [],
          truncated: false,
          error: _timelineError(commentsResult.error!),
        );
      }
      final reviews = reviewsResult.bucket?.items ?? const [];
      final reviewCommentBuckets = await Future.wait([
        for (final review in reviews)
          if ((_num(review, 'comments_count') ?? 0) > 0)
            _captureTimelineBucket(
              _loadGiteaTimelinePages(
                transport: transport,
                cwd: cwd,
                owner: repositoryOwner,
                repository: repositoryName,
                suffix:
                    'pulls/$prNumber/reviews/${_int(review, 'id')}/comments',
              ),
            ),
      ]);
      final items = <PullRequestTimelineItem>[
        for (final comment in commentsResult.bucket?.items ?? const [])
          if (_giteaTimelineComment(comment, pullRequest) case final item?)
            item,
        for (final review in reviews) _giteaTimelineReview(review),
        for (final result in reviewCommentBuckets)
          for (final comment in result.bucket?.items ?? const [])
            _giteaTimelineReviewComment(comment),
      ]..sort(_compareTimelineItems);
      return ForgePullRequestTimeline(
        prNumber: prNumber,
        items: List.unmodifiable(items),
        truncated:
            (commentsResult.bucket?.truncated ?? false) ||
            (reviewsResult.bucket?.truncated ?? false) ||
            reviewCommentBuckets.any(
              (result) => result.bucket?.truncated ?? false,
            ),
        error: null,
      );
    } catch (error) {
      return ForgePullRequestTimeline(
        prNumber: prNumber,
        items: const [],
        truncated: false,
        error: _timelineError(error),
      );
    }
  }

  @override
  Future<CheckoutCheckDetails> getCheckDetails({
    required String cwd,
    String? repositoryOwner,
    String? repositoryName,
    int? checkRunId,
    int? workflowRunId,
    int? changeRequestNumber,
  }) async {
    if (repositoryOwner == null || repositoryName == null) {
      throw StateError('Gitea getCheckDetails requires repoOwner and repoName');
    }
    if (checkRunId == null && workflowRunId == null) {
      throw StateError(
        'Gitea getCheckDetails requires a checkRunId or workflowRunId',
      );
    }
    int pullRequestNumber;
    if (changeRequestNumber != null) {
      pullRequestNumber = changeRequestNumber;
    } else {
      final branch = await runForgeCli(
        transport,
        'git',
        ['branch', '--show-current'],
        cwd: cwd,
        classifyAuthentication: false,
      );
      if (branch.isEmpty) {
        throw StateError('Gitea check details require a current branch');
      }
      final status = await getCurrentPullRequestStatus(
        cwd: cwd,
        headRef: branch,
        repositoryOwner: repositoryOwner,
        repositoryName: repositoryName,
      );
      final number = status?.number;
      if (number == null) {
        throw StateError('Gitea pull request for branch $branch was not found');
      }
      pullRequestNumber = number;
    }
    final viewArgs = ['pr', '$pullRequestNumber', '-o', 'json'];
    final pullRequest = _jsonMap(
      decodeForgeJson(
        await runForgeCli(transport, 'tea', viewArgs, cwd: cwd),
        executable: 'tea',
        args: viewArgs,
        cwd: cwd,
      ),
      executable: 'tea',
      args: viewArgs,
      cwd: cwd,
    );
    final sha =
        _string(pullRequest, 'headSha', nullable: true) ??
        _nestedString(pullRequest, 'head', 'sha', nullable: true);
    if (sha == null || sha.isEmpty) {
      throw StateError(
        'Gitea pull request #$pullRequestNumber did not include a head SHA',
      );
    }
    final owner = Uri.encodeComponent(repositoryOwner);
    final repo = Uri.encodeComponent(repositoryName);
    final encodedSha = Uri.encodeComponent(sha);
    List<Map<String, Object?>> statuses = const [];
    final statusArgs = ['api', 'repos/$owner/$repo/commits/$encodedSha/status'];
    try {
      final combined = _jsonMap(
        decodeForgeJson(
          await runForgeCli(transport, 'tea', statusArgs, cwd: cwd),
          executable: 'tea',
          args: statusArgs,
          cwd: cwd,
        ),
        executable: 'tea',
        args: statusArgs,
        cwd: cwd,
      );
      statuses = _mapList(combined['statuses']);
    } on ForgeCommandException {
      statuses = const [];
    }
    final commitStatus = statuses
        .where((status) => _num(status, 'id')?.toInt() == checkRunId)
        .firstOrNull;
    if (commitStatus != null) {
      return _giteaCommitCheckDetails(commitStatus);
    }

    final runs = <Map<String, Object?>>[];
    var fetched = 0;
    for (var page = 1; page <= 5; page++) {
      final args = [
        'api',
        'repos/$owner/$repo/actions/tasks?limit=50&page=$page',
      ];
      Map<String, Object?> document;
      try {
        document = _jsonMap(
          decodeForgeJson(
            await runForgeCli(transport, 'tea', args, cwd: cwd),
            executable: 'tea',
            args: args,
            cwd: cwd,
          ),
          executable: 'tea',
          args: args,
          cwd: cwd,
        );
      } on ForgeCommandException {
        break;
      }
      final rawRuns = _mapList(document['workflow_runs']);
      if (rawRuns.isEmpty) break;
      fetched += rawRuns.length;
      runs.addAll(
        rawRuns.where(
          (run) =>
              _num(run, 'id') != null &&
              _string(run, 'status', nullable: true) != null &&
              _string(run, 'head_sha', nullable: true) == sha,
        ),
      );
      if (runs.isNotEmpty) break;
      final total = _num(document, 'total_count')?.toInt();
      if (total != null && fetched >= total) break;
    }
    final targetId = workflowRunId ?? checkRunId;
    final workflowRun = runs
        .where((run) => _num(run, 'id')?.toInt() == targetId)
        .firstOrNull;
    if (workflowRun == null) {
      throw StateError('Gitea check $targetId was not found');
    }
    return _giteaActionsCheckDetails(workflowRun);
  }

  @override
  Future<ForgePullRequestCreateResult> createPullRequest({
    required String cwd,
    required String title,
    required String body,
    required String head,
    required String base,
    required String repositoryOwner,
    required String repositoryName,
  }) async {
    final args = [
      'pr',
      'create',
      '--title',
      title,
      '--description',
      body,
      '--head',
      head,
      '--base',
      base,
    ];
    final output = await runForgeCli(transport, 'tea', args, cwd: cwd);
    return _createResultFromUrl(
      output,
      RegExp(r'https?://\S+/pulls/(\d+)'),
      executable: 'tea',
      args: args,
      cwd: cwd,
    );
  }

  @override
  Future<void> mergePullRequest({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) async {
    _assertGiteaDirectMergeReady(status);
    await runForgeCli(transport, 'tea', [
      'pr',
      'merge',
      '$number',
      '--style',
      mergeMethod.name,
    ], cwd: cwd);
  }

  @override
  Future<void> enablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required CheckoutPrMergeMethod mergeMethod,
    required ForgePullRequestStatus status,
  }) => throw UnsupportedError(
    'enablePullRequestAutoMerge is not supported by $forge',
  );

  @override
  Future<void> disablePullRequestAutoMerge({
    required String cwd,
    required int number,
    required ForgePullRequestStatus status,
  }) => throw UnsupportedError(
    'disablePullRequestAutoMerge is not supported by $forge',
  );
}

Future<ForgeSearchResult> _searchForge({
  required ForgeCommandTransport transport,
  required String forge,
  required String cwd,
  required String query,
  required int? limit,
  required List<ForgeSearchKind>? kinds,
}) async {
  final requested = kinds?.toSet() ?? ForgeSearchKind.values.toSet();
  final trimmedQuery = query.trim();
  final executable = switch (forge) {
    'github' => 'gh',
    'gitlab' => 'glab',
    _ => 'tea',
  };
  List<String> argsFor(ForgeSearchKind kind) => switch ((forge, kind)) {
    ('github', ForgeSearchKind.issue) => [
      'issue',
      'list',
      '--search',
      query,
      '--json',
      'number,title,url,state,body,labels,updatedAt',
      '--limit',
      '${limit ?? 20}',
    ],
    ('github', ForgeSearchKind.changeRequest) => [
      'pr',
      'list',
      '--search',
      query,
      '--json',
      'number,title,url,state,body,labels,baseRefName,headRefName,updatedAt',
      '--limit',
      '${limit ?? 20}',
    ],
    ('gitlab', ForgeSearchKind.issue) => [
      'issue',
      'list',
      '-O',
      'json',
      if (trimmedQuery.isNotEmpty) ...['--search', trimmedQuery],
      if (limit != null) ...['-P', '$limit'],
    ],
    ('gitlab', ForgeSearchKind.changeRequest) => [
      'mr',
      'list',
      '-F',
      'json',
      if (trimmedQuery.isNotEmpty) ...['--search', trimmedQuery],
      if (limit != null) ...['-P', '$limit'],
    ],
    (_, ForgeSearchKind.issue) => [
      'issue',
      'list',
      '--fields',
      'index,state,author,url,title,body,labels,comments,created,updated',
      '--state',
      'open',
      '-o',
      'json',
      if (limit != null) ...['--limit', '$limit'],
    ],
    (_, ForgeSearchKind.changeRequest) => [
      'pr',
      'list',
      '--fields',
      'index,state,author,url,title,body,mergeable,base,head,created,updated,labels,comments,ci',
      '--state',
      'open',
      '-o',
      'json',
      if (limit != null) ...['--limit', '$limit'],
    ],
  };

  Future<_SearchAttempt> load(ForgeSearchKind kind) async {
    if (!requested.contains(kind)) return _SearchAttempt.skipped(kind);
    final args = argsFor(kind);
    try {
      var rows = _jsonMapList(
        decodeForgeJson(
          await runForgeCli(transport, executable, args, cwd: cwd),
          executable: executable,
          args: args,
          cwd: cwd,
        ),
        executable: executable,
        args: args,
        cwd: cwd,
      );
      if (executable == 'tea' && trimmedQuery.isNotEmpty) {
        final normalized = trimmedQuery.toLowerCase();
        rows = rows
            .where(
              (row) => (_string(row, 'title', nullable: true) ?? '')
                  .toLowerCase()
                  .contains(normalized),
            )
            .toList();
      }
      return _SearchAttempt.success(kind, rows);
    } catch (error) {
      return _SearchAttempt.failure(kind, error);
    }
  }

  final attempts = await Future.wait([
    load(ForgeSearchKind.issue),
    load(ForgeSearchKind.changeRequest),
  ]);
  final active = attempts.where((attempt) => attempt.requested).toList();
  if (active.isNotEmpty &&
      active.every(
        (attempt) =>
            attempt.error is ForgeCliMissingException ||
            attempt.error is ForgeAuthenticationException,
      )) {
    return ForgeSearchResult.unavailable(
      active.any((attempt) => attempt.error is ForgeCliMissingException)
          ? ForgeAuthState.cliMissing
          : ForgeAuthState.unauthenticated,
    );
  }
  if (forge != 'github') {
    for (final attempt in active) {
      final error = attempt.error;
      if (error != null &&
          error is! ForgeCliMissingException &&
          error is! ForgeAuthenticationException) {
        throw error;
      }
    }
  }
  final items = <ForgeSearchItem>[
    for (final attempt in active)
      for (final row in attempt.rows ?? const <Map<String, Object?>>[])
        _searchItem(row, kind: attempt.kind, forge: forge),
  ]..sort(_newestSearchItemFirst);
  return ForgeSearchResult(
    items: List.unmodifiable(items),
    authState: ForgeAuthState.authenticated,
  );
}

final class _SearchAttempt {
  const _SearchAttempt._({
    required this.kind,
    required this.requested,
    required this.rows,
    required this.error,
  });

  factory _SearchAttempt.skipped(ForgeSearchKind kind) =>
      _SearchAttempt._(kind: kind, requested: false, rows: null, error: null);

  factory _SearchAttempt.success(
    ForgeSearchKind kind,
    List<Map<String, Object?>> rows,
  ) => _SearchAttempt._(kind: kind, requested: true, rows: rows, error: null);

  factory _SearchAttempt.failure(ForgeSearchKind kind, Object error) =>
      _SearchAttempt._(kind: kind, requested: true, rows: null, error: error);

  final ForgeSearchKind kind;
  final bool requested;
  final List<Map<String, Object?>>? rows;
  final Object? error;
}

ForgeSearchItem _searchItem(
  Map<String, Object?> row, {
  required ForgeSearchKind kind,
  required String forge,
}) {
  final gitLab = row.containsKey('iid') || row.containsKey('web_url');
  final gitea = !gitLab && !row.containsKey('number');
  final number = _int(
    row,
    gitLab
        ? 'iid'
        : gitea
        ? 'index'
        : 'number',
  );
  final url = _string(row, gitLab ? 'web_url' : 'url')!;
  final updatedKey = gitLab
      ? 'updated_at'
      : row.containsKey('updatedAt')
      ? 'updatedAt'
      : 'updated';
  return ForgeSearchItem(
    kind: kind,
    forge: forge,
    number: number,
    title: _string(row, 'title')!,
    url: url,
    state: _string(row, 'state')!,
    body: _string(row, gitLab ? 'description' : 'body', nullable: true),
    labels: _searchLabels(row['labels']),
    projectPath:
        _gitLabProjectPath(row) ?? _projectPathFromSearchUrl(url, forge),
    baseRefName: kind == ForgeSearchKind.changeRequest
        ? _searchRef(
            row[gitLab
                ? 'target_branch'
                : gitea
                ? 'base'
                : 'baseRefName'],
          )
        : null,
    headRefName: kind == ForgeSearchKind.changeRequest
        ? _searchRef(
            row[gitLab
                ? 'source_branch'
                : gitea
                ? 'head'
                : 'headRefName'],
          )
        : null,
    updatedAt: _string(row, updatedKey, nullable: true),
  );
}

String? _gitLabProjectPath(Map<String, Object?> row) {
  final full = _nestedString(row, 'references', 'full', nullable: true);
  return full?.split(RegExp(r'[#!]')).firstOrNull?.trim();
}

String? _projectPathFromSearchUrl(String value, String forge) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final marker = forge == 'gitlab'
      ? parts.indexOf('-')
      : parts.indexWhere(
          (part) => part == 'issues' || part == 'pull' || part == 'pulls',
        );
  if (marker < 2) return null;
  return parts.sublist(0, marker).join('/');
}

String? _searchRef(Object? value) {
  if (value is String) {
    final separator = value.indexOf(':');
    return separator < 0 ? value : value.substring(separator + 1);
  }
  final ref = _giteaRef(value);
  if (ref.isEmpty) return null;
  final separator = ref.indexOf(':');
  return separator < 0 ? ref : ref.substring(separator + 1);
}

List<String> _searchLabels(Object? value) {
  if (value is! List) return const [];
  return [
    for (final label in value)
      if (label is String)
        label
      else if (label is Map && label['name'] is String)
        label['name']! as String,
  ];
}

int _newestSearchItemFirst(ForgeSearchItem left, ForgeSearchItem right) {
  final leftTime =
      DateTime.tryParse(left.updatedAt ?? '')?.millisecondsSinceEpoch ?? 0;
  final rightTime =
      DateTime.tryParse(right.updatedAt ?? '')?.millisecondsSinceEpoch ?? 0;
  return rightTime.compareTo(leftTime);
}

ForgePullRequestStatus _githubStatus(
  Map<String, Object?> row, {
  Map<String, Object?>? forgeSpecific,
}) {
  final mergedAt = _string(row, 'mergedAt', nullable: true);
  final checks = _githubChecks(row['statusCheckRollup']);
  final identity = _identityFromChangeRequestUrl(
    _string(row, 'url')!,
    marker: 'pull',
  );
  return ForgePullRequestStatus(
    number: _int(row, 'number'),
    repoOwner: identity?.$1,
    repoName: identity?.$2,
    url: _string(row, 'url')!,
    title: _string(row, 'title')!,
    state: _githubState(row),
    baseRefName: _string(row, 'baseRefName')!,
    headRefName: _string(row, 'headRefName')!,
    isMerged: mergedAt != null,
    isDraft: _bool(row, 'isDraft', fallback: false),
    mergeable: _mergeable(row['mergeable']),
    checks: checks,
    checksStatus: computeForgeChecksStatus(checks),
    reviewDecision: _reviewDecision(row['reviewDecision']),
    forgeSpecific: forgeSpecific,
  );
}

Future<Map<String, Object?>?> _loadGitHubPullRequestStatusFacts({
  required ForgeCommandTransport transport,
  required String cwd,
  required String owner,
  required String name,
  required int number,
}) async {
  final args = [
    'api',
    'graphql',
    '-f',
    'query=$_githubPullRequestStatusFactsQuery',
    '-F',
    'owner=$owner',
    '-F',
    'name=$name',
    '-F',
    'number=$number',
  ];
  try {
    final decoded = decodeForgeJson(
      await runForgeCli(
        transport,
        'gh',
        args,
        cwd: cwd,
        environment: const {'GH_PROMPT_DISABLED': '1'},
      ),
      executable: 'gh',
      args: args,
      cwd: cwd,
    );
    final data = _map(_map(decoded)['data']);
    final repositoryValue = data['repository'];
    if (repositoryValue is! Map) return null;
    final repository = _map(repositoryValue);
    final pullRequestValue = repository['pullRequest'];
    if (pullRequestValue is! Map) return null;
    final pullRequest = _map(pullRequestValue);
    final autoMergeRequest = _map(pullRequest['autoMergeRequest']);
    return {
      'forge': 'github',
      'mergeStateStatus': _string(
        pullRequest,
        'mergeStateStatus',
        nullable: true,
      ),
      'autoMergeRequest': autoMergeRequest.isEmpty
          ? null
          : {
              'enabledAt': _string(
                autoMergeRequest,
                'enabledAt',
                nullable: true,
              ),
              'mergeMethod': _string(
                autoMergeRequest,
                'mergeMethod',
                nullable: true,
              ),
              'enabledBy': _nestedString(
                autoMergeRequest,
                'enabledBy',
                'login',
                nullable: true,
              ),
            },
      'viewerCanEnableAutoMerge': _bool(
        pullRequest,
        'viewerCanEnableAutoMerge',
        fallback: false,
      ),
      'viewerCanDisableAutoMerge': _bool(
        pullRequest,
        'viewerCanDisableAutoMerge',
        fallback: false,
      ),
      'viewerCanMergeAsAdmin': _bool(
        pullRequest,
        'viewerCanMergeAsAdmin',
        fallback: false,
      ),
      'viewerCanUpdateBranch': _bool(
        pullRequest,
        'viewerCanUpdateBranch',
        fallback: false,
      ),
      'repository': {
        'autoMergeAllowed': _bool(
          repository,
          'autoMergeAllowed',
          fallback: false,
        ),
        'mergeCommitAllowed': _bool(
          repository,
          'mergeCommitAllowed',
          fallback: false,
        ),
        'squashMergeAllowed': _bool(
          repository,
          'squashMergeAllowed',
          fallback: false,
        ),
        'rebaseMergeAllowed': _bool(
          repository,
          'rebaseMergeAllowed',
          fallback: false,
        ),
        'viewerDefaultMergeMethod': _string(
          repository,
          'viewerDefaultMergeMethod',
          nullable: true,
        ),
      },
      'isMergeQueueEnabled': _bool(
        pullRequest,
        'isMergeQueueEnabled',
        fallback: false,
      ),
      'isInMergeQueue': _bool(pullRequest, 'isInMergeQueue', fallback: false),
    };
  } on ForgeCommandException {
    return null;
  }
}

ForgePullRequestStatus _gitLabStatus(Map<String, Object?> row) {
  final state = _gitLabState(row);
  final reference = _nestedString(row, 'references', 'full', nullable: true);
  final projectPath = reference?.split('!').firstOrNull?.trim();
  final segments = projectPath
      ?.split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  final pipeline = _map(row['head_pipeline']);
  final pipelineStatus = _string(pipeline, 'status', nullable: true);
  return ForgePullRequestStatus(
    number: _int(row, 'iid'),
    repoOwner: segments != null && segments.length > 1
        ? segments.sublist(0, segments.length - 1).join('/')
        : null,
    repoName: segments?.lastOrNull,
    projectPath: projectPath,
    url: _string(row, 'web_url')!,
    title: _string(row, 'title')!,
    state: state,
    baseRefName: _string(row, 'target_branch')!,
    headRefName: _string(row, 'source_branch')!,
    isMerged:
        state == 'merged' || _string(row, 'merged_at', nullable: true) != null,
    isDraft:
        _bool(row, 'draft', fallback: false) ||
        _bool(row, 'work_in_progress', fallback: false),
    mergeable: _gitLabMergeable(row),
    checks: const [],
    checksStatus: _pipelineChecksStatus(pipelineStatus),
    reviewDecision: null,
    forgeSpecific: {
      'forge': 'gitlab',
      'detailedMergeStatus': _string(
        row,
        'detailed_merge_status',
        nullable: true,
      ),
      'mergeStatus': _string(row, 'merge_status', nullable: true),
      'hasConflicts': _bool(row, 'has_conflicts', fallback: false),
      'blockingDiscussionsResolved': _bool(
        row,
        'blocking_discussions_resolved',
        fallback: true,
      ),
      'approvalsRequired': _num(row, 'approvals_required') ?? 0,
      'approvalsGiven': _num(row, 'approvals_given') ?? 0,
      'pipelineStatus': pipelineStatus,
      'pipelineId': _num(pipeline, 'id'),
      'pipelineUrl': _string(pipeline, 'web_url', nullable: true),
      'mergeWhenPipelineSucceeds': _bool(
        row,
        'merge_when_pipeline_succeeds',
        fallback: false,
      ),
    },
  );
}

ForgePullRequestStatus _giteaStatus(Map<String, Object?> row) {
  final state = _giteaState(row);
  final identity = _identityFromChangeRequestUrl(
    _string(row, 'url')!,
    marker: 'pulls',
  );
  return ForgePullRequestStatus(
    number: _int(row, 'index'),
    repoOwner: identity?.$1,
    repoName: identity?.$2,
    projectPath: identity == null ? null : '${identity.$1}/${identity.$2}',
    url: _string(row, 'url')!,
    title: _string(row, 'title')!,
    state: state,
    baseRefName: _giteaRef(row['base']),
    headRefName: _giteaHead(row),
    isMerged: state == 'merged',
    isDraft: _bool(row, 'draft', fallback: false),
    mergeable: _bool(row, 'mergeable', fallback: false)
        ? ForgeMergeable.mergeable
        : ForgeMergeable.unknown,
    checks: const [],
    checksStatus: _giteaChecksStatus(_string(row, 'ci', nullable: true)),
    reviewDecision: null,
    forgeSpecific: {
      'forge': 'gitea',
      'mergeable': _bool(row, 'mergeable', fallback: false),
      'hasMerged':
          _bool(row, 'has_merged', fallback: false) || state == 'merged',
      'ciStatus': _string(row, 'ci', nullable: true),
    },
  );
}

List<ForgeCheck> _githubChecks(Object? value) {
  final rows = value is List
      ? value.whereType<Map>().map((row) => Map<String, Object?>.from(row))
      : const Iterable<Map<String, Object?>>.empty();
  return [
    for (final row in rows)
      ForgeCheck(
        name:
            _string(row, 'name', nullable: true) ??
            _string(row, 'context', nullable: true) ??
            'Check',
        status: _githubCheckStatus(row),
        url:
            _string(row, 'detailsUrl', nullable: true) ??
            _string(row, 'targetUrl', nullable: true),
        workflow: _string(row, 'workflowName', nullable: true),
        duration: _duration(row),
      ),
  ];
}

ForgeCheckStatus _githubCheckStatus(Map<String, Object?> row) {
  final raw = [
    _string(row, 'conclusion', nullable: true),
    _string(row, 'state', nullable: true),
    _string(row, 'status', nullable: true),
  ].whereType<String>().join(' ').toLowerCase();
  if (RegExp(r'failure|failed|error|timed_out|action_required').hasMatch(raw)) {
    return ForgeCheckStatus.failure;
  }
  if (RegExp(r'cancel').hasMatch(raw)) return ForgeCheckStatus.cancelled;
  if (RegExp(r'skip|neutral').hasMatch(raw)) return ForgeCheckStatus.skipped;
  if (RegExp(r'success|completed').hasMatch(raw)) {
    return ForgeCheckStatus.success;
  }
  return ForgeCheckStatus.pending;
}

String? _duration(Map<String, Object?> row) {
  final start = DateTime.tryParse(
    _string(row, 'startedAt', nullable: true) ?? '',
  );
  final end = DateTime.tryParse(
    _string(row, 'completedAt', nullable: true) ?? '',
  );
  if (start == null || end == null || end.isBefore(start)) return null;
  final seconds = end.difference(start).inSeconds;
  return seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m ${seconds % 60}s';
}

ForgeReviewDecision? _reviewDecision(Object? value) =>
    switch (value?.toString().toUpperCase()) {
      'APPROVED' => ForgeReviewDecision.approved,
      'CHANGES_REQUESTED' => ForgeReviewDecision.changesRequested,
      'REVIEW_REQUIRED' || 'PENDING' => ForgeReviewDecision.pending,
      _ => null,
    };

ForgeMergeable _mergeable(Object? value) =>
    switch (value?.toString().toUpperCase()) {
      'MERGEABLE' => ForgeMergeable.mergeable,
      'CONFLICTING' => ForgeMergeable.conflicting,
      _ => ForgeMergeable.unknown,
    };

ForgeMergeable _gitLabMergeable(Map<String, Object?> row) {
  if (_bool(row, 'has_conflicts', fallback: false)) {
    return ForgeMergeable.conflicting;
  }
  final detailed = _string(
    row,
    'detailed_merge_status',
    nullable: true,
  )?.toLowerCase();
  final status = _string(row, 'merge_status', nullable: true)?.toLowerCase();
  if (const {'mergeable', 'can_be_merged'}.contains(detailed) ||
      const {'can_be_merged'}.contains(status)) {
    return ForgeMergeable.mergeable;
  }
  return ForgeMergeable.unknown;
}

ForgeChecksStatus _pipelineChecksStatus(String? value) =>
    switch (value?.toLowerCase()) {
      null || '' => ForgeChecksStatus.none,
      'success' || 'passed' => ForgeChecksStatus.success,
      'failed' || 'failure' || 'canceled' => ForgeChecksStatus.failure,
      _ => ForgeChecksStatus.pending,
    };

ForgeChecksStatus _giteaChecksStatus(String? value) =>
    _pipelineChecksStatus(value);

String _githubState(Map<String, Object?> row) {
  if (_string(row, 'mergedAt', nullable: true) != null) return 'merged';
  return _string(row, 'state')!.toLowerCase();
}

String _gitLabState(Map<String, Object?> row) =>
    switch (_string(row, 'state')!.toLowerCase()) {
      'opened' || 'reopened' => 'open',
      'merged' => 'merged',
      'closed' => 'closed',
      final value => value,
    };

String _giteaState(Map<String, Object?> row) {
  if (_bool(row, 'has_merged', fallback: false)) return 'merged';
  return switch (_string(row, 'state')!.toLowerCase()) {
    'opened' => 'open',
    final value => value,
  };
}

String _giteaHead(Map<String, Object?> row) {
  final value = _giteaRef(row['head']);
  final separator = value.indexOf(':');
  return separator < 0 ? value : value.substring(separator + 1);
}

String _giteaRef(Object? value) {
  if (value is String) return value;
  if (value is Map) {
    final map = Map<String, Object?>.from(value);
    return _string(map, 'ref', nullable: true) ??
        _string(map, 'label', nullable: true) ??
        '';
  }
  return '';
}

bool _matchesGiteaOwner(Map<String, Object?> row, String? expectedOwner) {
  if (expectedOwner == null) return true;
  final head = _giteaRef(row['head']);
  final separator = head.indexOf(':');
  return separator < 0 || head.substring(0, separator) == expectedOwner;
}

Map<String, Object?> _giteaApiToListRow(Map<String, Object?> row) {
  final head = _map(row['head']);
  final base = _map(row['base']);
  final headRepository = _map(head['repo']);
  final ownerMap = _map(headRepository['owner']);
  final owner = _string(ownerMap, 'login', nullable: true);
  final ref = _string(head, 'ref', nullable: true) ?? '';
  return {
    'index': row['number'] ?? row['index'],
    'title': row['title'],
    'state': row['state'],
    'url': row['html_url'] ?? row['url'],
    'base': _string(base, 'ref', nullable: true) ?? '',
    'head': owner == null ? ref : '$owner:$ref',
    'head_sha': _string(head, 'sha', nullable: true),
    'mergeable': row['mergeable'],
    'has_merged': row['merged'] ?? row['has_merged'],
    'draft': row['draft'],
    'ci': row['ci'],
  };
}

(String, String)? _identityFromChangeRequestUrl(
  String value, {
  required String marker,
}) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final markerIndex = parts.indexOf(marker);
  if (markerIndex < 2) return null;
  return (parts[markerIndex - 2], parts[markerIndex - 1]);
}

bool _isStatusRollupPermissionError(String value) {
  final normalized = value.toLowerCase();
  return normalized.contains('statuscheckrollup') &&
      (normalized.contains('permission') ||
          normalized.contains('resource not accessible') ||
          normalized.contains('forbidden'));
}

ForgePullRequestCreateResult _createResultFromUrl(
  String output,
  RegExp pattern, {
  required String executable,
  required List<String> args,
  required String cwd,
}) {
  final match = pattern.firstMatch(output);
  final number = int.tryParse(match?.group(1) ?? '');
  if (match == null || number == null) {
    throw ForgeCommandException(
      executable: executable,
      args: List.unmodifiable(args),
      cwd: cwd,
      exitCode: null,
      stderr:
          '$executable reported a created change request but returned no URL',
    );
  }
  return ForgePullRequestCreateResult(url: match.group(0)!, number: number);
}

void _assertGitHubDirectMergeReady(
  ForgePullRequestStatus status,
  CheckoutPrMergeMethod mergeMethod,
) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'github') {
    throw StateError(
      'GitHub merge facts are unavailable for this pull request',
    );
  }
  final mergeState = facts!['mergeStateStatus'];
  if (mergeState != 'CLEAN' && mergeState != 'HAS_HOOKS') {
    throw StateError(
      'GitHub does not report this pull request as ready for direct merge',
    );
  }
  if (facts['isMergeQueueEnabled'] == true || facts['isInMergeQueue'] == true) {
    throw StateError(
      'Direct merge is not available because this repository uses a merge queue',
    );
  }
  if (facts['autoMergeRequest'] != null) {
    throw StateError(
      'Direct merge is not available because auto-merge is already enabled',
    );
  }
  final repository = _map(facts['repository']);
  if (!_isGitHubMergeMethodAllowed(repository, mergeMethod)) {
    throw StateError(
      'Direct merge is not available because ${mergeMethod.name} is disabled',
    );
  }
}

void _assertGitHubAutoMergeEnableReady(
  ForgePullRequestStatus status,
  CheckoutPrMergeMethod mergeMethod,
) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'github') {
    throw StateError(
      'GitHub auto-merge facts are unavailable for this pull request',
    );
  }
  if (facts!['mergeStateStatus'] != 'BLOCKED') {
    throw StateError(
      'GitHub does not report this pull request as blocked for auto-merge',
    );
  }
  if (facts['viewerCanEnableAutoMerge'] != true) {
    throw StateError('GitHub does not allow this viewer to enable auto-merge');
  }
  final repository = _map(facts['repository']);
  if (repository['autoMergeAllowed'] != true) {
    throw StateError('Auto-merge is disabled for this repository');
  }
  if (!_isGitHubMergeMethodAllowed(repository, mergeMethod)) {
    throw StateError(
      'Auto-merge is not available because ${mergeMethod.name} is disabled',
    );
  }
  if (facts['autoMergeRequest'] != null) {
    throw StateError('Auto-merge is already enabled for this pull request');
  }
  if (facts['isMergeQueueEnabled'] == true || facts['isInMergeQueue'] == true) {
    throw StateError(
      'Auto-merge is not available because this repository uses a merge queue',
    );
  }
  if (status.mergeable == ForgeMergeable.conflicting) {
    throw StateError(
      'Auto-merge is not available because this pull request has conflicts',
    );
  }
}

void _assertGitHubAutoMergeDisableReady(ForgePullRequestStatus status) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'github') {
    throw StateError(
      'GitHub auto-merge facts are unavailable for this pull request',
    );
  }
  if (facts!['autoMergeRequest'] == null) {
    throw StateError('Auto-merge is not enabled for this pull request');
  }
  if (facts['viewerCanDisableAutoMerge'] != true) {
    throw StateError('GitHub does not allow this viewer to disable auto-merge');
  }
  if (facts['isMergeQueueEnabled'] == true || facts['isInMergeQueue'] == true) {
    throw StateError(
      'Auto-merge is not available because this repository uses a merge queue',
    );
  }
}

bool _isGitHubMergeMethodAllowed(
  Map<String, Object?> repository,
  CheckoutPrMergeMethod mergeMethod,
) => switch (mergeMethod) {
  CheckoutPrMergeMethod.merge => repository['mergeCommitAllowed'] == true,
  CheckoutPrMergeMethod.squash => repository['squashMergeAllowed'] == true,
  CheckoutPrMergeMethod.rebase => repository['rebaseMergeAllowed'] == true,
};

void _assertGitLabDirectMergeReady(ForgePullRequestStatus status) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'gitlab') {
    throw StateError(
      'GitLab merge facts are unavailable for this merge request',
    );
  }
  if (facts!['mergeWhenPipelineSucceeds'] == true) {
    throw StateError(
      'Direct merge is not available because auto-merge is already enabled',
    );
  }
  final detailed = facts['detailedMergeStatus'];
  final legacyReady =
      detailed == null &&
      facts['mergeStatus'] == 'can_be_merged' &&
      facts['hasConflicts'] != true;
  if (detailed != 'mergeable' && !legacyReady) {
    throw StateError(
      'GitLab does not report this merge request as ready for direct merge',
    );
  }
}

void _assertGitLabAutoMergeEnableReady(ForgePullRequestStatus status) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'gitlab') {
    throw StateError(
      'GitLab auto-merge facts are unavailable for this merge request',
    );
  }
  if (facts!['mergeWhenPipelineSucceeds'] == true) {
    throw StateError('Auto-merge is already enabled for this merge request');
  }
  if (!const {
    'created',
    'waiting_for_resource',
    'preparing',
    'pending',
    'running',
    'scheduled',
  }.contains(facts['pipelineStatus'])) {
    throw StateError(
      'GitLab auto-merge requires an in-progress pipeline; without one the merge would run immediately',
    );
  }
}

void _assertGiteaDirectMergeReady(ForgePullRequestStatus status) {
  final facts = status.forgeSpecific;
  if (facts?['forge'] != 'gitea') {
    throw StateError('Gitea merge facts are unavailable for this pull request');
  }
  if (facts!['hasMerged'] == true) {
    throw StateError('This pull request is already merged');
  }
  if (facts['mergeable'] != true) {
    throw StateError(
      'Gitea does not report this pull request as ready for direct merge',
    );
  }
}

CheckoutCheckAnnotation _githubCheckAnnotation(
  Map<String, Object?> annotation,
) => CheckoutCheckAnnotation(
  path: _string(annotation, 'path', nullable: true),
  startLine: _num(annotation, 'start_line'),
  endLine: _num(annotation, 'end_line'),
  annotationLevel: _string(annotation, 'annotation_level', nullable: true),
  message: _string(annotation, 'message', nullable: true),
  title: _string(annotation, 'title', nullable: true),
  rawDetails: _string(annotation, 'raw_details', nullable: true),
);

bool _isFailedGitHubJob(Map<String, Object?> job) => const {
  'failure',
  'cancelled',
  'timed_out',
  'action_required',
}.contains(_string(job, 'conclusion', nullable: true));

final class _CheckLogTail {
  const _CheckLogTail(this.tail, this.truncated);
  final String tail;
  final bool truncated;
}

_CheckLogTail _capCheckLogTail(String log) {
  final lines = log.split('\n');
  var truncated = lines.length > 200;
  var tail = lines.skip(lines.length > 200 ? lines.length - 200 : 0).join('\n');
  if (utf8.encode(tail).length > 16 * 1024) {
    truncated = true;
    var lower = 0;
    var upper = tail.length;
    while (lower < upper) {
      final midpoint = (lower + upper) ~/ 2;
      if (utf8.encode(tail.substring(midpoint)).length > 16 * 1024) {
        lower = midpoint + 1;
      } else {
        upper = midpoint;
      }
    }
    tail = tail.substring(lower);
  }
  return _CheckLogTail(tail, truncated);
}

CheckoutCheckDetails _gitLabCheckDetails(Map<String, Object?> pipeline) {
  final jobs = _mapList(pipeline['jobs'])
    ..sort((left, right) => _int(left, 'id').compareTo(_int(right, 'id')));
  final stages = <String, List<CheckoutPipelineJob>>{};
  for (final raw in jobs) {
    final stage = _string(raw, 'stage')!;
    stages
        .putIfAbsent(stage, () => [])
        .add(
          CheckoutPipelineJob(
            id: _int(raw, 'id'),
            name: _string(raw, 'name')!,
            stage: stage,
            status: _pipelineJobStatus(_string(raw, 'status')!),
            rawStatus: _string(raw, 'status')!,
            url: _string(raw, 'web_url', nullable: true),
            allowFailure: _bool(raw, 'allow_failure', fallback: false),
            durationSeconds: _num(raw, 'duration'),
          ),
        );
  }
  final pipelineStages = [
    for (final entry in stages.entries)
      CheckoutPipelineStage(
        name: entry.key,
        status: _aggregatePipelineStage(entry.value),
        jobs: List.unmodifiable(entry.value),
      ),
  ];
  final id = _int(pipeline, 'id');
  final rawStatus = _string(pipeline, 'status')!;
  final ref = _string(pipeline, 'ref', nullable: true);
  final url = _string(pipeline, 'web_url', nullable: true);
  return CheckoutCheckDetails(
    checkRunId: id,
    name: ref == null ? 'Pipeline #$id' : 'Pipeline ($ref)',
    status: null,
    conclusion: null,
    url: url,
    detailsUrl: url,
    output: null,
    annotations: const [],
    failedJobs: const [],
    truncated: false,
    pipeline: CheckoutPipeline(
      id: id,
      status: _pipelineJobStatus(rawStatus),
      rawStatus: rawStatus,
      url: url,
      ref: ref,
      sha: _string(pipeline, 'sha', nullable: true),
      stages: pipelineStages,
    ),
  );
}

String _pipelineJobStatus(String raw) => switch (raw) {
  'success' || 'passed' => 'success',
  'failed' => 'failed',
  'running' => 'running',
  'pending' ||
  'waiting_for_resource' ||
  'preparing' ||
  'scheduled' => 'pending',
  'created' => 'created',
  'canceled' || 'cancelled' => 'canceled',
  'skipped' => 'skipped',
  'manual' => 'manual',
  _ => 'unknown',
};

String _aggregatePipelineStage(List<CheckoutPipelineJob> jobs) {
  final present = {
    for (final job in jobs)
      job.status == 'failed' && job.allowFailure ? 'success' : job.status,
  };
  for (final status in const [
    'running',
    'failed',
    'pending',
    'created',
    'manual',
    'canceled',
    'skipped',
    'success',
  ]) {
    if (present.contains(status)) return status;
  }
  return 'unknown';
}

CheckoutCheckDetails _giteaCommitCheckDetails(Map<String, Object?> status) {
  final id = _int(status, 'id');
  final context = _string(status, 'context', nullable: true) ?? '';
  final description = _string(status, 'description', nullable: true);
  return CheckoutCheckDetails(
    checkRunId: id,
    name: context.isEmpty ? 'status-$id' : context,
    status: _string(status, 'status')!,
    conclusion: _giteaCommitConclusion(_string(status, 'status')!),
    url: _string(status, 'target_url', nullable: true),
    detailsUrl: _string(status, 'url', nullable: true),
    output: description == null
        ? null
        : {
            'title': context.isEmpty ? null : context,
            'summary': description,
            'text': null,
          },
    annotations: const [],
    failedJobs: const [],
    truncated: false,
  );
}

CheckoutCheckDetails _giteaActionsCheckDetails(Map<String, Object?> run) {
  final id = _int(run, 'id');
  final name =
      _string(run, 'name', nullable: true) ??
      _string(run, 'display_title', nullable: true) ??
      _string(run, 'workflow_id', nullable: true) ??
      'actions-$id';
  final rawStatus = _string(run, 'status')!;
  final url = _string(run, 'url', nullable: true);
  return CheckoutCheckDetails(
    checkRunId: id,
    workflowRunId: id,
    name: name,
    status: rawStatus,
    conclusion: _giteaActionsConclusion(rawStatus),
    url: url,
    detailsUrl: url,
    output: {
      'title':
          _string(run, 'display_title', nullable: true) ??
          _string(run, 'name', nullable: true) ??
          _string(run, 'workflow_id', nullable: true),
      'summary': _string(run, 'workflow_id', nullable: true),
      'text': null,
    },
    annotations: const [],
    failedJobs: const [],
    truncated: false,
  );
}

String _giteaCommitConclusion(String status) => switch (status.toLowerCase()) {
  'success' => 'success',
  'failure' || 'error' || 'warning' => 'failure',
  _ => 'pending',
};

String _giteaActionsConclusion(String status) => switch (status.toLowerCase()) {
  'success' => 'success',
  'failure' || 'failed' || 'error' => 'failure',
  'cancelled' || 'canceled' => 'cancelled',
  'skipped' => 'skipped',
  _ => 'pending',
};

ForgePullRequestTimeline _githubTimeline(
  Map<String, Object?> document, {
  required int fallbackNumber,
}) {
  final repository = _map(_map(document['data'])['repository']);
  final rawPullRequest = repository['pullRequest'];
  if (rawPullRequest is! Map) {
    return ForgePullRequestTimeline(
      prNumber: fallbackNumber,
      items: const [],
      truncated: false,
      error: const PullRequestTimelineError(
        kind: PullRequestTimelineErrorKind.notFound,
        message: 'Pull request not found',
      ),
    );
  }
  final pullRequest = Map<String, Object?>.from(rawPullRequest);
  final reviewsConnection = _map(pullRequest['reviews']);
  final commentsConnection = _map(pullRequest['comments']);
  final threadsConnection = _map(pullRequest['reviewThreads']);
  final threadItems = <PullRequestTimelineItem>[
    for (final thread in _mapList(threadsConnection['nodes']))
      ..._githubReviewThreadItems(thread),
  ];
  final threadItemIds = {
    for (final item in threadItems)
      if (item.id.isNotEmpty) item.id,
  };
  final items = <PullRequestTimelineItem>[
    for (final review in _mapList(reviewsConnection['nodes']))
      if (_githubTimelineReview(review) case final item?) item,
    for (final comment in _mapList(commentsConnection['nodes']))
      if (!threadItemIds.contains(_string(comment, 'id', nullable: true) ?? ''))
        _githubTimelineComment(comment),
    ...threadItems,
  ]..sort(_compareTimelineItems);
  final threadCommentsTruncated = _mapList(
    threadsConnection['nodes'],
  ).any((thread) => _pageHasNext(_map(thread['comments'])));
  return ForgePullRequestTimeline(
    prNumber: _num(pullRequest, 'number')?.toInt() ?? fallbackNumber,
    items: List.unmodifiable(items),
    truncated:
        _pageHasNext(reviewsConnection) ||
        _pageHasNext(commentsConnection) ||
        _pageHasNext(threadsConnection) ||
        threadCommentsTruncated,
    error: null,
  );
}

PullRequestTimelineReview? _githubTimelineReview(Map<String, Object?> review) {
  final body = _string(review, 'body', nullable: true) ?? '';
  final state = (_string(review, 'state', nullable: true) ?? '').toUpperCase();
  final reviewState = switch (state) {
    'APPROVED' => PullRequestTimelineReviewState.approved,
    'CHANGES_REQUESTED' => PullRequestTimelineReviewState.changesRequested,
    'COMMENTED' => PullRequestTimelineReviewState.commented,
    _ when body.trim().isNotEmpty => PullRequestTimelineReviewState.commented,
    _ => null,
  };
  if (reviewState == null) return null;
  final author = _map(review['author']);
  return PullRequestTimelineReview(
    id: _string(review, 'id', nullable: true) ?? '',
    author: _string(author, 'login', nullable: true) ?? 'unknown',
    authorUrl: _string(author, 'url', nullable: true),
    avatarUrl: _string(author, 'avatarUrl', nullable: true),
    body: _normalizeGitHubTimelineBody(
      body,
      _string(review, 'bodyHTML', nullable: true) ?? '',
    ),
    createdAt: _parseTimelineTime(
      _string(review, 'submittedAt', nullable: true),
    ),
    url: _string(review, 'url', nullable: true) ?? '',
    reviewState: reviewState,
  );
}

PullRequestTimelineComment _githubTimelineComment(
  Map<String, Object?> comment,
) {
  final author = _map(comment['author']);
  return PullRequestTimelineComment(
    id: _string(comment, 'id', nullable: true) ?? '',
    author: _string(author, 'login', nullable: true) ?? 'unknown',
    authorUrl: _string(author, 'url', nullable: true),
    avatarUrl: _string(author, 'avatarUrl', nullable: true),
    body: _normalizeGitHubTimelineBody(
      _string(comment, 'body', nullable: true) ?? '',
      _string(comment, 'bodyHTML', nullable: true) ?? '',
    ),
    createdAt: _parseTimelineTime(
      _string(comment, 'createdAt', nullable: true),
    ),
    url: _string(comment, 'url', nullable: true) ?? '',
  );
}

List<PullRequestTimelineItem> _githubReviewThreadItems(
  Map<String, Object?> thread,
) => [
  for (final comment in _mapList(_map(thread['comments'])['nodes']))
    PullRequestTimelineComment(
      id: _string(comment, 'id', nullable: true) ?? '',
      author:
          _string(_map(comment['author']), 'login', nullable: true) ??
          'unknown',
      authorUrl: _string(_map(comment['author']), 'url', nullable: true),
      avatarUrl: _string(_map(comment['author']), 'avatarUrl', nullable: true),
      body: _normalizeGitHubTimelineBody(
        _string(comment, 'body', nullable: true) ?? '',
        _string(comment, 'bodyHTML', nullable: true) ?? '',
      ),
      createdAt: _parseTimelineTime(
        _string(comment, 'createdAt', nullable: true),
      ),
      url: _string(comment, 'url', nullable: true) ?? '',
      reviewId: _string(
        _map(comment['pullRequestReview']),
        'id',
        nullable: true,
      ),
      location: PullRequestTimelineCommentLocation(
        path: _string(thread, 'path', nullable: true) ?? '',
        line: _num(thread, 'line'),
        startLine: _num(thread, 'startLine'),
        threadId: _string(thread, 'id', nullable: true),
        isResolved: _bool(thread, 'isResolved', fallback: false),
        isOutdated: _bool(thread, 'isOutdated', fallback: false),
      ),
    ),
];

bool _pageHasNext(Map<String, Object?> connection) =>
    _bool(_map(connection['pageInfo']), 'hasNextPage', fallback: false);

final class _ImageSourceReference {
  const _ImageSourceReference(this.source, this.start, this.end);
  final String source;
  final int start;
  final int end;
}

final _rawMarkdownImagePattern = RegExp(
  r'''!\[[^\]]*\]\(\s*([^\s)]+)(?:\s+["'][^)]*["'])?\s*\)''',
);
final _htmlImagePattern = RegExp(
  r'''<img\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1[^>]*>''',
  caseSensitive: false,
);

String _normalizeGitHubTimelineBody(String body, String bodyHtml) {
  final rawImages = <_ImageSourceReference>[
    ..._htmlImageReferences(body),
    ..._markdownImageReferences(body),
  ]..sort((left, right) => left.start.compareTo(right.start));
  if (rawImages.isEmpty) return body;
  final rendered = _htmlImageReferences(
    bodyHtml,
  ).map((reference) => reference.source).toList(growable: false);
  if (rendered.length != rawImages.length) return body;
  final output = StringBuffer();
  var cursor = 0;
  for (var index = 0; index < rawImages.length; index++) {
    final raw = rawImages[index];
    final replacement = rendered[index];
    if (!_isRawGitHubAttachment(raw.source) ||
        !_isRenderedGitHubImage(replacement)) {
      return body;
    }
    output
      ..write(body.substring(cursor, raw.start))
      ..write(replacement);
    cursor = raw.end;
  }
  output.write(body.substring(cursor));
  return output.toString();
}

List<_ImageSourceReference> _htmlImageReferences(String source) => [
  for (final match in _htmlImagePattern.allMatches(source))
    if ((match.group(2) ?? '').isNotEmpty)
      _ImageSourceReference(
        _decodeHtmlAttribute(match.group(2)!),
        match.start + match.group(0)!.indexOf(match.group(2)!),
        match.start +
            match.group(0)!.indexOf(match.group(2)!) +
            match.group(2)!.length,
      ),
];

List<_ImageSourceReference> _markdownImageReferences(String source) => [
  for (final match in _rawMarkdownImagePattern.allMatches(source))
    if ((match.group(1) ?? '').isNotEmpty)
      _ImageSourceReference(
        match.group(1)!,
        match.start + match.group(0)!.indexOf(match.group(1)!),
        match.start +
            match.group(0)!.indexOf(match.group(1)!) +
            match.group(1)!.length,
      ),
];

bool _isRawGitHubAttachment(String source) {
  final uri = Uri.tryParse(source);
  return uri?.scheme == 'https' &&
      uri?.host == 'github.com' &&
      uri!.path.startsWith('/user-attachments/assets/');
}

bool _isRenderedGitHubImage(String source) {
  final uri = Uri.tryParse(source);
  return uri?.scheme == 'https' &&
      const {
        'camo.githubusercontent.com',
        'private-user-images.githubusercontent.com',
      }.contains(uri?.host);
}

String _decodeHtmlAttribute(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

PullRequestTimelineComment? _gitLabTimelineComment(
  Map<String, Object?> note,
  Map<String, Object?> discussion,
  String mergeRequestUrl,
) {
  if (_bool(note, 'system', fallback: false)) return null;
  final author = _map(note['author']);
  final location = _gitLabTimelineLocation(note, discussion);
  final notes = _mapList(discussion['notes']);
  final individual = discussion['individual_note'];
  final isThread =
      individual == false || (individual != true && notes.length > 1);
  final resolvable = note['resolvable'] == true;
  return PullRequestTimelineComment(
    id: '${_num(note, 'id')?.toInt() ?? ''}',
    author:
        _string(author, 'username', nullable: true) ??
        _string(author, 'name', nullable: true) ??
        'unknown',
    authorUrl: _string(author, 'web_url', nullable: true),
    avatarUrl: _string(author, 'avatar_url', nullable: true),
    body: _string(note, 'body', nullable: true) ?? '',
    createdAt: _parseTimelineTime(_string(note, 'created_at', nullable: true)),
    url: '$mergeRequestUrl#note_${_num(note, 'id')?.toInt() ?? ''}',
    threadId: isThread ? _string(discussion, 'id', nullable: true) : null,
    threadIsResolved: location == null && resolvable
        ? _bool(note, 'resolved', fallback: false)
        : null,
    location: location,
  );
}

PullRequestTimelineCommentLocation? _gitLabTimelineLocation(
  Map<String, Object?> note,
  Map<String, Object?> discussion,
) {
  final rawPosition = note['position'];
  if (rawPosition is! Map) return null;
  final position = Map<String, Object?>.from(rawPosition);
  final path =
      _string(position, 'new_path', nullable: true) ??
      _string(position, 'old_path', nullable: true);
  if (path == null) return null;
  final line = _num(position, 'new_line') ?? _num(position, 'old_line');
  final start = _map(_map(position['line_range'])['start']);
  final startLine = _num(start, 'new_line') ?? _num(start, 'old_line');
  final resolvable = note['resolvable'] == true;
  return PullRequestTimelineCommentLocation(
    path: path,
    line: line,
    startLine: startLine != line ? startLine : null,
    threadId: _string(discussion, 'id', nullable: true),
    isResolved: resolvable ? _bool(note, 'resolved', fallback: false) : null,
  );
}

final class _TimelineBucket {
  const _TimelineBucket(this.items, this.truncated);
  final List<Map<String, Object?>> items;
  final bool truncated;
}

final class _TimelineBucketCapture {
  const _TimelineBucketCapture({this.bucket, this.error});
  final _TimelineBucket? bucket;
  final Object? error;
}

Future<_TimelineBucketCapture> _captureTimelineBucket(
  Future<_TimelineBucket> future,
) async {
  try {
    return _TimelineBucketCapture(bucket: await future);
  } catch (error) {
    return _TimelineBucketCapture(error: error);
  }
}

Future<_TimelineBucket> _loadGiteaTimelinePages({
  required ForgeCommandTransport transport,
  required String cwd,
  required String owner,
  required String repository,
  required String suffix,
}) async {
  final items = <Map<String, Object?>>[];
  for (var page = 1; page <= 4; page++) {
    final args = [
      'api',
      'repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(repository)}/$suffix?page=$page&limit=50',
    ];
    final pageItems = _jsonMapList(
      decodeForgeJson(
        await runForgeCli(transport, 'tea', args, cwd: cwd),
        executable: 'tea',
        args: args,
        cwd: cwd,
      ),
      executable: 'tea',
      args: args,
      cwd: cwd,
    );
    items.addAll(pageItems);
    if (pageItems.length < 50) {
      return _TimelineBucket(List.unmodifiable(items), false);
    }
  }
  return _TimelineBucket(List.unmodifiable(items), true);
}

PullRequestTimelineComment? _giteaTimelineComment(
  Map<String, Object?> comment,
  Map<String, Object?> pullRequest,
) {
  final type = _string(comment, 'type', nullable: true);
  if (type != null && type != 'comment') return null;
  final id = _num(comment, 'id')?.toInt() ?? 0;
  final user = _map(comment['user']);
  final pullRequestUrl =
      _string(pullRequest, 'url', nullable: true) ??
      _string(pullRequest, 'html_url', nullable: true) ??
      '';
  return PullRequestTimelineComment(
    id: '$id',
    author: _giteaUserName(user),
    authorUrl: _string(user, 'html_url', nullable: true),
    avatarUrl: _string(user, 'avatar_url', nullable: true),
    body: _string(comment, 'body', nullable: true) ?? '',
    createdAt: _parseTimelineTime(
      _string(comment, 'created_at', nullable: true),
    ),
    url:
        _string(comment, 'html_url', nullable: true) ??
        '$pullRequestUrl#issuecomment-$id',
  );
}

PullRequestTimelineReview _giteaTimelineReview(Map<String, Object?> review) {
  final user = _map(review['user']);
  final state = (_string(review, 'state', nullable: true) ?? '')
      .trim()
      .toUpperCase();
  final reviewState = switch (state) {
    'APPROVED' || 'APPROVE' => PullRequestTimelineReviewState.approved,
    'REQUEST_CHANGES' ||
    'REQUESTED_CHANGES' ||
    'CHANGES_REQUESTED' => PullRequestTimelineReviewState.changesRequested,
    _ => PullRequestTimelineReviewState.commented,
  };
  return PullRequestTimelineReview(
    id: '${_num(review, 'id')?.toInt() ?? 0}',
    author: _giteaUserName(user),
    authorUrl: _string(user, 'html_url', nullable: true),
    avatarUrl: _string(user, 'avatar_url', nullable: true),
    body: _string(review, 'body', nullable: true) ?? '',
    createdAt: _parseTimelineTime(
      _string(review, 'submitted_at', nullable: true) ??
          _string(review, 'updated_at', nullable: true),
    ),
    url: _string(review, 'html_url', nullable: true) ?? '',
    reviewState: reviewState,
  );
}

PullRequestTimelineComment _giteaTimelineReviewComment(
  Map<String, Object?> comment,
) {
  final user = _map(comment['user']);
  final path = _string(comment, 'path', nullable: true);
  final position =
      _num(comment, 'position') ?? _num(comment, 'original_position');
  final id = _num(comment, 'id')?.toInt() ?? 0;
  final resolved = comment.containsKey('resolver')
      ? comment['resolver'] != null
      : null;
  final location = path == null
      ? null
      : PullRequestTimelineCommentLocation(
          path: path,
          line: _num(comment, 'position'),
          threadId:
              '$path#${position == null ? 'comment-$id' : 'pos-${position.toInt()}'}',
          isResolved: resolved,
        );
  final reviewId = _num(comment, 'pull_request_review_id')?.toInt();
  return PullRequestTimelineComment(
    id: '$id',
    author: _giteaUserName(user),
    authorUrl: _string(user, 'html_url', nullable: true),
    avatarUrl: _string(user, 'avatar_url', nullable: true),
    body: _string(comment, 'body', nullable: true) ?? '',
    createdAt: _parseTimelineTime(
      _string(comment, 'created_at', nullable: true) ??
          _string(comment, 'updated_at', nullable: true),
    ),
    url: _string(comment, 'html_url', nullable: true) ?? '',
    reviewId: reviewId == null ? null : '$reviewId',
    location: location,
  );
}

String _giteaUserName(Map<String, Object?> user) =>
    _string(user, 'login', nullable: true) ??
    _string(user, 'full_name', nullable: true) ??
    'unknown';

int _parseTimelineTime(String? value) =>
    value == null ? 0 : DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;

int _compareTimelineItems(
  PullRequestTimelineItem left,
  PullRequestTimelineItem right,
) {
  final time = left.createdAt.compareTo(right.createdAt);
  return time != 0 ? time : left.id.compareTo(right.id);
}

PullRequestTimelineError _timelineError(Object error) {
  final message = switch (error) {
    ForgeCommandException() when error.stderr.isNotEmpty => error.stderr,
    ForgeCliException() => error.message,
    _ => error.toString(),
  };
  if (error is ForgeAuthenticationException ||
      error is ForgeCliMissingException) {
    return PullRequestTimelineError(
      kind: PullRequestTimelineErrorKind.forbidden,
      message: message,
    );
  }
  final normalized = message.toLowerCase();
  final kind =
      normalized.contains('404') ||
          normalized.contains('not found') ||
          normalized.contains('could not resolve to a pullrequest')
      ? PullRequestTimelineErrorKind.notFound
      : normalized.contains('403') ||
            normalized.contains('forbidden') ||
            normalized.contains('permission') ||
            normalized.contains('resource not accessible') ||
            normalized.contains('access denied') ||
            normalized.contains('requires authentication')
      ? PullRequestTimelineErrorKind.forbidden
      : PullRequestTimelineErrorKind.unknown;
  return PullRequestTimelineError(kind: kind, message: message);
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is Map) Map<String, Object?>.from(entry),
  ];
}

List<Map<String, Object?>> _jsonMapList(
  Object? value, {
  required String executable,
  required List<String> args,
  required String cwd,
}) {
  if (value is List && value.every((entry) => entry is Map)) {
    return [for (final entry in value) Map<String, Object?>.from(entry as Map)];
  }
  throw ForgeCommandException(
    executable: executable,
    args: List.unmodifiable(args),
    cwd: cwd,
    exitCode: null,
    stderr: '$executable JSON must be an array of objects',
  );
}

Map<String, Object?> _jsonMap(
  Object? value, {
  required String executable,
  required List<String> args,
  required String cwd,
}) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw ForgeCommandException(
    executable: executable,
    args: List.unmodifiable(args),
    cwd: cwd,
    exitCode: null,
    stderr: '$executable JSON must be an object',
  );
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};

String? _string(
  Map<String, Object?> value,
  String key, {
  bool nullable = false,
}) {
  final raw = value[key];
  if (raw is String && (nullable || raw.isNotEmpty)) return raw;
  if (nullable && raw == null) return null;
  if (nullable) return null;
  throw FormatException('$key must be a non-empty string');
}

String? _nestedString(
  Map<String, Object?> value,
  String key,
  String nested, {
  bool nullable = false,
}) => _string(_map(value[key]), nested, nullable: nullable);

int _int(Map<String, Object?> value, String key) {
  final raw = value[key];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final parsed = int.tryParse(raw?.toString() ?? '');
  if (parsed != null) return parsed;
  throw FormatException('$key must be an integer');
}

num? _num(Map<String, Object?> value, String key) {
  final raw = value[key];
  return raw is num ? raw : num.tryParse(raw?.toString() ?? '');
}

bool _bool(Map<String, Object?> value, String key, {required bool fallback}) {
  final raw = value[key];
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) return raw.toLowerCase() == 'true';
  return fallback;
}
