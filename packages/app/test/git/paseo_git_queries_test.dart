// Ports of the upstream suites for `git/query-keys.ts`,
// `git/use-commits-query.ts`, `git/use-diff-files.ts` and
// `git/use-forge-search-query.ts`, plus the edge cases those suites leave
// unpinned: the narrow PR-pane sweep (untested upstream), the checkout-key
// guard's rejection rules, TanStack's prefix-vs-predicate matching asymmetry,
// the precedence order inside the commits load-state union, the commit-file
// selection helper, per-file diff aggregation and error precedence, and the
// item/auth-state normalization rules that upstream only exercises through its
// happy paths.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge.dart';
import 'package:coding_agent_app/git/paseo_git_queries.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Mirrors the upstream `createCommitFile` helper; named parameters stand in
/// for TypeScript's partial-override object.
CheckoutCommitFile commitFile({
  required String path,
  int additions = 0,
  int deletions = 0,
  CheckoutCommitFileStatus? status,
}) => CheckoutCommitFile(
  path: path,
  additions: additions,
  deletions: deletions,
  status: status,
);

/// Mirrors the upstream `createParsedDiffFile` helper. `ParsedDiffFile` is
/// `CheckoutDiffFile` in the Dart protocol.
CheckoutDiffFile parsedDiffFile({
  required String path,
  bool isNew = false,
  bool isDeleted = false,
  int additions = 1,
  int deletions = 0,
  List<CheckoutDiffHunk>? hunks,
  CheckoutDiffFileStatus? status,
}) => CheckoutDiffFile(
  path: path,
  isNew: isNew,
  isDeleted: isDeleted,
  additions: additions,
  deletions: deletions,
  hunks:
      hunks ??
      const [
        CheckoutDiffHunk(
          oldStart: 1,
          oldCount: 1,
          newStart: 1,
          newCount: 1,
          lines: [
            CheckoutDiffLine(type: CheckoutDiffLineType.add, content: 'x'),
          ],
        ),
      ],
  status: status,
);

CheckoutCommit checkoutCommit({
  required String sha,
  bool? isOnBase,
  List<CheckoutCommitFile> files = const [],
}) => CheckoutCommit(
  sha: sha,
  shortSha: sha.length >= 7 ? sha.substring(0, 7) : sha,
  subject: 'subject $sha',
  authorName: 'Ada',
  authorDate: '2026-01-01T00:00:00Z',
  isOnRemote: false,
  isOnBase: isOnBase,
  files: files,
);

ClassifiedCheckoutCommit classified({
  required String sha,
  bool isOnBase = false,
  List<CheckoutCommitFile> files = const [],
}) => ClassifiedCheckoutCommit(
  commit: checkoutCommit(sha: sha, isOnBase: isOnBase, files: files),
  isOnBase: isOnBase,
);

/// Upstream's `EMPTY_COMMITS`.
const emptyCommits = CheckoutCommitsData(baseRef: 'main', commits: []);

/// Records every request it is handed, which is how the transport choice and
/// the request rewriting are observed. Mirrors the inline fakes in the upstream
/// `buildForgeSearchQueryOptions` suite.
final class RecordingForgeSearchClient implements ForgeSearchClient {
  RecordingForgeSearchClient({
    this.forgeResponse,
    this.githubResponse,
    this.forgeThrows = false,
  });

  final ForgeSearchResponsePayload? forgeResponse;
  final GitHubSearchResponsePayload? githubResponse;
  final bool forgeThrows;

  final forgeRequests = <ForgeSearchRequestOptions>[];
  final githubRequests = <LegacyGitHubSearchRequestOptions>[];

  @override
  Future<ForgeSearchResponsePayload> searchForge(
    ForgeSearchRequestOptions options, {
    String? requestId,
  }) async {
    if (forgeThrows) throw StateError('unexpected forge search');
    forgeRequests.add(options);
    return forgeResponse ??
        const ForgeSearchResponsePayload(
          items: [],
          authState: 'authenticated',
          error: null,
          requestId: 'forge-request',
        );
  }

  /// Null reproduces upstream's *absent* optional method, which is what makes
  /// the github transport fall through to [searchForge].
  @override
  LegacyGitHubSearchCall? get searchGitHub =>
      githubResponse == null ? null : _searchGitHub;

  Future<GitHubSearchResponsePayload> _searchGitHub(
    LegacyGitHubSearchRequestOptions options, {
    String? requestId,
  }) async {
    githubRequests.add(options);
    return githubResponse!;
  }
}

/// Upstream's `ThisDependentSearchClient`: both entry points delegate to a
/// private method that reads `this`. Dart method tear-offs are always bound, so
/// this can only fail if the port ever routed a call through an unbound
/// function reference.
final class ThisDependentSearchClient implements ForgeSearchClient {
  final requests = <Object>[];

  GitHubSearchResponsePayload _send(
    String requestId,
    LegacyGitHubSearchRequestOptions options,
  ) {
    requests.add(options);
    return GitHubSearchResponsePayload(
      items: const [],
      featuresEnabled: true,
      authState: 'authenticated',
      githubFeaturesEnabled: true,
      error: null,
      requestId: requestId,
    );
  }

  @override
  Future<ForgeSearchResponsePayload> searchForge(
    ForgeSearchRequestOptions options, {
    String? requestId,
  }) async {
    final legacy = _send(
      'forge.search.request',
      LegacyGitHubSearchRequestOptions(
        cwd: options.cwd,
        query: options.query,
        limit: options.limit,
      ),
    );
    return ForgeSearchResponsePayload(
      items: legacy.items,
      authState: legacy.authState,
      error: legacy.error,
      requestId: legacy.requestId,
    );
  }

  @override
  LegacyGitHubSearchCall? get searchGitHub => _searchGitHub;

  Future<GitHubSearchResponsePayload> _searchGitHub(
    LegacyGitHubSearchRequestOptions options, {
    String? requestId,
  }) async => _send('github_search_request', options);
}

void main() {
  // -------------------------------------------------------------------------
  // query-keys.ts
  // -------------------------------------------------------------------------

  group('checkout query keys', () {
    const serverId = 'server-1';
    const cwd = '/tmp/repo';

    test('builds the frozen key shapes', () {
      expect(checkoutStatusQueryKey(serverId, cwd), [
        'checkoutStatus',
        serverId,
        cwd,
      ]);
      expect(checkoutPrStatusQueryKey(serverId, cwd), [
        'checkoutPrStatus',
        serverId,
        cwd,
      ]);
      expect(checkoutCommitsQueryKey(serverId, cwd), [
        'checkoutCommits',
        serverId,
        cwd,
      ]);
      expect(checkoutCommitFileDiffQueryKey(serverId, cwd, 'abc', 'a/b.ts'), [
        'checkoutCommitFileDiff',
        serverId,
        cwd,
        'abc',
        'a/b.ts',
      ]);
    });

    test(
      'normalizes the diff key so omitted options share one cache entry',
      () {
        expect(
          checkoutDiffQueryKey(serverId, cwd, CheckoutDiffMode.uncommitted),
          ['checkoutDiff', serverId, cwd, 'uncommitted', '', false],
        );
        expect(
          checkoutDiffQueryKey(
            serverId,
            cwd,
            CheckoutDiffMode.base,
            'main',
            true,
          ),
          ['checkoutDiff', serverId, cwd, 'base', 'main', true],
        );
        expect(
          checkoutDiffQueryKey(
            serverId,
            cwd,
            CheckoutDiffMode.base,
            null,
            false,
          ),
          checkoutDiffQueryKey(serverId, cwd, CheckoutDiffMode.base),
        );
      },
    );

    test('pins the commit-file-diff stale window', () {
      expect(commitFileDiffStaleTimeMs, 5 * 60000);
    });

    test('invalidates every query for a checkout without touching other '
        'checkouts', () {
      final matchers = checkoutGitInvalidationMatchersForClient(
        serverId: serverId,
        cwd: cwd,
      );
      bool invalidated(CheckoutQueryKey key) =>
          matchesAnyCheckoutQueryMatcher(matchers, key);

      expect(invalidated(checkoutStatusQueryKey(serverId, cwd)), isTrue);
      expect(
        invalidated(
          checkoutDiffQueryKey(
            serverId,
            cwd,
            CheckoutDiffMode.base,
            'main',
            true,
          ),
        ),
        isTrue,
      );
      expect(invalidated(checkoutPrStatusQueryKey(serverId, cwd)), isTrue);
      expect(invalidated(checkoutCommitsQueryKey(serverId, cwd)), isTrue);
      expect(
        invalidated(checkoutCommitsQueryKey(serverId, '/tmp/other')),
        isFalse,
      );
      expect(
        invalidated(
          prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: 12),
        ),
        isTrue,
      );
      expect(
        invalidated(
          prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: 13),
        ),
        isTrue,
      );
      expect(
        invalidated(
          prPanePipelineQueryKey(
            serverId: serverId,
            cwd: cwd,
            pipelineId: 9001,
            changeRequestNumber: 1,
          ),
        ),
        isTrue,
      );
      expect(
        invalidated(
          prPaneTimelineQueryKey(
            serverId: serverId,
            cwd: '/tmp/other',
            prNumber: 12,
          ),
        ),
        isFalse,
      );
      expect(
        invalidated(
          prPanePipelineQueryKey(
            serverId: serverId,
            cwd: '/tmp/other',
            pipelineId: 9001,
            changeRequestNumber: 1,
          ),
        ),
        isFalse,
      );
    });

    test('invalidates fetch-based checkout queries server-wide without '
        'touching other servers', () {
      const otherServerId = 'server-2';
      const otherCwd = '/tmp/repo-2';
      final matchers = checkoutGitInvalidationMatchersForServer(serverId);
      bool invalidated(CheckoutQueryKey key) =>
          matchesAnyCheckoutQueryMatcher(matchers, key);

      expect(invalidated(checkoutStatusQueryKey(serverId, cwd)), isTrue);
      expect(invalidated(checkoutStatusQueryKey(serverId, otherCwd)), isTrue);
      expect(invalidated(checkoutPrStatusQueryKey(serverId, cwd)), isTrue);
      expect(invalidated(checkoutCommitsQueryKey(serverId, cwd)), isTrue);
      expect(invalidated(checkoutCommitsQueryKey(otherServerId, cwd)), isFalse);
      expect(
        invalidated(
          prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: 12),
        ),
        isTrue,
      );
      expect(
        invalidated(
          prPanePipelineQueryKey(
            serverId: serverId,
            cwd: cwd,
            pipelineId: 9001,
            changeRequestNumber: 1,
          ),
        ),
        isTrue,
      );
      // Subscription-fed diff queries are deliberately not part of the
      // server-wide sweep.
      expect(
        invalidated(
          checkoutDiffQueryKey(
            serverId,
            cwd,
            CheckoutDiffMode.base,
            'main',
            true,
          ),
        ),
        isFalse,
      );
      expect(invalidated(checkoutStatusQueryKey(otherServerId, cwd)), isFalse);
    });

    test('selects the invalidated keys in cache order', () {
      final cached = <CheckoutQueryKey>[
        checkoutStatusQueryKey(serverId, cwd),
        checkoutCommitsQueryKey(serverId, '/tmp/other'),
        checkoutCommitsQueryKey(serverId, cwd),
        prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: null),
      ];

      expect(
        selectInvalidatedCheckoutQueryKeys(
          cachedQueryKeys: cached,
          matchers: checkoutGitInvalidationMatchersForClient(
            serverId: serverId,
            cwd: cwd,
          ),
        ),
        [
          checkoutStatusQueryKey(serverId, cwd),
          checkoutCommitsQueryKey(serverId, cwd),
          prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: null),
        ],
      );
    });

    test('sweeps only the PR pane when just its data went stale', () {
      final matchers = prPaneTimelineInvalidationMatchersForCheckout(
        serverId: serverId,
        cwd: cwd,
      );
      bool invalidated(CheckoutQueryKey key) =>
          matchesAnyCheckoutQueryMatcher(matchers, key);

      expect(
        invalidated(
          prPaneTimelineQueryKey(serverId: serverId, cwd: cwd, prNumber: 12),
        ),
        isTrue,
      );
      expect(
        invalidated(
          prPanePipelineQueryKey(
            serverId: serverId,
            cwd: cwd,
            pipelineId: null,
            changeRequestNumber: 3,
          ),
        ),
        isTrue,
      );
      expect(invalidated(checkoutStatusQueryKey(serverId, cwd)), isFalse);
      expect(invalidated(checkoutCommitsQueryKey(serverId, cwd)), isFalse);
      expect(
        invalidated(
          prPaneTimelineQueryKey(
            serverId: serverId,
            cwd: '/tmp/other',
            prNumber: 12,
          ),
        ),
        isFalse,
      );
    });

    test('rejects keys that are not checkout-scoped', () {
      expect(isCheckoutQueryKey(['checkoutStatus', serverId]), isFalse);
      expect(isCheckoutQueryKey(['checkoutStatus', serverId, 7]), isFalse);
      expect(isCheckoutQueryKey(['checkoutStatus', 7, cwd]), isFalse);
      expect(isCheckoutQueryKey([1, serverId, cwd]), isFalse);
      expect(isCheckoutQueryKey(['checkoutStatus', serverId, cwd]), isTrue);
      expect(
        isCheckoutQueryKey(['checkoutStatus', serverId, cwd, 'extra']),
        isTrue,
      );
    });

    test('the kind predicate ignores a non-string cwd slot', () {
      const matcher = CheckoutQueryKindMatcher(
        queryKind: prPaneTimelineQueryKind,
        serverId: serverId,
      );
      expect(
        matchesCheckoutQueryMatcher(matcher, [
          prPaneTimelineQueryKind,
          serverId,
          42,
        ]),
        isFalse,
      );
    });

    test(
      'key-based invalidation matches by prefix, predicate-based by kind',
      () {
        final matchers = checkoutGitInvalidationMatchersForClient(
          serverId: serverId,
          cwd: cwd,
        );
        // TanStack's default `invalidateQueries({queryKey})` is a partial match,
        // so a longer key sharing the checkoutStatus prefix is swept too.
        expect(
          matchesAnyCheckoutQueryMatcher(matchers, [
            ...checkoutStatusQueryKey(serverId, cwd),
            'detail',
          ]),
          isTrue,
        );
        // A prefix matcher on a shorter key cannot match.
        expect(
          matchesCheckoutQueryMatcher(
            CheckoutQueryKeyPrefixMatcher(
              checkoutStatusQueryKey(serverId, cwd),
            ),
            ['checkoutStatus', serverId],
          ),
          isFalse,
        );
      },
    );

    test('key parts compare structurally, not by identity', () {
      expect(
        matchesCheckoutQueryMatcher(
          const CheckoutQueryKeyPrefixMatcher([
            'kind',
            ['a', 'b'],
          ]),
          [
            'kind',
            ['a', 'b'],
            'tail',
          ],
        ),
        isTrue,
      );
      expect(
        matchesCheckoutQueryMatcher(
          const CheckoutQueryKeyPrefixMatcher([
            'kind',
            {'a': 1},
          ]),
          [
            'kind',
            {'a': 2},
          ],
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // use-commits-query.ts
  // -------------------------------------------------------------------------

  group('resolveCheckoutCommitsQueryResult', () {
    test('stays idle while the collapsed section has never loaded', () {
      expect(
        resolveCheckoutCommitsQueryResult(
          enabled: false,
          capabilityPresent: true,
          canFetch: true,
          data: null,
          isPlaceholderData: false,
          error: null,
        ),
        isA<CheckoutCommitsIdle>(),
      );
    });

    test('reports loading instead of an empty result while the first request '
        'is pending', () {
      expect(
        resolveCheckoutCommitsQueryResult(
          enabled: true,
          capabilityPresent: true,
          canFetch: true,
          data: null,
          isPlaceholderData: false,
          error: null,
        ),
        isA<CheckoutCommitsLoading>(),
      );
    });

    test('types an empty commit list as loaded data', () {
      final result = resolveCheckoutCommitsQueryResult(
        enabled: true,
        capabilityPresent: true,
        canFetch: true,
        data: emptyCommits,
        isPlaceholderData: false,
        error: null,
      );
      expect(result, isA<CheckoutCommitsLoaded>());
      expect((result as CheckoutCommitsLoaded).data, same(emptyCommits));
    });

    test('surfaces a cold-load error', () {
      final error = StateError('git log failed');
      final result = resolveCheckoutCommitsQueryResult(
        enabled: true,
        capabilityPresent: true,
        canFetch: true,
        data: null,
        isPlaceholderData: false,
        error: error,
      );
      expect(result, isA<CheckoutCommitsError>());
      expect((result as CheckoutCommitsError).error, same(error));
    });

    test('keeps cached data available while collapsed', () {
      final result = resolveCheckoutCommitsQueryResult(
        enabled: false,
        capabilityPresent: true,
        canFetch: true,
        data: emptyCommits,
        isPlaceholderData: false,
        error: null,
      );
      expect(result, isA<CheckoutCommitsLoaded>());
      expect((result as CheckoutCommitsLoaded).data, same(emptyCommits));
    });

    test('keeps previous-checkout placeholder data in loading state', () {
      expect(
        resolveCheckoutCommitsQueryResult(
          enabled: true,
          capabilityPresent: true,
          canFetch: true,
          data: emptyCommits,
          isPlaceholderData: true,
          error: null,
        ),
        isA<CheckoutCommitsLoading>(),
      );
    });

    test('an unsupported daemon outranks cached data and errors alike', () {
      expect(
        resolveCheckoutCommitsQueryResult(
          enabled: true,
          capabilityPresent: false,
          canFetch: true,
          data: emptyCommits,
          isPlaceholderData: false,
          error: StateError('ignored'),
        ),
        isA<CheckoutCommitsUnsupported>(),
      );
    });

    test(
      'placeholder data on a collapsed section reads as idle, not loading',
      () {
        expect(
          resolveCheckoutCommitsQueryResult(
            enabled: false,
            capabilityPresent: true,
            canFetch: true,
            data: emptyCommits,
            isPlaceholderData: true,
            error: null,
          ),
          isA<CheckoutCommitsIdle>(),
        );
      },
    );

    test(
      'a disconnected host reads as connecting even with an error in hand',
      () {
        expect(
          resolveCheckoutCommitsQueryResult(
            enabled: true,
            capabilityPresent: true,
            canFetch: false,
            data: null,
            isPlaceholderData: false,
            error: StateError('stale failure'),
          ),
          isA<CheckoutCommitsConnecting>(),
        );
      },
    );

    test('an error still surfaces alongside placeholder data', () {
      final error = StateError('git log failed');
      final result = resolveCheckoutCommitsQueryResult(
        enabled: true,
        capabilityPresent: true,
        canFetch: true,
        data: emptyCommits,
        isPlaceholderData: true,
        error: error,
      );
      expect(result, isA<CheckoutCommitsError>());
      expect((result as CheckoutCommitsError).error, same(error));
    });
  });

  group('checkout commits gating', () {
    test('requires both commit capabilities together', () {
      expect(
        checkoutCommitsCapabilityPresent(const {
          'commitsList': true,
          'commitBaseClassification': true,
        }),
        isTrue,
      );
      expect(
        checkoutCommitsCapabilityPresent(const {'commitsList': true}),
        isFalse,
      );
      expect(
        checkoutCommitsCapabilityPresent(const {
          'commitsList': true,
          'commitBaseClassification': 'yes',
        }),
        isFalse,
      );
      expect(checkoutCommitsCapabilityPresent(null), isFalse);
      expect(checkoutCommitsCapabilityPresent(const {}), isFalse);
    });

    test('canFetch needs a cwd, a client and a live connection', () {
      expect(
        canFetchCheckoutCommits(
          cwd: '/repo',
          hasClient: true,
          isConnected: true,
        ),
        isTrue,
      );
      expect(
        canFetchCheckoutCommits(cwd: '', hasClient: true, isConnected: true),
        isFalse,
      );
      expect(
        canFetchCheckoutCommits(
          cwd: '/repo',
          hasClient: false,
          isConnected: true,
        ),
        isFalse,
      );
      expect(
        canFetchCheckoutCommits(
          cwd: '/repo',
          hasClient: true,
          isConnected: false,
        ),
        isFalse,
      );
    });

    test('an all-whitespace cwd is truthy, matching JavaScript', () {
      expect(
        canFetchCheckoutCommits(cwd: '   ', hasClient: true, isConnected: true),
        isTrue,
      );
    });

    test('the query runs only when want, capability and transport agree', () {
      expect(
        checkoutCommitsQueryEnabled(
          enabled: true,
          capabilityPresent: true,
          canFetch: true,
        ),
        isTrue,
      );
      expect(
        checkoutCommitsQueryEnabled(
          enabled: false,
          capabilityPresent: true,
          canFetch: true,
        ),
        isFalse,
      );
      expect(
        checkoutCommitsQueryEnabled(
          enabled: true,
          capabilityPresent: false,
          canFetch: true,
        ),
        isFalse,
      );
      expect(
        checkoutCommitsQueryEnabled(
          enabled: true,
          capabilityPresent: true,
          canFetch: false,
        ),
        isFalse,
      );
    });

    test('pins the commits stale window', () {
      expect(checkoutCommitsStaleTimeMs, 30000);
    });
  });

  group('classifyCheckoutCommits', () {
    test('narrows the optional wire flag onto every commit', () {
      final data = classifyCheckoutCommits(
        baseRef: 'main',
        commits: [
          checkoutCommit(sha: 'aaaaaaa1', isOnBase: true),
          checkoutCommit(sha: 'bbbbbbb2', isOnBase: false),
        ],
      );

      expect(data.baseRef, 'main');
      expect(data.commits.map((commit) => commit.sha), [
        'aaaaaaa1',
        'bbbbbbb2',
      ]);
      expect(data.commits.map((commit) => commit.isOnBase), [true, false]);
    });

    test('keeps a null baseRef distinct from an empty commit list', () {
      final data = classifyCheckoutCommits(baseRef: null, commits: const []);
      expect(data.baseRef, isNull);
      expect(data.commits, isEmpty);
    });

    test('rejects a daemon that advertised classification but omitted it', () {
      expect(
        () => classifyCheckoutCommits(
          baseRef: 'main',
          commits: [checkoutCommit(sha: 'aaaaaaa1')],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Host omitted commit base classification',
          ),
        ),
      );
    });

    test('exposes the commit files through the classified wrapper', () {
      final file = commitFile(path: 'a.ts');
      final data = classifyCheckoutCommits(
        baseRef: 'main',
        commits: [
          checkoutCommit(sha: 'aaaaaaa1', isOnBase: false, files: [file]),
        ],
      );
      expect(data.commits.single.files, [same(file)]);
    });
  });

  // -------------------------------------------------------------------------
  // use-diff-files.ts
  // -------------------------------------------------------------------------

  group('resolveCommitDiffFiles', () {
    test('keeps pending commit files out of the shared view until their '
        'per-file diff resolves', () {
      final files = [
        commitFile(path: 'blob.bin', status: CheckoutCommitFileStatus.added),
        commitFile(
          path: 'src/app.ts',
          additions: 3,
          deletions: 1,
          status: CheckoutCommitFileStatus.modified,
        ),
      ];

      final resolvedByPath = <String, CommitFileDiffResolution>{
        'blob.bin': const PendingCommitFileDiff(),
        'src/app.ts': ResolvedCommitFileDiff(
          parsedDiffFile(path: 'src/app.ts', additions: 3, deletions: 1),
        ),
      };

      final resolved = resolveCommitDiffFiles(files, resolvedByPath);
      expect(resolved, hasLength(1));
      expect(resolved.single.path, 'src/app.ts');
      expect(resolved.single.additions, 3);
      expect(resolved.single.deletions, 1);
    });

    test('preserves binary-only commit files from commit metadata when the '
        'per-file diff is null', () {
      final files = [
        commitFile(path: 'blob.bin', status: CheckoutCommitFileStatus.added),
        commitFile(
          path: 'src/app.ts',
          additions: 3,
          deletions: 1,
          status: CheckoutCommitFileStatus.modified,
        ),
      ];

      final resolvedByPath = <String, CommitFileDiffResolution>{
        'blob.bin': const UnavailableCommitFileDiff(),
        'src/app.ts': ResolvedCommitFileDiff(
          parsedDiffFile(path: 'src/app.ts', additions: 3, deletions: 1),
        ),
      };

      final resolved = resolveCommitDiffFiles(files, resolvedByPath);
      expect(resolved, hasLength(2));
      expect(resolved.first.toJson(), {
        'path': 'blob.bin',
        'isNew': true,
        'isDeleted': false,
        'additions': 0,
        'deletions': 0,
        'hunks': <Object?>[],
        'status': 'binary',
      });
      expect(resolved.last.path, 'src/app.ts');
      expect(resolved.last.additions, 3);
      expect(resolved.last.deletions, 1);
    });

    test('treats a path missing from the map as pending', () {
      final resolved = resolveCommitDiffFiles([
        commitFile(path: 'ghost.ts'),
      ], const {});
      expect(resolved, isEmpty);
    });

    test('reconstructs the deleted and unknown binary statuses', () {
      final deleted = resolveCommitDiffFile(
        commitFile(
          path: 'gone.bin',
          additions: 0,
          deletions: 9,
          status: CheckoutCommitFileStatus.deleted,
        ),
        const UnavailableCommitFileDiff(),
      );
      expect(deleted!.isNew, isFalse);
      expect(deleted.isDeleted, isTrue);
      expect(deleted.deletions, 9);

      final unknown = resolveCommitDiffFile(
        commitFile(path: 'mystery.bin'),
        const UnavailableCommitFileDiff(),
      );
      expect(unknown!.isNew, isFalse);
      expect(unknown.isDeleted, isFalse);
      expect(unknown.status, CheckoutDiffFileStatus.binary);
      expect(unknown.hunks, isEmpty);
    });

    test('a resolved diff wins over the commit metadata', () {
      final diff = parsedDiffFile(path: 'src/app.ts');
      expect(
        resolveCommitDiffFile(
          commitFile(
            path: 'src/app.ts',
            status: CheckoutCommitFileStatus.added,
          ),
          ResolvedCommitFileDiff(diff),
        ),
        same(diff),
      );
    });
  });

  group('selectCommitFilesForSha', () {
    final files = [commitFile(path: 'a.ts')];
    final data = CheckoutCommitsData(
      baseRef: 'main',
      commits: [classified(sha: 'aaaaaaa1', files: files)],
    );

    test('returns the matching commit files', () {
      expect(selectCommitFilesForSha(data, 'aaaaaaa1'), same(files));
    });

    test(
      'returns empty for an empty sha, a null snapshot or an unknown sha',
      () {
        expect(selectCommitFilesForSha(data, ''), isEmpty);
        expect(selectCommitFilesForSha(null, 'aaaaaaa1'), isEmpty);
        expect(selectCommitFilesForSha(data, 'ccccccc3'), isEmpty);
      },
    );
  });

  group('commitFileDiffsEnabled', () {
    test(
      'waits for the commits query to load before fetching any file diff',
      () {
        bool enabledFor(CheckoutCommitsQueryResult commitsQuery) =>
            commitFileDiffsEnabled(
              enabled: true,
              commitsQuery: commitsQuery,
              cwd: '/repo',
              sha: 'aaaaaaa1',
              hasClient: true,
              isConnected: true,
            );

        expect(enabledFor(const CheckoutCommitsLoaded(emptyCommits)), isTrue);
        expect(enabledFor(const CheckoutCommitsLoading()), isFalse);
        expect(enabledFor(const CheckoutCommitsConnecting()), isFalse);
        expect(enabledFor(const CheckoutCommitsIdle()), isFalse);
        expect(enabledFor(const CheckoutCommitsUnsupported()), isFalse);
      },
    );

    test(
      'needs the consumer gate, a cwd, a sha, a client and a connection',
      () {
        bool enabledWith({
          bool enabled = true,
          String cwd = '/repo',
          String sha = 'aaaaaaa1',
          bool hasClient = true,
          bool isConnected = true,
        }) => commitFileDiffsEnabled(
          enabled: enabled,
          commitsQuery: const CheckoutCommitsLoaded(emptyCommits),
          cwd: cwd,
          sha: sha,
          hasClient: hasClient,
          isConnected: isConnected,
        );

        expect(enabledWith(), isTrue);
        expect(enabledWith(enabled: false), isFalse);
        expect(enabledWith(cwd: ''), isFalse);
        expect(enabledWith(sha: ''), isFalse);
        expect(enabledWith(hasClient: false), isFalse);
        expect(enabledWith(isConnected: false), isFalse);
      },
    );
  });

  group('resolveCommitDiffFilesResult', () {
    final commitFiles = [
      commitFile(path: 'blob.bin', status: CheckoutCommitFileStatus.added),
      commitFile(
        path: 'src/app.ts',
        additions: 3,
        deletions: 1,
        status: CheckoutCommitFileStatus.modified,
      ),
    ];

    test('merges resolved, binary-only and pending per-file results', () {
      final result = resolveCommitDiffFilesResult(
        commitFiles: commitFiles,
        fileDiffResults: [
          const CommitFileDiffFetchState(data: CommitFileDiffPayload(null)),
          CommitFileDiffFetchState(
            data: CommitFileDiffPayload(
              parsedDiffFile(path: 'src/app.ts', additions: 3, deletions: 1),
            ),
          ),
        ],
        commitsQuery: const CheckoutCommitsLoaded(emptyCommits),
      );

      expect(result.files.map((file) => file.path), ['blob.bin', 'src/app.ts']);
      expect(result.files.first.status, CheckoutDiffFileStatus.binary);
      expect(result.isLoading, isFalse);
      expect(result.error, isNull);
      expect(result.capabilityMissing, isFalse);
    });

    test('withholds files whose fetch has not answered yet', () {
      final result = resolveCommitDiffFilesResult(
        commitFiles: commitFiles,
        fileDiffResults: const [
          CommitFileDiffFetchState(isLoading: true),
          CommitFileDiffFetchState(isLoading: true),
        ],
        commitsQuery: const CheckoutCommitsLoaded(emptyCommits),
      );

      expect(result.files, isEmpty);
      expect(result.isLoading, isTrue);
    });

    test('tolerates fewer fetch states than commit files', () {
      final result = resolveCommitDiffFilesResult(
        commitFiles: commitFiles,
        fileDiffResults: const [
          CommitFileDiffFetchState(data: CommitFileDiffPayload(null)),
        ],
        commitsQuery: const CheckoutCommitsLoaded(emptyCommits),
      );

      expect(result.files.map((file) => file.path), ['blob.bin']);
    });

    test('reports the first per-file error', () {
      final first = StateError('blob failed');
      final second = StateError('app failed');
      final result = resolveCommitDiffFilesResult(
        commitFiles: commitFiles,
        fileDiffResults: [
          CommitFileDiffFetchState(error: first),
          CommitFileDiffFetchState(error: second),
        ],
        commitsQuery: const CheckoutCommitsLoaded(emptyCommits),
      );

      expect(result.error, same(first));
    });

    test('a commits-level error outranks a per-file error', () {
      final commitsError = StateError('git log failed');
      final result = resolveCommitDiffFilesResult(
        commitFiles: commitFiles,
        fileDiffResults: [CommitFileDiffFetchState(error: StateError('file'))],
        commitsQuery: CheckoutCommitsError(commitsError),
      );

      expect(result.error, same(commitsError));
    });

    test('is loading while the commits query is connecting or loading', () {
      for (final commitsQuery in const [
        CheckoutCommitsConnecting(),
        CheckoutCommitsLoading(),
      ]) {
        expect(
          resolveCommitDiffFilesResult(
            commitFiles: const [],
            fileDiffResults: const [],
            commitsQuery: commitsQuery,
          ).isLoading,
          isTrue,
        );
      }
      expect(
        resolveCommitDiffFilesResult(
          commitFiles: const [],
          fileDiffResults: const [],
          commitsQuery: const CheckoutCommitsIdle(),
        ).isLoading,
        isFalse,
      );
    });

    test('surfaces the missing capability distinctly from an error', () {
      final result = resolveCommitDiffFilesResult(
        commitFiles: const [],
        fileDiffResults: const [],
        commitsQuery: const CheckoutCommitsUnsupported(),
      );

      expect(result.capabilityMissing, isTrue);
      expect(result.error, isNull);
      expect(result.isLoading, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // use-forge-search-query.ts
  // -------------------------------------------------------------------------

  group('forgeSearchQueryKey', () {
    test('keeps the shared cache key shape for no-kinds searches', () {
      expect(forgeSearchQueryKey('server-1', '/repo', '  123  '), [
        'forge-search',
        'server-1',
        '/repo',
        'forge',
        '123',
      ]);
    });

    test('adds a deterministic kinds key when kinds are specified', () {
      expect(
        forgeSearchQueryKey('server-1', '/repo', '123', [
          ForgeSearchKind.changeRequest,
          ForgeSearchKind.issue,
        ]),
        [
          'forge-search',
          'server-1',
          '/repo',
          'forge',
          '123',
          'change_request,issue',
        ],
      );
    });

    test(
      'separates legacy GitHub fallback results from forge search results',
      () {
        expect(
          forgeSearchQueryKey(
            'server-1',
            '/repo',
            '123',
            null,
            ForgeSearchTransport.github,
          ),
          ['forge-search', 'server-1', '/repo', 'github', '123'],
        );
      },
    );

    test('is order-insensitive across kinds', () {
      expect(
        forgeSearchQueryKey('server-1', '/repo', '123', [
          ForgeSearchKind.issue,
          ForgeSearchKind.changeRequest,
        ]),
        forgeSearchQueryKey('server-1', '/repo', '123', [
          ForgeSearchKind.changeRequest,
          ForgeSearchKind.issue,
        ]),
      );
    });

    test('an empty kinds list is a different key from no kinds at all', () {
      expect(forgeSearchQueryKey('server-1', '/repo', '123', const []), [
        'forge-search',
        'server-1',
        '/repo',
        'forge',
        '123',
        '',
      ]);
      expect(
        forgeSearchQueryKey('server-1', '/repo', '123', const []),
        isNot(forgeSearchQueryKey('server-1', '/repo', '123')),
      );
    });
  });

  group('buildForgeSearchQueryOptions', () {
    test('forwards kinds to the forge search request when specified', () async {
      final client = RecordingForgeSearchClient(
        forgeResponse: const ForgeSearchResponsePayload(
          items: [],
          authState: 'authenticated',
          error: null,
          requestId: 'request-1',
        ),
      );
      final query = buildForgeSearchQueryOptions(
        client: client,
        serverId: 'server-1',
        cwd: '/repo',
        query: ' 123 ',
        kinds: const [ForgeSearchKind.changeRequest],
        enabled: true,
      );

      await query.queryFn();

      expect(client.forgeRequests, [
        const ForgeSearchRequestOptions(
          cwd: '/repo',
          query: '123',
          limit: 20,
          kinds: [ForgeSearchKind.changeRequest],
        ),
      ]);
    });

    test('uses the legacy GitHub search request when forge search is '
        'unsupported', () async {
      final client = RecordingForgeSearchClient(
        githubResponse: const GitHubSearchResponsePayload(
          items: [],
          featuresEnabled: true,
          authState: 'authenticated',
          githubFeaturesEnabled: true,
          error: null,
          requestId: 'github-request',
        ),
      );
      final query = buildForgeSearchQueryOptions(
        client: client,
        serverId: 'server-1',
        cwd: '/repo',
        query: ' 456 ',
        kinds: const [ForgeSearchKind.issue],
        enabled: true,
        supportsForgeSearch: false,
      );

      await query.queryFn();

      expect(client.forgeRequests, isEmpty);
      expect(client.githubRequests, [
        const LegacyGitHubSearchRequestOptions(
          cwd: '/repo',
          query: '456',
          limit: 20,
          kinds: [LegacyGitHubSearchKind.issue],
        ),
      ]);
    });

    test('normalizes legacy GitHub PR items into neutral change-request '
        'items', () async {
      final query = buildForgeSearchQueryOptions(
        client: RecordingForgeSearchClient(
          forgeThrows: true,
          githubResponse: const GitHubSearchResponsePayload(
            items: [
              {
                'kind': 'pr',
                'number': 17,
                'title': 'Fix search',
                'url': 'https://github.com/acme/repo/pull/17',
                'state': 'open',
                'body': null,
                'labels': ['bug'],
                'baseRefName': 'main',
                'headRefName': 'fix-search',
              },
            ],
            featuresEnabled: true,
            authState: 'authenticated',
            githubFeaturesEnabled: true,
            error: null,
            requestId: 'github-request',
          ),
        ),
        serverId: 'server-1',
        cwd: '/repo',
        query: ' 456 ',
        enabled: true,
        supportsForgeSearch: false,
      );

      final result = await query.queryFn();

      expect(result.items.map((item) => item.toJson()), [
        {
          'kind': 'change_request',
          'number': 17,
          'title': 'Fix search',
          'url': 'https://github.com/acme/repo/pull/17',
          'state': 'open',
          'body': null,
          'labels': ['bug'],
          'baseRefName': 'main',
          'headRefName': 'fix-search',
        },
      ]);
    });

    test('interprets modern search payloads at the query boundary', () async {
      final query = buildForgeSearchQueryOptions(
        client: RecordingForgeSearchClient(
          forgeResponse: const ForgeSearchResponsePayload(
            items: [
              {
                'kind': 'issue',
                'number': 23,
                'title': 'Keep this',
                'url': 'https://gitlab.com/acme/repo/-/issues/23',
                'state': 'open',
                'body': null,
                'labels': <String>[],
              },
              {'kind': 'future_kind', 'futureField': true},
            ],
            authState: 'future_auth_state',
            error: null,
            requestId: 'forge-request',
          ),
        ),
        serverId: 'server-1',
        cwd: '/repo',
        query: '23',
        enabled: true,
        supportsForgeSearch: true,
      );

      final result = await query.queryFn();

      expect(result.items, hasLength(1));
      expect(result.items.first.kind, ForgeSearchKind.issue);
      expect(result.authState, ForgeAuthState.unauthenticated);
    });

    test('derives legacy search auth from legacy feature flags', () async {
      final query = buildForgeSearchQueryOptions(
        client: RecordingForgeSearchClient(
          forgeThrows: true,
          githubResponse: const GitHubSearchResponsePayload(
            items: [],
            githubFeaturesEnabled: false,
            error: null,
            requestId: 'github-request',
          ),
        ),
        serverId: 'server-1',
        cwd: '/repo',
        query: '23',
        enabled: true,
        supportsForgeSearch: false,
      );

      expect((await query.queryFn()).authState, ForgeAuthState.unauthenticated);
    });

    test('invokes forge search bound to the client so this-dependent methods '
        'work', () async {
      final client = ThisDependentSearchClient();

      final query = buildForgeSearchQueryOptions(
        client: client,
        serverId: 'server-1',
        cwd: '/repo',
        query: ' 789 ',
        enabled: true,
        supportsForgeSearch: true,
      );

      final result = await query.queryFn();

      expect(result.requestId, 'forge.search.request');
      expect(client.requests, [
        const LegacyGitHubSearchRequestOptions(
          cwd: '/repo',
          query: '789',
          limit: 20,
        ),
      ]);
    });

    test('invokes the legacy GitHub search bound to the client', () async {
      final client = ThisDependentSearchClient();

      final query = buildForgeSearchQueryOptions(
        client: client,
        serverId: 'server-1',
        cwd: '/repo',
        query: ' 789 ',
        enabled: true,
        supportsForgeSearch: false,
      );

      final result = await query.queryFn();

      expect(result.requestId, 'github_search_request');
      expect(client.requests, [
        const LegacyGitHubSearchRequestOptions(
          cwd: '/repo',
          query: '789',
          limit: 20,
        ),
      ]);
    });

    test(
      'falls back to forge search when the client has no legacy RPC',
      () async {
        final client = RecordingForgeSearchClient();
        final query = buildForgeSearchQueryOptions(
          client: client,
          serverId: 'server-1',
          cwd: '/repo',
          query: '123',
          enabled: true,
          supportsForgeSearch: false,
        );

        await query.queryFn();

        expect(client.forgeRequests, hasLength(1));
        expect(client.githubRequests, isEmpty);
      },
    );

    test('an unknown forge-search capability falls back to the legacy '
        'transport', () {
      final key = buildForgeSearchQueryOptions(
        client: RecordingForgeSearchClient(),
        serverId: 'server-1',
        cwd: '/repo',
        query: '123',
        enabled: true,
      ).queryKey;

      expect(key, ['forge-search', 'server-1', '/repo', 'github', '123']);
    });

    test('carries the frozen cache policy and gates on a client', () {
      final options = buildForgeSearchQueryOptions(
        client: RecordingForgeSearchClient(),
        serverId: 'server-1',
        cwd: '/repo',
        query: '123',
        enabled: true,
      );
      expect(options.staleTimeMs, forgeSearchStaleTimeMs);
      expect(options.staleTimeMs, 30000);
      expect(options.dataShape, FetchQueryDataShape.list);
      expect(options.enabled, isTrue);

      expect(
        buildForgeSearchQueryOptions(
          client: RecordingForgeSearchClient(),
          serverId: 'server-1',
          cwd: '/repo',
          query: '123',
          enabled: false,
        ).enabled,
        isFalse,
      );
      expect(
        buildForgeSearchQueryOptions(
          client: null,
          serverId: 'server-1',
          cwd: '/repo',
          query: '123',
          enabled: true,
        ).enabled,
        isFalse,
      );
    });

    test('a null client makes the fetch fail with the host-disconnected '
        'message', () async {
      final fallback = buildForgeSearchQueryOptions(
        client: null,
        serverId: 'server-1',
        cwd: '/repo',
        query: '123',
        enabled: true,
      );
      await expectLater(
        fallback.queryFn(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            defaultForgeSearchHostDisconnectedMessage,
          ),
        ),
      );

      final translated = buildForgeSearchQueryOptions(
        client: null,
        serverId: 'server-1',
        cwd: '/repo',
        query: '123',
        enabled: true,
        hostDisconnectedMessage: 'Host niet verbonden',
      );
      await expectLater(
        translated.queryFn(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Host niet verbonden',
          ),
        ),
      );
    });

    test('trims the query into both the key and the request', () async {
      final client = RecordingForgeSearchClient();
      final options = buildForgeSearchQueryOptions(
        client: client,
        serverId: 'server-1',
        cwd: '/repo',
        query: '  spaced  ',
        enabled: true,
        supportsForgeSearch: true,
      );

      await options.queryFn();

      expect(options.queryKey.last, 'spaced');
      expect(client.forgeRequests.single.query, 'spaced');
    });
  });

  group('forge search payload normalization', () {
    test('preserves a recognized modern auth state', () {
      final payload = normalizeForgeSearchPayload(
        const ForgeSearchResponsePayload(
          items: [],
          authState: 'cli_missing',
          error: 'gh missing',
          requestId: 'forge-1',
        ),
      );
      expect(payload.authState, ForgeAuthState.cliMissing);
      expect(payload.error, 'gh missing');
      expect(payload.requestId, 'forge-1');
    });

    test('an absent modern auth state reads as unauthenticated', () {
      expect(
        normalizeForgeSearchPayload(
          const ForgeSearchResponsePayload(
            items: [],
            error: null,
            requestId: 'forge-1',
          ),
        ).authState,
        ForgeAuthState.unauthenticated,
      );
    });

    test('legacy featuresEnabled outranks githubFeaturesEnabled', () {
      expect(
        normalizeLegacyGitHubSearchPayload(
          const GitHubSearchResponsePayload(
            items: [],
            featuresEnabled: true,
            githubFeaturesEnabled: false,
            error: null,
            requestId: 'github-1',
          ),
        ).authState,
        ForgeAuthState.authenticated,
      );
      expect(
        normalizeLegacyGitHubSearchPayload(
          const GitHubSearchResponsePayload(
            items: [],
            featuresEnabled: false,
            githubFeaturesEnabled: true,
            error: null,
            requestId: 'github-1',
          ),
        ).authState,
        ForgeAuthState.unauthenticated,
      );
    });

    test('a legacy payload with neither flag is assumed authenticated', () {
      expect(
        normalizeLegacyGitHubSearchPayload(
          const GitHubSearchResponsePayload(
            items: [],
            error: null,
            requestId: 'github-1',
          ),
        ).authState,
        ForgeAuthState.authenticated,
      );
    });

    test('an explicit legacy auth state outranks the feature flags', () {
      expect(
        normalizeLegacyGitHubSearchPayload(
          const GitHubSearchResponsePayload(
            items: [],
            authState: 'no_remote',
            githubFeaturesEnabled: false,
            error: null,
            requestId: 'github-1',
          ),
        ).authState,
        ForgeAuthState.noRemote,
      );
    });

    test('an unrecognized legacy auth state falls through to the flags', () {
      expect(
        normalizeLegacyGitHubSearchPayload(
          const GitHubSearchResponsePayload(
            items: [],
            authState: 'future_auth_state',
            githubFeaturesEnabled: false,
            error: null,
            requestId: 'github-1',
          ),
        ).authState,
        ForgeAuthState.unauthenticated,
      );
    });
  });

  group('search item parsing', () {
    Map<String, Object?> item({
      Object? kind = 'issue',
      Object? number = 23,
      Object? title = 'Keep this',
      Object? url = 'https://example.com/issues/23',
      Object? state = 'open',
    }) => <String, Object?>{
      'kind': kind,
      'number': number,
      'title': title,
      'url': url,
      'state': state,
      'body': null,
      'labels': <String>[],
    };

    test('reads a full modern item including every optional field', () {
      final parsed = parseForgeSearchItem(<String, Object?>{
        ...item(kind: 'change_request', number: 7),
        'forge': 'gitlab',
        'body': 'text',
        'labels': ['bug', 'ui'],
        'projectPath': 'acme/repo',
        'baseRefName': 'main',
        'headRefName': 'fix',
        'updatedAt': '2026-01-01T00:00:00Z',
      });

      expect(parsed, isNotNull);
      expect(parsed!.kind, ForgeSearchKind.changeRequest);
      expect(parsed.forge, 'gitlab');
      expect(parsed.number, 7);
      expect(parsed.labels, ['bug', 'ui']);
      expect(parsed.projectPath, 'acme/repo');
      expect(parsed.baseRefName, 'main');
      expect(parsed.headRefName, 'fix');
      expect(parsed.updatedAt, '2026-01-01T00:00:00Z');
    });

    test('accepts a null baseRefName and headRefName', () {
      final parsed = parseForgeSearchItem(<String, Object?>{
        ...item(),
        'baseRefName': null,
        'headRefName': null,
      });
      expect(parsed, isNotNull);
      expect(parsed!.baseRefName, isNull);
      expect(parsed.headRefName, isNull);
    });

    test('drops non-objects and unknown kinds', () {
      expect(parseForgeSearchItem(null), isNull);
      expect(parseForgeSearchItem('issue'), isNull);
      expect(parseForgeSearchItem(item(kind: 'future_kind')), isNull);
      expect(parseForgeSearchItem(item(kind: null)), isNull);
    });

    test('the modern parser rejects the legacy pr spelling and vice versa', () {
      expect(parseForgeSearchItem(item(kind: 'pr')), isNull);
      expect(parseLegacyGitHubSearchItem(item(kind: 'change_request')), isNull);
      expect(
        parseLegacyGitHubSearchItem(item(kind: 'pr'))?.kind,
        ForgeSearchKind.changeRequest,
      );
      expect(
        parseLegacyGitHubSearchItem(item(kind: 'issue'))?.kind,
        ForgeSearchKind.issue,
      );
    });

    test('drops items with an unusable number', () {
      expect(parseForgeSearchItem(item(number: '23')), isNull);
      expect(parseForgeSearchItem(item(number: 23.5)), isNull);
      expect(parseForgeSearchItem(item(number: double.nan)), isNull);
      expect(parseForgeSearchItem(item(number: null)), isNull);
    });

    test('accepts zero and negative numbers, matching z.number()', () {
      expect(parseForgeSearchItem(item(number: 0))?.number, 0);
      expect(parseForgeSearchItem(item(number: -1))?.number, -1);
      expect(parseForgeSearchItem(item(number: 23.0))?.number, 23);
    });

    test('requires the body key even though its value may be null', () {
      final withoutBody = item()..remove('body');
      expect(parseForgeSearchItem(withoutBody), isNull);
      expect(parseForgeSearchItem(item()..['body'] = 12), isNull);
      expect(parseForgeSearchItem(item()..['body'] = 'text')?.body, 'text');
    });

    test('requires string labels', () {
      expect(parseForgeSearchItem(item()..remove('labels')), isNull);
      expect(parseForgeSearchItem(item()..['labels'] = 'bug'), isNull);
      expect(parseForgeSearchItem(item()..['labels'] = [1]), isNull);
    });

    test('rejects a null in an optional-but-not-nullable string field', () {
      expect(parseForgeSearchItem(item()..['forge'] = null), isNull);
      expect(parseForgeSearchItem(item()..['projectPath'] = null), isNull);
      expect(parseForgeSearchItem(item()..['updatedAt'] = null), isNull);
    });

    test('drops items whose title, url or state is not a string', () {
      expect(parseForgeSearchItem(item(title: 12)), isNull);
      expect(parseForgeSearchItem(item(url: null)), isNull);
      expect(parseForgeSearchItem(item(state: false)), isNull);
    });

    test('ignores unknown keys, matching zod stripping', () {
      final parsed = parseForgeSearchItem(<String, Object?>{
        ...item(),
        'futureField': true,
      });
      expect(parsed, isNotNull);
      expect(parsed!.toJson().containsKey('futureField'), isFalse);
    });
  });

  group('toLegacyGitHubSearchRequest', () {
    test('passes a kind-less request through untouched', () {
      expect(
        toLegacyGitHubSearchRequest(
          const ForgeSearchRequestOptions(cwd: '/repo', query: '1', limit: 20),
        ),
        const LegacyGitHubSearchRequestOptions(
          cwd: '/repo',
          query: '1',
          limit: 20,
        ),
      );
    });

    test('translates every kind into the legacy vocabulary', () {
      expect(
        toLegacyGitHubSearchRequest(
          const ForgeSearchRequestOptions(
            cwd: '/repo',
            query: '1',
            kinds: [ForgeSearchKind.changeRequest, ForgeSearchKind.issue],
          ),
        ),
        const LegacyGitHubSearchRequestOptions(
          cwd: '/repo',
          query: '1',
          kinds: [
            LegacyGitHubSearchKind.changeRequest,
            LegacyGitHubSearchKind.issue,
          ],
        ),
      );
      expect(
        toLegacyGitHubSearchRequest(
          const ForgeSearchRequestOptions(cwd: '/repo', query: '1', kinds: []),
        ).kinds,
        isEmpty,
      );
    });

    test('pins the legacy kind wire names', () {
      expect(LegacyGitHubSearchKind.issue.wireName, 'github-issue');
      expect(LegacyGitHubSearchKind.changeRequest.wireName, 'github-pr');
      expect(
        toLegacyGitHubSearchKind(ForgeSearchKind.changeRequest),
        LegacyGitHubSearchKind.changeRequest,
      );
      expect(
        toLegacyGitHubSearchKind(ForgeSearchKind.issue),
        LegacyGitHubSearchKind.issue,
      );
    });
  });
}
