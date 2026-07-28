sealed class CreateAgentWorktreeTarget {
  const CreateAgentWorktreeTarget();

  factory CreateAgentWorktreeTarget.fromJson(Map<String, Object?> json) {
    return switch (json['mode']) {
      'branch-off' => BranchOffCreateAgentWorktreeTarget(
        newBranch: _requiredString(json, 'newBranch'),
        base: _optionalString(json, 'base'),
      ),
      'checkout-branch' => CheckoutBranchCreateAgentWorktreeTarget(
        branch: _requiredString(json, 'branch'),
      ),
      'checkout-pr' => CheckoutPrCreateAgentWorktreeTarget(
        prNumber: _requiredPositiveInt(json, 'prNumber'),
      ),
      final mode => throw FormatException(
        'Unknown create agent worktree mode: $mode',
      ),
    };
  }

  Map<String, Object?> toJson();
}

final class BranchOffCreateAgentWorktreeTarget
    extends CreateAgentWorktreeTarget {
  const BranchOffCreateAgentWorktreeTarget({
    required this.newBranch,
    this.base,
  });

  final String newBranch;
  final String? base;

  @override
  Map<String, Object?> toJson() => {
    'mode': 'branch-off',
    'newBranch': newBranch,
    if (base != null) 'base': base,
  };
}

final class CheckoutBranchCreateAgentWorktreeTarget
    extends CreateAgentWorktreeTarget {
  const CheckoutBranchCreateAgentWorktreeTarget({required this.branch});

  final String branch;

  @override
  Map<String, Object?> toJson() => {
    'mode': 'checkout-branch',
    'branch': branch,
  };
}

final class CheckoutPrCreateAgentWorktreeTarget
    extends CreateAgentWorktreeTarget {
  const CheckoutPrCreateAgentWorktreeTarget({required this.prNumber});

  final int prNumber;

  @override
  Map<String, Object?> toJson() => {
    'mode': 'checkout-pr',
    'prNumber': prNumber,
  };
}

final class CreateAgentLifecycleFields {
  const CreateAgentLifecycleFields({this.worktree, this.autoArchive});

  final CreateAgentWorktreeTarget? worktree;
  final bool? autoArchive;

  factory CreateAgentLifecycleFields.fromJson(Map<String, Object?> json) {
    final rawWorktree = json['worktree'];
    if (json.containsKey('worktree') && rawWorktree is! Map) {
      throw const FormatException('worktree must be an object');
    }
    final rawAutoArchive = json['autoArchive'];
    if (json.containsKey('autoArchive') && rawAutoArchive is! bool) {
      throw const FormatException('autoArchive must be a boolean');
    }
    return CreateAgentLifecycleFields(
      worktree: rawWorktree == null
          ? null
          : CreateAgentWorktreeTarget.fromJson(
              Map<String, Object?>.from(rawWorktree as Map),
            ),
      autoArchive: rawAutoArchive as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    if (worktree != null) 'worktree': worktree!.toJson(),
    if (autoArchive != null) 'autoArchive': autoArchive,
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredPositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value != value.roundToDouble() || value <= 0) {
    throw FormatException('$key must be a positive integer');
  }
  return value.toInt();
}
