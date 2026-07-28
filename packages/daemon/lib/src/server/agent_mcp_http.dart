import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../agent/agent_manager.dart';
import '../providers/paseo/provider_catalog_registry.dart';
import '../terminal/terminal_manager.dart';
import '../workspace/workspace_v2_service.dart';
import '../workspace/workspace_scripts_service.dart';
import 'agent_mcp_tools.dart';
import 'daemon_auth.dart';

final class AgentMcpHttpHandler {
  AgentMcpHttpHandler({
    required AgentManager manager,
    required PaseoProviderCatalogRegistry providerCatalog,
    required WorkspaceV2Service Function() workspaceService,
    required WorkspaceScriptsService Function() workspaceScripts,
    required TerminalManager terminals,
    required String capabilityToken,
    String? passwordHash,
    Duration agentWaitTimeout = const Duration(seconds: 30),
  }) : _toolsHost = AgentMcpTools(
         manager: manager,
         providerCatalog: providerCatalog,
         workspaceService: workspaceService,
         workspaceScripts: workspaceScripts,
         terminals: terminals,
         agentWaitTimeout: agentWaitTimeout,
       ),
       _capabilityToken = capabilityToken,
       _passwordHash = passwordHash;

  static const protocolVersion = '2025-03-26';

  final AgentMcpTools _toolsHost;
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
      final structured = await _toolsHost.execute(
        name,
        arguments,
        callerAgentId,
      );
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

  static String _requiredString(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required');
    }
    return value.trim();
  }

  static const _tools = <Map<String, Object?>>[
    {
      'name': 'create_workspace',
      'title': 'Create workspace',
      'description':
          'Create a workspace using an existing local checkout or a new '
          'Tinyrack-managed worktree.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'isolation': {
            'type': 'string',
            'enum': ['local', 'worktree'],
          },
          'path': {'type': 'string'},
          'projectId': {'type': 'string'},
          'title': {'type': 'string', 'minLength': 1},
          'mode': {
            'type': 'string',
            'enum': ['branch-off', 'checkout-branch', 'checkout-pr'],
          },
          'worktreeSlug': {'type': 'string', 'minLength': 1},
          'branchName': {'type': 'string', 'minLength': 1},
          'baseBranch': {'type': 'string', 'minLength': 1},
          'branch': {'type': 'string', 'minLength': 1},
          'prNumber': {'type': 'integer', 'minimum': 1},
          'forge': {'type': 'string', 'minLength': 1},
        },
        'required': ['isolation'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_workspaces',
      'title': 'List workspaces',
      'description': 'List active workspaces.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'archive_workspace',
      'title': 'Archive workspace',
      'description': 'Archive a workspace and everything it owns.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string', 'minLength': 1},
        },
        'required': ['workspaceId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'create_agent',
      'title': 'Create agent',
      'description':
          'Create an agent with a provider/model pair and start its initial '
          'prompt immediately.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'minLength': 1, 'maxLength': 60},
          'provider': {'type': 'string', 'minLength': 3},
          'workspaceId': {'type': 'string'},
          'labels': {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
          'settings': {
            'type': 'object',
            'properties': {
              'modeId': {'type': 'string'},
              'thinkingOptionId': {'type': 'string'},
              'features': {'type': 'object'},
            },
            'additionalProperties': false,
          },
          'initialPrompt': {'type': 'string', 'minLength': 1},
          'background': {'type': 'boolean'},
          'notifyOnFinish': {'type': 'boolean'},
        },
        'required': ['title', 'provider', 'initialPrompt'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'rename_workspace',
      'title': 'Rename workspace',
      'description':
          'Rename a workspace by setting its user-visible title. Omit '
          'workspaceId to rename your current workspace.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string', 'minLength': 1},
          'title': {'type': 'string', 'minLength': 1},
        },
        'required': ['title'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_workspace_scripts',
      'title': 'List workspace scripts',
      'description':
          'List configured workspace scripts and their lifecycle, service '
          'port, proxy URL, health, and terminal ID.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string', 'minLength': 1},
        },
        'required': ['workspaceId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'start_workspace_script',
      'title': 'Start workspace script',
      'description':
          'Start one configured workspace script through the managed '
          'workspace-script launcher.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string', 'minLength': 1},
          'scriptName': {'type': 'string', 'minLength': 1},
        },
        'required': ['workspaceId', 'scriptName'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'stop_workspace_script',
      'title': 'Stop workspace script',
      'description':
          'Stop a running script through its supervised terminal lifecycle.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string', 'minLength': 1},
          'scriptName': {'type': 'string', 'minLength': 1},
        },
        'required': ['workspaceId', 'scriptName'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_agents',
      'title': 'List agents',
      'description': 'List active or archived coding agents.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'cwd': {'type': 'string'},
          'includeArchived': {'type': 'boolean'},
          'sinceHours': {'type': 'integer', 'minimum': 1, 'maximum': 720},
          'statuses': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
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
          'sessionMode': {'type': 'string'},
          'background': {'type': 'boolean'},
          'notifyOnFinish': {'type': 'boolean'},
        },
        'required': ['agentId', 'prompt'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'cancel_agent',
      'title': 'Cancel agent run',
      'description':
          "Abort the agent's current run but keep the agent alive for future tasks.",
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
    {
      'name': 'kill_agent',
      'title': 'Kill agent',
      'description': 'Terminate an agent session permanently.',
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
      'name': 'update_agent',
      'title': 'Update agent',
      'description': 'Update an agent name, labels, and/or runtime settings.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'name': {'type': 'string'},
          'labels': {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
          'settings': {'type': 'object'},
        },
        'required': ['agentId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_agent_activity',
      'title': 'Get agent activity',
      'description':
          'Return recent agent timeline entries as a curated summary.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'limit': {'type': 'integer', 'minimum': 0},
        },
        'required': ['agentId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'set_agent_mode',
      'title': 'Set agent session mode',
      'description': "Switch the agent's session mode.",
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'modeId': {'type': 'string'},
        },
        'required': ['agentId', 'modeId'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_pending_permissions',
      'title': 'List pending permissions',
      'description':
          'Return all pending permission requests across all agents.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'respond_to_permission',
      'title': 'Respond to permission',
      'description': 'Approve or deny a pending permission request.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'requestId': {'type': 'string'},
          'response': {
            'oneOf': [
              {
                'type': 'object',
                'properties': {
                  'behavior': {'const': 'allow'},
                  'selectedActionId': {'type': 'string'},
                  'updatedInput': {'type': 'object'},
                  'updatedPermissions': {
                    'type': 'array',
                    'items': {'type': 'object'},
                  },
                },
                'required': ['behavior'],
                'additionalProperties': false,
              },
              {
                'type': 'object',
                'properties': {
                  'behavior': {'const': 'deny'},
                  'selectedActionId': {'type': 'string'},
                  'message': {'type': 'string'},
                  'interrupt': {'type': 'boolean'},
                },
                'required': ['behavior'],
                'additionalProperties': false,
              },
            ],
          },
        },
        'required': ['agentId', 'requestId', 'response'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_providers',
      'title': 'List providers',
      'description':
          'List configured agent providers, availability, and their modes.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_models',
      'title': 'List models',
      'description': 'List models for an agent provider.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'provider': {'type': 'string'},
        },
        'required': ['provider'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'inspect_provider',
      'title': 'Inspect provider',
      'description': 'Inspect compact provider capabilities.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'provider': {'type': 'string'},
          'cwd': {'type': 'string'},
          'settings': {'type': 'object'},
        },
        'required': ['provider'],
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
