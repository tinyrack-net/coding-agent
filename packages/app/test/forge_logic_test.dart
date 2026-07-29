import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GithubMergeFacts', () {
    test('applies every frozen nested default', () {
      final facts = GithubMergeFacts.parse({'forge': 'github'});
      expect(facts, isNotNull);
      expect(facts!.mergeStateStatus, isNull);
      expect(facts.autoMergeRequest, isNull);
      expect(facts.viewerCanEnableAutoMerge, isFalse);
      expect(facts.viewerCanDisableAutoMerge, isFalse);
      expect(facts.viewerCanMergeAsAdmin, isFalse);
      expect(facts.viewerCanUpdateBranch, isFalse);
      expect(facts.isMergeQueueEnabled, isFalse);
      expect(facts.isInMergeQueue, isFalse);
      expect(facts.repository.autoMergeAllowed, isFalse);
      expect(facts.repository.mergeCommitAllowed, isFalse);
      expect(facts.repository.squashMergeAllowed, isFalse);
      expect(facts.repository.rebaseMergeAllowed, isFalse);
      expect(facts.repository.viewerDefaultMergeMethod, isNull);
    });

    test('parses auto-merge and repository policy facts', () {
      final facts = GithubMergeFacts.parse(
        _githubFacts(
          autoMergeRequest: {
            'enabledAt': 'now',
            'mergeMethod': 'SQUASH',
            'enabledBy': 'octocat',
          },
          repository: {
            'autoMergeAllowed': true,
            'mergeCommitAllowed': true,
            'squashMergeAllowed': true,
            'rebaseMergeAllowed': false,
            'viewerDefaultMergeMethod': 'SQUASH',
          },
        ),
      )!;
      expect(facts.autoMergeRequest!.enabledAt, 'now');
      expect(facts.autoMergeRequest!.mergeMethod, 'SQUASH');
      expect(facts.autoMergeRequest!.enabledBy, 'octocat');
      expect(facts.repository.autoMergeAllowed, isTrue);
      expect(facts.repository.viewerDefaultMergeMethod, 'SQUASH');
    });

    test('rejects untagged, wrong-family, and mismatched nested facts', () {
      for (final value in [
        null,
        {'mergeStateStatus': 'CLEAN'},
        {'forge': 'gitlab', 'mergeStateStatus': 'CLEAN'},
        {'forge': 'github', 'mergeStateStatus': false},
        {'forge': 'github', 'viewerCanEnableAutoMerge': null},
        {'forge': 'github', 'autoMergeRequest': false},
        {
          'forge': 'github',
          'autoMergeRequest': {'enabledAt': 1},
        },
        {'forge': 'github', 'repository': null},
        {
          'forge': 'github',
          'repository': {'mergeCommitAllowed': null},
        },
        {
          'forge': 'github',
          'repository': {'viewerDefaultMergeMethod': false},
        },
      ]) {
        expect(GithubMergeFacts.parse(value), isNull, reason: '$value');
      }
    });
  });

  group('deriveGithubMergeCapability', () {
    test('allows direct merge only for CLEAN and HAS_HOOKS', () {
      expect(
        _githubCapability(mergeStateStatus: 'CLEAN')!.directMergeReady,
        isTrue,
      );
      expect(
        _githubCapability(mergeStateStatus: 'HAS_HOOKS')!.directMergeReady,
        isTrue,
      );
      expect(
        _githubCapability(mergeStateStatus: 'BLOCKED')!.directMergeReady,
        isFalse,
      );
      expect(
        _githubCapability(mergeStateStatus: null)!.directMergeReady,
        isFalse,
      );
    });

    test('enables auto-merge only for the three required conditions', () {
      final ready = _githubCapability(
        mergeStateStatus: 'BLOCKED',
        viewerCanEnableAutoMerge: true,
        repository: {
          'autoMergeAllowed': true,
          'mergeCommitAllowed': true,
          'squashMergeAllowed': true,
          'rebaseMergeAllowed': true,
          'viewerDefaultMergeMethod': 'SQUASH',
        },
      )!;
      expect(ready.canEnableAutoMerge, isTrue);
      expect(
        _githubCapability(
          mergeStateStatus: 'BLOCKED',
          viewerCanEnableAutoMerge: false,
        )!.canEnableAutoMerge,
        isFalse,
      );
      expect(
        _githubCapability(
          mergeStateStatus: 'CLEAN',
          viewerCanEnableAutoMerge: true,
          repository: {'autoMergeAllowed': true},
        )!.canEnableAutoMerge,
        isFalse,
      );
    });

    test('reports enabled auto-merge and viewer disable permission', () {
      final capability = _githubCapability(
        autoMergeRequest: {
          'enabledAt': 'now',
          'mergeMethod': 'SQUASH',
          'enabledBy': 'octocat',
        },
        viewerCanDisableAutoMerge: true,
      )!;
      expect(capability.autoMergeEnabled, isTrue);
      expect(capability.canDisableAutoMerge, isTrue);
      expect(_githubCapability()!.autoMergeEnabled, isFalse);
    });

    test('treats either queue signal as blocking', () {
      expect(
        _githubCapability(isMergeQueueEnabled: true)!.mergeBlockedByQueue,
        isTrue,
      );
      expect(
        _githubCapability(isInMergeQueue: true)!.mergeBlockedByQueue,
        isTrue,
      );
      expect(_githubCapability()!.mergeBlockedByQueue, isFalse);
    });

    test('derives allowed and preferred repository merge methods', () {
      final capability = _githubCapability(
        repository: {
          'autoMergeAllowed': false,
          'mergeCommitAllowed': false,
          'squashMergeAllowed': true,
          'rebaseMergeAllowed': true,
          'viewerDefaultMergeMethod': 'REBASE',
        },
      )!;
      expect(capability.allowedMethods, ['squash', 'rebase']);
      expect(capability.preferredMethod, 'rebase');
      expect(
        _githubCapability(
          repository: {'viewerDefaultMergeMethod': 'UNKNOWN'},
        )!.preferredMethod,
        isNull,
      );
    });
  });

  group('deriveForgeMergeCapability registry', () {
    test('supports the legacy GitHub facts fallback', () {
      final legacy = Map<String, Object?>.from(_githubFacts())..remove('forge');
      final capability = deriveForgeMergeCapability(
        null,
        legacyGithubFacts: legacy,
      );
      expect(capability, isNotNull);
      expect(capability!.directMergeReady, isTrue);
      expect(capability.allowedMethods, ['merge', 'squash', 'rebase']);
    });

    test('returns null without facts and dispatches registered families', () {
      expect(deriveForgeMergeCapability(null), isNull);
      expect(deriveForgeMergeCapability({'forge': 'unknown'}), isNull);
      expect(
        deriveForgeMergeCapability({
          'forge': 'gitea',
          'mergeable': true,
          'hasMerged': false,
        })?.directMergeReady,
        isTrue,
      );
    });
  });

  group('GiteaMergeFacts', () {
    test('validates the family and applies frozen defaults', () {
      final defaults = GiteaMergeFacts.parse({'forge': 'gitea'});
      expect(defaults, isNotNull);
      expect(defaults!.mergeable, isFalse);
      expect(defaults.hasMerged, isFalse);
      expect(defaults.ciStatus, isNull);

      expect(
        GiteaMergeFacts.parse({
          'forge': 'gitea',
          'mergeable': true,
          'hasMerged': false,
          'ciStatus': 'success',
          'futureField': 1,
        })?.ciStatus,
        'success',
      );
    });

    test('rejects untagged and schema-mismatched facts', () {
      for (final value in [
        null,
        {'mergeable': true},
        {'forge': 'forgejo', 'mergeable': true},
        {'forge': 'gitea', 'mergeable': 'yes'},
        {'forge': 'gitea', 'hasMerged': 0},
        {'forge': 'gitea', 'ciStatus': false},
      ]) {
        expect(GiteaMergeFacts.parse(value), isNull, reason: '$value');
      }
    });
  });

  group('deriveGiteaMergeCapability', () {
    test('allows direct merge only for mergeable and unmerged PRs', () {
      expect(_capability()?.directMergeReady, isTrue);
      expect(_capability(mergeable: false)?.directMergeReady, isFalse);
      expect(_capability(hasMerged: true)?.directMergeReady, isFalse);
      expect(deriveGiteaMergeCapability(null), isNull);
    });

    test('offers all direct methods without auto-merge or a queue', () {
      final capability = _capability()!;
      expect(capability.allowedMethods, ['merge', 'squash', 'rebase']);
      expect(capability.preferredMethod, isNull);
      expect(capability.canEnableAutoMerge, isFalse);
      expect(capability.autoMergeEnabled, isFalse);
      expect(capability.canDisableAutoMerge, isFalse);
      expect(capability.mergeBlockedByQueue, isFalse);
    });
  });

  group('Gitea native fallback checks', () {
    test('brands the aggregate check with the top-level forge', () {
      final checks = getGiteaNativeFallbackChecks(
        _status(ciStatus: 'failure'),
        'forgejo',
      );
      expect(checks, hasLength(1));
      expect(checks.single.provider, 'forgejo');
      expect(checks.single.name, 'CI');
      expect(checks.single.status, ForgeCheckStatus.failure);
      expect(checks.single.url, 'https://forge.example/pr/7');
    });

    test('maps warning and error to failure, not pending', () {
      for (final raw in ['warning', 'error']) {
        expect(
          getGiteaNativeFallbackChecks(
            _status(ciStatus: raw),
            'gitea',
          ).single.status,
          ForgeCheckStatus.failure,
        );
      }
    });

    test('uses the neutral status mapping for other raw values', () {
      expect(mapForgeCheckStatus('success'), ForgeCheckStatus.success);
      expect(mapForgeCheckStatus('failure'), ForgeCheckStatus.failure);
      expect(mapForgeCheckStatus('cancelled'), ForgeCheckStatus.skipped);
      expect(mapForgeCheckStatus('running'), ForgeCheckStatus.pending);
      expect(
        getGiteaNativeFallbackChecks(
          _status(ciStatus: 'success'),
          'gitea',
        ).single.status,
        ForgeCheckStatus.success,
      );
    });

    test('returns no aggregate check without a CI status', () {
      expect(
        getGiteaNativeFallbackChecks(_status(ciStatus: null), 'gitea'),
        isEmpty,
      );
      expect(
        getGiteaNativeFallbackChecks(
          _status(ciStatus: '', factsForge: 'gitea'),
          'gitea',
        ),
        isEmpty,
      );
      expect(
        getGiteaNativeFallbackChecks(
          _status(ciStatus: 'success', factsForge: 'gitlab'),
          'gitlab',
        ),
        isEmpty,
      );
    });

    test('native checks win and null-URL checks fall back', () {
      final native = _status(
        ciStatus: 'success',
        checks: const [
          CheckoutPrCheck(
            name: 'build',
            status: 'failure',
            url: 'https://ci.example/build',
          ),
        ],
      );
      expect(resolvePullRequestChecks(native).single.name, 'build');

      final unknown = _status(
        ciStatus: 'success',
        checks: const [
          CheckoutPrCheck(
            name: 'running',
            status: 'in_progress',
            url: 'https://ci.example/running',
          ),
        ],
      );
      expect(resolvePullRequestChecks(unknown).single.status, 'pending');

      final unusable = _status(
        ciStatus: 'success',
        checks: const [
          CheckoutPrCheck(name: 'hidden', status: 'success', url: null),
        ],
      );
      final fallback = resolvePullRequestChecks(unusable).single;
      expect(fallback.name, 'CI');
      expect(fallback.status, 'success');
      expect(fallback.url, 'https://forge.example/pr/7');
    });
  });
}

ForgeMergeCapability? _capability({
  bool mergeable = true,
  bool hasMerged = false,
}) => deriveGiteaMergeCapability({
  'forge': 'gitea',
  'mergeable': mergeable,
  'hasMerged': hasMerged,
  'ciStatus': 'success',
});

ForgeMergeCapability? _githubCapability({
  String? mergeStateStatus = 'CLEAN',
  Object? autoMergeRequest,
  bool viewerCanEnableAutoMerge = false,
  bool viewerCanDisableAutoMerge = false,
  Map<String, Object?>? repository,
  bool isMergeQueueEnabled = false,
  bool isInMergeQueue = false,
}) => deriveGithubMergeCapability(
  _githubFacts(
    mergeStateStatus: mergeStateStatus,
    autoMergeRequest: autoMergeRequest,
    viewerCanEnableAutoMerge: viewerCanEnableAutoMerge,
    viewerCanDisableAutoMerge: viewerCanDisableAutoMerge,
    repository: repository,
    isMergeQueueEnabled: isMergeQueueEnabled,
    isInMergeQueue: isInMergeQueue,
  ),
);

Map<String, Object?> _githubFacts({
  String? mergeStateStatus = 'CLEAN',
  Object? autoMergeRequest,
  bool viewerCanEnableAutoMerge = false,
  bool viewerCanDisableAutoMerge = false,
  Map<String, Object?>? repository,
  bool isMergeQueueEnabled = false,
  bool isInMergeQueue = false,
}) => {
  'forge': 'github',
  'mergeStateStatus': mergeStateStatus,
  'autoMergeRequest': autoMergeRequest,
  'viewerCanEnableAutoMerge': viewerCanEnableAutoMerge,
  'viewerCanDisableAutoMerge': viewerCanDisableAutoMerge,
  'viewerCanMergeAsAdmin': false,
  'viewerCanUpdateBranch': false,
  'repository':
      repository ??
      {
        'autoMergeAllowed': false,
        'mergeCommitAllowed': true,
        'squashMergeAllowed': true,
        'rebaseMergeAllowed': true,
        'viewerDefaultMergeMethod': 'SQUASH',
      },
  'isMergeQueueEnabled': isMergeQueueEnabled,
  'isInMergeQueue': isInMergeQueue,
};

CheckoutPrStatus _status({
  required String? ciStatus,
  String factsForge = 'gitea',
  List<CheckoutPrCheck> checks = const [],
}) => CheckoutPrStatus(
  forge: 'gitea',
  url: 'https://forge.example/pr/7',
  title: 'Native data',
  state: 'open',
  baseRefName: 'main',
  headRefName: 'feature',
  isMerged: false,
  isDraft: false,
  mergeable: 'UNKNOWN',
  checks: checks,
  forgeSpecific: {
    'forge': factsForge,
    'mergeable': true,
    'hasMerged': false,
    'ciStatus': ciStatus,
  },
);
