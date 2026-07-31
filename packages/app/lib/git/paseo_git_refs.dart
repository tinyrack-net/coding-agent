/// Port of five frozen Paseo 0.2.0 modules that all answer "which git *thing*
/// is this text, ref, forge, or directory pointing at?". They live together
/// because each is a small, dependency-light derivation that sits on the
/// boundary between an opaque wire/user string and a typed git identity:
///
/// - `utils/github-refs.ts` — given pasted prose and the checkout's remote,
///   which pull/issue numbers on *this* repository does it reference?
/// - `utils/branch-suggestions.ts` — how do the many spellings of a branch
///   (`refs/heads/x`, `refs/remotes/origin/x`, `origin/x`, `x`) collapse into
///   one de-duplicated combo-box list?
/// - `git/forges/index.ts` — the pure-logic forge registry: id lookup, URL
///   grammar presence, and runtime-facts parsing, kept free of the rendering
///   half so logic consumers never pull the widget stack.
/// - `utils/server-info-capabilities.ts` — what does the daemon's `server_info`
///   capability block say about voice/dictation readiness, and what message (if
///   any) explains why a mode is unavailable?
/// - `utils/agent-working-directory-suggestions.ts` — which working directories
///   should the "new agent" picker offer, most-recent first, excluding the
///   worktrees Paseo itself owns?
///
/// Deliberately **not** re-implemented here, because prior ports already own
/// them and this file reuses them:
///
/// - remote-URL parsing and GitHub identity extraction —
///   `parseGitHubRemoteUrl` from `package:agent_protocol` (`git_remote.dart`);
/// - the forge manifest (ids, cloud hosts, brand metadata) — `core/forge.dart`;
/// - forge URL grammars (`hasForgeWebUrls`) — `core/forge_url.dart`;
/// - forge runtime-facts validation and merge-capability derivation
///   (`GithubMergeFacts`, `GitlabMergeFacts`, `GiteaMergeFacts`,
///   `derive*MergeCapability`, `getGiteaNativeFallbackChecks`) —
///   `core/forge_logic.dart`.
///
/// ## Known upstream gap (reported, not worked around)
///
/// Upstream's forge manifest lists **two** GitHub cloud hosts —
/// `github.com` and `ssh.github.com` (the SSH-over-443 endpoint) — and
/// `protocol/git-remote.ts`'s `isGitHubHost` is built from that list. The Dart
/// twin in `packages/protocol/lib/src/git_remote.dart` hardcodes only
/// `github.com`, so a remote such as `ssh://git@ssh.github.com/owner/repo.git`
/// yields a `GithubRemote` upstream but `null` here. [normalizeGithubRemote]
/// reuses `parseGitHubRemoteUrl` as instructed rather than papering over the
/// difference locally; the divergence is pinned by a test so it cannot drift
/// silently, and fixing it belongs in the protocol package.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../core/forge_logic.dart';
import '../core/forge_url.dart';

// ---------------------------------------------------------------------------
// utils/github-refs.ts
// ---------------------------------------------------------------------------

/// The two kinds of GitHub reference Paseo recognises in pasted text.
///
/// Upstream's `"pull" | "issues"` union is genuinely closed and its members are
/// also *URL path segments*, so it becomes an enum whose [pathSegment] carries
/// the wire spelling (note the asymmetric plural: `pull` but `issues`).
enum GithubRefKind {
  pull('pull'),
  issues('issues');

  const GithubRefKind(this.pathSegment);

  /// The literal segment as it appears in a `github.com` URL.
  final String pathSegment;
}

GithubRefKind? _githubRefKindFrom(String? value) => switch (value) {
  'pull' => GithubRefKind.pull,
  'issues' => GithubRefKind.issues,
  _ => null,
};

/// The GitHub repository a checkout's remote points at.
///
/// [host] is upstream's literal `"github.com"` type, not the remote's actual
/// hostname: a `git@github.com:o/r.git` remote and an
/// `https://github.com/o/r` remote produce the identical value, which is what
/// lets an HTTPS URL pasted into a checkout with an SSH remote still match.
final class GithubRemote {
  const GithubRemote({required this.owner, required this.repo});

  final String owner;
  final String repo;

  /// Always `'github.com'`, mirroring upstream's `host: "github.com"` literal.
  String get host => 'github.com';

  @override
  bool operator ==(Object other) =>
      other is GithubRemote && other.owner == owner && other.repo == repo;

  @override
  int get hashCode => Object.hash(owner, repo);

  @override
  String toString() => 'GithubRemote(owner: $owner, repo: $repo, host: $host)';
}

/// One pull request or issue on the checkout's own repository.
///
/// [owner] and [repo] are taken from the *remote*, not from the matched URL, so
/// the casing is the repository's canonical casing even when the pasted link
/// spelled it differently. [url] is likewise rebuilt canonically, dropping any
/// `/files`, `?diff=split`, or `#discussion_r1` suffix the paste carried.
final class GithubRef {
  const GithubRef({
    required this.kind,
    required this.number,
    required this.owner,
    required this.repo,
    required this.url,
  });

  final GithubRefKind kind;
  final int number;
  final String owner;
  final String repo;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is GithubRef &&
      other.kind == kind &&
      other.number == number &&
      other.owner == owner &&
      other.repo == repo &&
      other.url == url;

  @override
  int get hashCode => Object.hash(kind, number, owner, repo, url);

  @override
  String toString() =>
      'GithubRef(kind: ${kind.pathSegment}, number: $number, '
      'owner: $owner, repo: $repo, url: $url)';
}

/// Upstream's `GITHUB_REF_URL_PATTERN`, transcribed verbatim.
///
/// The owner/repo classes exclude `/`, whitespace, `<`, `>`, `)` and `]` so a
/// link wrapped in markdown (`[PR](url)`), autolink brackets (`<url>`), or
/// trailing prose punctuation still yields a clean match. Upstream's `g` flag
/// maps to [RegExp.allMatches], `i` to `caseSensitive: false`, and `u` to
/// `unicode: true`.
///
/// The pattern's behaviour was verified against the frozen TypeScript executed
/// under Node rather than reasoned about: both engines agree on all of the
/// edge cases pinned in the test suite (bare `pull/0`, zero-padded `007`,
/// a 20-digit number, `paseo.git` as the repo segment, a trailing dot in the
/// host, `www.` prefixes, `prefixhttps://…`, and two URLs run together by a
/// `/` versus separated by a space).
final _githubRefUrlPattern = RegExp(
  r'https?://github\.com/([^/\s<>)\]]+)/([^/\s<>)\]]+)/(pull|issues)/(\d+)'
  r'(?:[/?#][^\s<>)\]]*)?',
  caseSensitive: false,
  unicode: true,
);

/// JavaScript's `Number.MAX_SAFE_INTEGER`.
///
/// Upstream guards the parsed number with `Number.isSafeInteger`. Dart's `int`
/// is 64-bit, so it would happily accept values JavaScript cannot represent
/// exactly; the bound is reapplied explicitly to keep the accept/reject
/// boundary identical.
const _maxSafeInteger = 9007199254740991;

/// The checkout's GitHub repository, or `null` when the remote is missing,
/// blank, or not a GitHub remote.
///
/// Reuses `parseGitHubRemoteUrl` from `package:agent_protocol` — the remote
/// grammar (scp-like, `https://`, `ssh://`, `.git` suffix, trailing dots) is
/// already ported there and is deliberately not duplicated. See the library
/// doc comment for the `ssh.github.com` host gap that reuse inherits.
///
/// Deviation: upstream takes `string | null | undefined` and relies on JS
/// truthiness, where `""` and `"   "` are equivalent to absent. Dart has no
/// `undefined`, so a null-or-blank [remoteUrl] is the single "absent" case.
GithubRemote? normalizeGithubRemote(String? remoteUrl) {
  final trimmed = remoteUrl?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final identity = parseGitHubRemoteUrl(trimmed);
  if (identity == null) return null;

  return GithubRemote(owner: identity.owner, repo: identity.name);
}

/// The first reference in [text] belonging to [remoteUrl]'s repository.
///
/// Convenience over [extractGithubRefs]; returns `null` when nothing matches.
GithubRef? parseGithubRef(String? text, String? remoteUrl) {
  final refs = extractGithubRefs(text, remoteUrl);
  return refs.isEmpty ? null : refs.first;
}

/// Every reference in [text] that points at [remoteUrl]'s repository, in the
/// order encountered and de-duplicated by `(kind, number)`.
///
/// Owner/repo comparison is case-insensitive (GitHub treats them so), but the
/// emitted [GithubRef.owner]/[GithubRef.repo]/[GithubRef.url] always use the
/// remote's canonical casing. Links to *other* repositories are skipped rather
/// than rewritten.
///
/// Returns an empty list when the remote is not GitHub or the text is blank —
/// upstream's `!remote || !body` guard, where `body` is the trimmed text.
List<GithubRef> extractGithubRefs(String? text, String? remoteUrl) {
  final remote = normalizeGithubRemote(remoteUrl);
  final body = text?.trim();
  if (remote == null || body == null || body.isEmpty) {
    return const <GithubRef>[];
  }

  final refs = <GithubRef>[];
  final seen = <String>{};

  for (final match in _githubRefUrlPattern.allMatches(body)) {
    final owner = match.group(1);
    final repo = match.group(2);
    final kind = _githubRefKindFrom(match.group(3));
    final numberText = match.group(4);
    if (owner == null ||
        owner.isEmpty ||
        repo == null ||
        repo.isEmpty ||
        kind == null ||
        numberText == null ||
        numberText.isEmpty) {
      continue;
    }

    // `int.tryParse` returning null covers upstream's `Number.isSafeInteger`
    // rejection of magnitudes past 64 bits; `_maxSafeInteger` covers the band
    // between 2^53 and 2^63 that Dart can hold but JavaScript cannot.
    final number = int.tryParse(numberText);
    if (number == null || number <= 0 || number > _maxSafeInteger) {
      continue;
    }

    if (owner.toLowerCase() != remote.owner.toLowerCase() ||
        repo.toLowerCase() != remote.repo.toLowerCase()) {
      continue;
    }

    final dedupeKey = '${kind.pathSegment}:$number';
    if (!seen.add(dedupeKey)) continue;

    refs.add(
      GithubRef(
        kind: kind,
        number: number,
        owner: remote.owner,
        repo: remote.repo,
        url:
            'https://github.com/${remote.owner}/${remote.repo}/'
            '${kind.pathSegment}/$number',
      ),
    );
  }

  return refs;
}

// ---------------------------------------------------------------------------
// utils/branch-suggestions.ts
// ---------------------------------------------------------------------------

/// One entry in the base-branch combo box.
///
/// Upstream's `id` and `label` are always the same normalized branch name; the
/// pair is kept because the combo-box widget addresses options by id.
final class BranchComboOption {
  const BranchComboOption({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is BranchComboOption && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'BranchComboOption(id: $id, label: $label)';
}

/// Collapse a branch spelling to the bare branch name, or `null` if it is not
/// a usable suggestion.
///
/// Strips at most one of `refs/heads/` **or** `refs/remotes/` (upstream uses an
/// `else if`, so they never both apply), then — independently — a leading
/// `origin/`. That ordering is load-bearing: `refs/remotes/origin/main` loses
/// both prefixes and becomes `main`, while `refs/heads/origin/main` also loses
/// both, because the second strip is not conditioned on the first.
///
/// `HEAD` is rejected both before and after normalization, so `origin/HEAD` and
/// `refs/remotes/origin/HEAD` are filtered out too — a detached or symbolic
/// head is never a base-branch choice.
String? normalizeBranchOptionName(String? input) {
  final trimmed = input?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == 'HEAD') return null;

  var normalized = trimmed;
  if (normalized.startsWith('refs/heads/')) {
    normalized = normalized.substring('refs/heads/'.length);
  } else if (normalized.startsWith('refs/remotes/')) {
    normalized = normalized.substring('refs/remotes/'.length);
  }
  if (normalized.startsWith('origin/')) {
    normalized = normalized.substring('origin/'.length);
  }

  return normalized.isNotEmpty && normalized != 'HEAD' ? normalized : null;
}

/// Merge every source of branch names the base-branch picker knows about into
/// one normalized, de-duplicated, insertion-ordered option list.
///
/// Sources are consumed in upstream's fixed order — suggested branches, the
/// current branch, the checkout's base ref, whatever the user has typed, then
/// worktree labels — and a `Set` keeps the *first* occurrence's position. That
/// is why `origin/main` listed before `refs/remotes/origin/main` yields a single
/// `main` option at the front.
///
/// Deviation: upstream's parameters are optional object fields distinguished
/// from `null` only by JS truthiness; here every parameter is nullable and
/// `null` means "absent", which is observationally identical because
/// [normalizeBranchOptionName] already discards blanks.
List<BranchComboOption> buildBranchComboOptions({
  List<String>? suggestedBranches,
  String? currentBranch,
  String? baseRef,
  String? typedBaseBranch,
  List<String>? worktreeBranchLabels,
}) {
  final branchSet = <String>{};
  void addBranch(String? name) {
    final normalized = normalizeBranchOptionName(name);
    if (normalized != null) branchSet.add(normalized);
  }

  for (final branch in suggestedBranches ?? const <String>[]) {
    addBranch(branch);
  }
  addBranch(currentBranch);
  addBranch(baseRef);
  addBranch(typedBaseBranch);
  for (final label in worktreeBranchLabels ?? const <String>[]) {
    addBranch(label);
  }

  return branchSet
      .map((name) => BranchComboOption(id: name, label: name))
      .toList(growable: false);
}

// ---------------------------------------------------------------------------
// git/forges/index.ts
// ---------------------------------------------------------------------------

/// A forge's runtime `forgeSpecific` payload after schema validation.
///
/// Upstream's `ForgeSpecificEnvelope` is the structural union
/// `{ forge: string } & Record<string, unknown>` — the *output* of a Zod parse,
/// so absent optional fields have been filled with their defaults and unknown
/// keys survive via `.passthrough()`. Dart has no structural unions, so the
/// envelope is a `final class` carrying the discriminant [forge] plus the
/// normalized [values] map (which includes `'forge'`, exactly like the JS
/// object it stands in for).
final class ForgeSpecificEnvelope {
  const ForgeSpecificEnvelope({required this.forge, required this.values});

  /// The discriminant: `'github'`, `'gitlab'`, or `'gitea'`.
  final String forge;

  /// Schema defaults applied, unknown keys preserved, nested objects
  /// (`autoMergeRequest`, `repository`) normalized in place.
  final Map<String, Object?> values;

  @override
  String toString() => 'ForgeSpecificEnvelope(forge: $forge, values: $values)';
}

/// The runtime-facts half of a registered forge.
///
/// Mirrors upstream's `ClientForgeFactsEntry`. The three members are exposed as
/// function fields rather than methods so the registry stays a `const` list of
/// tear-offs pointing at the already-ported derivations in `core/forge_logic.dart`.
final class ClientForgeFactsEntry {
  const ClientForgeFactsEntry({
    required this.family,
    required this.parse,
    required this.deriveMergeCapability,
    this.nativeFallbackChecks = _noNativeFallbackChecks,
  });

  /// The `forge` discriminant this entry claims.
  final String family;

  /// Validates and normalizes an opaque `forgeSpecific` payload, or `null` when
  /// it belongs to another family or fails the schema.
  final ForgeSpecificEnvelope? Function(Object? facts) parse;

  /// The neutral merge capability, or `null` when the payload is not this
  /// family's.
  final ForgeMergeCapability? Function(Object? facts) deriveMergeCapability;

  /// Aggregate check rows this forge synthesizes when it reports no individual
  /// checks. Empty for every forge but Gitea.
  final List<ForgeFallbackCheck> Function(CheckoutPrStatus status, String forge)
  nativeFallbackChecks;
}

List<ForgeFallbackCheck> _noNativeFallbackChecks(
  CheckoutPrStatus status,
  String forge,
) => const <ForgeFallbackCheck>[];

/// The pure-logic half of a forge: identity, URL grammar, runtime facts.
///
/// Upstream keeps this deliberately free of React/React-Native imports so URL
/// builders, merge-capability derivation, and the Node e2e harness never pull
/// the rendering stack. The Dart twin preserves the split by *delegating*:
/// [hasUrlGrammar] asks `core/forge_url.dart`, and [facts] points at
/// `core/forge_logic.dart`. The view half (brand glyph, brand colour) lives in
/// `core/forge.dart`'s `ForgeBrandIcon` and is intentionally not referenced here.
final class ClientForgeLogicModule {
  const ClientForgeLogicModule({required this.id, this.facts});

  /// The forge id, matching `core/forge.dart`'s manifest.
  final String id;

  /// `null` for forges that expose no runtime merge facts (Forgejo, Codeberg).
  final ClientForgeFactsEntry? facts;

  /// Whether this forge has a web URL grammar (tree/blob infixes plus a line
  /// anchor), i.e. whether `buildForgeBlobUrl` / `buildForgeBranchTreeUrl` can
  /// produce links for it.
  ///
  /// Upstream exposes the grammar object itself (`module.urlGrammar`) and
  /// callers check it for `undefined`; here the grammar table is already owned
  /// by `core/forge_url.dart`, so the module surfaces the *predicate* and the
  /// builders stay the single place that knows the infixes.
  bool get hasUrlGrammar => hasForgeWebUrls(id);
}

const _githubKnownKeys = <String>{
  'forge',
  'mergeStateStatus',
  'autoMergeRequest',
  'viewerCanEnableAutoMerge',
  'viewerCanDisableAutoMerge',
  'viewerCanMergeAsAdmin',
  'viewerCanUpdateBranch',
  'repository',
  'isMergeQueueEnabled',
  'isInMergeQueue',
};

const _gitlabKnownKeys = <String>{
  'forge',
  'detailedMergeStatus',
  'mergeStatus',
  'hasConflicts',
  'blockingDiscussionsResolved',
  'approvalsRequired',
  'approvalsGiven',
  'pipelineStatus',
  'pipelineId',
  'pipelineUrl',
  'mergeWhenPipelineSucceeds',
};

const _giteaKnownKeys = <String>{'forge', 'mergeable', 'hasMerged', 'ciStatus'};

/// Copies the keys Zod's `.passthrough()` would have carried through untouched.
///
/// Deviation: only `String` keys are copied. A JavaScript object can only have
/// string (or symbol) keys, so a decoded JSON map always satisfies this; a
/// hand-built Dart map with non-string keys silently drops them rather than
/// crashing.
Map<String, Object?> _passthrough(
  Map<Object?, Object?> input,
  Set<String> known,
) {
  final extras = <String, Object?>{};
  for (final entry in input.entries) {
    final key = entry.key;
    if (key is String && !known.contains(key)) extras[key] = entry.value;
  }
  return extras;
}

/// Validate and normalize a GitHub `forgeSpecific` payload.
///
/// Validation is `core/forge_logic.dart`'s `GithubMergeFacts.parse`; this
/// function only re-emits the result in the map shape upstream's Zod schema
/// produces, so nested `autoMergeRequest` / `repository` objects come back with
/// their defaults filled and their unknown keys stripped (neither nested schema
/// is `.passthrough()`), while unknown *top-level* keys survive.
ForgeSpecificEnvelope? parseGithubForgeFacts(Object? facts) {
  final parsed = GithubMergeFacts.parse(facts);
  if (parsed == null || facts is! Map) return null;
  final autoMerge = parsed.autoMergeRequest;
  final repository = parsed.repository;
  return ForgeSpecificEnvelope(
    forge: 'github',
    values: <String, Object?>{
      'forge': 'github',
      'mergeStateStatus': parsed.mergeStateStatus,
      'autoMergeRequest': autoMerge == null
          ? null
          : <String, Object?>{
              'enabledAt': autoMerge.enabledAt,
              'mergeMethod': autoMerge.mergeMethod,
              'enabledBy': autoMerge.enabledBy,
            },
      'viewerCanEnableAutoMerge': parsed.viewerCanEnableAutoMerge,
      'viewerCanDisableAutoMerge': parsed.viewerCanDisableAutoMerge,
      'viewerCanMergeAsAdmin': parsed.viewerCanMergeAsAdmin,
      'viewerCanUpdateBranch': parsed.viewerCanUpdateBranch,
      'repository': <String, Object?>{
        'autoMergeAllowed': repository.autoMergeAllowed,
        'mergeCommitAllowed': repository.mergeCommitAllowed,
        'squashMergeAllowed': repository.squashMergeAllowed,
        'rebaseMergeAllowed': repository.rebaseMergeAllowed,
        'viewerDefaultMergeMethod': repository.viewerDefaultMergeMethod,
      },
      'isMergeQueueEnabled': parsed.isMergeQueueEnabled,
      'isInMergeQueue': parsed.isInMergeQueue,
      ..._passthrough(facts, _githubKnownKeys),
    },
  );
}

/// Validate and normalize a GitLab `forgeSpecific` payload. See
/// [parseGithubForgeFacts] for the normalization contract.
ForgeSpecificEnvelope? parseGitlabForgeFacts(Object? facts) {
  final parsed = GitlabMergeFacts.parse(facts);
  if (parsed == null || facts is! Map) return null;
  return ForgeSpecificEnvelope(
    forge: 'gitlab',
    values: <String, Object?>{
      'forge': 'gitlab',
      'detailedMergeStatus': parsed.detailedMergeStatus,
      'mergeStatus': parsed.mergeStatus,
      'hasConflicts': parsed.hasConflicts,
      'blockingDiscussionsResolved': parsed.blockingDiscussionsResolved,
      'approvalsRequired': parsed.approvalsRequired,
      'approvalsGiven': parsed.approvalsGiven,
      'pipelineStatus': parsed.pipelineStatus,
      'pipelineId': parsed.pipelineId,
      'pipelineUrl': parsed.pipelineUrl,
      'mergeWhenPipelineSucceeds': parsed.mergeWhenPipelineSucceeds,
      ..._passthrough(facts, _gitlabKnownKeys),
    },
  );
}

/// Validate and normalize a Gitea `forgeSpecific` payload. See
/// [parseGithubForgeFacts] for the normalization contract.
ForgeSpecificEnvelope? parseGiteaForgeFacts(Object? facts) {
  final parsed = GiteaMergeFacts.parse(facts);
  if (parsed == null || facts is! Map) return null;
  return ForgeSpecificEnvelope(
    forge: 'gitea',
    values: <String, Object?>{
      'forge': 'gitea',
      'mergeable': parsed.mergeable,
      'hasMerged': parsed.hasMerged,
      'ciStatus': parsed.ciStatus,
      ..._passthrough(facts, _giteaKnownKeys),
    },
  );
}

/// The pure-logic forge registry, in upstream's declaration order.
///
/// Order is observable: [parseClientForgeFacts] returns the *first* family whose
/// schema accepts a payload, and the merge-capability derivation upstream reads
/// the list the same way. Forgejo and Codeberg are Gitea-family forges that ship
/// a URL grammar but no runtime merge facts, so their [ClientForgeLogicModule.facts]
/// is `null`.
///
/// Adding a forge means adding a manifest entry in `core/forge.dart` **and** a
/// line here; the accompanying test asserts the two stay in sync, which is the
/// Dart analogue of upstream's directory-listing completeness test (Dart has no
/// bundler-independent module enumeration to discover files with).
const clientForgeLogicModules = <ClientForgeLogicModule>[
  ClientForgeLogicModule(
    id: 'github',
    facts: ClientForgeFactsEntry(
      family: 'github',
      parse: parseGithubForgeFacts,
      deriveMergeCapability: deriveGithubMergeCapability,
    ),
  ),
  ClientForgeLogicModule(
    id: 'gitlab',
    facts: ClientForgeFactsEntry(
      family: 'gitlab',
      parse: parseGitlabForgeFacts,
      deriveMergeCapability: deriveGitlabMergeCapability,
    ),
  ),
  ClientForgeLogicModule(
    id: 'gitea',
    facts: ClientForgeFactsEntry(
      family: 'gitea',
      parse: parseGiteaForgeFacts,
      deriveMergeCapability: deriveGiteaMergeCapability,
      nativeFallbackChecks: getGiteaNativeFallbackChecks,
    ),
  ),
  ClientForgeLogicModule(id: 'forgejo'),
  ClientForgeLogicModule(id: 'codeberg'),
];

/// The registered logic module for [id], or `null` for an unknown forge.
ClientForgeLogicModule? getClientForgeLogicModule(String id) {
  for (final module in clientForgeLogicModules) {
    if (module.id == id) return module;
  }
  return null;
}

/// Normalize an opaque `forgeSpecific` payload against every registered forge,
/// returning the first family that accepts it.
///
/// Returns `null` for `null`, for a non-map, for an unknown `forge`
/// discriminant, and for a payload whose own family rejects it (a type error in
/// a known field) — the caller then renders no forge-specific detail.
///
/// Deviation: upstream's guard is `if (!facts) return null`, which also swallows
/// `""`, `0`, `false`, and `NaN`. Those are all non-objects, so the per-family
/// `value is! Map` check rejects them identically; only `null` needs the
/// explicit Dart arm.
ForgeSpecificEnvelope? parseClientForgeFacts(Object? facts) {
  for (final module in clientForgeLogicModules) {
    final parsed = module.facts?.parse(facts);
    if (parsed != null) return parsed;
  }
  return null;
}

// ---------------------------------------------------------------------------
// utils/server-info-capabilities.ts
// ---------------------------------------------------------------------------

/// Which voice capability a readiness question is about.
///
/// Upstream's `"dictation" | "voice"` union selects between two identically
/// shaped states, so it becomes an enum rather than a string.
enum VoiceReadinessMode { dictation, voice }

/// One capability's readiness: whether the daemon can serve it, and why not.
///
/// Both fields are required upstream (`z.object({ enabled, reason })`), and
/// [reason] is a possibly-empty string rather than nullable — "enabled with no
/// explanation" is `enabled: true, reason: ""`.
final class ServerCapabilityState {
  const ServerCapabilityState({required this.enabled, required this.reason});

  final bool enabled;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is ServerCapabilityState &&
      other.enabled == enabled &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(enabled, reason);

  @override
  String toString() =>
      'ServerCapabilityState(enabled: $enabled, reason: $reason)';
}

/// The daemon's two voice-related capability states.
final class ServerVoiceCapabilities {
  const ServerVoiceCapabilities({required this.dictation, required this.voice});

  final ServerCapabilityState dictation;
  final ServerCapabilityState voice;

  @override
  bool operator ==(Object other) =>
      other is ServerVoiceCapabilities &&
      other.dictation == dictation &&
      other.voice == voice;

  @override
  int get hashCode => Object.hash(dictation, voice);

  @override
  String toString() =>
      'ServerVoiceCapabilities(dictation: $dictation, voice: $voice)';
}

/// The validated `server_info.capabilities` block.
///
/// Upstream's schema is `.passthrough()` with a single known optional `voice`
/// key, so unknown capability groups a newer daemon advertises survive
/// untouched in [extras] instead of being dropped.
final class ServerCapabilities {
  const ServerCapabilities({required this.voice, required this.extras});

  final ServerVoiceCapabilities? voice;

  /// Every capability key other than `voice`, passed through unparsed.
  final Map<String, Object?> extras;

  @override
  String toString() => 'ServerCapabilities(voice: $voice, extras: $extras)';
}

ServerCapabilityState? _parseCapabilityState(Object? value) {
  if (value is! Map) return null;
  final enabled = value['enabled'];
  final reason = value['reason'];
  if (enabled is! bool || reason is! String) return null;
  return ServerCapabilityState(enabled: enabled, reason: reason);
}

ServerVoiceCapabilities? _parseVoiceCapabilities(Object? value) {
  if (value is! Map) return null;
  final dictation = _parseCapabilityState(value['dictation']);
  final voice = _parseCapabilityState(value['voice']);
  if (dictation == null || voice == null) return null;
  return ServerVoiceCapabilities(dictation: dictation, voice: voice);
}

/// The daemon's advertised capabilities, or `null` when it advertised none.
///
/// Upstream validates the whole block up front (in the `server_info` payload
/// schema) and collapses a *malformed* block to `undefined`; the Dart
/// `ServerInfoStatus` keeps `capabilities` as a raw map, so the same validation
/// happens here and a malformed `voice` group likewise makes the entire result
/// `null` rather than yielding a half-parsed block.
///
/// Deviation: `ServerInfoStatus.capabilities` defaults to `const {}` and its
/// `toJson` omits an empty map, so "absent" and "explicitly `{}`" are already
/// indistinguishable on the Dart side. An empty map therefore returns `null`,
/// whereas upstream's truthiness check would return the empty object. No
/// caller can observe the difference: [getVoiceReadinessState] reads `voice`
/// out of it, and an empty block has none.
ServerCapabilities? getServerCapabilities({ServerInfoStatus? serverInfo}) {
  final capabilities = serverInfo?.capabilities;
  if (capabilities == null || capabilities.isEmpty) return null;

  ServerVoiceCapabilities? voice;
  if (capabilities.containsKey('voice')) {
    voice = _parseVoiceCapabilities(capabilities['voice']);
    // A present-but-invalid `voice` fails the whole capabilities schema
    // upstream, including an explicit JSON `null` (the field is optional, not
    // nullable).
    if (voice == null) return null;
  }

  return ServerCapabilities(
    voice: voice,
    extras: <String, Object?>{
      for (final entry in capabilities.entries)
        if (entry.key != 'voice') entry.key: entry.value,
    },
  );
}

/// The readiness state for [mode], or `null` when the daemon advertises no
/// voice capabilities at all.
ServerCapabilityState? getVoiceReadinessState({
  ServerInfoStatus? serverInfo,
  required VoiceReadinessMode mode,
}) {
  final voice = getServerCapabilities(serverInfo: serverInfo)?.voice;
  if (voice == null) return null;
  return switch (mode) {
    VoiceReadinessMode.dictation => voice.dictation,
    VoiceReadinessMode.voice => voice.voice,
  };
}

/// The message explaining why [mode] is unavailable, or `null` when there is
/// nothing to say.
///
/// Note that a non-blank reason is surfaced *even when the capability is
/// enabled* — the daemon uses it for transient states such as "models are still
/// downloading", which the composer shows as a hint rather than a hard block.
/// Upstream's early `enabled && reason is blank` return is therefore redundant
/// with the final blank check; both collapse to "the trimmed reason, if any".
String? resolveVoiceUnavailableMessage({
  ServerInfoStatus? serverInfo,
  required VoiceReadinessMode mode,
}) {
  final readiness = getVoiceReadinessState(serverInfo: serverInfo, mode: mode);
  if (readiness == null) return null;
  final message = readiness.reason.trim();
  return message.isEmpty ? null : message;
}

// ---------------------------------------------------------------------------
// utils/agent-working-directory-suggestions.ts
// ---------------------------------------------------------------------------

/// One agent's contribution to the working-directory suggestion list.
///
/// Deviation: upstream's fields are `Date | null | undefined`, and an
/// *Invalid Date* (`new Date("nope")`) is coerced to epoch 0 by its
/// `Number.isFinite` guard. Dart's `DateTime` cannot be invalid, so `null` is
/// the only "no timestamp" case and it maps to the same 0.
final class AgentWorkingDirectorySource {
  const AgentWorkingDirectorySource({
    this.cwd,
    this.createdAt,
    this.lastActivityAt,
  });

  final String? cwd;
  final DateTime? createdAt;
  final DateTime? lastActivityAt;
}

/// Upstream's `PASEO_WORKTREE_PATH_PATTERN`.
///
/// Anchored on a path *segment* boundary so `.paseo/worktrees` is matched at the
/// start of the path or after a separator, and only when it ends the path or is
/// followed by one — a directory merely named `my.paseo/worktreesX` is not a
/// managed worktree.
final _paseoWorktreePathPattern = RegExp(r'(^|/)\.paseo/worktrees(/|$)');

/// Working directories worth offering when starting a new agent, most recently
/// used first.
///
/// De-duplicates by trimmed path, keeping the newest timestamp seen for it, and
/// drops Paseo-managed worktrees (`…/.paseo/worktrees/…`) — those are created
/// per-agent and offering them would nest a new agent inside another's tree.
/// `lastActivityAt` wins over `createdAt`; a source with neither sorts as epoch
/// 0, i.e. last.
///
/// Deviation: ties are broken with Dart's `String.compareTo` (UTF-16 code-unit
/// order) where upstream uses `localeCompare` (ICU collation). The two disagree
/// on case and punctuation — ICU orders `"a"` before `"A"` and largely ignores
/// `-` and `_`, while code-unit order puts every uppercase letter first. Dart's
/// core library has no locale-aware comparator, and pulling `intl` in for a
/// tiebreak between distinct absolute paths is not worth the dependency; the
/// primary sort key (timestamp) is unaffected, and the divergence is pinned by a
/// test so it is visible rather than accidental.
List<String> collectAgentWorkingDirectorySuggestions(
  Iterable<AgentWorkingDirectorySource> sources,
) {
  // Insertion-ordered, matching JS `Map`; ties therefore fall through to the
  // explicit path comparison below rather than depending on iteration order.
  final lastSeenByPath = <String, int>{};

  for (final source in sources) {
    final cwd = source.cwd?.trim();
    if (cwd == null || cwd.isEmpty) continue;
    if (_isPaseoOwnedWorktreePath(cwd)) continue;

    final timestamp = _toEpochMs(source.lastActivityAt ?? source.createdAt);
    final previous = lastSeenByPath[cwd];
    if (previous == null || timestamp > previous) {
      lastSeenByPath[cwd] = timestamp;
    }
  }

  final entries = lastSeenByPath.entries.toList();
  entries.sort((left, right) {
    final timeDiff = right.value - left.value;
    if (timeDiff != 0) return timeDiff;
    return left.key.compareTo(right.key);
  });
  return entries.map((entry) => entry.key).toList(growable: false);
}

/// Whether [cwd] lives inside a Paseo-managed worktree.
///
/// Backslashes are folded to forward slashes first so a Windows path
/// (`C:\repo\.paseo\worktrees\feature`) is recognised by the same POSIX-shaped
/// pattern.
bool _isPaseoOwnedWorktreePath(String cwd) =>
    _paseoWorktreePathPattern.hasMatch(cwd.replaceAll(r'\', '/'));

int _toEpochMs(DateTime? date) => date?.millisecondsSinceEpoch ?? 0;
