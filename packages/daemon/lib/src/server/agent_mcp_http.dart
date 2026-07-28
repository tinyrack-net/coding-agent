import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../agent/agent_manager.dart';
import 'daemon_auth.dart';

final class AgentMcpHttpHandler {
  AgentMcpHttpHandler({
    required AgentManager manager,
    required String capabilityToken,
    String? passwordHash,
  }) : _manager = manager,
       _capabilityToken = capabilityToken,
       _passwordHash = passwordHash;

  static const protocolVersion = '2025-03-26';

  final AgentManager _manager;
  final String _capabilityToken;
  final String? _passwordHash;

  Future<Response> call(Request request) async {
    if (!isAgentMcpRequestAuthorized(
      capabilityToken: _capabilityToken,
      passwordHash: _passwordHash,
      authorizationHeader: request.headers['authorization'],
    )) {
      return _json({'error': 'Unauthorized'}, statusCode: 401);
    }
    if (request.method != 'POST') {
      return _rpcError(null, -32000, 'Method not allowed', statusCode: 405);
    }

    Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return _rpcError(null, -32700, 'Parse error');
    }
    if (decoded is! Map) {
      return _rpcError(null, -32600, 'Invalid Request');
    }
    final message = Map<String, Object?>.from(decoded);
    final id = message['id'];
    final method = message['method'];
    if (message['jsonrpc'] != '2.0' || method is! String) {
      return _rpcError(id, -32600, 'Invalid Request');
    }
    final params = message['params'];
    if (params != null && params is! Map) {
      return _rpcError(id, -32602, 'Invalid params');
    }
    final arguments = params == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(params as Map);

    try {
      return switch (method) {
        'notifications/initialized' => Response(202),
        'ping' => _rpcResult(id, const <String, Object?>{}),
        'initialize' => _rpcResult(id, {
          'protocolVersion': arguments['protocolVersion'] is String
              ? arguments['protocolVersion']
              : protocolVersion,
          'capabilities': const {
            'tools': {'listChanged': false},
          },
          'serverInfo': const {'name': 'agent-mcp', 'version': '2.0.0'},
        }),
        'tools/list' => _rpcResult(id, {'tools': _tools}),
        'tools/call' => await _callTool(id, arguments, request.url),
        _ => _rpcError(id, -32601, 'Method not found'),
      };
    } on FormatException catch (error) {
      return _rpcError(id, -32602, error.message.toString());
    } catch (error) {
      return _rpcError(id, -32603, '$error');
    }
  }

  Future<Response> _callTool(
    Object? id,
    Map<String, Object?> params,
    Uri requestUrl,
  ) async {
    final name = _requiredString(params, 'name');
    final rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map) {
      throw const FormatException('arguments must be an object');
    }
    final arguments = rawArguments == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(rawArguments as Map);
    final callerAgentId = requestUrl.queryParameters['callerAgentId'];
    try {
      final structured = await _executeTool(name, arguments, callerAgentId);
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(structured)},
        ],
        'structuredContent': structured,
      });
    } catch (error) {
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': '$error'},
        ],
        'isError': true,
      });
    }
  }

  Future<Map<String, Object?>> _executeTool(
    String name,
    Map<String, Object?> arguments,
    String? callerAgentId,
  ) async {
    switch (name) {
      case 'list_agents':
        final includeArchived = arguments['includeArchived'] as bool? ?? false;
        final explicitCwd = arguments['cwd'] as String?;
        final callerCwd = callerAgentId == null
            ? null
            : _manager.get(callerAgentId)?.cwd;
        final cwd = explicitCwd ?? callerCwd;
        final agents = _manager
            .list(includeArchived: includeArchived)
            .where((agent) => cwd == null || agent.cwd == cwd)
            .map((agent) => agent.toJson())
            .toList(growable: false);
        return {'agents': agents};
      case 'get_agent_status':
        final agentId = _requiredString(arguments, 'agentId');
        final agent = _manager.get(agentId);
        if (agent == null) throw StateError('Agent $agentId not found');
        return {'status': agent.runState.name, 'snapshot': agent.toJson()};
      case 'send_agent_prompt':
        final agentId = _requiredString(arguments, 'agentId');
        final prompt = _requiredString(arguments, 'prompt');
        await _manager.prompt(agentId, prompt);
        return {'agentId': agentId, 'accepted': true};
      case 'archive_agent':
        final agentId = _requiredString(arguments, 'agentId');
        await _manager.archive(agentId);
        return {'agentId': agentId, 'archived': true};
      default:
        throw StateError('Unknown tool: $name');
    }
  }

  static String _requiredString(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required');
    }
    return value.trim();
  }

  static const _tools = <Map<String, Object?>>[
    {
      'name': 'list_agents',
      'title': 'List agents',
      'description': 'List active or archived coding agents.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'cwd': {'type': 'string'},
          'includeArchived': {'type': 'boolean'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_agent_status',
      'title': 'Get agent status',
      'description': 'Get the current status and snapshot for one agent.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
        },
        'required': ['agentId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'send_agent_prompt',
      'title': 'Send agent prompt',
      'description': 'Send a follow-up prompt to an existing agent.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'prompt': {'type': 'string'},
        },
        'required': ['agentId', 'prompt'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'archive_agent',
      'title': 'Archive agent',
      'description': 'Archive an agent and its managed descendants.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
        },
        'required': ['agentId'],
        'additionalProperties': false,
      },
    },
  ];

  static Response _rpcResult(Object? id, Object? result) =>
      _json({'jsonrpc': '2.0', 'result': result, 'id': id});

  static Response _rpcError(
    Object? id,
    int code,
    String message, {
    int statusCode = 200,
  }) => _json({
    'jsonrpc': '2.0',
    'error': {'code': code, 'message': message},
    'id': id,
  }, statusCode: statusCode);

  static Response _json(Object? body, {int statusCode = 200}) => Response(
    statusCode,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json'},
  );
}
