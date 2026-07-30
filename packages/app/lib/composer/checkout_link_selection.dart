import 'package:agent_protocol/agent_protocol.dart';

final class CheckoutLinkTarget {
  const CheckoutLinkTarget({required this.serverId, required this.cwd});

  final String serverId;
  final String cwd;

  @override
  bool operator ==(Object other) =>
      other is CheckoutLinkTarget &&
      other.serverId == serverId &&
      other.cwd == cwd;

  @override
  int get hashCode => Object.hash(serverId, cwd);
}

final class GithubPullRequestRef {
  const GithubPullRequestRef({
    required this.owner,
    required this.repository,
    required this.number,
  });

  final String owner;
  final String repository;
  final int number;

  String get key =>
      '${owner.toLowerCase()}/${repository.toLowerCase()}#$number';
  String get url => 'https://github.com/$owner/$repository/pull/$number';
}

final class CheckoutLinkLookup {
  const CheckoutLinkLookup({
    required this.target,
    required this.reference,
    required this.generation,
  });

  final CheckoutLinkTarget target;
  final GithubPullRequestRef reference;
  final int generation;
}

sealed class CheckoutLinkSelection {
  const CheckoutLinkSelection();
}

final class BranchCheckoutLinkSelection extends CheckoutLinkSelection {
  const BranchCheckoutLinkSelection(this.name);

  final String name;
}

final class ChangeRequestCheckoutLinkSelection extends CheckoutLinkSelection {
  const ChangeRequestCheckoutLinkSelection(this.item);

  final ForgeSearchItem item;
}

/// Frozen Paseo 0.2.0 pasted-PR selection lifecycle.
///
/// The upstream release detects newly present GitHub PR URLs from composer
/// text changes; it does not expose a distinct paste event. Consequently a URL
/// completed by typing has the same semantics as a pasted URL, while ordinary
/// edits around an already-present URL do not re-arm automatic selection.
final class CheckoutLinkSelectionLifecycle {
  CheckoutLinkTarget? _target;
  Set<String> _presentKeys = const {};
  int _generation = 0;
  bool _allowAutomaticSelection = false;
  CheckoutLinkSelection? _selection;

  CheckoutLinkTarget? get target => _target;
  CheckoutLinkSelection? get selection => _selection;

  List<CheckoutLinkLookup> observe({
    required String text,
    required CheckoutLinkTarget target,
  }) {
    final references = extractGithubPullRequestRefs(text);
    final currentKeys = {for (final reference in references) reference.key};
    final previousTarget = _target;
    if (previousTarget != null && previousTarget != target) {
      _target = target;
      _presentKeys = currentKeys;
      _generation++;
      _allowAutomaticSelection = false;
      _selection = null;
      return const [];
    }
    _target = target;

    final newlyPresent = [
      for (final reference in references)
        if (!_presentKeys.contains(reference.key)) reference,
    ];
    if (!_sameKeys(_presentKeys, currentKeys)) _generation++;
    _presentKeys = currentKeys;
    if (newlyPresent.isEmpty) return const [];

    _allowAutomaticSelection = true;
    final generation = _generation;
    return [
      for (final reference in newlyPresent)
        CheckoutLinkLookup(
          target: target,
          reference: reference,
          generation: generation,
        ),
    ];
  }

  void selectBranch(String name) {
    _generation++;
    _allowAutomaticSelection = false;
    _selection = BranchCheckoutLinkSelection(name);
  }

  void changeTarget(CheckoutLinkTarget target, {required String text}) {
    if (_target == target) return;
    _target = target;
    _presentKeys = {
      for (final reference in extractGithubPullRequestRefs(text)) reference.key,
    };
    _generation++;
    _allowAutomaticSelection = false;
    _selection = null;
  }

  bool apply(CheckoutLinkLookup lookup, ForgeSearchItem item) {
    if (!_allowAutomaticSelection ||
        lookup.target != _target ||
        lookup.generation != _generation ||
        !_presentKeys.contains(lookup.reference.key) ||
        !forgeItemMatchesGithubPullRequest(item, lookup.reference)) {
      return false;
    }
    _allowAutomaticSelection = false;
    _selection = ChangeRequestCheckoutLinkSelection(item);
    return true;
  }
}

List<GithubPullRequestRef> extractGithubPullRequestRefs(String text) {
  final references = <GithubPullRequestRef>[];
  final seen = <String>{};
  for (final match in _githubPullRequestPattern.allMatches(text.trim())) {
    final owner = match.group(1);
    final repository = match.group(2);
    final number = int.tryParse(match.group(3) ?? '');
    if (owner == null || repository == null || number == null || number <= 0) {
      continue;
    }
    final reference = GithubPullRequestRef(
      owner: owner,
      repository: repository,
      number: number,
    );
    if (seen.add(reference.key)) references.add(reference);
  }
  return List.unmodifiable(references);
}

bool forgeItemMatchesGithubPullRequest(
  ForgeSearchItem item,
  GithubPullRequestRef reference,
) {
  if (item.kind != ForgeSearchKind.changeRequest ||
      item.number != reference.number ||
      (item.forge ?? 'github').toLowerCase() != 'github') {
    return false;
  }
  final parsed = extractGithubPullRequestRefs(item.url);
  return parsed.length == 1 && parsed.single.key == reference.key;
}

Map<String, Object?> checkoutSourceForChangeRequest(ForgeSearchItem item) => {
  'kind': 'change_request',
  'forge': item.forge ?? 'github',
  'number': item.number,
  if (item.projectPath?.trim().isNotEmpty == true)
    'projectPath': item.projectPath!.trim(),
};

final _githubPullRequestPattern = RegExp(
  r'https?://github\.com/([^/\s<>)\]]+)/([^/\s<>)\]]+)/pull/(\d+)(?![\w-])(?:[/?#][^\s<>)\]]*)?',
  caseSensitive: false,
);

bool _sameKeys(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
