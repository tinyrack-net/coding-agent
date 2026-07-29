import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_output.dart';
import 'schedule_command.dart'
    show resolveScheduleDaemonEndpoint, ScheduleDaemonEndpoint;

const chatRpcTimeout = Duration(seconds: 30);
const chatWaitPreflightTimeout = Duration(seconds: 2);

abstract interface class ChatRpcClient {
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  });
  Future<void> close();
}

typedef ChatClientConnector =
    Future<ChatRpcClient> Function({
      required String? host,
      required String? home,
      required Map<String, String> environment,
    });

Future<int> runChatCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  ChatClientConnector connect = connectChatClient,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final out = writeOutput ?? stdout.write;
  final err = writeError ?? stderr.write;
  final parsed = _parseChatInvocation(arguments);
  if (parsed case _ChatParseFailure(:final message)) {
    err('$message\n$_chatUsage\n');
    return 64;
  }
  final invocation = parsed as _ChatInvocation;
  final env = environment ?? Platform.environment;
  ChatRpcClient? client;
  try {
    client = await connect(
      host: invocation.host,
      home: invocation.home,
      environment: env,
    );
    final result = await _executeChat(client, invocation, env);
    _renderChatResult(result, options: invocation.output, write: out);
    return 0;
  } on Object catch (error) {
    final commandError = _toChatCommandError(invocation.action, error);
    err(
      '${renderCliError(code: commandError.code, message: commandError.message, details: commandError.details, options: invocation.output)}\n',
    );
    return 1;
  } finally {
    await client?.close();
  }
}

Future<_ChatResult> _executeChat(
  ChatRpcClient client,
  _ChatInvocation invocation,
  Map<String, String> environment,
) async {
  final requestId = 'chat_${DateTime.now().microsecondsSinceEpoch}';
  switch (invocation.action) {
    case 'create':
      final payload = await client.request(
        ChatCreateRequest(
          requestId: requestId,
          name: invocation.room!,
          purpose: invocation.purpose,
        ).toJson(),
      );
      return _ChatResult.rooms([
        ChatRoomDetail.fromJson(_requiredMap(payload, 'room')),
      ], isList: false);
    case 'ls':
      final payload = await client.request(
        ChatListRequest(requestId: requestId).toJson(),
      );
      return _ChatResult.rooms(
        _mapList(payload, 'rooms', ChatRoomDetail.fromJson),
        isList: true,
      );
    case 'inspect':
    case 'delete':
      final payload = await client.request(
        ChatRoomRequest(
          requestId: requestId,
          typeValue: invocation.action == 'inspect'
              ? ChatRoomRequest.inspectType
              : ChatRoomRequest.deleteType,
          room: invocation.room!,
        ).toJson(),
      );
      return _ChatResult.rooms([
        ChatRoomDetail.fromJson(_requiredMap(payload, 'room')),
      ], isList: false);
    case 'post':
      final payload = await client.request(
        ChatPostRequest(
          requestId: requestId,
          room: invocation.room!,
          body: invocation.message!,
          authorAgentId: _authorAgentId(environment),
          replyToMessageId: invocation.replyTo,
        ).toJson(),
      );
      final messages = [ChatMessage.fromJson(_requiredMap(payload, 'message'))];
      return _ChatResult.messages(
        await _attachAgentNames(client, messages, bestEffort: true),
        isList: false,
      );
    case 'read':
      final payload = await client.request(
        ChatReadRequest(
          requestId: requestId,
          room: invocation.room!,
          limit: invocation.limit,
          since: invocation.since,
          authorAgentId: invocation.agentId,
        ).toJson(),
      );
      final messages = _mapList(payload, 'messages', ChatMessage.fromJson);
      return _ChatResult.messages(
        await _attachAgentNames(client, messages, bestEffort: true),
        isList: true,
      );
    case 'wait':
      final deadline = invocation.timeout == null
          ? null
          : DateTime.now().add(invocation.timeout!);
      Duration? remaining() {
        if (deadline == null) return null;
        final value = deadline.difference(DateTime.now());
        return value <= Duration.zero ? const Duration(milliseconds: 1) : value;
      }

      final latest = await client.request(
        ChatReadRequest(
          requestId: '${requestId}_read',
          room: invocation.room!,
          limit: 1,
        ).toJson(),
        timeout: deadline == null
            ? null
            : _minimum(remaining()!, chatWaitPreflightTimeout),
      );
      final prior = _mapList(latest, 'messages', ChatMessage.fromJson);
      final timeout = remaining() ?? invocation.timeout;
      final payload = await client.request(
        ChatWaitRequest(
          requestId: requestId,
          room: invocation.room!,
          afterMessageId: prior.firstOrNull?.id,
          timeoutMs: timeout?.inMilliseconds,
        ).toJson(),
        timeout: timeout == null
            ? const Duration(days: 365)
            : timeout + const Duration(seconds: 2),
      );
      final messages = _mapList(payload, 'messages', ChatMessage.fromJson);
      return _ChatResult.messages(
        await _attachAgentNames(client, messages, bestEffort: true),
        isList: true,
      );
    default:
      throw StateError('Unsupported chat action ${invocation.action}');
  }
}

Future<List<_NamedChatMessage>> _attachAgentNames(
  ChatRpcClient client,
  List<ChatMessage> messages, {
  required bool bestEffort,
}) async {
  if (messages.isEmpty) return const [];
  try {
    final payload = await client.request({
      'type': FetchAgentsRequest.type,
      'requestId': 'chat_agents_${DateTime.now().microsecondsSinceEpoch}',
      'filter': {'includeArchived': true},
    });
    final entries = payload['entries'];
    final names = <String, String>{};
    if (entries is List) {
      for (final value in entries) {
        if (value is! Map) continue;
        final agent = value['agent'];
        if (agent is! Map) continue;
        final id = agent['id'] ?? agent['agentId'];
        final title = agent['title'];
        if (id is String && title is String && title.trim().isNotEmpty) {
          names[id] = title.trim();
        }
      }
    }
    return [
      for (final message in messages)
        _NamedChatMessage(
          message,
          authorName: names[message.authorAgentId],
          mentionLabels: [
            for (final id in message.mentionAgentIds)
              names[id] == null ? id : '${names[id]} ($id)',
          ],
        ),
    ];
  } on Object {
    if (!bestEffort) rethrow;
    return [for (final message in messages) _NamedChatMessage(message)];
  }
}

Future<ChatRpcClient> connectChatClient({
  required String? host,
  required String? home,
  required Map<String, String> environment,
}) async {
  final config = loadDaemonRuntimeConfig(home: home, environment: environment);
  final endpoint = resolveScheduleDaemonEndpoint(
    config,
    hostOverride: host,
    environment: environment,
  );
  try {
    return await _ChatSocketClient.connect(endpoint);
  } on Object catch (error) {
    throw _ChatCommandException(
      'DAEMON_NOT_RUNNING',
      'Cannot connect to daemon at ${endpoint.webSocketUri}: $error',
      details: 'Start the daemon with: coding-agent daemon start',
    );
  }
}

final class _ChatSocketClient implements ChatRpcClient {
  _ChatSocketClient(this._socket, this._frames);
  final WebSocket _socket;
  final StreamIterator<dynamic> _frames;

  static Future<_ChatSocketClient> connect(
    ScheduleDaemonEndpoint endpoint,
  ) async {
    final socket = await WebSocket.connect(
      endpoint.webSocketUri.toString(),
      protocols: endpoint.password == null
          ? null
          : ['tinyrack.bearer.${endpoint.password}'],
      compression: CompressionOptions.compressionOff,
    ).timeout(chatRpcTimeout);
    final frames = StreamIterator<dynamic>(socket);
    socket.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'coding-agent-chat-cli',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await _nextChatMessage(
      frames,
      (message) => message['status'] == 'server_info',
      timeout: chatRpcTimeout,
      allowEnvelope: false,
    );
    return _ChatSocketClient(socket, frames);
  }

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) async {
    _socket.add(jsonEncode({'type': 'session', 'message': request}));
    final requestId = request['requestId'];
    final response = await _nextChatMessage(_frames, (message) {
      final payload = message['payload'];
      return payload is Map && payload['requestId'] == requestId;
    }, timeout: timeout ?? chatRpcTimeout);
    final payload = response['payload'];
    if (response['type'] == 'rpc_error') {
      final map = payload is Map ? payload : const {};
      throw _ChatRpcException(
        '${map['code'] ?? 'CHAT_REQUEST_FAILED'}',
        '${map['error'] ?? 'Chat RPC failed'}',
      );
    }
    if (payload is! Map) throw StateError('Invalid chat response');
    return Map<String, Object?>.from(payload);
  }

  @override
  Future<void> close() async {
    await _frames.cancel();
    await _socket.close();
  }
}

Future<Map<String, Object?>> _nextChatMessage(
  StreamIterator<dynamic> frames,
  bool Function(Map<String, Object?> message) predicate, {
  required Duration timeout,
  bool allowEnvelope = true,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (!await frames.moveNext().timeout(remaining)) {
      throw StateError('Daemon closed during chat request');
    }
    final frame = frames.current;
    if (frame is! String) continue;
    final decoded = jsonDecode(frame);
    if (decoded is! Map<String, Object?>) continue;
    final candidate =
        allowEnvelope &&
            decoded['type'] == 'session' &&
            decoded['message'] is Map
        ? (decoded['message'] as Map).cast<String, Object?>()
        : decoded;
    if (predicate(candidate)) return candidate;
  }
  throw TimeoutException('Daemon chat request timed out');
}

sealed class _ChatParsed {}

final class _ChatParseFailure extends _ChatParsed {
  _ChatParseFailure(this.message);
  final String message;
}

final class _ChatInvocation extends _ChatParsed {
  _ChatInvocation(this.action);
  final String action;
  String? room;
  String? message;
  String? purpose;
  String? replyTo;
  String? agentId;
  String? host;
  String? home;
  int? limit;
  String? since;
  Duration? timeout;
  String format = 'table';
  bool json = false;
  bool quiet = false;
  bool headers = true;
  bool color = true;

  CliOutputOptions get output => CliOutputOptions(
    format: json ? 'json' : format,
    quiet: quiet,
    noHeaders: !headers,
    noColor: !color,
  );
}

_ChatParsed _parseChatInvocation(List<String> arguments) {
  if (arguments.isEmpty) return _ChatParseFailure('Missing chat command');
  const actions = {'create', 'ls', 'inspect', 'delete', 'post', 'read', 'wait'};
  final result = _ChatInvocation(arguments.first);
  if (!actions.contains(result.action)) {
    return _ChatParseFailure('Unknown chat command: ${result.action}');
  }
  final positionals = <String>[];
  for (var index = 1; index < arguments.length; index++) {
    final argument = arguments[index];
    String? next() => index + 1 < arguments.length ? arguments[++index] : null;
    switch (argument) {
      case '--json':
        result.json = true;
      case '-o' || '--format':
        final raw = next();
        if (raw == null) {
          return _ChatParseFailure('$argument requires a value');
        }
        try {
          result.format = normalizeCliOutputFormat(raw);
        } on FormatException catch (error) {
          return _ChatParseFailure(error.message);
        }
      case '-q' || '--quiet':
        result.quiet = true;
      case '--no-headers':
        result.headers = false;
      case '--no-color':
        result.color = false;
      case '--host':
        result.host = next();
        if (result.host == null)
          return _ChatParseFailure('--host requires a value');
      case '--home':
        result.home = next();
        if (result.home == null)
          return _ChatParseFailure('--home requires a value');
      case '--purpose':
        result.purpose = next();
        if (result.purpose == null) {
          return _ChatParseFailure('--purpose requires a value');
        }
      case '--reply-to':
        result.replyTo = next();
        if (result.replyTo == null) {
          return _ChatParseFailure('--reply-to requires a value');
        }
      case '--agent':
        result.agentId = next();
        if (result.agentId == null) {
          return _ChatParseFailure('--agent requires a value');
        }
      case '--limit':
        final raw = next();
        result.limit = raw == null ? null : int.tryParse(raw);
        if (result.limit == null || result.limit! < 0) {
          return _ChatParseFailure(
            'Invalid --limit value. Use a non-negative integer.',
          );
        }
      case '--since':
        final raw = next();
        if (raw == null) return _ChatParseFailure('--since requires a value');
        try {
          result.since = _parseSince(raw);
        } on FormatException catch (error) {
          return _ChatParseFailure(error.message);
        }
      case '--timeout':
        final raw = next();
        if (raw == null) return _ChatParseFailure('--timeout requires a value');
        try {
          result.timeout = _parseDuration(raw, positive: true);
        } on FormatException catch (error) {
          return _ChatParseFailure(error.message);
        }
      default:
        if (argument.startsWith('--format=')) {
          try {
            result.format = normalizeCliOutputFormat(
              argument.substring('--format='.length),
            );
          } on FormatException catch (error) {
            return _ChatParseFailure(error.message);
          }
          continue;
        }
        if (argument.startsWith('-o') && argument.length > 2) {
          try {
            result.format = normalizeCliOutputFormat(argument.substring(2));
          } on FormatException catch (error) {
            return _ChatParseFailure(error.message);
          }
          continue;
        }
        if (argument.startsWith('-')) {
          return _ChatParseFailure('Unknown option: $argument');
        }
        positionals.add(argument);
    }
  }
  final expected = result.action == 'ls'
      ? 0
      : result.action == 'post'
      ? 2
      : 1;
  if (positionals.length != expected) {
    return _ChatParseFailure(
      'chat ${result.action} expects $expected argument${expected == 1 ? '' : 's'}',
    );
  }
  if (positionals.isNotEmpty) result.room = positionals.first;
  if (positionals.length > 1) result.message = positionals[1];
  if (result.purpose != null && result.action != 'create') {
    return _ChatParseFailure('--purpose is only valid for chat create');
  }
  if (result.replyTo != null && result.action != 'post') {
    return _ChatParseFailure('--reply-to is only valid for chat post');
  }
  if ((result.limit != null ||
          result.since != null ||
          result.agentId != null) &&
      result.action != 'read') {
    return _ChatParseFailure(
      '--limit, --since, and --agent are only valid for chat read',
    );
  }
  if (result.timeout != null && result.action != 'wait') {
    return _ChatParseFailure('--timeout is only valid for chat wait');
  }
  return result;
}

void _renderChatResult(
  _ChatResult result, {
  required CliOutputOptions options,
  required void Function(String) write,
}) {
  if (result.rooms != null) {
    final rows = result.rooms!.map(_roomRow).toList(growable: false);
    final rendered = renderCliOutput(
      result.isList
          ? CliOutputResult.list(rows: rows, schema: _chatRoomSchema)
          : CliOutputResult.single(row: rows.single, schema: _chatRoomSchema),
      options,
    );
    if (rendered.isNotEmpty) write('$rendered\n');
    return;
  }
  final rows = [for (final message in result.messages!) message.toJson()];
  final rendered = renderCliOutput(
    result.isList
        ? CliOutputResult.list(rows: rows, schema: _chatMessageSchema)
        : CliOutputResult.single(row: rows.single, schema: _chatMessageSchema),
    options,
  );
  if (rendered.isNotEmpty) write('$rendered\n');
}

Map<String, Object?> _roomRow(ChatRoomDetail room) => {
  'name': room.name,
  'id': room.id,
  'purpose': room.purpose ?? '-',
  'messages': room.messageCount,
  'lastMessageAt': room.lastMessageAt ?? '-',
};

final _chatRoomSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 22),
    CliOutputColumn(header: 'ID', field: (row) => row['id'], width: 36),
    CliOutputColumn(
      header: 'PURPOSE',
      field: (row) => row['purpose'],
      width: 30,
    ),
    CliOutputColumn(
      header: 'MESSAGES',
      field: (row) => row['messages'],
      width: 10,
      alignment: CliOutputAlignment.right,
    ),
    CliOutputColumn(
      header: 'LAST MESSAGE',
      field: (row) => row['lastMessageAt'],
      width: 24,
    ),
  ],
);

final _chatMessageSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'ID', field: (row) => row['id'], width: 36),
    CliOutputColumn(header: 'AUTHOR', field: (row) => row['author'], width: 16),
    CliOutputColumn(
      header: 'AUTHOR NAME',
      field: (row) => row['authorName'] ?? '-',
      width: 20,
    ),
    CliOutputColumn(
      header: 'CREATED',
      field: (row) => row['createdAt'],
      width: 24,
    ),
    CliOutputColumn(
      header: 'REPLY TO',
      field: (row) => row['replyTo'],
      width: 36,
    ),
    CliOutputColumn(
      header: 'MENTIONS',
      field: (row) {
        final labels = row['mentionLabels'] as List<Object?>;
        return labels.isEmpty ? '-' : labels.join(', ');
      },
      width: 24,
    ),
    CliOutputColumn(header: 'MESSAGE', field: (row) => row['body'], width: 60),
  ],
  renderHuman: _renderChatTranscript,
);

String _renderChatTranscript(
  List<Map<String, Object?>> rows,
  CliOutputOptions _,
) => rows.map(_renderMessageRow).join('\n\n');

String _renderMessageRow(Map<String, Object?> row) {
  final authorName = row['authorName'];
  final author = authorName == null
      ? '${row['author']}'
      : '$authorName (${row['author']})';
  final createdAt = '${row['createdAt']}';
  final timestamp =
      DateTime.tryParse(createdAt)
          ?.toUtc()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .replaceFirst('.000Z', 'Z') ??
      createdAt;
  final replyTo = '${row['replyTo']}';
  final mentionLabels = row['mentionLabels'] as List<Object?>;
  final body = '${row['body']}';
  final lines = <String>[
    '┌─ $author ── $timestamp ── [msg ${row['id']}]',
    if (replyTo != '-') '│  reply-to: msg $replyTo',
    if (mentionLabels.isNotEmpty) '│  mentions: ${mentionLabels.join(', ')}',
    '│',
    for (final line in body.split(RegExp(r'\r?\n'))) '│  $line',
    '│',
    '└─',
  ];
  return lines.join('\n');
}

final class _ChatResult {
  const _ChatResult._({this.rooms, this.messages, required this.isList});
  factory _ChatResult.rooms(
    List<ChatRoomDetail> rooms, {
    required bool isList,
  }) => _ChatResult._(rooms: rooms, isList: isList);
  factory _ChatResult.messages(
    List<_NamedChatMessage> messages, {
    required bool isList,
  }) => _ChatResult._(messages: messages, isList: isList);
  final List<ChatRoomDetail>? rooms;
  final List<_NamedChatMessage>? messages;
  final bool isList;
}

final class _NamedChatMessage {
  _NamedChatMessage(
    this.message, {
    this.authorName,
    List<String>? mentionLabels,
  }) : mentionLabels = mentionLabels ?? message.mentionAgentIds;
  final ChatMessage message;
  final String? authorName;
  final List<String> mentionLabels;
  Map<String, Object?> toJson() => {
    'id': message.id,
    'author': message.authorAgentId,
    'authorName': authorName,
    'createdAt': message.createdAt,
    'replyTo': message.replyToMessageId ?? '-',
    'mentionAgentIds': message.mentionAgentIds,
    'mentionLabels': mentionLabels,
    'body': message.body,
  };
}

final class _ChatRpcException implements Exception {
  const _ChatRpcException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

final class _ChatCommandException implements Exception {
  const _ChatCommandException(this.code, this.message, {this.details});
  final String code;
  final String message;
  final String? details;
}

_ChatCommandException _toChatCommandError(String action, Object error) {
  if (error case _ChatCommandException()) return error;
  if (error case _ChatRpcException(:final code, :final message)) {
    return _ChatCommandException(code, message);
  }
  final (code, label) = switch (action) {
    'create' => ('CHAT_CREATE_FAILED', 'create chat room'),
    'ls' => ('CHAT_LIST_FAILED', 'list chat rooms'),
    'inspect' => ('CHAT_INSPECT_FAILED', 'inspect chat room'),
    'delete' => ('CHAT_DELETE_FAILED', 'delete chat room'),
    'post' => ('CHAT_POST_FAILED', 'post chat message'),
    'read' => ('CHAT_READ_FAILED', 'read chat messages'),
    'wait' => ('CHAT_WAIT_FAILED', 'wait for chat messages'),
    _ => ('CHAT_FAILED', 'run chat command'),
  };
  return _ChatCommandException(code, 'Failed to $label: ${_errorText(error)}');
}

String _authorAgentId(Map<String, String> environment) {
  final value =
      environment['TINYRACK_AGENT_ID'] ?? environment['PASEO_AGENT_ID'];
  return value?.trim().isNotEmpty == true ? value!.trim() : 'manual';
}

String _parseSince(String value) {
  try {
    return DateTime.now()
        .toUtc()
        .subtract(_parseDuration(value))
        .toIso8601String();
  } on FormatException {
    final timestamp = DateTime.tryParse(value);
    if (timestamp == null) {
      throw const FormatException(
        'Invalid --since value. Use a duration like 10m or an ISO timestamp.',
      );
    }
    return timestamp.toUtc().toIso8601String();
  }
}

Duration _parseDuration(String value, {bool positive = false}) {
  final match = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h|d)$').firstMatch(value);
  if (match == null) throw FormatException('Invalid duration: $value');
  final amount = double.parse(match.group(1)!);
  final multiplier = switch (match.group(2)) {
    'ms' => 1,
    's' => 1000,
    'm' => 60000,
    'h' => 3600000,
    'd' => 86400000,
    _ => 0,
  };
  final duration = Duration(milliseconds: (amount * multiplier).round());
  if (positive && duration <= Duration.zero) {
    throw const FormatException('Invalid timeout value');
  }
  return duration;
}

Duration _minimum(Duration left, Duration right) =>
    left <= right ? left : right;

Map<String, Object?> _requiredMap(Map<String, Object?> source, String field) {
  final value = source[field];
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

List<T> _mapList<T>(
  Map<String, Object?> source,
  String field,
  T Function(Map<String, Object?>) parse,
) {
  final value = source[field];
  if (value is! List) throw FormatException('$field must be an array');
  return [
    for (final item in value) parse(Map<String, Object?>.from(item as Map)),
  ];
}

String _errorText(Object error) => switch (error) {
  _ChatRpcException(:final code, :final message) => '$code: $message',
  StateError(message: final message) => message,
  _ => '$error',
};

const _chatUsage =
    'Usage: coding-agent chat create <name> [--purpose <text>] [--json]\n'
    '       coding-agent chat ls [--json]\n'
    '       coding-agent chat <inspect|delete> <name-or-id> [--json]\n'
    '       coding-agent chat post <name-or-id> <message> '
    '[--reply-to <msg-id>] [--json]\n'
    '       coding-agent chat read <name-or-id> [--limit <n>] '
    '[--since <duration-or-timestamp>] [--agent <agent-id>] [--json]\n'
    '       coding-agent chat wait <name-or-id> [--timeout <duration>] [--json]';

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
