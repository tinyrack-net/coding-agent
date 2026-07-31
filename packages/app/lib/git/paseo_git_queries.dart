/// Port of Paseo 0.2.0's four frozen git *query* modules. They live together
/// because each one is the pure half of a TanStack Query hook: the cache key it
/// addresses, the gate that decides whether a fetch may run at all, and the
/// transform that turns a wire payload into something the UI can switch on.
///
/// - `git/query-keys.ts` — the checkout-scoped cache key namespace, plus the
///   matchers that decide which cached keys a "this checkout changed" or "this
///   daemon changed" event must invalidate.
/// - `git/use-commits-query.ts` — how a commits fetch's four inputs (consumer
///   gate, daemon capability, connectivity, cached data) collapse into one
///   load-state union, so no downstream widget re-derives it.
/// - `git/use-diff-files.ts` — how a commit's file list and its per-file diff
///   fetches merge into a single diff view, including the binary-file fallback
///   that keeps a file visible when the daemon has no textual diff for it.
/// - `git/use-forge-search-query.ts` — the forge-search cache key, the choice
///   between the modern `forge.search.*` RPC and the legacy GitHub one, and the
///   forward-compatible normalization of either response.
///
/// ## What is *not* ported
///
/// The React/TanStack plumbing itself — `useQuery`, `useQueries`,
/// `useMemo`, the Zustand/session-store selectors, and
/// `QueryClient.invalidateQueries` — has no Dart analogue here and no behavior
/// worth reproducing. Wherever upstream hands TanStack a value (a key, an
/// `enabled` flag, a stale time, a `dataShape`, a `queryFn`), that value is
/// ported as data or as an injectable function; wherever upstream hands
/// TanStack *control*, the port stops. In particular:
///
///  - `invalidateCheckoutGitQueriesForClient/ForServer` and
///    `invalidatePrPaneTimelineForCheckout` are async only because
///    `invalidateQueries` is; their entire content is a *set of matchers*, so
///    they are ported as [checkoutGitInvalidationMatchersForClient] and friends
///    plus [selectInvalidatedCheckoutQueryKeys], which answers the same
///    question the upstream tests ask ("which cached keys got invalidated?").
///  - `useCheckoutCommitsQuery`, `useCommitDiffFiles` and `useForgeSearchQuery`
///    are hook shells; their bodies are ported as the pure functions they
///    delegate to.
///  - Retry policy is deliberately absent: none of these four modules sets one.
///    The upstream `QueryClient` (`data/query-client.ts`) leaves TanStack's
///    default in place, so there is nothing module-local to port.
///
/// Forge auth-state parsing (`parseForgeAuthState`, [ForgeAuthState]) is reused
/// from `core/forge.dart`; the wire item, commit, diff and search types are
/// reused from `package:agent_protocol`. The runtime counterpart that actually
/// performs these fetches lives in `state/checkout_commits_provider.dart`.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../core/forge.dart';

// ---------------------------------------------------------------------------
// Shared: the fetch-query policy fields these modules hand to TanStack
// ---------------------------------------------------------------------------

/// Upstream `data/query.ts`'s `dataShape: "list" | "value"` discriminator.
///
/// It is pure policy data, not behavior: `list` additionally installs
/// `placeholderData: keepPreviousData`, which is what makes a re-keyed list
/// query surface the *previous* checkout's rows as placeholder data — the exact
/// condition [resolveCheckoutCommitsQueryResult] reads as `isPlaceholderData`.
/// `data/query.ts` itself is outside this cluster, so only the discriminator is
/// declared here.
enum FetchQueryDataShape { list, value }

// ---------------------------------------------------------------------------
// query-keys.ts
// ---------------------------------------------------------------------------

/// A TanStack query key: a heterogeneous, order-significant tuple.
///
/// Upstream's `readonly unknown[]` becomes `List<Object?>`. Keys are compared
/// structurally (see [matchesCheckoutQueryMatcher]), never by identity, so
/// rebuilding a key with the same arguments always addresses the same cache
/// entry.
typedef CheckoutQueryKey = List<Object?>;

/// A commit's file diff is immutable for a given sha+path, so every consumer
/// can share the same long-lived cache policy.
const int commitFileDiffStaleTimeMs = 5 * 60000;

/// Key for a checkout's git status.
CheckoutQueryKey checkoutStatusQueryKey(String serverId, String cwd) => [
  'checkoutStatus',
  serverId,
  cwd,
];

/// Key for a checkout's diff.
///
/// [mode] reuses the protocol's [CheckoutDiffMode]; its `name` values
/// (`uncommitted`, `base`) are byte-identical to upstream's string union, so
/// the key shape is unchanged.
///
/// A null [baseRef] collapses to the empty string and a null
/// [ignoreWhitespace] to `false`, so callers that omit either land on the same
/// cache entry as callers that pass the default — upstream's `?? ""` and
/// `=== true` respectively.
CheckoutQueryKey checkoutDiffQueryKey(
  String serverId,
  String cwd,
  CheckoutDiffMode mode, [
  String? baseRef,
  bool? ignoreWhitespace,
]) => [
  'checkoutDiff',
  serverId,
  cwd,
  mode.name,
  baseRef ?? '',
  ignoreWhitespace == true,
];

/// Key for a checkout's change-request status.
CheckoutQueryKey checkoutPrStatusQueryKey(String serverId, String cwd) => [
  'checkoutPrStatus',
  serverId,
  cwd,
];

/// Key for a checkout's commits-ahead-of-base list.
CheckoutQueryKey checkoutCommitsQueryKey(String serverId, String cwd) => [
  'checkoutCommits',
  serverId,
  cwd,
];

/// Key for one file's diff within one commit. Immutable for a given sha+path;
/// see [commitFileDiffStaleTimeMs].
CheckoutQueryKey checkoutCommitFileDiffQueryKey(
  String serverId,
  String cwd,
  String sha,
  String path,
) => ['checkoutCommitFileDiff', serverId, cwd, sha, path];

/// Kind tag of the PR pane's timeline query.
///
/// This and [prPanePipelineQueryKind] come from
/// `git/pull-request-panel/query-keys.ts`, which is outside this cluster but is
/// imported by `git/query-keys.ts`: the checkout-wide invalidation sweeps have
/// to name them. Only the two kinds and their key builders are ported.
const String prPaneTimelineQueryKind = 'prPaneTimeline';

/// Key for the PR pane's timeline. [prNumber] is nullable because the pane
/// mounts before a change request is known.
CheckoutQueryKey prPaneTimelineQueryKey({
  required String serverId,
  required String cwd,
  required int? prNumber,
}) => [prPaneTimelineQueryKind, serverId, cwd, prNumber];

/// Kind tag of the PR pane's pipeline query. See [prPaneTimelineQueryKind].
const String prPanePipelineQueryKind = 'prPanePipeline';

/// Key for the PR pane's pipeline detail.
///
/// [changeRequestNumber] is part of the key because the fetch routes by it: the
/// same pipeline id reached through a different MR is a different request.
CheckoutQueryKey prPanePipelineQueryKey({
  required String serverId,
  required String cwd,
  required int? pipelineId,
  required int changeRequestNumber,
}) => [prPanePipelineQueryKind, serverId, cwd, pipelineId, changeRequestNumber];

/// One rule for "does this cached key need invalidating?".
///
/// Upstream expresses invalidation two ways — `invalidateQueries({queryKey})`
/// and `invalidateQueries({predicate})` — and the two do *not* match the same
/// things, so both are reified rather than collapsed into one.
sealed class CheckoutQueryMatcher {
  const CheckoutQueryMatcher();
}

/// Upstream's `invalidateQueries({ queryKey })`.
///
/// TanStack's default is a *partial* match: the filter key must be a prefix of
/// the cached key, element by element. Reproduced rather than tightened to
/// equality, because that is what actually decides whether a longer key that
/// happens to share the prefix gets swept up.
final class CheckoutQueryKeyPrefixMatcher extends CheckoutQueryMatcher {
  const CheckoutQueryKeyPrefixMatcher(this.prefix);

  final CheckoutQueryKey prefix;
}

/// Upstream's `checkoutQueryPredicate(kind, scope)`.
///
/// Matches on the key's first three elements only, so it reaches keys of any
/// length — which is the point: the PR-pane keys carry a fourth and fifth
/// element that the sweep must ignore. A null [cwd] widens the scope to every
/// checkout on the daemon (upstream's optional `CheckoutQueryScope.cwd`).
final class CheckoutQueryKindMatcher extends CheckoutQueryMatcher {
  const CheckoutQueryKindMatcher({
    required this.queryKind,
    required this.serverId,
    this.cwd,
  });

  final Object? queryKind;
  final String serverId;
  final String? cwd;
}

/// Upstream's `isCheckoutQueryKey` guard: a key is checkout-scoped only if it
/// has at least three elements and the first three are all strings.
///
/// The guard is what keeps the sweep from mistaking an unrelated key (a short
/// one, or one whose cwd slot holds a number) for a checkout query.
bool isCheckoutQueryKey(CheckoutQueryKey key) =>
    key.length >= 3 && key[0] is String && key[1] is String && key[2] is String;

/// Whether [matcher] selects [queryKey].
bool matchesCheckoutQueryMatcher(
  CheckoutQueryMatcher matcher,
  CheckoutQueryKey queryKey,
) => switch (matcher) {
  CheckoutQueryKeyPrefixMatcher(:final prefix) =>
    queryKey.length >= prefix.length &&
        Iterable<int>.generate(
          prefix.length,
        ).every((index) => _queryKeyPartsEqual(queryKey[index], prefix[index])),
  CheckoutQueryKindMatcher(:final queryKind, :final serverId, :final cwd) =>
    isCheckoutQueryKey(queryKey) &&
        queryKey[0] == queryKind &&
        queryKey[1] == serverId &&
        (cwd == null || queryKey[2] == cwd),
};

/// Whether any of [matchers] selects [queryKey].
bool matchesAnyCheckoutQueryMatcher(
  List<CheckoutQueryMatcher> matchers,
  CheckoutQueryKey queryKey,
) => matchers.any((matcher) => matchesCheckoutQueryMatcher(matcher, queryKey));

/// The cached keys an invalidation described by [matchers] would touch,
/// in the order they were cached.
///
/// This is the observable content of upstream's `invalidateQueries` calls: the
/// upstream tests seed a `QueryClient`, invalidate, then read `isInvalidated`
/// off each key. Returning the selected keys answers the same question without
/// a cache implementation, and preserves input order because the caller's
/// iteration order is the only ordering upstream has.
List<CheckoutQueryKey> selectInvalidatedCheckoutQueryKeys({
  required Iterable<CheckoutQueryKey> cachedQueryKeys,
  required List<CheckoutQueryMatcher> matchers,
}) => cachedQueryKeys
    .where((key) => matchesAnyCheckoutQueryMatcher(matchers, key))
    .toList(growable: false);

/// Everything one checkout's git state can invalidate.
///
/// `checkoutStatus` and `checkoutCommits` are invalidated by *key* upstream and
/// the rest by *predicate*, because the latter carry extra key elements (diff
/// mode/baseRef, PR number, pipeline id) that must all be swept regardless of
/// value. That asymmetry is preserved here rather than normalized away.
List<CheckoutQueryMatcher> checkoutGitInvalidationMatchersForClient({
  required String serverId,
  required String cwd,
}) => [
  CheckoutQueryKeyPrefixMatcher(checkoutStatusQueryKey(serverId, cwd)),
  CheckoutQueryKindMatcher(
    queryKind: 'checkoutDiff',
    serverId: serverId,
    cwd: cwd,
  ),
  CheckoutQueryKindMatcher(
    queryKind: 'checkoutPrStatus',
    serverId: serverId,
    cwd: cwd,
  ),
  CheckoutQueryKeyPrefixMatcher(checkoutCommitsQueryKey(serverId, cwd)),
  CheckoutQueryKindMatcher(
    queryKind: prPaneTimelineQueryKind,
    serverId: serverId,
    cwd: cwd,
  ),
  CheckoutQueryKindMatcher(
    queryKind: prPanePipelineQueryKind,
    serverId: serverId,
    cwd: cwd,
  ),
];

/// Everything a whole daemon's git state can invalidate, across every checkout.
///
/// `checkoutDiff` is excluded: diff queries are subscription-fed
/// (`queryFn: skipToken`) and receive a fresh snapshot on every resubscribe, so
/// invalidation cannot and need not refetch them.
List<CheckoutQueryMatcher> checkoutGitInvalidationMatchersForServer(
  String serverId,
) => [
  for (final kind in const [
    'checkoutStatus',
    'checkoutPrStatus',
    'checkoutCommits',
    prPaneTimelineQueryKind,
    prPanePipelineQueryKind,
  ])
    CheckoutQueryKindMatcher(queryKind: kind, serverId: serverId),
];

/// The narrower sweep used when only the PR pane's own data went stale — a
/// timeline comment landed, say — so the surrounding status/diff/commits
/// queries are left alone.
List<CheckoutQueryMatcher> prPaneTimelineInvalidationMatchersForCheckout({
  required String serverId,
  required String cwd,
}) => [
  CheckoutQueryKindMatcher(
    queryKind: prPaneTimelineQueryKind,
    serverId: serverId,
    cwd: cwd,
  ),
  CheckoutQueryKindMatcher(
    queryKind: prPanePipelineQueryKind,
    serverId: serverId,
    cwd: cwd,
  ),
];

/// Structural equality for one key element.
///
/// TanStack compares keys with a deep equality that recurses into arrays and
/// plain objects. Key elements here are scalars, but the recursion is kept so a
/// future composite element does not silently start comparing by identity.
bool _queryKeyPartsEqual(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_queryKeyPartsEqual(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) return false;
      if (!_queryKeyPartsEqual(entry.value, right[entry.key])) return false;
    }
    return true;
  }
  return left == right;
}

// ---------------------------------------------------------------------------
// use-commits-query.ts
// ---------------------------------------------------------------------------

/// Commits ahead of base change rarely while the section is open; this keeps a
/// collapse/re-expand cycle warm without leaving the fetch result stale for
/// long.
///
/// Private upstream (`CHECKOUT_COMMITS_STALE_TIME`); exported here because the
/// hook that would otherwise carry it into `useFetchQuery` is not ported, so
/// this constant is the only remaining witness to the policy.
const int checkoutCommitsStaleTimeMs = 30000;

/// A commit whose base classification the daemon actually supplied.
///
/// Upstream narrows the optional wire field by interface extension
/// (`ClassifiedCheckoutCommit extends CheckoutCommit { isOnBase: boolean }`).
/// The protocol's [CheckoutCommit] is a `final class`, so it cannot be
/// extended; composition carries the same guarantee — reaching
/// [ClassifiedCheckoutCommit] at all proves the classification was present.
final class ClassifiedCheckoutCommit {
  const ClassifiedCheckoutCommit({
    required this.commit,
    required this.isOnBase,
  });

  final CheckoutCommit commit;

  /// Whether this commit is already contained in the base branch.
  final bool isOnBase;

  /// Convenience passthroughs for the fields call sites read most, so the
  /// composition does not make every reader spell out `.commit.`.
  String get sha => commit.sha;

  List<CheckoutCommitFile> get files => commit.files;
}

/// A checkout's commits-ahead-of-base list, with the base it was measured
/// against.
final class CheckoutCommitsData {
  const CheckoutCommitsData({required this.baseRef, required this.commits});

  /// Null when the daemon could not determine a base branch; distinct from an
  /// empty commit list, which means "a base exists and you are level with it".
  final String? baseRef;

  final List<ClassifiedCheckoutCommit> commits;
}

/// The single load-state union downstream widgets read.
///
/// Upstream's discriminated union becomes a sealed hierarchy so an exhaustive
/// `switch` is checked by the compiler. Capability detection happens once, in
/// [resolveCheckoutCommitsQueryResult], precisely so nothing downstream has to
/// re-test it.
sealed class CheckoutCommitsQueryResult {
  const CheckoutCommitsQueryResult();
}

/// The daemon is too old to list commits; there is nothing to wait for and the
/// section should not render at all.
final class CheckoutCommitsUnsupported extends CheckoutCommitsQueryResult {
  const CheckoutCommitsUnsupported();
}

/// The consumer has not asked for commits yet (a collapsed section), and
/// nothing is cached.
final class CheckoutCommitsIdle extends CheckoutCommitsQueryResult {
  const CheckoutCommitsIdle();
}

/// Wanted, but the host is unreachable or the checkout is unknown, so no
/// request has even been attempted.
final class CheckoutCommitsConnecting extends CheckoutCommitsQueryResult {
  const CheckoutCommitsConnecting();
}

/// A request is in flight with nothing trustworthy to show yet.
final class CheckoutCommitsLoading extends CheckoutCommitsQueryResult {
  const CheckoutCommitsLoading();
}

/// The cold load failed.
final class CheckoutCommitsError extends CheckoutCommitsQueryResult {
  const CheckoutCommitsError(this.error);

  /// Upstream types this `Error`; Dart's throwables are unconstrained, so the
  /// widest type is used rather than pretending every failure is an
  /// [Exception].
  final Object error;
}

/// Real data for this checkout — including an empty commit list, which is a
/// legitimate answer and not a loading state.
final class CheckoutCommitsLoaded extends CheckoutCommitsQueryResult {
  const CheckoutCommitsLoaded(this.data);

  final CheckoutCommitsData data;
}

/// Collapses the commits query's four independent inputs into one state.
///
/// The ordering is load-bearing:
///  - capability loses to nothing: an unsupported daemon can never produce
///    data, so no other input can rescue it.
///  - real (non-placeholder) data outranks the consumer's gate, which is what
///    lets a collapsed section keep showing what it already fetched.
///  - the gate outranks connectivity, so a collapsed section on a disconnected
///    host reads `idle` rather than alarming the user with `connecting`.
///  - an error only surfaces once we know a fetch could actually have run.
///
/// Placeholder data (the previous checkout's rows, kept by
/// [FetchQueryDataShape.list]) deliberately does *not* count as loaded: it
/// belongs to a different checkout, so showing it as this one's answer would be
/// a lie.
CheckoutCommitsQueryResult resolveCheckoutCommitsQueryResult({
  required bool enabled,
  required bool capabilityPresent,
  required bool canFetch,
  required CheckoutCommitsData? data,
  required bool isPlaceholderData,
  required Object? error,
}) {
  if (!capabilityPresent) {
    return const CheckoutCommitsUnsupported();
  }
  if (data != null && !isPlaceholderData) {
    return CheckoutCommitsLoaded(data);
  }
  if (!enabled) {
    return const CheckoutCommitsIdle();
  }
  if (!canFetch) {
    return const CheckoutCommitsConnecting();
  }
  if (error != null) {
    return CheckoutCommitsError(error);
  }
  return const CheckoutCommitsLoading();
}

/// Whether the daemon can list commits *and* classify them against the base.
///
/// COMPAT(commitsList): added in v0.1.110, remove after 2027-01-16.
/// COMPAT(commitBaseClassification): added in v0.2.0, remove after 2027-01-23.
///
/// Both flags are required together because a daemon with only the first would
/// return commits that [classifyCheckoutCommits] must then reject. Upstream
/// reads them off the session store with `=== true`, so a missing flag, a null
/// feature map, or a non-boolean value all read as absent.
bool checkoutCommitsCapabilityPresent(Map<String, Object?>? features) =>
    features?['commitsList'] == true &&
    features?['commitBaseClassification'] == true;

/// Whether a commits fetch has everything it needs to leave the client.
///
/// Upstream's `Boolean(cwd) && Boolean(client) && isConnected` — note that an
/// all-whitespace cwd is *truthy* in JavaScript and is therefore accepted here
/// too, deliberately: trimming would change which checkouts fetch.
bool canFetchCheckoutCommits({
  required String cwd,
  required bool hasClient,
  required bool isConnected,
}) => cwd.isNotEmpty && hasClient && isConnected;

/// Whether the query is handed to the fetcher at all: the consumer must want
/// it, the daemon must support it, and the transport must be ready.
bool checkoutCommitsQueryEnabled({
  required bool enabled,
  required bool capabilityPresent,
  required bool canFetch,
}) => enabled && capabilityPresent && canFetch;

/// Turns a `checkout.commits.list` response into the shape the UI reads,
/// asserting that every commit carries its base classification.
///
/// This is upstream's `queryFn` body. The assertion is not defensive
/// programming: [checkoutCommitsCapabilityPresent] has already established that
/// the daemon advertises `commitBaseClassification`, so a missing flag here
/// means the daemon lied, and failing loudly is better than silently rendering
/// every commit as "not on base".
///
/// Upstream uses `tiny-invariant`; the thrown message is preserved verbatim.
/// [StateError] is used rather than [FormatException] because the payload
/// parsed fine — it is the daemon's *contract* that broke.
CheckoutCommitsData classifyCheckoutCommits({
  required String? baseRef,
  required List<CheckoutCommit> commits,
}) => CheckoutCommitsData(
  baseRef: baseRef,
  commits: commits
      .map((commit) {
        final isOnBase = commit.isOnBase;
        if (isOnBase == null) {
          throw StateError('Host omitted commit base classification');
        }
        return ClassifiedCheckoutCommit(commit: commit, isOnBase: isOnBase);
      })
      .toList(growable: false),
);

// ---------------------------------------------------------------------------
// use-diff-files.ts
// ---------------------------------------------------------------------------

/// What the per-file diff fetch has to say about one path.
///
/// Upstream distinguishes three states through a single
/// `ParsedDiffFile | null | undefined` map value, and the two absent forms mean
/// opposite things: `undefined` is "not answered yet", `null` is "answered:
/// there is no textual diff". A Dart `Map<String, CheckoutDiffFile?>` cannot
/// tell those apart (a missing key and a null value both read as null), so the
/// distinction is reified into this hierarchy. This is the one place the port's
/// *shape* differs from upstream; the behavior is identical.
sealed class CommitFileDiffResolution {
  const CommitFileDiffResolution();
}

/// Upstream's `undefined`: the fetch has not answered. The file is withheld
/// from the view entirely rather than flickering in with placeholder counts.
final class PendingCommitFileDiff extends CommitFileDiffResolution {
  const PendingCommitFileDiff();
}

/// Upstream's `null`: the daemon answered but has no textual diff — a binary
/// blob, typically. The file is still shown, reconstructed from commit
/// metadata.
final class UnavailableCommitFileDiff extends CommitFileDiffResolution {
  const UnavailableCommitFileDiff();
}

/// The daemon returned a parsed diff.
final class ResolvedCommitFileDiff extends CommitFileDiffResolution {
  const ResolvedCommitFileDiff(this.file);

  final CheckoutDiffFile file;
}

/// The payload of one `checkout.commits.file_diff` fetch: a diff, or an
/// explicit null meaning "no textual diff exists".
///
/// Declared rather than reusing [CheckoutCommitFileDiffResponse] because
/// upstream's `queryFn` returns only `{ file }`; the response's echoed
/// cwd/sha/path/requestId play no part in this transform.
final class CommitFileDiffPayload {
  const CommitFileDiffPayload(this.file);

  final CheckoutDiffFile? file;
}

/// One per-file diff fetch as the aggregator sees it.
///
/// The slice of TanStack's `UseQueryResult` that
/// [resolveCommitDiffFilesResult] actually reads. A null [data] covers both
/// "not started" and "in flight" — upstream's `fileResult?.data ? … :
/// undefined` treats them identically.
final class CommitFileDiffFetchState {
  const CommitFileDiffFetchState({
    this.data,
    this.error,
    this.isLoading = false,
  });

  final CommitFileDiffPayload? data;
  final Object? error;
  final bool isLoading;
}

/// The merged diff view for one commit.
final class CommitDiffFilesResult {
  const CommitDiffFilesResult({
    required this.files,
    required this.isLoading,
    required this.error,
    required this.capabilityMissing,
  });

  final List<CheckoutDiffFile> files;
  final bool isLoading;
  final Object? error;

  /// True when the daemon cannot list commits at all — a distinct condition
  /// from "failed", and one the UI answers with an explanation rather than a
  /// retry button.
  final bool capabilityMissing;
}

/// The diff to render for one commit file, or null to withhold it.
///
/// A [ResolvedCommitFileDiff] wins outright. [PendingCommitFileDiff] yields
/// null so the file stays out of the shared view until its fetch lands.
/// [UnavailableCommitFileDiff] synthesizes a hunk-less `binary` entry from the
/// commit's own metadata, which is what keeps a binary file visible in the file
/// list with its add/delete counts intact.
CheckoutDiffFile? resolveCommitDiffFile(
  CheckoutCommitFile file,
  CommitFileDiffResolution resolution,
) => switch (resolution) {
  ResolvedCommitFileDiff(:final file) => file,
  PendingCommitFileDiff() => null,
  UnavailableCommitFileDiff() => CheckoutDiffFile(
    path: file.path,
    isNew: file.status == CheckoutCommitFileStatus.added,
    isDeleted: file.status == CheckoutCommitFileStatus.deleted,
    additions: file.additions,
    deletions: file.deletions,
    hunks: const [],
    status: CheckoutDiffFileStatus.binary,
  ),
};

/// The commit's files in commit order, minus the ones still pending.
///
/// A path absent from [resolvedByPath] is treated as pending, matching a JS
/// `Map.get` miss.
List<CheckoutDiffFile> resolveCommitDiffFiles(
  List<CheckoutCommitFile> files,
  Map<String, CommitFileDiffResolution> resolvedByPath,
) => [
  for (final file in files)
    ?resolveCommitDiffFile(
      file,
      resolvedByPath[file.path] ?? const PendingCommitFileDiff(),
    ),
];

/// The files of the commit [sha] within [commitsData], or empty when either is
/// missing.
///
/// An empty [sha] is treated as "no commit selected", matching upstream's
/// `!sha` guard; an unknown sha yields empty rather than throwing, because the
/// commits list can legitimately be a stale snapshot.
List<CheckoutCommitFile> selectCommitFilesForSha(
  CheckoutCommitsData? commitsData,
  String sha,
) {
  if (sha.isEmpty || commitsData == null) {
    return const [];
  }
  for (final commit in commitsData.commits) {
    if (commit.sha == sha) return commit.files;
  }
  return const [];
}

/// Whether the per-file diff fetches may run.
///
/// They are gated on the commits query having *loaded*, not merely on
/// connectivity: without the commit's file list there is nothing to fetch a
/// diff for.
bool commitFileDiffsEnabled({
  required bool enabled,
  required CheckoutCommitsQueryResult commitsQuery,
  required String cwd,
  required String sha,
  required bool hasClient,
  required bool isConnected,
}) =>
    enabled &&
    commitsQuery is CheckoutCommitsLoaded &&
    cwd.isNotEmpty &&
    sha.isNotEmpty &&
    hasClient &&
    isConnected;

/// Merges the commit's file list with its per-file diff fetches.
///
/// [fileDiffResults] is positionally aligned with [commitFiles] — upstream
/// indexes one by the other — and a short list is tolerated the same way an
/// out-of-range JS index is: those files read as pending.
///
/// The commits query's own failure takes precedence over any per-file failure,
/// because a commits-level error explains the empty view while a single file's
/// error does not.
CommitDiffFilesResult resolveCommitDiffFilesResult({
  required List<CheckoutCommitFile> commitFiles,
  required List<CommitFileDiffFetchState> fileDiffResults,
  required CheckoutCommitsQueryResult commitsQuery,
}) {
  final resolvedByPath = <String, CommitFileDiffResolution>{};
  for (var index = 0; index < commitFiles.length; index++) {
    final file = commitFiles[index];
    final fetchState = index < fileDiffResults.length
        ? fileDiffResults[index]
        : null;
    final payload = fetchState?.data;
    resolvedByPath[file.path] = payload == null
        ? const PendingCommitFileDiff()
        : switch (payload.file) {
            final diff? => ResolvedCommitFileDiff(diff),
            _ => const UnavailableCommitFileDiff(),
          };
  }

  Object? firstFileError;
  for (final fetchState in fileDiffResults) {
    if (fetchState.error != null) {
      firstFileError = fetchState.error;
      break;
    }
  }

  final commitsLoading =
      commitsQuery is CheckoutCommitsConnecting ||
      commitsQuery is CheckoutCommitsLoading;

  return CommitDiffFilesResult(
    files: resolveCommitDiffFiles(commitFiles, resolvedByPath),
    isLoading:
        commitsLoading || fileDiffResults.any((result) => result.isLoading),
    error: switch (commitsQuery) {
      CheckoutCommitsError(:final error) => error,
      _ => firstFileError,
    },
    capabilityMissing: commitsQuery is CheckoutCommitsUnsupported,
  );
}

// ---------------------------------------------------------------------------
// use-forge-search-query.ts
// ---------------------------------------------------------------------------

/// Search results are cheap to re-derive but rate-limited upstream at the
/// forge, so a half-minute window absorbs an autocomplete's keystrokes.
const int forgeSearchStaleTimeMs = 30000;

/// The frozen English copy for `workspace.terminal.hostDisconnected`.
///
/// Upstream binds to the i18next singleton at call time; Dart's translator is
/// loaded asynchronously and handed down, so the literal is the fallback when a
/// caller has no translator in hand — the same pattern
/// `defaultWorktreeArchiveWarningLabels` uses in `git/paseo_pr_rules.dart`.
const String defaultForgeSearchHostDisconnectedMessage =
    'Host is not connected';

/// Which RPC family a search goes out on.
///
/// COMPAT(githubSearchRpc): added in v0.1.106, remove after 2026-12-28 once
/// clients use `forge.search.*`. The transport is part of the cache key so a
/// daemon upgrade cannot serve stale legacy-shaped results to the modern path.
enum ForgeSearchTransport { forge, github }

/// The legacy `github_search_request` kind vocabulary.
///
/// COMPAT(githubSearchKind): added in v0.1.106, removed with the legacy RPC.
enum LegacyGitHubSearchKind {
  issue('github-issue'),
  changeRequest('github-pr');

  const LegacyGitHubSearchKind(this.wireName);

  final String wireName;
}

/// Cache key for a forge search.
///
/// The query is trimmed into the key so `"123"`, `" 123"` and `"123  "` share
/// one cache entry. Kinds are sorted so the key is order-insensitive: asking
/// for issues-then-PRs must hit the same entry as PRs-then-issues.
///
/// A null [kinds] and an empty one are *different* keys — upstream's `if
/// (!kinds)` short-circuits on null/undefined only, and an empty JS array is
/// truthy — so `kinds: []` produces a six-element key ending in the empty
/// string.
///
/// Dart's [List.sort] is not stable, so an explicit index tiebreak is added.
/// It cannot change the output here (equal wire names are the same enum value)
/// but keeps the key deterministic if the vocabulary ever grows a pair that
/// compares equal without being identical.
CheckoutQueryKey forgeSearchQueryKey(
  String serverId,
  String cwd,
  String query, [
  List<ForgeSearchKind>? kinds,
  ForgeSearchTransport transport = ForgeSearchTransport.forge,
]) {
  final trimmedQuery = query.trim();
  if (kinds == null) {
    return ['forge-search', serverId, cwd, transport.name, trimmedQuery];
  }
  final indexed = kinds.indexed.toList()
    ..sort((left, right) {
      final byName = left.$2.wireName.compareTo(right.$2.wireName);
      return byName != 0 ? byName : left.$1.compareTo(right.$1);
    });
  return [
    'forge-search',
    serverId,
    cwd,
    transport.name,
    trimmedQuery,
    indexed.map((entry) => entry.$2.wireName).join(','),
  ];
}

/// The options one forge-search RPC is issued with.
///
/// Distinct from the protocol's [ForgeSearchRequest], which is the wire message
/// and carries a `requestId` and a validated 1..50 limit; this is the *call*
/// shape the client interface takes, exactly as upstream's `ForgeSearchOptions`
/// is. Value equality is provided because asserting on the request a fake
/// client received is how this module's behavior is observed.
final class ForgeSearchRequestOptions {
  const ForgeSearchRequestOptions({
    required this.cwd,
    required this.query,
    this.limit,
    this.kinds,
  });

  final String cwd;
  final String query;
  final int? limit;
  final List<ForgeSearchKind>? kinds;

  @override
  bool operator ==(Object other) =>
      other is ForgeSearchRequestOptions &&
      other.cwd == cwd &&
      other.query == query &&
      other.limit == limit &&
      _listsEqual(other.kinds, kinds);

  @override
  int get hashCode =>
      Object.hash(cwd, query, limit, Object.hashAll(kinds ?? const []));

  @override
  String toString() =>
      'ForgeSearchRequestOptions(cwd: $cwd, query: $query, limit: $limit, '
      'kinds: $kinds)';
}

/// The options one legacy `github_search_request` RPC is issued with.
final class LegacyGitHubSearchRequestOptions {
  const LegacyGitHubSearchRequestOptions({
    required this.cwd,
    required this.query,
    this.limit,
    this.kinds,
  });

  final String cwd;
  final String query;
  final int? limit;
  final List<LegacyGitHubSearchKind>? kinds;

  @override
  bool operator ==(Object other) =>
      other is LegacyGitHubSearchRequestOptions &&
      other.cwd == cwd &&
      other.query == query &&
      other.limit == limit &&
      _listsEqual(other.kinds, kinds);

  @override
  int get hashCode =>
      Object.hash(cwd, query, limit, Object.hashAll(kinds ?? const []));

  @override
  String toString() =>
      'LegacyGitHubSearchRequestOptions(cwd: $cwd, query: $query, '
      'limit: $limit, kinds: $kinds)';
}

/// A `forge.search.response` payload as it arrives, before interpretation.
///
/// The protocol's [ForgeSearchResponse] is deliberately *not* reused: it parses
/// every item eagerly and throws on the first one it does not recognize, which
/// would defeat the whole point of this boundary. Upstream models the payload
/// as `items: z.array(z.unknown())` precisely so a newer daemon can add item
/// kinds without breaking older clients, and drops the unrecognized ones one at
/// a time. [authState] is `Object?` for the same reason.
final class ForgeSearchResponsePayload {
  const ForgeSearchResponsePayload({
    required this.items,
    required this.error,
    required this.requestId,
    this.authState,
  });

  final List<Object?> items;
  final Object? authState;
  final String? error;
  final String requestId;
}

/// A legacy `github_search_response` payload as it arrives.
///
/// COMPAT(githubSearchAuthState): added in v0.1.106, remove after 2026-12-28.
/// Both feature booleans are optional and mean the same thing; the newer name
/// wins, and a payload carrying neither is assumed enabled.
final class GitHubSearchResponsePayload {
  const GitHubSearchResponsePayload({
    required this.items,
    required this.error,
    required this.requestId,
    this.featuresEnabled,
    this.authState,
    this.githubFeaturesEnabled,
  });

  final List<Object?> items;
  final bool? featuresEnabled;
  final Object? authState;
  final bool? githubFeaturesEnabled;
  final String? error;
  final String requestId;
}

/// A legacy search call, or null on a client that never had one.
typedef LegacyGitHubSearchCall =
    Future<GitHubSearchResponsePayload> Function(
      LegacyGitHubSearchRequestOptions options, {
      String? requestId,
    });

/// The slice of the daemon client a forge search needs.
///
/// [searchGitHub] is a *nullable getter* rather than a method because upstream
/// declares it as an optional member (`searchGitHub?:`) and branches on its
/// presence: a client without it falls through to [searchForge] even on the
/// github transport. Dart interfaces have no optional members, so the option is
/// carried in the value.
abstract interface class ForgeSearchClient {
  Future<ForgeSearchResponsePayload> searchForge(
    ForgeSearchRequestOptions options, {
    String? requestId,
  });

  LegacyGitHubSearchCall? get searchGitHub;
}

/// A forge search normalized into one shape regardless of which RPC served it.
final class ForgeSearchPayload {
  const ForgeSearchPayload({
    required this.items,
    required this.authState,
    required this.error,
    required this.requestId,
  });

  final List<ForgeSearchItem> items;

  /// Always a state feature code can branch on: an unrecognized wire value is
  /// resolved away here rather than leaked upward.
  final ForgeAuthState authState;

  final String? error;
  final String requestId;
}

/// Everything upstream's `buildForgeSearchQueryOptions` hands TanStack, minus
/// TanStack itself.
///
/// [queryFn] is kept as a callable because it is where the transport choice and
/// both normalizations happen, and because that is what the upstream suite
/// exercises.
final class ForgeSearchQueryOptions {
  const ForgeSearchQueryOptions({
    required this.queryKey,
    required this.queryFn,
    required this.enabled,
    required this.dataShape,
    required this.staleTimeMs,
  });

  final CheckoutQueryKey queryKey;
  final Future<ForgeSearchPayload> Function() queryFn;
  final bool enabled;
  final FetchQueryDataShape dataShape;
  final int staleTimeMs;
}

/// Builds the forge-search query: its key, its gate, its cache policy, and the
/// call that fulfils it.
///
/// The transport is chosen from [supportsForgeSearch] with `== true`, so an
/// *unknown* capability (null) is treated as unsupported and falls back to the
/// legacy RPC — the safe direction, since an old daemon cannot answer the
/// modern one at all.
///
/// The gate also requires a client, because a null client makes [queryFn]
/// throw; disabling the query is how upstream keeps that throw from ever
/// happening under normal operation, while still leaving it as the honest
/// failure mode if something forces a fetch anyway.
ForgeSearchQueryOptions buildForgeSearchQueryOptions({
  required ForgeSearchClient? client,
  required String serverId,
  required String cwd,
  required String query,
  required bool enabled,
  List<ForgeSearchKind>? kinds,
  bool? supportsForgeSearch,
  String? hostDisconnectedMessage,
}) {
  final trimmedQuery = query.trim();
  final transport = supportsForgeSearch == true
      ? ForgeSearchTransport.forge
      : ForgeSearchTransport.github;

  return ForgeSearchQueryOptions(
    queryKey: forgeSearchQueryKey(
      serverId,
      cwd,
      trimmedQuery,
      kinds,
      transport,
    ),
    queryFn: () async {
      if (client == null) {
        throw StateError(
          hostDisconnectedMessage ?? defaultForgeSearchHostDisconnectedMessage,
        );
      }
      final request = ForgeSearchRequestOptions(
        cwd: cwd,
        query: trimmedQuery,
        limit: 20,
        kinds: kinds,
      );
      // COMPAT(githubSearchRpc): added in v0.1.106, remove after 2026-12-28
      // once clients use forge.search.*.
      final legacySearch = client.searchGitHub;
      if (transport == ForgeSearchTransport.github && legacySearch != null) {
        return normalizeLegacyGitHubSearchPayload(
          await legacySearch(toLegacyGitHubSearchRequest(request)),
        );
      }
      return normalizeForgeSearchPayload(await client.searchForge(request));
    },
    enabled: enabled && client != null,
    dataShape: FetchQueryDataShape.list,
    staleTimeMs: forgeSearchStaleTimeMs,
  );
}

/// Interprets a modern search payload, dropping items this client cannot read.
///
/// An unrecognized auth state resolves to `unauthenticated` rather than
/// propagating: the UI's only sane response to "I don't know what this daemon
/// means" is to offer sign-in.
ForgeSearchPayload normalizeForgeSearchPayload(
  ForgeSearchResponsePayload payload,
) => ForgeSearchPayload(
  items: [for (final item in payload.items) ?parseForgeSearchItem(item)],
  authState:
      parseForgeAuthState(payload.authState) ?? ForgeAuthState.unauthenticated,
  error: payload.error,
  requestId: payload.requestId,
);

/// Interprets a legacy GitHub search payload into the same neutral shape.
///
/// The legacy `pr` kind becomes `change_request` so nothing downstream has to
/// know which RPC served the result. Auth state falls back to the legacy
/// feature booleans, which is the only signal a pre-v0.1.106 daemon sends.
ForgeSearchPayload normalizeLegacyGitHubSearchPayload(
  GitHubSearchResponsePayload payload,
) {
  // COMPAT(githubSearchAuthState): added in v0.1.106, remove after 2026-12-28.
  final featuresEnabled =
      payload.featuresEnabled ?? payload.githubFeaturesEnabled ?? true;
  return ForgeSearchPayload(
    items: [
      for (final item in payload.items) ?parseLegacyGitHubSearchItem(item),
    ],
    authState:
        parseForgeAuthState(payload.authState) ??
        (featuresEnabled
            ? ForgeAuthState.authenticated
            : ForgeAuthState.unauthenticated),
    error: payload.error,
    requestId: payload.requestId,
  );
}

/// Rewrites a modern request for the legacy RPC.
///
/// A kind-less request passes through untouched (upstream's `if
/// (!request.kinds)` branch); otherwise every kind is translated. Note that a
/// modern `change_request` becomes `github-pr`, never the neutral name — the
/// old daemon would not recognize it.
LegacyGitHubSearchRequestOptions toLegacyGitHubSearchRequest(
  ForgeSearchRequestOptions request,
) {
  final kinds = request.kinds;
  if (kinds == null) {
    return LegacyGitHubSearchRequestOptions(
      cwd: request.cwd,
      query: request.query,
      limit: request.limit,
    );
  }
  return LegacyGitHubSearchRequestOptions(
    cwd: request.cwd,
    query: request.query,
    limit: request.limit,
    kinds: kinds.map(toLegacyGitHubSearchKind).toList(growable: false),
  );
}

/// The legacy name for a neutral search kind.
LegacyGitHubSearchKind toLegacyGitHubSearchKind(ForgeSearchKind kind) =>
    kind == ForgeSearchKind.changeRequest
    ? LegacyGitHubSearchKind.changeRequest
    : LegacyGitHubSearchKind.issue;

/// Reads one modern search item, or null when this client cannot represent it.
///
/// The Dart analogue of upstream's `ForgeSearchItemSchema.safeParse`. The kind
/// vocabulary is *closed* here even though the protocol's
/// [ForgeSearchKind.fromWire] also accepts the legacy spellings: upstream's
/// modern schema is `z.enum(["issue", "change_request"])`, so a legacy `pr`
/// arriving on the modern transport is dropped, and reusing the permissive
/// protocol parser would silently accept it.
ForgeSearchItem? parseForgeSearchItem(Object? raw) =>
    _parseSearchItem(raw, const {
      'issue': ForgeSearchKind.issue,
      'change_request': ForgeSearchKind.changeRequest,
    });

/// Reads one legacy GitHub search item, or null when it is unreadable.
///
/// The Dart analogue of `GitHubSearchItemSchema.safeParse` followed by
/// upstream's `kind === "pr" ? change_request : issue` remap. Symmetrically to
/// [parseForgeSearchItem], a neutral `change_request` on the legacy transport
/// is dropped: the old daemon never emits it.
ForgeSearchItem? parseLegacyGitHubSearchItem(Object? raw) => _parseSearchItem(
  raw,
  const {'issue': ForgeSearchKind.issue, 'pr': ForgeSearchKind.changeRequest},
);

/// Shared body of the two item parsers, reproducing the zod object schema
/// field by field.
///
/// Deviation: upstream's `number: z.number()` admits any JavaScript number,
/// including fractions. The protocol's [ForgeSearchItem.number] is an `int`, so
/// a non-integral number is dropped here rather than silently truncated. Zero
/// and negatives *are* accepted, matching upstream — which is why
/// [ForgeSearchItem.fromJson]'s positive-int rule is not reused.
///
/// Zod strips unknown keys, which a typed Dart class does inherently.
ForgeSearchItem? _parseSearchItem(
  Object? raw,
  Map<String, ForgeSearchKind> kindsByWireName,
) {
  if (raw is! Map) return null;
  final json = Map<String, Object?>.from(raw);

  final kind = kindsByWireName[json['kind']];
  if (kind == null) return null;

  final number = json['number'];
  if (number is! num || !number.isFinite || number != number.roundToDouble()) {
    return null;
  }

  final title = json['title'];
  final url = json['url'];
  final state = json['state'];
  if (title is! String || url is! String || state is! String) return null;

  // `z.string().nullable()` — null is allowed, an absent key is not.
  if (!json.containsKey('body')) return null;
  final body = json['body'];
  if (body != null && body is! String) return null;

  final labels = json['labels'];
  if (labels is! List || labels.any((label) => label is! String)) return null;

  final forge = json['forge'];
  final projectPath = json['projectPath'];
  final updatedAt = json['updatedAt'];
  // `z.string().optional()` — null is *not* a valid value, only absence is.
  if (json.containsKey('forge') && forge is! String) return null;
  if (json.containsKey('projectPath') && projectPath is! String) return null;
  if (json.containsKey('updatedAt') && updatedAt is! String) return null;

  // `z.string().nullable().optional()` — absent or null or string.
  final baseRefName = json['baseRefName'];
  final headRefName = json['headRefName'];
  if (baseRefName != null && baseRefName is! String) return null;
  if (headRefName != null && headRefName is! String) return null;

  return ForgeSearchItem(
    kind: kind,
    forge: forge as String?,
    number: number.toInt(),
    title: title,
    url: url,
    state: state,
    body: body as String?,
    labels: List<String>.unmodifiable(labels.cast<String>()),
    projectPath: projectPath as String?,
    baseRefName: baseRefName as String?,
    headRefName: headRefName as String?,
    updatedAt: updatedAt as String?,
  );
}

bool _listsEqual<T>(List<T>? left, List<T>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null) return false;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
