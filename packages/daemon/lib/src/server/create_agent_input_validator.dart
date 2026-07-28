void validateCreateAgentArguments(
  Map<String, Object?> arguments, {
  required bool agentScoped,
}) {
  final legacy = hasLegacyCreateAgentPlacement(arguments);
  const common = {'title', 'provider', 'labels', 'settings', 'initialPrompt'};
  final allowed = <String>{
    ...common,
    if (legacy) ...{
      'relationship',
      'workspace',
      'notifyOnFinish',
      if (!agentScoped) ...{
        'background',
        'cwd',
        'mode',
        'thinking',
        'features',
        'worktreeName',
        'branchName',
        'baseBranch',
        'refName',
        'githubPrNumber',
      },
    } else ...{
      'workspaceId',
      'notifyOnFinish',
      if (!agentScoped) 'background',
    },
  };
  _requireOnlyKeys(arguments, allowed, 'create_agent');

  _requireString(arguments, 'title', trim: true, nonEmpty: true);
  _requireString(arguments, 'provider', trim: true, nonEmpty: true);
  _requireString(arguments, 'initialPrompt', trim: true, nonEmpty: true);
  _validateOptionalStringMap(arguments, 'labels', 'create_agent.labels');
  if (arguments.containsKey('settings')) {
    final settings = _requiredMap(arguments, 'settings');
    _requireOnlyKeys(settings, const {
      'modeId',
      'thinkingOptionId',
      'features',
    }, 'create_agent.settings');
    _validateOptionalString(settings, 'modeId', 'create_agent.settings.modeId');
    _validateOptionalString(
      settings,
      'thinkingOptionId',
      'create_agent.settings.thinkingOptionId',
    );
    _validateOptionalObjectMap(
      settings,
      'features',
      'create_agent.settings.features',
    );
  }

  if (!legacy) {
    _validateOptionalNonEmptyString(
      arguments,
      'workspaceId',
      'create_agent.workspaceId',
    );
    _validateOptionalBool(
      arguments,
      'notifyOnFinish',
      'create_agent.notifyOnFinish',
    );
    if (!agentScoped) {
      _validateOptionalBool(arguments, 'background', 'create_agent.background');
    }
    return;
  }

  if (agentScoped) {
    _validateRelationship(_requiredMap(arguments, 'relationship'));
    _validateWorkspace(_requiredMap(arguments, 'workspace'));
  } else {
    if (arguments.containsKey('relationship')) {
      _validateRelationship(_requiredMap(arguments, 'relationship'));
    }
    if (arguments.containsKey('workspace')) {
      _validateWorkspace(_requiredMap(arguments, 'workspace'));
    }
    _validateOptionalBool(arguments, 'background', 'create_agent.background');
    for (final key in const ['cwd', 'mode', 'thinking']) {
      _validateOptionalString(arguments, key, 'create_agent.$key');
    }
    _validateOptionalObjectMap(arguments, 'features', 'create_agent.features');
    for (final key in const [
      'worktreeName',
      'branchName',
      'baseBranch',
      'refName',
    ]) {
      _validateOptionalNonEmptyString(arguments, key, 'create_agent.$key');
    }
    if (arguments.containsKey('githubPrNumber')) {
      _requirePositiveInt(
        arguments,
        'githubPrNumber',
        'create_agent.githubPrNumber',
      );
    }
  }
  _validateOptionalBool(
    arguments,
    'notifyOnFinish',
    'create_agent.notifyOnFinish',
  );
}

bool hasLegacyCreateAgentPlacement(Map<String, Object?> arguments) => const [
  'relationship',
  'workspace',
  'cwd',
  'worktreeName',
  'branchName',
  'baseBranch',
  'refName',
  'githubPrNumber',
].any(arguments.containsKey);

void _validateRelationship(Map<String, Object?> relationship) {
  _requireOnlyKeys(relationship, const {'kind'}, 'create_agent.relationship');
  final kind = _requireString(
    relationship,
    'kind',
    path: 'create_agent.relationship.kind',
  );
  if (kind != 'subagent' && kind != 'detached') {
    throw FormatException(
      'create_agent.relationship.kind must be subagent or detached',
    );
  }
}

void _validateWorkspace(Map<String, Object?> workspace) {
  final kind = _requireString(
    workspace,
    'kind',
    path: 'create_agent.workspace.kind',
  );
  switch (kind) {
    case 'current':
      _requireOnlyKeys(workspace, const {
        'kind',
        'cwd',
      }, 'create_agent.workspace');
      _validateOptionalString(workspace, 'cwd', 'create_agent.workspace.cwd');
      return;
    case 'existing':
      _requireOnlyKeys(workspace, const {
        'kind',
        'workspaceId',
        'cwd',
      }, 'create_agent.workspace');
      _requireString(
        workspace,
        'workspaceId',
        nonEmpty: true,
        path: 'create_agent.workspace.workspaceId',
      );
      _validateOptionalString(workspace, 'cwd', 'create_agent.workspace.cwd');
      return;
    case 'create':
      _requireOnlyKeys(workspace, const {
        'kind',
        'source',
      }, 'create_agent.workspace');
      _validateSource(_requiredMap(workspace, 'source'));
      return;
    default:
      throw FormatException(
        'create_agent.workspace.kind must be current, existing, or create',
      );
  }
}

void _validateSource(Map<String, Object?> source) {
  final kind = _requireString(
    source,
    'kind',
    path: 'create_agent.workspace.source.kind',
  );
  switch (kind) {
    case 'directory':
      _requireOnlyKeys(source, const {
        'kind',
        'path',
      }, 'create_agent.workspace.source');
      _validateOptionalString(
        source,
        'path',
        'create_agent.workspace.source.path',
      );
      return;
    case 'worktree':
      _requireOnlyKeys(source, const {
        'kind',
        'cwd',
        'target',
      }, 'create_agent.workspace.source');
      _validateOptionalString(
        source,
        'cwd',
        'create_agent.workspace.source.cwd',
      );
      _validateWorktreeTarget(_requiredMap(source, 'target'));
      return;
    default:
      throw FormatException(
        'create_agent.workspace.source.kind must be directory or worktree',
      );
  }
}

void _validateWorktreeTarget(Map<String, Object?> target) {
  final kind = _requireString(
    target,
    'kind',
    path: 'create_agent.workspace.source.target.kind',
  );
  switch (kind) {
    case 'branch-off':
      _requireOnlyKeys(target, const {
        'kind',
        'worktreeSlug',
        'branchName',
        'baseBranch',
      }, 'create_agent.workspace.source.target');
      for (final key in const ['worktreeSlug', 'branchName', 'baseBranch']) {
        _validateOptionalNonEmptyString(
          target,
          key,
          'create_agent.workspace.source.target.$key',
        );
      }
      return;
    case 'checkout-branch':
      _requireOnlyKeys(target, const {
        'kind',
        'branch',
      }, 'create_agent.workspace.source.target');
      _requireString(
        target,
        'branch',
        nonEmpty: true,
        path: 'create_agent.workspace.source.target.branch',
      );
      return;
    case 'checkout-pr':
      _requireOnlyKeys(target, const {
        'kind',
        'githubPrNumber',
      }, 'create_agent.workspace.source.target');
      _requirePositiveInt(
        target,
        'githubPrNumber',
        'create_agent.workspace.source.target.githubPrNumber',
      );
      return;
    default:
      throw FormatException(
        'create_agent.workspace.source.target.kind must be branch-off, '
        'checkout-branch, or checkout-pr',
      );
  }
}

void _requireOnlyKeys(
  Map<String, Object?> values,
  Set<String> allowed,
  String path,
) {
  final unknown = values.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException(
      '$path contains unknown fields: ${unknown.join(', ')}',
    );
  }
}

Map<String, Object?> _requiredMap(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! Map || value.keys.any((candidate) => candidate is! String)) {
    throw FormatException('$key must be an object');
  }
  return Map<String, Object?>.from(value);
}

String _requireString(
  Map<String, Object?> values,
  String key, {
  String? path,
  bool trim = false,
  bool nonEmpty = false,
}) {
  final value = values[key];
  final label = path ?? key;
  if (value is! String) {
    throw FormatException('$label must be a string');
  }
  final normalized = trim ? value.trim() : value;
  if (nonEmpty && normalized.isEmpty) {
    throw FormatException('$label must not be empty');
  }
  return normalized;
}

void _validateOptionalString(
  Map<String, Object?> values,
  String key,
  String path,
) {
  if (!values.containsKey(key)) return;
  _requireString(values, key, path: path);
}

void _validateOptionalNonEmptyString(
  Map<String, Object?> values,
  String key,
  String path,
) {
  if (!values.containsKey(key)) return;
  _requireString(values, key, path: path, nonEmpty: true);
}

void _validateOptionalBool(
  Map<String, Object?> values,
  String key,
  String path,
) {
  if (!values.containsKey(key)) return;
  if (values[key] is! bool) {
    throw FormatException('$path must be a boolean');
  }
}

void _validateOptionalObjectMap(
  Map<String, Object?> values,
  String key,
  String path,
) {
  if (!values.containsKey(key)) return;
  final value = values[key];
  if (value is! Map || value.keys.any((candidate) => candidate is! String)) {
    throw FormatException('$path must be an object');
  }
}

void _validateOptionalStringMap(
  Map<String, Object?> values,
  String key,
  String path,
) {
  if (!values.containsKey(key)) return;
  final value = values[key];
  if (value is! Map ||
      value.keys.any((candidate) => candidate is! String) ||
      value.values.any((candidate) => candidate is! String)) {
    throw FormatException('$path must contain string values');
  }
}

void _requirePositiveInt(Map<String, Object?> values, String key, String path) {
  final value = values[key];
  if (value is! num ||
      value != value.roundToDouble() ||
      value <= 0 ||
      value > 0x7fffffff) {
    throw FormatException('$path must be a positive integer');
  }
}
