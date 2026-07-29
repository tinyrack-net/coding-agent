import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
