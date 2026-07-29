import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent_attachment.dart';

enum GitSetupAction { branchOff, checkout }

final class ChangeRequestCheckoutSource {
  const ChangeRequestCheckoutSource({
    required this.number,
    this.forge,
    this.projectPath,
  });

  final int number;
  final String? forge;
  final String? projectPath;

  factory ChangeRequestCheckoutSource.fromJson(Map<String, Object?> json) {
    if (json['kind'] != 'change_request') {
      throw const FormatException('checkoutSource.kind must be change_request');
    }
    return ChangeRequestCheckoutSource(
      number: _requiredPositiveInt(json, 'number'),
      forge: _optionalString(json, 'forge', allowEmpty: true),
      projectPath: _optionalString(json, 'projectPath', allowEmpty: true),
    );
  }

  Map<String, Object?> toJson() => {
    'kind': 'change_request',
    if (forge != null) 'forge': forge,
    'number': number,
    if (projectPath != null) 'projectPath': projectPath,
  };
}

/// Frozen Paseo 0.2.0 legacy git setup accepted by
/// `create_agent_request`.
final class GitSetupOptions {
  const GitSetupOptions({
    this.baseBranch,
    this.createNewBranch,
    this.newBranchName,
    this.createWorktree,
    this.worktreeSlug,
    this.refName,
    this.action,
    this.checkoutSource,
    this.githubPrNumber,
  });

  final String? baseBranch;
  final bool? createNewBranch;
  final String? newBranchName;
  final bool? createWorktree;
  final String? worktreeSlug;
  final String? refName;
  final GitSetupAction? action;
  final ChangeRequestCheckoutSource? checkoutSource;
  final int? githubPrNumber;

  factory GitSetupOptions.fromJson(Map<String, Object?> json) =>
      GitSetupOptions(
        baseBranch: _optionalString(json, 'baseBranch', allowEmpty: true),
        createNewBranch: _optionalBool(json, 'createNewBranch'),
        newBranchName: _optionalString(json, 'newBranchName', allowEmpty: true),
        createWorktree: _optionalBool(json, 'createWorktree'),
        worktreeSlug: _optionalString(json, 'worktreeSlug', allowEmpty: true),
        refName: _optionalString(json, 'refName'),
        action: switch (json['action']) {
          null => null,
          'branch-off' => GitSetupAction.branchOff,
          'checkout' => GitSetupAction.checkout,
          final value => throw FormatException(
            'Unknown git setup action: $value',
          ),
        },
        checkoutSource: json['checkoutSource'] == null
            ? null
            : ChangeRequestCheckoutSource.fromJson(
                _requiredMap(json, 'checkoutSource'),
              ),
        githubPrNumber: json['githubPrNumber'] == null
            ? null
            : _requiredPositiveInt(json, 'githubPrNumber'),
      );

  Map<String, Object?> toJson() => {
    if (baseBranch != null) 'baseBranch': baseBranch,
    if (createNewBranch != null) 'createNewBranch': createNewBranch,
    if (newBranchName != null) 'newBranchName': newBranchName,
    if (createWorktree != null) 'createWorktree': createWorktree,
    if (worktreeSlug != null) 'worktreeSlug': worktreeSlug,
    if (refName != null) 'refName': refName,
    if (action != null)
      'action': action == GitSetupAction.branchOff ? 'branch-off' : 'checkout',
    if (checkoutSource != null) 'checkoutSource': checkoutSource!.toJson(),
    if (githubPrNumber != null) 'githubPrNumber': githubPrNumber,
  };
}

/// Frozen Paseo 0.2.0 session configuration sent with
/// `create_agent_request`.
final class CreateAgentSessionConfig {
  const CreateAgentSessionConfig({
    required this.provider,
    required this.cwd,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.featureValues,
    this.title,
    this.hasTitle = false,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.webSearch,
    this.extra,
    this.systemPrompt,
    this.mcpServers,
  });

  final String provider;
  final String cwd;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final Map<String, Object?>? featureValues;
  final String? title;
  final bool hasTitle;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final bool? webSearch;
  final Map<String, Object?>? extra;
  final String? systemPrompt;
  final Map<String, Object?>? mcpServers;

  factory CreateAgentSessionConfig.fromJson(Map<String, Object?> json) {
    final title = json['title'];
    if (title != null && title is! String) {
      throw const FormatException('config.title must be a string or null');
    }
    if (title is String && title.trim().isEmpty) {
      throw const FormatException('config.title must not be empty');
    }
    return CreateAgentSessionConfig(
      provider: _requiredString(json, 'provider'),
      cwd: _requiredString(json, 'cwd'),
      modeId: _optionalString(json, 'modeId'),
      model: _optionalString(json, 'model'),
      thinkingOptionId: _optionalString(json, 'thinkingOptionId'),
      featureValues: _optionalMap(json, 'featureValues'),
      title: title as String?,
      hasTitle: json.containsKey('title'),
      approvalPolicy: _optionalString(json, 'approvalPolicy'),
      sandboxMode: _optionalString(json, 'sandboxMode'),
      networkAccess: _optionalBool(json, 'networkAccess'),
      webSearch: _optionalBool(json, 'webSearch'),
      extra: _optionalMap(json, 'extra'),
      systemPrompt: _optionalString(json, 'systemPrompt'),
      mcpServers: _optionalMap(json, 'mcpServers'),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'cwd': cwd,
    if (modeId != null) 'modeId': modeId,
    if (model != null) 'model': model,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
    if (featureValues != null) 'featureValues': featureValues,
    if (hasTitle) 'title': title,
    if (approvalPolicy != null) 'approvalPolicy': approvalPolicy,
    if (sandboxMode != null) 'sandboxMode': sandboxMode,
    if (networkAccess != null) 'networkAccess': networkAccess,
    if (webSearch != null) 'webSearch': webSearch,
    if (extra != null) 'extra': extra,
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    if (mcpServers != null) 'mcpServers': mcpServers,
  };
}

/// Frozen Paseo 0.2.0 `create_agent_request` wire contract.
final class CreateAgentRequest {
  const CreateAgentRequest({
    required this.requestId,
    required this.config,
    this.env,
    this.workspaceId,
    this.callerAgentId,
    this.worktreeName,
    this.initialPrompt,
    this.clientMessageId,
    this.outputSchema,
    this.images = const [],
    this.attachments = const [],
    this.git,
    this.worktree,
    this.autoArchive,
    this.labels = const {},
  });

  static const type = 'create_agent_request';

  final String requestId;
  final CreateAgentSessionConfig config;
  final Map<String, String>? env;
  final String? workspaceId;
  final String? callerAgentId;
  final String? worktreeName;
  final String? initialPrompt;
  final String? clientMessageId;
  final Map<String, Object?>? outputSchema;
  final List<AgentPromptImage> images;
  final List<AgentAttachment> attachments;
  final GitSetupOptions? git;
  final CreateAgentWorktreeTarget? worktree;
  final bool? autoArchive;
  final Map<String, String> labels;

  factory CreateAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected create_agent_request');
    }
    final rawImages = json['images'];
    if (rawImages != null && rawImages is! List) {
      throw const FormatException('images must be an array');
    }
    final images = <AgentPromptImage>[];
    for (final raw in rawImages is List ? rawImages : const []) {
      final image = AgentPromptImage.tryFromJson(raw);
      if (image == null) throw const FormatException('Invalid prompt image');
      images.add(image);
    }
    final labels = _optionalStringMap(json, 'labels') ?? const {};
    final rawWorktree = json['worktree'];
    if (rawWorktree != null && rawWorktree is! Map) {
      throw const FormatException('worktree must be an object');
    }
    final rawGit = json['git'];
    if (rawGit != null && rawGit is! Map) {
      throw const FormatException('git must be an object');
    }
    return CreateAgentRequest(
      requestId: _requiredString(json, 'requestId'),
      config: CreateAgentSessionConfig.fromJson(_requiredMap(json, 'config')),
      env: _optionalStringMap(json, 'env'),
      workspaceId: _optionalString(json, 'workspaceId'),
      callerAgentId: _optionalString(json, 'callerAgentId'),
      worktreeName: _optionalString(json, 'worktreeName', allowEmpty: true),
      initialPrompt: _optionalString(json, 'initialPrompt', allowEmpty: true),
      clientMessageId: _optionalString(json, 'clientMessageId'),
      outputSchema: _optionalMap(json, 'outputSchema'),
      images: List.unmodifiable(images),
      attachments: List.unmodifiable(
        AgentAttachment.normalizeList(json['attachments']),
      ),
      git: rawGit == null
          ? null
          : GitSetupOptions.fromJson(Map<String, Object?>.from(rawGit as Map)),
      worktree: rawWorktree == null
          ? null
          : CreateAgentWorktreeTarget.fromJson(
              Map<String, Object?>.from(rawWorktree as Map),
            ),
      autoArchive: _optionalBool(json, 'autoArchive'),
      labels: Map.unmodifiable(labels),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'config': config.toJson(),
    if (env != null) 'env': env,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (callerAgentId != null) 'callerAgentId': callerAgentId,
    if (worktreeName != null) 'worktreeName': worktreeName,
    if (initialPrompt != null) 'initialPrompt': initialPrompt,
    if (clientMessageId != null) 'clientMessageId': clientMessageId,
    if (outputSchema != null) 'outputSchema': outputSchema,
    if (images.isNotEmpty)
      'images': [for (final image in images) image.toJson()],
    'attachments': [for (final attachment in attachments) attachment.toJson()],
    if (git != null) 'git': git!.toJson(),
    if (worktree != null) 'worktree': worktree!.toJson(),
    if (autoArchive != null) 'autoArchive': autoArchive,
    'labels': labels,
    'requestId': requestId,
  };
}

sealed class CreateAgentStatus {
  const CreateAgentStatus({required this.requestId});

  final String requestId;

  factory CreateAgentStatus.fromJson(Map<String, Object?> json) {
    if (json['type'] != 'status') {
      throw const FormatException('Expected create agent status');
    }
    final payload = _requiredMap(json, 'payload');
    return switch (payload['status']) {
      'agent_created' => AgentCreatedStatus.fromPayload(payload),
      'agent_create_failed' => AgentCreateFailedStatus.fromPayload(payload),
      final status => throw FormatException(
        'Unknown create agent status: $status',
      ),
    };
  }
}

final class AgentCreatedStatus extends CreateAgentStatus {
  const AgentCreatedStatus({
    required super.requestId,
    required this.agentId,
    required this.agent,
  });

  final String agentId;
  final Map<String, Object?> agent;

  factory AgentCreatedStatus.fromPayload(Map<String, Object?> payload) {
    final agent = _requiredMap(payload, 'agent');
    PaseoAgentSnapshotCodec.decode(agent);
    return AgentCreatedStatus(
      requestId: _requiredString(payload, 'requestId'),
      agentId: _requiredString(payload, 'agentId'),
      agent: Map.unmodifiable(agent),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'status',
    'payload': {
      'status': 'agent_created',
      'agentId': agentId,
      'requestId': requestId,
      'agent': agent,
    },
  };
}

final class AgentCreateFailedStatus extends CreateAgentStatus {
  const AgentCreateFailedStatus({
    required super.requestId,
    required this.error,
    this.errorCode,
  });

  final String error;
  final String? errorCode;

  factory AgentCreateFailedStatus.fromPayload(Map<String, Object?> payload) =>
      AgentCreateFailedStatus(
        requestId: _requiredString(payload, 'requestId'),
        error: _requiredString(payload, 'error'),
        errorCode: _optionalString(payload, 'errorCode'),
      );

  Map<String, Object?> toJson() => {
    'type': 'status',
    'payload': {
      'status': 'agent_create_failed',
      'requestId': requestId,
      'error': error,
      if (errorCode != null) 'errorCode': errorCode,
    },
  };
}

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

String? _optionalString(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || (!allowEmpty && value.isEmpty)) {
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

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, String>? _optionalStringMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map ||
      value.keys.any((entry) => entry is! String) ||
      value.values.any((entry) => entry is! String)) {
    throw FormatException('$key must contain string values');
  }
  return Map<String, String>.from(value);
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}
