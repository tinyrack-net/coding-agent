// Ports of the upstream suites for `utils/github-refs.ts`,
// `utils/branch-suggestions.ts`, `git/forges/index.ts`,
// `utils/server-info-capabilities.ts` and
// `utils/agent-working-directory-suggestions.ts`, plus the edge cases those
// suites leave unpinned:
//
// - ref-URL scanning boundaries the upstream suite never exercises (bare
//   `pull/0`, zero-padded numbers, numbers past `Number.MAX_SAFE_INTEGER`,
//   `www.` and trailing-dot hosts, `.git` in the repo segment, autolink and
//   parenthesis wrappers, two URLs run together);
// - the double-prefix and empty-after-strip branches of branch normalization;
// - the forge registry's schema normalization (Zod defaults, `.passthrough()`
//   top-level keys, nested objects that are *not* passthrough), verified
//   against the frozen schemas executed under Node;
// - malformed and absent daemon capability blocks;
// - timestamp fallback, tie-breaking, and the Windows-separator worktree path;
// - `String.compareTo` standing in for `localeCompare`, the one documented
//   Dart deviation left in this cluster.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge.dart';
import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:coding_agent_app/git/paseo_git_refs.dart';
import 'package:flutter_test/flutter_test.dart';

const httpsRemote = 'https://github.com/getpaseo/paseo.git';
const sshRemote = 'git@github.com:getpaseo/paseo.git';

GithubRef pullRef(
  int number, {
  String owner = 'getpaseo',
  String repo = 'paseo',
}) => GithubRef(
  kind: GithubRefKind.pull,
  number: number,
  owner: owner,
  repo: repo,
  url: 'https://github.com/$owner/$repo/pull/$number',
);

GithubRef issueRef(
  int number, {
  String owner = 'getpaseo',
  String repo = 'paseo',
}) => GithubRef(
  kind: GithubRefKind.issues,
  number: number,
  owner: owner,
  repo: repo,
  url: 'https://github.com/$owner/$repo/issues/$number',
);

/// Mirrors the upstream `buildServerInfo` fixture; `capabilities` defaults to
/// the empty map the Dart `ServerInfoStatus` uses for "the daemon advertised
/// none".
ServerInfoStatus serverInfo({Map<String, Object?> capabilities = const {}}) =>
    ServerInfoStatus(
      serverId: 'srv-1',
      hostname: 'test-host',
      version: '0.1.0',
      desktopManaged: false,
      capabilities: capabilities,
    );

CheckoutPrStatus prStatus({Object? forgeSpecific, String forge = 'gitea'}) =>
    CheckoutPrStatus(
      forge: forge,
      url: 'https://gitea.com/acme/repo/pulls/7',
      title: 'Add a thing',
      state: 'open',
      baseRefName: 'main',
      headRefName: 'feature',
      isMerged: false,
      isDraft: false,
      mergeable: 'MERGEABLE',
      checks: const [],
      forgeSpecific: forgeSpecific,
    );

void main() {
  // -------------------------------------------------------------------------
  // utils/github-refs.ts
  // -------------------------------------------------------------------------
  group('normalizeGithubRemote', () {
    const cases = <String, (String, String)>{
      'https://github.com/getpaseo/paseo': ('getpaseo', 'paseo'),
      'https://github.com/getpaseo/paseo.git': ('getpaseo', 'paseo'),
      'git@github.com:getpaseo/paseo.git': ('getpaseo', 'paseo'),
      'ssh://git@github.com/getpaseo/paseo.git': ('getpaseo', 'paseo'),
    };

    cases.forEach((remoteUrl, expected) {
      test('extracts GitHub identity from $remoteUrl', () {
        final remote = normalizeGithubRemote(remoteUrl);
        expect(remote, isNotNull);
        expect(remote!.owner, expected.$1);
        expect(remote.repo, expected.$2);
        expect(remote.host, 'github.com');
      });
    });

    test('returns null for non-GitHub remotes and empty input', () {
      expect(
        normalizeGithubRemote('git@gitlab.com:getpaseo/paseo.git'),
        isNull,
      );
      expect(normalizeGithubRemote(null), isNull);
    });

    test('treats blank and whitespace-only remotes as absent', () {
      // Upstream's `if (!trimmed)` truthiness guard; Dart needs both arms
      // spelled out because there is no `undefined`.
      expect(normalizeGithubRemote(''), isNull);
      expect(normalizeGithubRemote('   '), isNull);
    });

    test('trims surrounding whitespace before parsing', () {
      expect(
        normalizeGithubRemote('  https://github.com/getpaseo/paseo.git  '),
        const GithubRemote(owner: 'getpaseo', repo: 'paseo'),
      );
    });

    test('preserves the remote spelling of owner and repo casing', () {
      expect(
        normalizeGithubRemote('https://github.com/GetPaseo/Paseo.git'),
        const GithubRemote(owner: 'GetPaseo', repo: 'Paseo'),
      );
    });

    test('rejects remotes that are not exactly owner/repo', () {
      expect(normalizeGithubRemote('https://github.com/getpaseo'), isNull);
      expect(
        normalizeGithubRemote('https://github.com/getpaseo/paseo/extra'),
        isNull,
      );
    });

    test('accepts ssh.github.com, the port-443 SSH alias', () {
      // The frozen forge manifest lists `github.com` and `ssh.github.com` as
      // GitHub cloud hosts, and `isGitHubHost` derives from that list. The
      // protocol's twin originally hardcoded only `github.com`; porting this
      // module surfaced the gap and it was fixed there, not worked around here.
      for (final remote in const [
        'ssh://git@ssh.github.com/getpaseo/paseo.git',
        'git@ssh.github.com:getpaseo/paseo.git',
      ]) {
        expect(
          normalizeGithubRemote(remote),
          const GithubRemote(owner: 'getpaseo', repo: 'paseo'),
          reason: remote,
        );
      }
      expect(
        getForgeDefinition('github')!.cloudHosts,
        containsAll(<String>['github.com', 'ssh.github.com']),
      );
    });
  });

  group('parseGithubRef', () {
    const pullVariants = <String>[
      'https://github.com/getpaseo/paseo/pull/994',
      'https://github.com/getpaseo/paseo/pull/994/',
      'https://github.com/getpaseo/paseo/pull/994/files',
      'https://github.com/getpaseo/paseo/pull/994?diff=split',
      'https://github.com/getpaseo/paseo/pull/994#discussion_r123',
    ];

    for (final text in pullVariants) {
      test('parses a matching pull request URL: $text', () {
        expect(parseGithubRef(text, httpsRemote), pullRef(994));
      });
    }

    test('parses a matching issue URL', () {
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/issues/456',
          httpsRemote,
        ),
        issueRef(456),
      );
    });

    test('matches HTTPS pasted URLs against an SSH remote', () {
      expect(
        parseGithubRef('https://github.com/getpaseo/paseo/pull/994', sshRemote),
        pullRef(994),
      );
    });

    test('ignores URLs for another owner or repo', () {
      expect(
        parseGithubRef('https://github.com/other/paseo/pull/994', httpsRemote),
        isNull,
      );
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/other/pull/994',
          httpsRemote,
        ),
        isNull,
      );
    });

    test('returns null for non-GitHub remotes and empty text', () {
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pull/994',
          'git@gitlab.com:getpaseo/paseo.git',
        ),
        isNull,
      );
      expect(parseGithubRef('', httpsRemote), isNull);
      expect(
        parseGithubRef('https://github.com/getpaseo/paseo/pull/994', null),
        isNull,
      );
    });

    test('finds URLs embedded in text and markdown links', () {
      expect(
        parseGithubRef(
          'See:\n[the PR](https://github.com/getpaseo/paseo/pull/994/files).',
          httpsRemote,
        ),
        pullRef(994),
      );
    });

    test('returns null for null or whitespace-only text', () {
      expect(parseGithubRef(null, httpsRemote), isNull);
      expect(parseGithubRef('   \n\t ', httpsRemote), isNull);
    });

    test('accepts http as well as https', () {
      expect(
        parseGithubRef(
          'http://github.com/getpaseo/paseo/issues/12',
          httpsRemote,
        ),
        issueRef(12),
      );
    });

    test('matches the host and owner/repo case-insensitively', () {
      // GitHub treats owner/repo case-insensitively, so a differently-cased
      // paste still resolves — but the emitted ref uses the *remote's* casing.
      expect(
        parseGithubRef(
          'HTTPS://GITHUB.COM/GetPaseo/Paseo/pull/994',
          httpsRemote,
        ),
        pullRef(994),
      );
    });

    test('canonicalizes the URL, dropping suffixes and zero padding', () {
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pull/007/files',
          httpsRemote,
        ),
        pullRef(7),
      );
    });

    test('rejects a zero or otherwise non-positive number', () {
      expect(
        parseGithubRef('https://github.com/getpaseo/paseo/pull/0', httpsRemote),
        isNull,
      );
      // A leading `-` is not part of `\d+`, so the regex simply never reaches a
      // negative number; the URL below matches nothing at all.
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pull/-1',
          httpsRemote,
        ),
        isNull,
      );
    });

    test(
      'rejects numbers past JavaScript MAX_SAFE_INTEGER but keeps the bound',
      () {
        expect(
          parseGithubRef(
            'https://github.com/getpaseo/paseo/pull/99999999999999999999',
            httpsRemote,
          ),
          isNull,
        );
        expect(
          parseGithubRef(
            'https://github.com/getpaseo/paseo/pull/9007199254740993',
            httpsRemote,
          ),
          isNull,
        );
        expect(
          parseGithubRef(
            'https://github.com/getpaseo/paseo/pull/9007199254740991',
            httpsRemote,
          ),
          pullRef(9007199254740991),
        );
      },
    );

    test('stops the number at the first non-digit', () {
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pull/994x',
          httpsRemote,
        ),
        pullRef(994),
      );
    });

    test('requires the exact pull/issues segment', () {
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pulls/994',
          httpsRemote,
        ),
        isNull,
      );
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/issue/994',
          httpsRemote,
        ),
        isNull,
      );
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/discussions/994',
          httpsRemote,
        ),
        isNull,
      );
    });

    test('does not strip .git from the matched repo segment', () {
      // The remote parser strips `.git`, but the *URL* scanner does not, so a
      // link written with `.git` in the path no longer names this repository.
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo.git/pull/994',
          httpsRemote,
        ),
        isNull,
      );
    });

    test('rejects hosts that merely resemble github.com', () {
      expect(
        parseGithubRef(
          'https://www.github.com/getpaseo/paseo/pull/994',
          httpsRemote,
        ),
        isNull,
      );
      expect(
        parseGithubRef(
          'https://github.com./getpaseo/paseo/pull/994',
          httpsRemote,
        ),
        isNull,
      );
      expect(
        parseGithubRef(
          'https://notgithub.com/getpaseo/paseo/pull/994',
          httpsRemote,
        ),
        isNull,
      );
    });

    test(
      'rejects a deeper path where owner/repo would have to span a slash',
      () {
        expect(
          parseGithubRef(
            'https://github.com/a/b/c/pull/1',
            'https://github.com/a/b',
          ),
          isNull,
        );
      },
    );

    test('matches an unanchored URL glued to preceding text', () {
      // The pattern has no left boundary, so `prefixhttps://...` still matches.
      // Pinned because it is surprising, not because it is desirable.
      expect(
        parseGithubRef(
          'prefixhttps://github.com/getpaseo/paseo/pull/994',
          httpsRemote,
        ),
        pullRef(994),
      );
    });

    test('stops the trailing-suffix run at bracket and angle delimiters', () {
      expect(
        parseGithubRef(
          '(https://github.com/getpaseo/paseo/pull/994)',
          httpsRemote,
        ),
        pullRef(994),
      );
      expect(
        parseGithubRef(
          '<https://github.com/getpaseo/paseo/pull/994>',
          httpsRemote,
        ),
        pullRef(994),
      );
      expect(
        parseGithubRef(
          'https://github.com/getpaseo/paseo/pull/994.',
          httpsRemote,
        ),
        pullRef(994),
      );
    });
  });

  group('extractGithubRefs', () {
    test('returns every matching ref deduped by kind and number', () {
      final text = [
        'https://github.com/getpaseo/paseo/pull/994',
        'https://github.com/getpaseo/paseo/issues/456#issuecomment-1',
        'https://github.com/getpaseo/paseo/pull/994/files',
        'https://github.com/other/paseo/issues/1',
      ].join('\n');

      expect(extractGithubRefs(text, httpsRemote), [
        pullRef(994),
        issueRef(456),
      ]);
    });

    test('returns an empty list for empty text or null remote', () {
      expect(extractGithubRefs('', httpsRemote), isEmpty);
      expect(
        extractGithubRefs('https://github.com/getpaseo/paseo/pull/994', null),
        isEmpty,
      );
    });

    test(
      'dedupes by kind and number, so the same number in both kinds survives',
      () {
        final text = [
          'https://github.com/getpaseo/paseo/pull/1',
          'https://github.com/getpaseo/paseo/issues/1',
          'https://github.com/getpaseo/paseo/pull/1?w=1',
        ].join(' ');

        expect(extractGithubRefs(text, httpsRemote), [pullRef(1), issueRef(1)]);
      },
    );

    test('preserves the order the refs appear in', () {
      final text = [
        'https://github.com/getpaseo/paseo/issues/9',
        'https://github.com/getpaseo/paseo/pull/2',
        'https://github.com/getpaseo/paseo/issues/5',
      ].join(', ');

      expect(extractGithubRefs(text, httpsRemote), [
        issueRef(9),
        pullRef(2),
        issueRef(5),
      ]);
    });

    test('separates adjacent URLs on whitespace but not on a slash', () {
      // A space ends the trailing-suffix run, so both URLs match; a slash keeps
      // the run going and the second URL is swallowed into the first match.
      expect(
        extractGithubRefs(
          'https://github.com/getpaseo/paseo/pull/12 '
          'https://github.com/getpaseo/paseo/pull/34',
          httpsRemote,
        ),
        [pullRef(12), pullRef(34)],
      );
      expect(
        extractGithubRefs(
          'https://github.com/getpaseo/paseo/pull/12/'
          'https://github.com/getpaseo/paseo/pull/34',
          httpsRemote,
        ),
        [pullRef(12)],
      );
    });

    test('emits the remote casing even when every paste is lowercased', () {
      expect(
        extractGithubRefs(
          'https://github.com/getpaseo/paseo/pull/3',
          'https://github.com/GetPaseo/Paseo.git',
        ),
        [pullRef(3, owner: 'GetPaseo', repo: 'Paseo')],
      );
    });

    test('skips an out-of-range number without abandoning later refs', () {
      expect(
        extractGithubRefs(
          'https://github.com/getpaseo/paseo/pull/0 '
          'https://github.com/getpaseo/paseo/pull/5',
          httpsRemote,
        ),
        [pullRef(5)],
      );
    });
  });

  // -------------------------------------------------------------------------
  // utils/branch-suggestions.ts
  // -------------------------------------------------------------------------
  group('normalizeBranchOptionName', () {
    test('normalizes local and origin-prefixed refs', () {
      expect(normalizeBranchOptionName('refs/heads/main'), 'main');
      expect(normalizeBranchOptionName('refs/remotes/origin/main'), 'main');
      expect(normalizeBranchOptionName('origin/feature/test'), 'feature/test');
      expect(normalizeBranchOptionName('feature/test'), 'feature/test');
    });

    test('filters out empty values and HEAD', () {
      expect(normalizeBranchOptionName(''), isNull);
      expect(normalizeBranchOptionName('   '), isNull);
      expect(normalizeBranchOptionName('HEAD'), isNull);
      expect(normalizeBranchOptionName('origin/HEAD'), isNull);
    });

    test('treats a null name as absent', () {
      expect(normalizeBranchOptionName(null), isNull);
    });

    test('trims before and after normalizing', () {
      expect(normalizeBranchOptionName('  refs/heads/main  '), 'main');
      expect(normalizeBranchOptionName('  HEAD  '), isNull);
    });

    test('strips a refs prefix and an origin prefix independently', () {
      // The two strips are separate `if`s, so both can apply to one ref.
      expect(normalizeBranchOptionName('refs/heads/origin/main'), 'main');
      expect(normalizeBranchOptionName('refs/remotes/origin/HEAD'), isNull);
    });

    test('keeps a non-origin remote prefix', () {
      expect(
        normalizeBranchOptionName('refs/remotes/upstream/main'),
        'upstream/main',
      );
      expect(normalizeBranchOptionName('upstream/main'), 'upstream/main');
    });

    test('applies at most one refs prefix, never both', () {
      // `refs/heads/` wins the else-if, leaving the rest untouched.
      expect(
        normalizeBranchOptionName('refs/heads/refs/remotes/origin/main'),
        'refs/remotes/origin/main',
      );
    });

    test('returns null when nothing is left after stripping', () {
      expect(normalizeBranchOptionName('refs/heads/'), isNull);
      expect(normalizeBranchOptionName('refs/remotes/'), isNull);
      expect(normalizeBranchOptionName('origin/'), isNull);
      expect(normalizeBranchOptionName('refs/remotes/origin/'), isNull);
    });

    test('only strips prefixes, never infixes', () {
      expect(
        normalizeBranchOptionName('feature/origin/main'),
        'feature/origin/main',
      );
      expect(
        normalizeBranchOptionName('my-refs/heads/main'),
        'my-refs/heads/main',
      );
    });
  });

  group('buildBranchComboOptions', () {
    test('merges branch sources and de-duplicates normalized names', () {
      final options = buildBranchComboOptions(
        suggestedBranches: const [
          'origin/main',
          'refs/remotes/origin/main',
          'feature/a',
        ],
        currentBranch: 'refs/heads/feature/a',
        baseRef: 'origin/main',
        typedBaseBranch: 'main',
        worktreeBranchLabels: const ['refs/heads/release/next'],
      );

      expect(options, const [
        BranchComboOption(id: 'main', label: 'main'),
        BranchComboOption(id: 'feature/a', label: 'feature/a'),
        BranchComboOption(id: 'release/next', label: 'release/next'),
      ]);
    });

    test('returns an empty list when every source is absent', () {
      expect(buildBranchComboOptions(), isEmpty);
    });

    test('drops blank, HEAD, and unusable entries from every source', () {
      final options = buildBranchComboOptions(
        suggestedBranches: const ['', '   ', 'HEAD', 'origin/HEAD'],
        currentBranch: 'HEAD',
        baseRef: '',
        typedBaseBranch: null,
        worktreeBranchLabels: const ['refs/heads/'],
      );

      expect(options, isEmpty);
    });

    test(
      'keeps the first occurrence position when a later source repeats it',
      () {
        // `main` first appears via the worktree labels in this ordering, so it
        // must land after `feature/a` even though `typedBaseBranch` repeats it.
        final options = buildBranchComboOptions(
          suggestedBranches: const ['feature/a'],
          worktreeBranchLabels: const ['refs/remotes/origin/main'],
          typedBaseBranch: 'main',
        );

        expect(options.map((option) => option.id), ['feature/a', 'main']);
      },
    );

    test('consumes sources in the upstream order', () {
      final options = buildBranchComboOptions(
        suggestedBranches: const ['s'],
        currentBranch: 'c',
        baseRef: 'b',
        typedBaseBranch: 't',
        worktreeBranchLabels: const ['w'],
      );

      expect(options.map((option) => option.id), ['s', 'c', 'b', 't', 'w']);
    });

    test('uses the same string for id and label', () {
      final options = buildBranchComboOptions(typedBaseBranch: 'origin/main');
      expect(options, const [BranchComboOption(id: 'main', label: 'main')]);
    });
  });

  // -------------------------------------------------------------------------
  // git/forges/index.ts
  // -------------------------------------------------------------------------
  group('clientForgeLogicModules completeness', () {
    test('registers every forge in the manifest, and nothing else', () {
      // Dart analogue of upstream's readdir-based completeness test: the forge
      // manifest in core/forge.dart is the enumerable source of truth here.
      final registeredIds =
          clientForgeLogicModules.map((module) => module.id).toList()..sort();
      final manifestIds =
          forgeDefinitions.map((definition) => definition.id).toList()..sort();
      expect(registeredIds, manifestIds);
    });

    test('has no duplicate forge ids', () {
      final ids = clientForgeLogicModules.map((module) => module.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('preserves upstream declaration order', () {
      // Order is observable through parseClientForgeFacts, which returns the
      // first accepting family.
      expect(clientForgeLogicModules.map((module) => module.id), [
        'github',
        'gitlab',
        'gitea',
        'forgejo',
        'codeberg',
      ]);
    });

    test('every registered module has a URL grammar', () {
      for (final module in clientForgeLogicModules) {
        expect(module.hasUrlGrammar, isTrue, reason: module.id);
      }
    });

    test('a facts entry always claims its own module id as its family', () {
      for (final module in clientForgeLogicModules) {
        final facts = module.facts;
        if (facts != null) expect(facts.family, module.id);
      }
    });

    test('only the fact-bearing forges expose a facts entry', () {
      Iterable<String> withFacts(bool present) => clientForgeLogicModules
          .where((module) => (module.facts != null) == present)
          .map((module) => module.id);

      expect(withFacts(true), ['github', 'gitlab', 'gitea']);
      expect(withFacts(false), ['forgejo', 'codeberg']);
    });
  });

  group('getClientForgeLogicModule', () {
    test('finds a registered forge by id', () {
      expect(getClientForgeLogicModule('gitlab')?.id, 'gitlab');
      expect(getClientForgeLogicModule('codeberg')?.facts, isNull);
    });

    test('returns null for an unknown or mis-cased id', () {
      expect(getClientForgeLogicModule('bitbucket'), isNull);
      expect(getClientForgeLogicModule('GitHub'), isNull);
      expect(getClientForgeLogicModule(''), isNull);
    });
  });

  group('parseClientForgeFacts', () {
    test('fills in every GitHub schema default', () {
      final parsed = parseClientForgeFacts(const {'forge': 'github'});
      expect(parsed, isNotNull);
      expect(parsed!.forge, 'github');
      expect(parsed.values, {
        'forge': 'github',
        'mergeStateStatus': null,
        'autoMergeRequest': null,
        'viewerCanEnableAutoMerge': false,
        'viewerCanDisableAutoMerge': false,
        'viewerCanMergeAsAdmin': false,
        'viewerCanUpdateBranch': false,
        'repository': {
          'autoMergeAllowed': false,
          'mergeCommitAllowed': false,
          'squashMergeAllowed': false,
          'rebaseMergeAllowed': false,
          'viewerDefaultMergeMethod': null,
        },
        'isMergeQueueEnabled': false,
        'isInMergeQueue': false,
      });
    });

    test('passes unknown top-level keys through but strips nested ones', () {
      // Upstream's outer schema is `.passthrough()`; the nested
      // `repository` / `autoMergeRequest` schemas are not. Verified against the
      // frozen Zod schemas run under Node.
      final parsed = parseClientForgeFacts(const {
        'forge': 'github',
        'autoMergeRequest': <String, Object?>{},
        'repository': {'squashMergeAllowed': true, 'bogus': 1},
        'custom': 'keep',
      });

      expect(parsed!.values['custom'], 'keep');
      expect(parsed.values['autoMergeRequest'], {
        'enabledAt': null,
        'mergeMethod': null,
        'enabledBy': null,
      });
      expect(parsed.values['repository'], {
        'autoMergeAllowed': false,
        'mergeCommitAllowed': false,
        'squashMergeAllowed': true,
        'rebaseMergeAllowed': false,
        'viewerDefaultMergeMethod': null,
      });
    });

    test('keeps an explicit null distinct from an empty auto-merge object', () {
      expect(
        parseClientForgeFacts(const {
          'forge': 'github',
          'autoMergeRequest': null,
        })!.values['autoMergeRequest'],
        isNull,
      );
      expect(
        parseClientForgeFacts(const {
          'forge': 'github',
          'autoMergeRequest': <String, Object?>{'enabledBy': 'octocat'},
        })!.values['autoMergeRequest'],
        {'enabledAt': null, 'mergeMethod': null, 'enabledBy': 'octocat'},
      );
    });

    test('fills in every GitLab schema default', () {
      final parsed = parseClientForgeFacts(const {'forge': 'gitlab'});
      expect(parsed!.forge, 'gitlab');
      expect(parsed.values, {
        'forge': 'gitlab',
        'detailedMergeStatus': null,
        'mergeStatus': null,
        'hasConflicts': false,
        // The only default that is not the falsy one.
        'blockingDiscussionsResolved': true,
        'approvalsRequired': 0,
        'approvalsGiven': 0,
        'pipelineStatus': null,
        'pipelineId': null,
        'pipelineUrl': null,
        'mergeWhenPipelineSucceeds': false,
      });
    });

    test('fills in every Gitea schema default and passes extras through', () {
      final parsed = parseClientForgeFacts(const {
        'forge': 'gitea',
        'ciStatus': 'warning',
        'extra': {'a': 1},
      });
      expect(parsed!.forge, 'gitea');
      expect(parsed.values, {
        'forge': 'gitea',
        'mergeable': false,
        'hasMerged': false,
        'ciStatus': 'warning',
        'extra': {'a': 1},
      });
    });

    test('returns null for absent, non-map, or unknown-family payloads', () {
      expect(parseClientForgeFacts(null), isNull);
      expect(parseClientForgeFacts('github'), isNull);
      expect(parseClientForgeFacts(0), isNull);
      expect(parseClientForgeFacts(false), isNull);
      expect(parseClientForgeFacts(const <String, Object?>{}), isNull);
      expect(parseClientForgeFacts(const {'forge': 'bitbucket'}), isNull);
      expect(parseClientForgeFacts(const {'forge': 'forgejo'}), isNull);
    });

    test('returns null when the claimed family rejects a field type', () {
      expect(
        parseClientForgeFacts(const {
          'forge': 'github',
          'isMergeQueueEnabled': null,
        }),
        isNull,
      );
      expect(
        parseClientForgeFacts(const {'forge': 'github', 'mergeStateStatus': 7}),
        isNull,
      );
      expect(
        parseClientForgeFacts(const {
          'forge': 'gitlab',
          'approvalsRequired': 'two',
        }),
        isNull,
      );
      expect(
        parseClientForgeFacts(const {'forge': 'gitea', 'mergeable': 'yes'}),
        isNull,
      );
    });

    test('never lets one family claim another family payload', () {
      expect(parseGithubForgeFacts(const {'forge': 'gitlab'}), isNull);
      expect(parseGitlabForgeFacts(const {'forge': 'gitea'}), isNull);
      expect(parseGiteaForgeFacts(const {'forge': 'github'}), isNull);
    });
  });

  group('registry facts wiring', () {
    test('routes merge-capability derivation to the owning forge', () {
      final github = getClientForgeLogicModule('github')!.facts!;
      final capability = github.deriveMergeCapability(const {
        'forge': 'github',
        'mergeStateStatus': 'CLEAN',
        'repository': {'squashMergeAllowed': true},
      });

      expect(capability, isNotNull);
      expect(capability!.directMergeReady, isTrue);
      expect(capability.allowedMethods, ['squash']);
      // A foreign payload is declined rather than coerced.
      expect(github.deriveMergeCapability(const {'forge': 'gitlab'}), isNull);
    });

    test('gitea is the only forge contributing a native fallback check', () {
      final gitea = getClientForgeLogicModule('gitea')!.facts!;
      final checks = gitea.nativeFallbackChecks(
        prStatus(
          forgeSpecific: const {'forge': 'gitea', 'ciStatus': 'warning'},
        ),
        'gitea',
      );

      expect(checks, hasLength(1));
      expect(checks.single.name, 'CI');
      // `warning` is terminal for Gitea, so it maps to failure, not pending.
      expect(checks.single.status, ForgeCheckStatus.failure);

      expect(
        getClientForgeLogicModule(
          'github',
        )!.facts!.nativeFallbackChecks(prStatus(forge: 'github'), 'github'),
        isEmpty,
      );
      expect(
        getClientForgeLogicModule(
          'gitlab',
        )!.facts!.nativeFallbackChecks(prStatus(forge: 'gitlab'), 'gitlab'),
        isEmpty,
      );
    });

    test('gitea contributes nothing when the status carries no CI string', () {
      final gitea = getClientForgeLogicModule('gitea')!.facts!;
      expect(gitea.nativeFallbackChecks(prStatus(), 'gitea'), isEmpty);
      expect(
        gitea.nativeFallbackChecks(
          prStatus(forgeSpecific: const {'forge': 'gitea'}),
          'gitea',
        ),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // utils/server-info-capabilities.ts
  // -------------------------------------------------------------------------
  group('server-info-capabilities', () {
    const bothVoiceStates = <String, Object?>{
      'voice': {
        'dictation': {'enabled': true, 'reason': 'Dictation is warming up.'},
        'voice': {
          'enabled': false,
          'reason': 'Voice is disabled in daemon config.',
        },
      },
    };

    test(
      'returns null capabilities when server_info does not include capability metadata',
      () {
        expect(getServerCapabilities(serverInfo: serverInfo()), isNull);
      },
    );

    test('returns null capabilities when there is no server_info at all', () {
      expect(getServerCapabilities(serverInfo: null), isNull);
      expect(
        getVoiceReadinessState(
          serverInfo: null,
          mode: VoiceReadinessMode.dictation,
        ),
        isNull,
      );
      expect(
        resolveVoiceUnavailableMessage(
          serverInfo: null,
          mode: VoiceReadinessMode.voice,
        ),
        isNull,
      );
    });

    test('returns the matching voice capability state by mode', () {
      final info = serverInfo(capabilities: bothVoiceStates);

      expect(
        getVoiceReadinessState(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        const ServerCapabilityState(
          enabled: true,
          reason: 'Dictation is warming up.',
        ),
      );
      expect(
        getVoiceReadinessState(
          serverInfo: info,
          mode: VoiceReadinessMode.voice,
        ),
        const ServerCapabilityState(
          enabled: false,
          reason: 'Voice is disabled in daemon config.',
        ),
      );
    });

    test('returns null when capability is enabled and has no reason', () {
      final info = serverInfo(
        capabilities: const {
          'voice': {
            'dictation': {'enabled': true, 'reason': ''},
            'voice': {'enabled': true, 'reason': ''},
          },
        },
      );

      expect(
        resolveVoiceUnavailableMessage(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        isNull,
      );
    });

    test('returns capability reason when present', () {
      final info = serverInfo(
        capabilities: const {
          'voice': {
            'dictation': {
              'enabled': true,
              'reason': 'Dictation models are still downloading.',
            },
            'voice': {'enabled': true, 'reason': ''},
          },
        },
      );

      expect(
        resolveVoiceUnavailableMessage(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        'Dictation models are still downloading.',
      );
    });

    test('returns null when capability reason is blank', () {
      final info = serverInfo(
        capabilities: const {
          'voice': {
            'dictation': {'enabled': false, 'reason': '   '},
            'voice': {'enabled': true, 'reason': ''},
          },
        },
      );

      expect(
        resolveVoiceUnavailableMessage(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        isNull,
      );
    });

    test('trims the surfaced reason', () {
      final info = serverInfo(
        capabilities: const {
          'voice': {
            'dictation': {'enabled': false, 'reason': '  No microphone.\n'},
            'voice': {'enabled': true, 'reason': ''},
          },
        },
      );

      expect(
        resolveVoiceUnavailableMessage(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        'No microphone.',
      );
    });

    test('passes unknown capability groups through and reports no voice', () {
      final info = serverInfo(
        capabilities: const {
          'browser': {'enabled': true},
        },
      );
      final capabilities = getServerCapabilities(serverInfo: info);

      expect(capabilities, isNotNull);
      expect(capabilities!.voice, isNull);
      expect(capabilities.extras, {
        'browser': {'enabled': true},
      });
      expect(
        getVoiceReadinessState(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        isNull,
      );
    });

    test('excludes the voice group from the passthrough extras', () {
      final info = serverInfo(
        capabilities: {...bothVoiceStates, 'browser': true},
      );
      expect(getServerCapabilities(serverInfo: info)!.extras, {
        'browser': true,
      });
    });

    test('collapses the whole block when the voice group is malformed', () {
      // Upstream validates capabilities as one unit, so a bad `voice` makes the
      // entire block `undefined` rather than yielding a half-parsed result.
      for (final malformed in <Object?>[
        null,
        'yes',
        <String, Object?>{},
        {
          'dictation': {'enabled': true, 'reason': 'ok'},
        },
        {
          'dictation': {'enabled': 'true', 'reason': 'ok'},
          'voice': {'enabled': true, 'reason': ''},
        },
        {
          'dictation': {'enabled': true},
          'voice': {'enabled': true, 'reason': ''},
        },
        {
          'dictation': {'enabled': true, 'reason': null},
          'voice': {'enabled': true, 'reason': ''},
        },
      ]) {
        final info = serverInfo(
          capabilities: {'voice': malformed, 'browser': true},
        );
        expect(
          getServerCapabilities(serverInfo: info),
          isNull,
          reason: '$malformed',
        );
        expect(
          getVoiceReadinessState(
            serverInfo: info,
            mode: VoiceReadinessMode.voice,
          ),
          isNull,
          reason: '$malformed',
        );
      }
    });

    test('ignores unknown keys inside a capability state', () {
      final info = serverInfo(
        capabilities: const {
          'voice': {
            'dictation': {'enabled': true, 'reason': 'ok', 'extra': 1},
            'voice': {'enabled': true, 'reason': ''},
          },
        },
      );

      expect(
        getVoiceReadinessState(
          serverInfo: info,
          mode: VoiceReadinessMode.dictation,
        ),
        const ServerCapabilityState(enabled: true, reason: 'ok'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // utils/agent-working-directory-suggestions.ts
  // -------------------------------------------------------------------------
  group('collectAgentWorkingDirectorySuggestions', () {
    test('deduplicates by cwd and sorts by most recent timestamp', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '/Users/me/project-alpha',
          createdAt: DateTime.utc(2026, 2, 10, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: '/Users/me/project-beta',
          createdAt: DateTime.utc(2026, 2, 11, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: '/Users/me/project-alpha',
          lastActivityAt: DateTime.utc(2026, 2, 12, 10),
        ),
      ]);

      expect(results, ['/Users/me/project-alpha', '/Users/me/project-beta']);
    });

    test('excludes Paseo-owned worktree paths', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '/Users/me/repo/.paseo/worktrees/feature-a',
          createdAt: DateTime.utc(2026, 2, 12, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: '/Users/me/repo',
          createdAt: DateTime.utc(2026, 2, 10, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: r'C:\Users\me\repo\.paseo\worktrees\feature-b',
          createdAt: DateTime.utc(2026, 2, 11, 10),
        ),
      ]);

      expect(results, ['/Users/me/repo']);
    });

    test('ignores empty cwd values', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '   ',
          createdAt: DateTime.utc(2026, 2, 10, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: null,
          createdAt: DateTime.utc(2026, 2, 11, 10),
        ),
        AgentWorkingDirectorySource(
          lastActivityAt: DateTime.utc(2026, 2, 12, 10),
        ),
        AgentWorkingDirectorySource(
          cwd: '/Users/me/project',
          createdAt: DateTime.utc(2026, 2, 9, 10),
        ),
      ]);

      expect(results, ['/Users/me/project']);
    });

    test('returns an empty list for no sources', () {
      expect(collectAgentWorkingDirectorySuggestions(const []), isEmpty);
    });

    test('prefers lastActivityAt over createdAt on the same source', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '/a',
          createdAt: DateTime.utc(2026, 3, 1),
          lastActivityAt: DateTime.utc(2026, 1, 1),
        ),
        AgentWorkingDirectorySource(
          cwd: '/b',
          createdAt: DateTime.utc(2026, 2, 1),
        ),
      ]);

      expect(results, ['/b', '/a']);
    });

    test(
      'keeps the newest timestamp seen for a repeated path, not the last',
      () {
        final results = collectAgentWorkingDirectorySuggestions([
          AgentWorkingDirectorySource(
            cwd: '/repo',
            lastActivityAt: DateTime.utc(2026, 5, 1),
          ),
          AgentWorkingDirectorySource(
            cwd: '/repo',
            lastActivityAt: DateTime.utc(2026, 1, 1),
          ),
          AgentWorkingDirectorySource(
            cwd: '/other',
            lastActivityAt: DateTime.utc(2026, 3, 1),
          ),
        ]);

        expect(results, ['/repo', '/other']);
      },
    );

    test('sorts a source with no timestamps last, as epoch zero', () {
      final results = collectAgentWorkingDirectorySuggestions([
        const AgentWorkingDirectorySource(cwd: '/undated'),
        AgentWorkingDirectorySource(
          cwd: '/dated',
          createdAt: DateTime.utc(1971),
        ),
      ]);

      expect(results, ['/dated', '/undated']);
    });

    test('trims the cwd and uses the trimmed value as identity and output', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '  /Users/me/repo  ',
          createdAt: DateTime.utc(2026),
        ),
        AgentWorkingDirectorySource(
          cwd: '/Users/me/repo',
          createdAt: DateTime.utc(2026, 6),
        ),
      ]);

      expect(results, ['/Users/me/repo']);
    });

    test('breaks timestamp ties by path', () {
      final tied = DateTime.utc(2026, 4, 1);
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(cwd: '/zulu', createdAt: tied),
        AgentWorkingDirectorySource(cwd: '/alpha', createdAt: tied),
        AgentWorkingDirectorySource(cwd: '/mike', createdAt: tied),
      ]);

      expect(results, ['/alpha', '/mike', '/zulu']);
    });

    test(
      'DEVIATION: ties use code-unit order, not localeCompare collation',
      () {
        // Upstream breaks ties with `localeCompare`, which under ICU orders
        // lowercase before uppercase ("/a" then "/A"). Dart's `compareTo` is
        // UTF-16 code-unit order, so uppercase wins. Verified against Node.
        // Dart core has no locale-aware comparator; pinned so the divergence is
        // deliberate rather than accidental.
        final tied = DateTime.utc(2026, 4, 1);
        final results = collectAgentWorkingDirectorySuggestions([
          AgentWorkingDirectorySource(cwd: '/a', createdAt: tied),
          AgentWorkingDirectorySource(cwd: '/A', createdAt: tied),
        ]);

        expect(results, ['/A', '/a']);
      },
    );

    test('excludes a worktree path at the very start of the cwd', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '.paseo/worktrees/feature',
          createdAt: DateTime.utc(2026),
        ),
        AgentWorkingDirectorySource(
          cwd: '/repo/.paseo/worktrees',
          createdAt: DateTime.utc(2026),
        ),
      ]);

      expect(results, isEmpty);
    });

    test('keeps paths that only resemble a managed worktree', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: '/repo/my.paseo/worktrees-old',
          createdAt: DateTime.utc(2026, 1, 3),
        ),
        AgentWorkingDirectorySource(
          cwd: '/repo/.paseo/worktreesX',
          createdAt: DateTime.utc(2026, 1, 2),
        ),
        AgentWorkingDirectorySource(
          cwd: '/repo/.paseo/config',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]);

      expect(results, [
        '/repo/my.paseo/worktrees-old',
        '/repo/.paseo/worktreesX',
        '/repo/.paseo/config',
      ]);
    });

    test('excludes a mixed-separator worktree path', () {
      final results = collectAgentWorkingDirectorySuggestions([
        AgentWorkingDirectorySource(
          cwd: r'C:\Users\me\repo/.paseo\worktrees/feature',
          createdAt: DateTime.utc(2026),
        ),
      ]);

      expect(results, isEmpty);
    });
  });
}
