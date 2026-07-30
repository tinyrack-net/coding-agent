import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/checkout_link_selection.dart';
import 'package:flutter_test/flutter_test.dart';

const target = CheckoutLinkTarget(serverId: 'host-a', cwd: '/repo');

ForgeSearchItem pr(
  int number, {
  String owner = 'acme',
  String repository = 'app',
  String forge = 'github',
}) => ForgeSearchItem(
  kind: ForgeSearchKind.changeRequest,
  forge: forge,
  number: number,
  title: 'PR $number',
  url: 'https://github.com/$owner/$repository/pull/$number',
  state: 'open',
  body: null,
  labels: const [],
  baseRefName: 'main',
  headRefName: 'feature-$number',
);

void main() {
  test(
    'extracts canonical GitHub PR URLs and deduplicates suffix variants',
    () {
      final refs = extractGithubPullRequestRefs(
        'See [PR](https://github.com/Acme/App/pull/42/files) and '
        'https://github.com/acme/app/pull/42?diff=split',
      );

      expect(refs, hasLength(1));
      expect(refs.single.owner, 'Acme');
      expect(refs.single.repository, 'App');
      expect(refs.single.number, 42);
      expect(refs.single.url, 'https://github.com/Acme/App/pull/42');
    },
  );

  test('ignores issues, GitLab MRs, invalid numbers, and non-http URLs', () {
    expect(
      extractGithubPullRequestRefs(
        'https://github.com/acme/app/issues/42 '
        'https://gitlab.com/acme/app/-/merge_requests/42 '
        'https://github.com/acme/app/pull/0 '
        'https://github.com/acme/app/pull/42abc '
        'git@github.com:acme/app/pull/42',
      ),
      isEmpty,
    );
  });

  test(
    'newly completed typed URL has paste semantics but plain edits do not',
    () {
      final lifecycle = CheckoutLinkSelectionLifecycle();
      expect(
        lifecycle.observe(
          text: 'https://github.com/acme/app/pull/',
          target: target,
        ),
        isEmpty,
      );
      final lookup = lifecycle.observe(
        text: 'https://github.com/acme/app/pull/42',
        target: target,
      );
      expect(lookup, hasLength(1));
      expect(
        lifecycle.observe(
          text: 'Review https://github.com/acme/app/pull/42 please',
          target: target,
        ),
        isEmpty,
      );
      expect(lifecycle.apply(lookup.single, pr(42)), isTrue);
    },
  );

  test('first matching PR wins when one edit contains multiple links', () {
    final lifecycle = CheckoutLinkSelectionLifecycle();
    final lookups = lifecycle.observe(
      text:
          'https://github.com/acme/app/pull/42 '
          'https://github.com/acme/app/pull/43',
      target: target,
    );

    expect(lifecycle.apply(lookups.first, pr(42)), isTrue);
    expect(lifecycle.apply(lookups.last, pr(43)), isFalse);
    expect(
      (lifecycle.selection as ChangeRequestCheckoutLinkSelection).item.number,
      42,
    );
  });

  test('explicit branch selection beats a pending lookup', () {
    final lifecycle = CheckoutLinkSelectionLifecycle();
    final lookup = lifecycle
        .observe(text: 'https://github.com/acme/app/pull/42', target: target)
        .single;

    lifecycle.selectBranch('main');

    expect(lifecycle.apply(lookup, pr(42)), isFalse);
    expect((lifecycle.selection as BranchCheckoutLinkSelection).name, 'main');
  });

  test('removed links and target changes reject stale lookup results', () {
    final lifecycle = CheckoutLinkSelectionLifecycle();
    final removed = lifecycle
        .observe(text: 'https://github.com/acme/app/pull/42', target: target)
        .single;
    lifecycle.observe(text: 'removed', target: target);
    expect(lifecycle.apply(removed, pr(42)), isFalse);

    final next = lifecycle
        .observe(text: 'https://github.com/acme/app/pull/42', target: target)
        .single;
    lifecycle.changeTarget(
      const CheckoutLinkTarget(serverId: 'host-b', cwd: '/other'),
      text: 'https://github.com/acme/app/pull/42',
    );
    expect(lifecycle.apply(next, pr(42)), isFalse);
    expect(lifecycle.selection, isNull);
  });

  test(
    'requires the searched item to match kind, forge, and repository URL',
    () {
      final lifecycle = CheckoutLinkSelectionLifecycle();
      CheckoutLinkLookup lookup() => lifecycle
          .observe(text: 'https://github.com/acme/app/pull/42', target: target)
          .single;

      var pending = lookup();
      expect(lifecycle.apply(pending, pr(42, repository: 'other')), isFalse);
      lifecycle.observe(text: '', target: target);
      pending = lookup();
      expect(lifecycle.apply(pending, pr(42, forge: 'gitlab')), isFalse);
    },
  );

  test(
    'builds generalized checkout source with GitHub compatibility fields',
    () {
      final item = pr(42);
      expect(checkoutSourceForChangeRequest(item), {
        'kind': 'change_request',
        'forge': 'github',
        'number': 42,
      });
    },
  );
}
