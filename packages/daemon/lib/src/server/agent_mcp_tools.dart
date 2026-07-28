import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_manager.dart';
import '../agent/timeline_projection.dart';
import '../agent/timeline_store.dart';
import '../providers/paseo/provider_catalog_registry.dart';

final class AgentMcpTools {
  AgentMcpTools({
    required AgentManager manager,
    required PaseoProviderCatalogRegistry providerCatalog,
  }) : _manager = manager,
       _providerCatalog = providerCatalog;

  final AgentManager _manager;
  final PaseoProviderCatalogRegistry _providerCatalog;

  Future<Map<String, Object?>> execute(
    String name,
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    switch (name) {
      case 'list_agents':
        return _listAgents(arguments, callerAgentId);
      case 'get_agent_status':
        final agentId = _requiredString(arguments, 'agentId');
        final snapshot = _snapshot(agentId);
        return {'status': snapshot['status'], 'snapshot': snapshot};
      case 'send_agent_prompt':
        final agentId = _requiredString(arguments, 'agentId');
        if (arguments['sessionMode'] case final String sessionMode) {
          await _manager.setModeId(agentId, sessionMode);
        } else if (arguments.containsKey('sessionMode')) {
          throw const FormatException('sessionMode must be a string');
        }
        await _manager.prompt(agentId, _requiredString(arguments, 'prompt'));
        final snapshot = _snapshot(agentId);
        return {
          'success': true,
          'status': snapshot['status'],
          'lastMessage': null,
          'permission': null,
          if (callerAgentId != null &&
              (arguments['background'] as bool? ?? true) &&
              (arguments['notifyOnFinish'] as bool? ?? true))
            'guidance':
                'You will get notified when the prompted agent finishes, '
                'errors, or needs permission. Do not poll for status; continue '
                'with other work until the notification arrives.',
        };
      case 'cancel_agent':
        final agentId = _requiredString(arguments, 'agentId');
        final agent = _manager.get(agentId);
        if (agent == null) throw StateError('Agent $agentId not found');
        final running =
            agent.runState == AgentRunState.running ||
            agent.runState == AgentRunState.awaitingPermission;
        if (running) await _manager.interrupt(agentId);
        return {'success': running};
      case 'archive_agent':
        await _manager.archive(_requiredString(arguments, 'agentId'));
        return {'success': true};
      case 'update_agent':
        return _updateAgent(arguments);
      case 'get_agent_activity':
        return _getAgentActivity(arguments);
      case 'set_agent_mode':
        final agentId = _requiredString(arguments, 'agentId');
        final modeId = _requiredString(arguments, 'modeId');
        await _manager.setModeId(agentId, modeId);
        return {'success': true, 'newMode': modeId};
      case 'list_pending_permissions':
        return _listPendingPermissions();
      case 'respond_to_permission':
        return _respondToPermission(arguments);
      case 'list_providers':
        final entries = await _providerCatalog.snapshot();
        return {
          'providers': [for (final entry in entries) _providerSummary(entry)],
        };
      case 'list_models':
        final provider = _requiredString(arguments, 'provider');
        final entries = await _providerCatalog.snapshot(providers: [provider]);
        if (entries.isEmpty) throw StateError("Provider '$provider' not found");
        return {
          'provider': provider,
          'models': [
            for (final model in entries.single.models ?? const [])
              model.toJson(),
          ],
        };
      case 'inspect_provider':
        return _inspectProvider(arguments);
      default:
        throw StateError('Unknown tool: $name');
    }
  }

  Map<String, Object?> _listAgents(
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) {
    final includeArchived = arguments['includeArchived'] as bool? ?? false;
    final explicitCwd = arguments['cwd'] as String?;
    final callerCwd = callerAgentId == null
        ? null
        : _manager.get(callerAgentId)?.cwd;
    final cwd = explicitCwd?.trim().isNotEmpty == true
        ? explicitCwd!.trim()
        : callerCwd;
    final sinceHours = _boundedInt(arguments, 'sinceHours', 48, 1, 720);
    final limit = _boundedInt(arguments, 'limit', 50, 1, 200);
    final statuses = arguments['statuses'];
    if (statuses != null &&
        (statuses is! List || statuses.any((value) => value is! String))) {
      throw const FormatException('statuses must be an array of strings');
    }
    final statusFilter = statuses == null
        ? null
        : Set<String>.from((statuses as List).cast<String>());
    final since = DateTime.now()
        .subtract(Duration(hours: sinceHours))
        .millisecondsSinceEpoch;
    final agents = <Map<String, Object?>>[];
    for (final agent in _manager.list(includeArchived: includeArchived)) {
      final snapshot = _encodeSnapshot(agent);
      if (cwd != null && !_sameOrDescendant(cwd, agent.cwd)) continue;
      if (statusFilter != null &&
          statusFilter.isNotEmpty &&
          !statusFilter.contains(snapshot['status'])) {
        continue;
      }
      if (agent.archivedAt != null && _activityTime(agent) < since) continue;
      agents.add(_listItem(snapshot));
    }
    agents.sort(_compareListItems);
    return {'agents': agents.take(limit).toList(growable: false)};
  }

  Future<Map<String, Object?>> _updateAgent(
    Map<String, Object?> arguments,
  ) async {
    final agentId = _requiredString(arguments, 'agentId');
    final settings = _optionalMap(arguments, 'settings');
    if (settings != null) {
      if (settings.containsKey('modeId')) {
        await _manager.setModeId(agentId, _requiredString(settings, 'modeId'));
      }
      if (settings.containsKey('model')) {
        await _manager.setModelId(agentId, _nullableString(settings, 'model'));
      }
      if (settings.containsKey('thinkingOptionId')) {
        await _manager.setThinkingOption(
          agentId,
          _nullableString(settings, 'thinkingOptionId'),
        );
      }
      final features = _optionalMap(settings, 'features');
      if (features != null) {
        for (final entry in features.entries) {
          await _manager.setFeature(agentId, entry.key, entry.value);
        }
      }
    }
    if (arguments['name'] case final String name) {
      await _manager.rename(agentId, name);
    } else if (arguments.containsKey('name')) {
      throw const FormatException('name must be a string');
    }
    final labels = _optionalMap(arguments, 'labels');
    if (labels != null) {
      if (labels.values.any((value) => value is! String)) {
        throw const FormatException('labels must contain string values');
      }
      await _manager.setLabels(agentId, labels.cast<String, String>());
    }
    return {'success': true};
  }

  Map<String, Object?> _getAgentActivity(Map<String, Object?> arguments) {
    final agentId = _requiredString(arguments, 'agentId');
    final canonical = _manager.fetchCanonicalTimeline(agentId);
    final rawItems = [for (final row in canonical.rows) row.item];
    final limit = arguments['limit'] == null
        ? 0
        : _boundedInt(arguments, 'limit', 0, 0, 1000000);
    final selection = selectTimelineItemsByProjectedLimit(
      items: rawItems,
      direction: 'tail',
      limit: limit,
    );
    final total = selection.totalProjected;
    final noun = total == 1 ? 'activity' : 'activities';
    final header = limit > 0 && selection.shownProjected < total
        ? 'Showing ${selection.shownProjected} of $total $noun '
              '(limited to $limit)'
        : 'Showing all $total $noun';
    return {
      'agentId': agentId,
      'updateCount': rawItems.length,
      'currentModeId': canonical.agent.currentModeId,
      'content': '$header\n\n${curateAgentActivity(selection.items)}',
    };
  }

  Map<String, Object?> _listPendingPermissions() {
    final permissions = <Map<String, Object?>>[];
    for (final agent in _manager.list(includeArchived: false)) {
      final snapshot = _encodeSnapshot(agent);
      for (final request in snapshot['pendingPermissions']! as List) {
        permissions.add({
          'agentId': agent.agentId,
          'status': snapshot['status'],
          'request': request,
        });
      }
    }
    return {'permissions': permissions};
  }

  Future<Map<String, Object?>> _respondToPermission(
    Map<String, Object?> arguments,
  ) async {
    final agentId = _requiredString(arguments, 'agentId');
    final requestId = _requiredString(arguments, 'requestId');
    if (_manager.get(agentId) == null) {
      throw StateError('Agent $agentId not found');
    }
    final ownsPendingRequest = _manager
        .fetchCanonicalTimeline(agentId)
        .rows
        .map((row) => row.item)
        .whereType<PermissionItem>()
        .any(
          (permission) =>
              permission.permissionId == requestId &&
              permission.status == PermissionStatus.pending,
        );
    if (!ownsPendingRequest) {
      throw StateError(
        'Pending permission $requestId not found for agent $agentId',
      );
    }
    final response = _requiredMap(arguments, 'response');
    final behavior = _requiredString(response, 'behavior');
    if (behavior != 'allow' && behavior != 'deny') {
      throw const FormatException('response.behavior must be allow or deny');
    }
    await _manager.respondPermission(requestId, behavior);
    return {'success': true};
  }

  Future<Map<String, Object?>> _inspectProvider(
    Map<String, Object?> arguments,
  ) async {
    final rawProvider = _requiredString(arguments, 'provider');
    final slash = rawProvider.indexOf('/');
    final provider = slash < 0 ? rawProvider : rawProvider.substring(0, slash);
    final providerModel = slash < 0 ? null : rawProvider.substring(slash + 1);
    if (provider.isEmpty || providerModel?.isEmpty == true) {
      throw const FormatException(
        'provider must be <provider> or <provider>/<model>',
      );
    }
    final cwd = arguments['cwd'] as String?;
    final entries = await _providerCatalog.snapshot(
      providers: [provider],
      cwd: cwd,
    );
    if (entries.isEmpty) throw StateError("Provider '$provider' not found");
    final entry = entries.single;
    if (!entry.enabled) throw StateError("Provider '$provider' is disabled");
    if (entry.status != ProviderCatalogStatus.ready) {
      throw StateError(entry.error ?? "Provider '$provider' is unavailable");
    }
    final settings = _optionalMap(arguments, 'settings');
    final selectedModel =
        _nullableString(settings ?? const {}, 'model') ?? providerModel;
    final features = await _manager.listFeatures(
      ListCommandsDraftConfig(
        provider: provider,
        cwd: cwd ?? p.current,
        modeId: _nullableString(settings ?? const {}, 'modeId'),
        model: selectedModel,
        thinkingOptionId: _nullableString(
          settings ?? const {},
          'thinkingOptionId',
        ),
        featureValues:
            _optionalMap(settings ?? const {}, 'features') ?? const {},
      ),
    );
    return {
      'provider': provider,
      'label': entry.label,
      'description': entry.description,
      'enabled': entry.enabled,
      'status': entry.status == ProviderCatalogStatus.ready
          ? 'available'
          : entry.status.name,
      'modes': entry.modes?.map((mode) => mode.toJson()).toList(),
      'selectedModel': selectedModel,
      'features': features.map((feature) => feature.toJson()).toList(),
    };
  }

  Map<String, Object?> _snapshot(String agentId) {
    final agent = _manager.get(agentId);
    if (agent == null) throw StateError('Agent $agentId not found');
    return _encodeSnapshot(agent);
  }

  Map<String, Object?> _encodeSnapshot(AgentSummary agent) {
    final timeline = _manager.fetchCanonicalTimeline(agent.agentId);
    return PaseoAgentSnapshotCodec.encode(
      agent,
      pendingPermissions: timeline.rows
          .map((row) => row.item)
          .whereType<PermissionItem>(),
    );
  }
}

Map<String, Object?> _providerSummary(ProviderSnapshotEntry entry) => {
  'id': entry.provider,
  'label': entry.label ?? entry.provider,
  'description': entry.description ?? '',
  'enabled': entry.enabled,
  'modes': entry.modes?.map((mode) => mode.toJson()).toList() ?? const [],
  'status': entry.status == ProviderCatalogStatus.ready
      ? 'available'
      : entry.status.name,
  if (entry.error != null) 'error': entry.error,
};

Map<String, Object?> _listItem(Map<String, Object?> snapshot) => {
  'id': snapshot['id'],
  'shortId': (snapshot['id']! as String).substring(
    0,
    (snapshot['id']! as String).length.clamp(0, 7),
  ),
  'title': snapshot['title'],
  'provider': snapshot['provider'],
  'model': (snapshot['runtimeInfo'] as Map?)?['model'] ?? snapshot['model'],
  'thinkingOptionId': snapshot['thinkingOptionId'],
  'effectiveThinkingOptionId': snapshot['effectiveThinkingOptionId'],
  'status': snapshot['status'],
  'cwd': snapshot['cwd'],
  'createdAt': snapshot['createdAt'],
  'updatedAt': snapshot['updatedAt'],
  'lastUserMessageAt': snapshot['lastUserMessageAt'],
  'archivedAt': snapshot['archivedAt'],
  'requiresAttention': snapshot['requiresAttention'] ?? false,
  'attentionReason': snapshot['attentionReason'],
  'attentionTimestamp': snapshot['attentionTimestamp'],
  'labels': snapshot['labels'],
  if (snapshot['providerUnavailable'] == true) 'providerUnavailable': true,
};

int _compareListItems(Map<String, Object?> left, Map<String, Object?> right) {
  final attention =
      (right['requiresAttention'] == true ? 1 : 0) -
      (left['requiresAttention'] == true ? 1 : 0);
  if (attention != 0) return attention;
  const order = {
    'running': 0,
    'initializing': 1,
    'idle': 2,
    'error': 3,
    'closed': 4,
  };
  final status =
      (order[left['status']] ?? 999) - (order[right['status']] ?? 999);
  if (status != 0) return status;
  return _jsonTime(right['updatedAt']).compareTo(_jsonTime(left['updatedAt']));
}

int _activityTime(AgentSummary agent) {
  for (final value in [
    agent.attentionTimestamp,
    agent.lastUserMessageAt,
    agent.updatedAt,
    agent.archivedAt,
  ]) {
    final parsed = value == null ? null : DateTime.tryParse(value);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
  }
  return agent.createdAtMs;
}

int _jsonTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0 : 0;

bool _sameOrDescendant(String parent, String candidate) {
  final root = p.normalize(p.absolute(parent));
  final child = p.normalize(p.absolute(candidate));
  final insensitive = p.style == p.Style.windows;
  final normalizedRoot = insensitive ? root.toLowerCase() : root;
  final normalizedChild = insensitive ? child.toLowerCase() : child;
  return normalizedChild == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedChild);
}

String curateAgentActivity(List<TimelineItem> items) {
  final lines = <String>[];
  for (final entry in projectTimelineRows([
    for (var index = 0; index < items.length; index++)
      TimelineRow(seq: index + 1, timestamp: '', item: items[index]),
  ], projected: true)) {
    switch (entry.item) {
      case UserMessageItem(:final text):
        if (text.trim().isNotEmpty) lines.add('[User] ${text.trim()}');
      case AssistantMessageItem(:final text):
        if (text.trim().isNotEmpty) lines.add(text.trim());
      case ReasoningItem(:final text):
        if (text.trim().isNotEmpty) lines.add('[Thought] ${text.trim()}');
      case ToolCallItem(:final toolName, :final detail):
        lines.add(_toolSummary(toolName, detail));
      case TodoItem(:final items):
        lines.add(
          '[Tasks]\n${items.map((item) => '- [${item.completed ? 'x' : ' '}] ${item.text}').join('\n')}',
        );
      case ErrorItem(:final message):
        lines.add('[Error] $message');
      case CompactionItem():
        lines.add('[Compacted]');
      default:
        break;
    }
  }
  return lines.isEmpty ? 'No activity to display.' : lines.join('\n\n');
}

String _toolSummary(String toolName, ToolCallDetail detail) {
  switch (detail) {
    case ShellDetail(:final command):
      return '[Shell] $command';
    case ReadDetail(:final path):
      return '[Read] $path';
    case EditDetail(:final path):
      return '[Edit] $path';
    case WriteDetail(:final path):
      return '[Write] $path';
    case SearchDetail(:final query, :final path):
      return '[Search] $query${path == null ? '' : ' in $path'}';
    case FetchDetail(:final url):
      return '[Fetch] $url';
    case PlainTextDetail(:final label, :final text):
      return '[${label?.trim().isNotEmpty == true ? label : toolName}] ${text ?? ''}'
          .trimRight();
    case SubAgentDetail(:final subAgentType, :final description, :final log):
      final summary =
          '[${subAgentType?.trim().isNotEmpty == true ? subAgentType : toolName}] '
                  '${description ?? ''}'
              .trimRight();
      return log.trim().isEmpty ? summary : '$summary\n${log.trim()}';
    default:
      return '[${_displayToolName(toolName)}]';
  }
}

String _displayToolName(String value) => value
    .replaceAll(RegExp(r'[_-]+'), ' ')
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

String _requiredString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key is required');
  }
  return value.trim();
}

String? _nullableString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value.trim().isEmpty ? null : value.trim();
}

Map<String, Object?> _requiredMap(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?>? _optionalMap(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

int _boundedInt(
  Map<String, Object?> values,
  String key,
  int fallback,
  int minimum,
  int maximum,
) {
  final value = values[key];
  if (value == null) return fallback;
  if (value is! num || value != value.roundToDouble()) {
    throw FormatException('$key must be an integer');
  }
  final integer = value.toInt();
  if (integer < minimum || integer > maximum) {
    throw FormatException('$key must be between $minimum and $maximum');
  }
  return integer;
}
