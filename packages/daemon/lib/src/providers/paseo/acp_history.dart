import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

/// Builds the authoritative timeline emitted by ACP `session/load`.
///
/// ACP history arrives as ordinary `session/update` notifications while the
/// load request is pending. The projector coalesces chunks into stable
/// timeline items before [AgentManager] replaces its local epoch.
final class AcpHistoryProjector {
  AcpHistoryProjector({Uuid uuid = const Uuid()}) : _uuid = uuid;

  final Uuid _uuid;
  final List<TimelineItem> _items = [];
  final Map<String, int> _itemIndex = {};
  final Map<String, _HistoryToolSnapshot> _tools = {};

  String? _pendingUserId;
  StringBuffer? _pendingUserText;
  String? _fallbackAssistantId;
  String? _fallbackReasoningId;
  bool _finished = false;

  void addUpdate(Map<String, Object?> update) {
    if (_finished) {
      throw StateError('ACP history projector is already finished');
    }
    final type = update['sessionUpdate'];
    if (type == 'user_message_chunk') {
      _addUserChunk(update);
      return;
    }

    _flushUser();
    switch (type) {
      case 'agent_message_chunk':
        _fallbackReasoningId = null;
        final text = acpContentBlockText(update['content']);
        if (text.isEmpty) return;
        final explicitId = update['messageId'];
        final id = explicitId is String && explicitId.isNotEmpty
            ? explicitId
            : (_fallbackAssistantId ??= _uuid.v4());
        _appendAssistant(id, text);
      case 'agent_thought_chunk':
        _fallbackAssistantId = null;
        final text = acpContentBlockText(update['content']);
        if (text.isEmpty) return;
        final explicitId = update['messageId'];
        final id = explicitId is String && explicitId.isNotEmpty
            ? explicitId
            : (_fallbackReasoningId ??= _uuid.v4());
        _appendReasoning(id, text);
      case 'tool_call':
      case 'tool_call_update':
        _fallbackAssistantId = null;
        _fallbackReasoningId = null;
        _upsertTool(update);
      case 'plan':
        _fallbackAssistantId = null;
        _fallbackReasoningId = null;
        final entries = _listOfMaps(update['entries']);
        _upsert(
          TodoItem(
            id: _string(update['id']) ?? _uuid.v4(),
            items: [
              for (final entry in entries)
                TodoEntry(
                  text: _string(entry['content']) ?? '',
                  completed: entry['status'] == 'completed',
                ),
            ],
          ),
        );
    }
  }

  List<TimelineItem> finish() {
    if (!_finished) {
      _flushUser();
      _finished = true;
    }
    return List.unmodifiable(_items);
  }

  void _addUserChunk(Map<String, Object?> update) {
    _fallbackAssistantId = null;
    _fallbackReasoningId = null;
    final text = acpContentBlockText(update['content']);
    if (text.isEmpty) return;
    final messageId = _string(update['messageId']);
    if (_pendingUserId != null &&
        messageId != null &&
        _pendingUserId != messageId) {
      _flushUser();
    }
    _pendingUserId ??= messageId;
    (_pendingUserText ??= StringBuffer()).write(text);
  }

  void _flushUser() {
    final text = _pendingUserText?.toString();
    if (text == null) return;
    _upsert(UserMessageItem(id: _pendingUserId ?? _uuid.v4(), text: text));
    _pendingUserId = null;
    _pendingUserText = null;
  }

  void _appendAssistant(String id, String chunk) {
    final index = _itemIndex[id];
    final previous = index == null ? null : _items[index];
    _upsert(
      AssistantMessageItem(
        id: id,
        text: previous is AssistantMessageItem
            ? '${previous.text}$chunk'
            : chunk,
        complete: true,
      ),
    );
  }

  void _appendReasoning(String id, String chunk) {
    final index = _itemIndex[id];
    final previous = index == null ? null : _items[index];
    _upsert(
      ReasoningItem(
        id: id,
        text: previous is ReasoningItem ? '${previous.text}$chunk' : chunk,
        complete: true,
      ),
    );
  }

  void _upsertTool(Map<String, Object?> update) {
    final id = _string(update['toolCallId']);
    if (id == null) return;
    final previous = _tools[id];
    final rawInput = update.containsKey('rawInput')
        ? (_map(update['rawInput']) ?? const <String, Object?>{})
        : previous?.rawInput ?? const <String, Object?>{};
    final snapshot = _HistoryToolSnapshot(
      title: _string(update['title']) ?? previous?.title ?? 'Tool',
      kind: _string(update['kind']) ?? previous?.kind,
      status:
          _toolStatus(update['status']) ??
          previous?.status ??
          ToolCallStatus.pending,
      rawInput: rawInput,
      rawOutput: update.containsKey('rawOutput')
          ? update['rawOutput']
          : previous?.rawOutput,
    );
    _tools[id] = snapshot;
    final error = snapshot.status == ToolCallStatus.error
        ? _errorMessage(snapshot.rawOutput)
        : null;
    _upsert(
      ToolCallItem(
        id: id,
        toolName: snapshot.kind ?? snapshot.title,
        status: snapshot.status,
        detail: GenericDetail(
          input: snapshot.rawInput,
          output: snapshot.rawOutput,
          errorMessage: error,
        ),
        errorMessage: error,
        metadata: {
          if (snapshot.kind != null) 'kind': snapshot.kind,
          'title': snapshot.title,
        },
      ),
    );
  }

  void _upsert(TimelineItem item) {
    final index = _itemIndex[item.id];
    if (index == null) {
      _itemIndex[item.id] = _items.length;
      _items.add(item);
    } else {
      _items[index] = item;
    }
  }
}

final class _HistoryToolSnapshot {
  const _HistoryToolSnapshot({
    required this.title,
    required this.kind,
    required this.status,
    required this.rawInput,
    required this.rawOutput,
  });

  final String title;
  final String? kind;
  final ToolCallStatus status;
  final Map<String, Object?> rawInput;
  final Object? rawOutput;
}

String acpContentBlockText(Object? value) {
  final content = _map(value);
  return switch (content?['type']) {
    'text' => _string(content?['text']) ?? '',
    'resource_link' =>
      _string(content?['title']) ?? _string(content?['uri']) ?? '',
    'resource' => switch (_map(content?['resource'])) {
      final resource? when resource['text'] is String =>
        resource['text']! as String,
      final resource? =>
        '[resource:${_string(resource['mimeType']) ?? 'binary'}]',
      null => '',
    },
    'image' => '[image]',
    'audio' => '[audio]',
    _ => '',
  };
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Map<String, Object?>> _listOfMaps(Object? value) => value is List
    ? value.map(_map).whereType<Map<String, Object?>>().toList()
    : const [];

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

ToolCallStatus? _toolStatus(Object? value) => switch (value) {
  'pending' => ToolCallStatus.pending,
  'in_progress' => ToolCallStatus.running,
  'completed' => ToolCallStatus.success,
  'failed' => ToolCallStatus.error,
  _ => null,
};

String _errorMessage(Object? value) {
  final record = _map(value);
  return _string(record?['message']) ?? value?.toString() ?? 'Tool failed';
}
