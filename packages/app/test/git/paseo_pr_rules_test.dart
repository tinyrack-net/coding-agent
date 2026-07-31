// Ports of the upstream suites for `git/pr-hint.ts`, `git/pr-status.ts`,
// `git/branch-switcher-operations.ts` and `git/worktree-archive-warning.ts`,
// plus the edge cases those suites leave unpinned (URL parsing failures,
// merged-vs-closed precedence, unknown wire enum values, zero/negative diff
// stats, and the i18n-backed label path).
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge.dart';
import 'package:coding_agent_app/git/paseo_pr_rules.dart';
import 'package:coding_agent_app/i18n/locales.dart';
import 'package:coding_agent_app/i18n/translations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the upstream `githubStatus` fixture; named parameters stand in for
/// TypeScript object spread on the fixture.
PrStatusLike prStatus({
  String url = 'https://github.com/acme/repo/pull/42',
  String state = 'open',
  bool isMerged = false,
  List<CheckoutPrCheck>? checks,
  String? checksStatus,
  String? reviewDecision,
  String? forge,
}) => PrStatusLike(
  url: url,
  state: state,
  isMerged: isMerged,
  checks: checks,
  checksStatus: checksStatus,
  reviewDecision: reviewDecision,
  forge: forge,
);

/// Mirrors the upstream `gitlabStatus` fixture.
final gitlabStatus = prStatus(
  url: 'https://gitlab.com/group/proj/-/merge_requests/7',
);

/// Mirrors the upstream `payload()` helper. `authState` is `Object?` on the
/// wire, so an unknown value can be passed exactly as upstream does.
CheckoutPrStatusResponse prStatusPayload({
  String cwd = '/repo',
  CheckoutPrStatus? status,
  bool githubFeaturesEnabled = true,
  Object? authState,
  String? forge = 'github',
  CheckoutError? error,
  String requestId = 'pr-status-1',
}) => CheckoutPrStatusResponse(
  cwd: cwd,
  status: status,
  githubFeaturesEnabled: githubFeaturesEnabled,
  authState: authState,
  forge: forge,
  error: error,
  requestId: requestId,
);

/// Records the cwd every operation was handed, which is the whole point of the
/// branch-switcher binding. Mirrors upstream's `createRecordingClient`.
final class RecordingBranchSwitcherClient implements BranchSwitcherGitClient {
  final List<String> cwds = [];
  final List<Object?> args = [];

  @override
  Future<BranchSuggestionsResponse> getBranchSuggestions({
    required String cwd,
    int? limit,
  }) async {
    cwds.add(cwd);
    args.add(limit);
    return const BranchSuggestionsResponse(
      branches: [],
      branchDetails: null,
      error: null,
      requestId: 'r',
    );
  }

  @override
  Future<StashListResponse> stashList({
    required String cwd,
    bool? paseoOnly,
  }) async {
    cwds.add(cwd);
    args.add(paseoOnly);
    return const StashListResponse(
      cwd: '/repo',
      entries: [],
      error: null,
      requestId: 'r',
    );
  }

  @override
  Future<StashSaveResponse> stashSave({
    required String cwd,
    String? branch,
  }) async {
    cwds.add(cwd);
    args.add(branch);
    return const StashSaveResponse(
      cwd: '/repo',
      success: true,
      error: null,
      requestId: 'r',
    );
  }

  @override
  Future<StashPopResponse> stashPop({
    required String cwd,
    required int stashIndex,
  }) async {
    cwds.add(cwd);
    args.add(stashIndex);
    return const StashPopResponse(
      cwd: '/repo',
      success: true,
      error: null,
      requestId: 'r',
    );
  }

  @override
  Future<CheckoutSwitchBranchResult> checkoutSwitchBranch({
    required String cwd,
    required String branch,
  }) async {
    cwds.add(cwd);
    args.add(branch);
    return CheckoutSwitchBranchResult(
      cwd: cwd,
      success: true,
      branch: branch,
      error: null,
      requestId: 'r',
    );
  }
}

/// The frozen English archiveWarning subtree, so the i18n-backed label path is
/// exercised without touching the asset bundle.
Translations englishTranslations() => Translations.fromTables(
  TranslationTable.fromJson(SupportedLocale.en, const {
    'workspace': {
      'git': {
        'actions': {
          'archiveWarning': {
            'title': 'Archive "{{workspaceName}}"?',
            'confirm': 'Archive',
            'cancel': 'Cancel',
            'uncommittedChanges': 'Uncommitted changes',
            'uncommittedChangesWithDiff': 'Uncommitted changes ({{diffStat}})',
            'addedLine': '{{count}} added line',
            'addedLines': '{{count}} added lines',
            'deletedLine': '{{count}} deleted line',
            'deletedLines': '{{count}} deleted lines',
            'unpushedCommit': '{{count}} unpushed commit',
            'unpushedCommits': '{{count}} unpushed commits',
          },
        },
      },
    },
  }),
);

void main() {
  group('selectPrHintFromStatus', () {
    test('defaults the forge to github when none is supplied (old daemon)', () {
      final hint = selectPrHintFromStatus(prStatus());
      expect(hint!.number, 42);
      expect(hint.forge, 'github');
    });

    test('carries the resolved forge onto the hint', () {
      final hint = selectPrHintFromStatus(prStatus(), forge: 'github');
      expect(hint!.forge, 'github');
    });

    test('parses a GitLab merge-request URL and carries the gitlab forge', () {
      final hint = selectPrHintFromStatus(gitlabStatus, forge: 'gitlab');
      expect(hint!.number, 7);
      expect(hint.forge, 'gitlab');
    });

    test('passes an unknown forge id through untouched', () {
      final hint = selectPrHintFromStatus(prStatus(), forge: 'bitbucket');
      expect(hint!.forge, 'bitbucket');
    });

    test(
      'returns null when the url has no parseable change-request number',
      () {
        expect(
          selectPrHintFromStatus(prStatus(url: 'https://example.com/x')),
          isNull,
        );
      },
    );

    // --- edge cases the upstream suite leaves unpinned ---

    test('returns null for an absent status', () {
      expect(selectPrHintFromStatus(null), isNull);
    });

    test('treats an empty url as an absent status', () {
      expect(selectPrHintFromStatus(prStatus(url: '')), isNull);
    });

    test('returns null for a url with no scheme', () {
      expect(
        selectPrHintFromStatus(prStatus(url: '/acme/repo/pull/42')),
        isNull,
      );
      expect(selectPrHintFromStatus(prStatus(url: 'not a url at all')), isNull);
    });

    test('falls back to the status forge only when none is supplied', () {
      expect(selectPrHintFromStatus(prStatus(forge: 'gitea'))!.forge, 'gitea');
      expect(
        selectPrHintFromStatus(
          prStatus(forge: 'gitea'),
          forge: 'forgejo',
        )!.forge,
        'forgejo',
      );
    });

    test('normalizes an explicitly empty forge to github', () {
      // Upstream uses `??`, so an empty string is *not* replaced by the
      // status's forge; it reaches normalizeForge and becomes github.
      expect(
        selectPrHintFromStatus(prStatus(forge: 'gitea'), forge: '')!.forge,
        'github',
      );
    });

    test('parses the gitea/forgejo /pulls/ path', () {
      final hint = selectPrHintFromStatus(
        prStatus(url: 'https://codeberg.org/acme/repo/pulls/9'),
        forge: 'codeberg',
      );
      expect(hint!.number, 9);
      expect(hint.forge, 'codeberg');
    });

    test('accepts a trailing segment after the number', () {
      expect(
        selectPrHintFromStatus(
          prStatus(url: 'https://github.com/acme/repo/pull/42/files'),
        )!.number,
        42,
      );
    });

    test('rejects a non-numeric or partially numeric change-request id', () {
      expect(
        selectPrHintFromStatus(
          prStatus(url: 'https://github.com/a/r/pull/abc'),
        ),
        isNull,
      );
      expect(
        selectPrHintFromStatus(
          prStatus(url: 'https://github.com/a/r/pull/42abc'),
        ),
        isNull,
      );
    });

    test(
      'ignores a change-request number that lives in the query or fragment',
      () {
        expect(
          selectPrHintFromStatus(
            prStatus(url: 'https://github.com/a/r?x=/pull/42'),
          ),
          isNull,
        );
        expect(
          selectPrHintFromStatus(
            prStatus(url: 'https://github.com/a/r#/pull/42'),
          ),
          isNull,
        );
      },
    );

    test('takes the first matching number when a path has several', () {
      expect(
        selectPrHintFromStatus(
          prStatus(url: 'https://github.com/a/pull/3/refs/pull/9'),
        )!.number,
        3,
      );
    });

    test('keeps JavaScript number semantics for oversized ids', () {
      // Number.parseInt("999999999999999999999") is finite but imprecise in
      // JS; Dart reproduces that by falling back to double.
      final hint = selectPrHintFromStatus(
        prStatus(url: 'https://github.com/a/r/pull/999999999999999999999'),
      );
      expect(hint!.number, 1e21);
      expect(hint.number.isFinite, isTrue);
    });

    test('rejects a digit run long enough to overflow to infinity', () {
      final huge = '9' * 400;
      expect(
        selectPrHintFromStatus(
          prStatus(url: 'https://github.com/a/r/pull/$huge'),
        ),
        isNull,
      );
    });

    test('reports merged when the status says merged', () {
      expect(
        selectPrHintFromStatus(prStatus(state: 'merged'))!.state,
        PrHintState.merged,
      );
    });

    test('lets isMerged win over an open state', () {
      expect(
        selectPrHintFromStatus(prStatus(state: 'open', isMerged: true))!.state,
        PrHintState.merged,
      );
    });

    test('reports open for an open, unmerged change request', () {
      expect(selectPrHintFromStatus(prStatus())!.state, PrHintState.open);
    });

    test('treats every other state as closed', () {
      expect(
        selectPrHintFromStatus(prStatus(state: 'closed'))!.state,
        PrHintState.closed,
      );
      expect(
        selectPrHintFromStatus(prStatus(state: 'draft'))!.state,
        PrHintState.closed,
      );
      expect(
        selectPrHintFromStatus(prStatus(state: ''))!.state,
        PrHintState.closed,
      );
    });

    test('carries checks and roll-up fields through untouched', () {
      const check = CheckoutPrCheck(
        name: 'build',
        status: 'success',
        url: null,
      );
      final hint = selectPrHintFromStatus(
        prStatus(
          checks: const [check],
          checksStatus: 'success',
          reviewDecision: 'approved',
        ),
      );
      expect(hint!.checks, [check]);
      expect(hint.checksStatus, 'success');
      expect(hint.reviewDecision, 'approved');
      expect(parsePrChecksStatus(hint.checksStatus), PrChecksStatus.success);
      expect(
        parsePrReviewDecision(hint.reviewDecision),
        PrReviewDecision.approved,
      );
    });

    test('lets an unknown roll-up value survive on the hint', () {
      // Upstream's cast is unchecked, so a newer daemon's value reaches the UI
      // verbatim rather than being dropped.
      final hint = selectPrHintFromStatus(
        prStatus(checksStatus: 'flaky', reviewDecision: 'dismissed'),
      );
      expect(hint!.checksStatus, 'flaky');
      expect(hint.reviewDecision, 'dismissed');
      expect(parsePrChecksStatus(hint.checksStatus), isNull);
      expect(parsePrReviewDecision(hint.reviewDecision), isNull);
    });

    test('adapts a wire CheckoutPrStatus onto the selector input', () {
      final status = CheckoutPrStatus.fromJson(const {
        'forge': 'gitlab',
        'url': 'https://gitlab.com/group/proj/-/merge_requests/7',
        'title': 'Add thing',
        'state': 'open',
        'baseRefName': 'main',
        'headRefName': 'feature',
        'isMerged': false,
        'isDraft': false,
        'mergeable': 'MERGEABLE',
        'checks': <Object?>[],
      });
      final hint = selectPrHintFromStatus(
        PrStatusLike.fromCheckoutPrStatus(status),
      );
      expect(hint!.number, 7);
      expect(hint.forge, 'gitlab');
      expect(hint.state, PrHintState.open);
    });

    test('parses every known roll-up and review wire value', () {
      expect(parsePrChecksStatus('none'), PrChecksStatus.none);
      expect(parsePrChecksStatus('pending'), PrChecksStatus.pending);
      expect(parsePrChecksStatus('failure'), PrChecksStatus.failure);
      expect(parsePrChecksStatus(null), isNull);
      expect(
        parsePrReviewDecision('changes_requested'),
        PrReviewDecision.changesRequested,
      );
      expect(parsePrReviewDecision('pending'), PrReviewDecision.pending);
      expect(parsePrReviewDecision(null), isNull);
    });
  });

  group('normalizeCheckoutPrStatusPayload', () {
    test('preserves known auth states', () {
      expect(
        normalizeCheckoutPrStatusPayload(
          prStatusPayload(authState: 'cli_missing'),
        ).authState,
        ForgeAuthState.cliMissing,
      );
    });

    test(
      'derives auth from the legacy feature flag when authState is absent',
      () {
        expect(
          normalizeCheckoutPrStatusPayload(prStatusPayload()).authState,
          ForgeAuthState.authenticated,
        );
        expect(
          normalizeCheckoutPrStatusPayload(
            prStatusPayload(githubFeaturesEnabled: false),
          ).authState,
          ForgeAuthState.unauthenticated,
        );
      },
    );

    test('does not expose an unknown wire auth state to feature code', () {
      expect(
        normalizeCheckoutPrStatusPayload(
          prStatusPayload(
            authState: 'future_auth_state',
            githubFeaturesEnabled: false,
          ),
        ).authState,
        ForgeAuthState.unauthenticated,
      );
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('preserves the remaining known auth states', () {
      for (final state in ForgeAuthState.values) {
        expect(
          normalizeCheckoutPrStatusPayload(
            // githubFeaturesEnabled disagrees, so only a real parse can pass.
            prStatusPayload(
              authState: state.wireName,
              githubFeaturesEnabled: state != ForgeAuthState.authenticated,
            ),
          ).authState,
          state,
        );
      }
    });

    test('falls back for a non-string wire auth state', () {
      expect(
        normalizeCheckoutPrStatusPayload(
          prStatusPayload(authState: 42, githubFeaturesEnabled: true),
        ).authState,
        ForgeAuthState.authenticated,
      );
    });

    test('carries every other payload field through unchanged', () {
      final status = CheckoutPrStatus.fromJson(const {
        'forge': 'github',
        'url': 'https://github.com/acme/repo/pull/42',
        'title': 'Add thing',
        'state': 'open',
        'baseRefName': 'main',
        'headRefName': 'feature',
        'isMerged': false,
        'isDraft': false,
        'mergeable': 'MERGEABLE',
        'checks': <Object?>[],
      });
      const error = CheckoutError(
        code: CheckoutErrorCode.unknown,
        message: 'nope',
      );
      final normalized = normalizeCheckoutPrStatusPayload(
        prStatusPayload(
          cwd: '/other',
          status: status,
          forge: 'gitea',
          error: error,
          requestId: 'pr-status-9',
        ),
      );

      expect(normalized.cwd, '/other');
      expect(normalized.status, same(status));
      expect(normalized.githubFeaturesEnabled, isTrue);
      expect(normalized.forge, 'gitea');
      expect(normalized.error, same(error));
      expect(normalized.requestId, 'pr-status-9');
    });

    test('defaults an omitted forge to github, as the wire schema does', () {
      expect(
        normalizeCheckoutPrStatusPayload(prStatusPayload(forge: null)).forge,
        'github',
      );
    });
  });

  group('BranchSwitcherOperations', () {
    test(
      'sends the workspace directory as cwd to every git operation, never the '
      'workspace id',
      () async {
        const workspaceDirectory = '/Users/dev/project';
        const workspaceId = 'wks_3f9a2b1c';
        final client = RecordingBranchSwitcherClient();

        final ops = BranchSwitcherOperations(
          client: client,
          cwd: workspaceDirectory,
        );
        await ops.getBranchSuggestions(limit: 200);
        await ops.listPaseoStashes();
        await ops.saveStash(branch: 'main');
        await ops.popStash(stashIndex: 0);
        await ops.switchBranch(branch: 'feature');

        expect(client.cwds, [
          workspaceDirectory,
          workspaceDirectory,
          workspaceDirectory,
          workspaceDirectory,
          workspaceDirectory,
        ]);
        expect(client.cwds, isNot(contains(workspaceId)));
      },
    );

    // --- edge cases the upstream suite leaves unpinned ---

    test('forwards each operation-specific argument verbatim', () async {
      final client = RecordingBranchSwitcherClient();
      final ops = BranchSwitcherOperations(client: client, cwd: '/repo');

      await ops.getBranchSuggestions(limit: 25);
      await ops.listPaseoStashes();
      await ops.saveStash(branch: 'main');
      await ops.saveStash();
      await ops.popStash(stashIndex: 3);
      await ops.switchBranch(branch: 'feature');

      expect(client.args, [25, true, 'main', null, 3, 'feature']);
    });

    test('always asks for Paseo-only stashes', () async {
      final client = RecordingBranchSwitcherClient();
      final ops = BranchSwitcherOperations(client: client, cwd: '/repo');
      await ops.listPaseoStashes();
      expect(client.args.single, isTrue);
    });

    test('returns the client result untouched', () async {
      final client = RecordingBranchSwitcherClient();
      final ops = BranchSwitcherOperations(client: client, cwd: '/repo');
      final result = await ops.switchBranch(branch: 'feature');
      expect(result.branch, 'feature');
      expect(result.cwd, '/repo');
      expect(result.success, isTrue);
      expect(result.source, isNull);
    });
  });

  group('workspace archive warning for worktree backing', () {
    test('does not require a confirmation for clean and pushed worktrees', () {
      expect(
        buildWorktreeArchiveConfirmationMessage(
          const WorktreeArchiveConfirmationInput(
            workspaceName: 'feature',
            risk: WorktreeArchiveRisk(
              isDirty: false,
              aheadOfOrigin: 0,
              diffStat: null,
            ),
          ),
        ),
        isNull,
      );
    });

    test('explains uncommitted line changes', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 0,
            diffStat: WorktreeArchiveDiffStat(additions: 12, deletions: 1),
          ),
        ),
        ['Uncommitted changes (12 added lines, 1 deleted line)'],
      );
    });

    test('treats nonzero diff stats as dirty when dirty state is missing', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            aheadOfOrigin: 0,
            diffStat: WorktreeArchiveDiffStat(additions: 4, deletions: 0),
          ),
        ),
        ['Uncommitted changes (4 added lines)'],
      );
    });

    test('explains unpushed commits', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: false,
            aheadOfOrigin: 2,
            diffStat: null,
          ),
        ),
        ['2 unpushed commits'],
      );
    });

    test('includes every archive risk in the confirmation copy', () {
      expect(
        buildWorktreeArchiveConfirmationMessage(
          const WorktreeArchiveConfirmationInput(
            workspaceName: 'risky-feature',
            risk: WorktreeArchiveRisk(
              isDirty: true,
              aheadOfOrigin: 1,
              diffStat: WorktreeArchiveDiffStat(additions: 1, deletions: 3),
            ),
          ),
        ),
        'Uncommitted changes (1 added line, 3 deleted lines)\n'
        '1 unpushed commit',
      );
    });

    test(
      'maps archive workspace fields into the shared worktree risk shape',
      () {
        expect(
          toWorktreeArchiveRisk(
            archiveHasUncommittedChanges: true,
            archiveUnpushedCommitCount: 3,
            diffStat: const WorktreeArchiveDiffStat(additions: 2, deletions: 1),
          ),
          const WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 3,
            diffStat: WorktreeArchiveDiffStat(additions: 2, deletions: 1),
          ),
        );
      },
    );

    // --- edge cases the upstream suite leaves unpinned ---

    test('maps absent archive fields to an all-null risk', () {
      expect(toWorktreeArchiveRisk(), const WorktreeArchiveRisk());
      expect(buildWorktreeArchiveRiskReasons(toWorktreeArchiveRisk()), isEmpty);
    });

    test('stays silent when nothing is known about the worktree', () {
      expect(
        buildWorktreeArchiveRiskReasons(const WorktreeArchiveRisk()),
        isEmpty,
      );
    });

    test('warns about dirtiness with no diff stat at all', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(isDirty: true),
        ),
        ['Uncommitted changes'],
      );
    });

    test('warns about dirtiness when the diff stat is all zeroes', () {
      // An empty diff stat formats to nothing, so the undecorated copy is used.
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            diffStat: WorktreeArchiveDiffStat(additions: 0, deletions: 0),
          ),
        ),
        ['Uncommitted changes'],
      );
    });

    test('an all-zero diff stat cannot stand in for a missing dirty flag', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            diffStat: WorktreeArchiveDiffStat(additions: 0, deletions: 0),
          ),
        ),
        isEmpty,
      );
    });

    test('an explicit clean flag beats a nonzero diff stat', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: false,
            diffStat: WorktreeArchiveDiffStat(additions: 9, deletions: 9),
          ),
        ),
        isEmpty,
      );
    });

    test('ignores negative diff counts, which read as no change', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            diffStat: WorktreeArchiveDiffStat(additions: -3, deletions: 2),
          ),
        ),
        ['Uncommitted changes (2 deleted lines)'],
      );
    });

    test('ignores a zero or negative ahead count', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(aheadOfOrigin: 0),
        ),
        isEmpty,
      );
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(aheadOfOrigin: -2),
        ),
        isEmpty,
      );
    });

    test('uses singular copy for exactly one of each unit', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 1,
            diffStat: WorktreeArchiveDiffStat(additions: 1, deletions: 1),
          ),
        ),
        [
          'Uncommitted changes (1 added line, 1 deleted line)',
          '1 unpushed commit',
        ],
      );
    });

    test('orders uncommitted changes before unpushed commits', () {
      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 5,
            diffStat: WorktreeArchiveDiffStat(additions: 2, deletions: 0),
          ),
        ),
        ['Uncommitted changes (2 added lines)', '5 unpushed commits'],
      );
    });

    test('the i18n-backed labels match the frozen English defaults', () {
      final labels = WorktreeArchiveWarningLabels.fromTranslations(
        englishTranslations(),
      );
      const risk = WorktreeArchiveRisk(
        isDirty: true,
        aheadOfOrigin: 1,
        diffStat: WorktreeArchiveDiffStat(additions: 1, deletions: 2),
      );

      expect(
        buildWorktreeArchiveRiskReasons(risk, labels: labels),
        buildWorktreeArchiveRiskReasons(risk),
      );
      expect(labels.title('feature'), 'Archive "feature"?');
      expect(labels.confirm, 'Archive');
      expect(labels.cancel, 'Cancel');
      expect(
        labels.title('feature'),
        defaultWorktreeArchiveWarningLabels.title('feature'),
      );
    });

    test('honours a caller-supplied label set', () {
      final labels = WorktreeArchiveWarningLabels(
        title: (name) => 'T:$name',
        confirm: 'OK',
        cancel: 'No',
        uncommittedChanges: 'dirty',
        uncommittedChangesWithDiff: (diffStat) => 'dirty[$diffStat]',
        addedLine: (count) => '+$count',
        deletedLine: (count) => '-$count',
        unpushedCommit: (count) => 'ahead $count',
      );

      expect(
        buildWorktreeArchiveRiskReasons(
          const WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 2,
            diffStat: WorktreeArchiveDiffStat(additions: 1, deletions: 4),
          ),
          labels: labels,
        ),
        ['dirty[+1, -4]', 'ahead 2'],
      );
    });
  });

  group('confirmRiskyWorktreeArchive', () {
    test('archives a risk-free worktree without prompting', () async {
      var prompted = false;
      final allowed = await confirmRiskyWorktreeArchive(
        const WorktreeArchiveConfirmationInput(
          workspaceName: 'feature',
          risk: WorktreeArchiveRisk(isDirty: false, aheadOfOrigin: 0),
        ),
        prompt: (_) async {
          prompted = true;
          return false;
        },
      );

      expect(allowed, isTrue);
      expect(prompted, isFalse);
    });

    test('prompts with the destructive request when work is at risk', () async {
      WorktreeArchiveConfirmRequest? seen;
      final allowed = await confirmRiskyWorktreeArchive(
        const WorktreeArchiveConfirmationInput(
          workspaceName: 'risky-feature',
          risk: WorktreeArchiveRisk(
            isDirty: true,
            aheadOfOrigin: 1,
            diffStat: WorktreeArchiveDiffStat(additions: 1, deletions: 3),
          ),
        ),
        prompt: (request) async {
          seen = request;
          return true;
        },
      );

      expect(allowed, isTrue);
      expect(seen!.title, 'Archive "risky-feature"?');
      expect(
        seen!.message,
        'Uncommitted changes (1 added line, 3 deleted lines)\n'
        '1 unpushed commit',
      );
      expect(seen!.confirmLabel, 'Archive');
      expect(seen!.cancelLabel, 'Cancel');
      expect(seen!.destructive, isTrue);
    });

    test('reports the user declining', () async {
      final allowed = await confirmRiskyWorktreeArchive(
        const WorktreeArchiveConfirmationInput(
          workspaceName: 'risky-feature',
          risk: WorktreeArchiveRisk(isDirty: true),
        ),
        prompt: (_) async => false,
      );

      expect(allowed, isFalse);
    });

    test('uses the supplied labels for the prompt chrome too', () async {
      WorktreeArchiveConfirmRequest? seen;
      await confirmRiskyWorktreeArchive(
        const WorktreeArchiveConfirmationInput(
          workspaceName: 'feature',
          risk: WorktreeArchiveRisk(isDirty: true),
        ),
        prompt: (request) async {
          seen = request;
          return true;
        },
        labels: WorktreeArchiveWarningLabels(
          title: (name) => 'T:$name',
          confirm: 'OK',
          cancel: 'No',
          uncommittedChanges: 'dirty',
          uncommittedChangesWithDiff: (diffStat) => 'dirty[$diffStat]',
          addedLine: (count) => '+$count',
          deletedLine: (count) => '-$count',
          unpushedCommit: (count) => 'ahead $count',
        ),
      );

      expect(seen!.title, 'T:feature');
      expect(seen!.message, 'dirty');
      expect(seen!.confirmLabel, 'OK');
      expect(seen!.cancelLabel, 'No');
    });
  });
}
