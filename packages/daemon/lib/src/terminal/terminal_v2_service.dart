/// Paseo 0.2.0 compatible terminal session surface.
library;

import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/connection.dart';
import 'terminal_manager.dart';

typedef TerminalWorkspaceResolver = Future<String?> Function(String cwd);

final class TerminalV2Service {
  TerminalV2Service({
    required this.terminals,
    required this.resolveWorkspaceId,
  }) {
    _unsubscribeChanged = terminals.subscribeTerminalsChanged(
      _handleTerminalsChanged,
    );
  }

  final TerminalManager terminals;
  final TerminalWorkspaceResolver resolveWorkspaceId;
  final Map<String, Map<String, _DirectorySubscription>>
  _directorySubscriptions = {};
  late final void Function() _unsubscribeChanged;

  Future<Map<String, Object?>?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    return switch (message['type']) {
      ListTerminalsRequest.type => _list(
        ListTerminalsRequest.fromJson(message),
      ),
      CreateTerminalRequest.type => _create(
        CreateTerminalRequest.fromJson(message),
      ),
      KillTerminalRequest.type => _kill(KillTerminalRequest.fromJson(message)),
      CaptureTerminalRequest.type => _capture(
        CaptureTerminalRequest.fromJson(message),
      ),
      TerminalInputRequest.type => _input(
        TerminalInputRequest.fromJson(message),
      ),
      SubscribeTerminalsRequest.type => _subscribeTerminals(
        connection,
        SubscribeTerminalsRequest.fromJson(message),
      ),
      UnsubscribeTerminalsRequest.type => _unsubscribeTerminals(
        connection,
        UnsubscribeTerminalsRequest.fromJson(message),
      ),
      SubscribeTerminalRequest.type => _subscribe(
        connection,
        SubscribeTerminalRequest.fromJson(message),
      ),
      UnsubscribeTerminalRequest.type => _unsubscribe(
        connection,
        UnsubscribeTerminalRequest.fromJson(message),
      ),
      'terminal.rename.request' => _rename(message),
      _ => null,
    };
  }

  Map<String, Object?> _list(ListTerminalsRequest request) {
    final terminalsForRequest = terminals.listV2(
      cwd: request.cwd,
      workspaceId: request.workspaceId,
    );
    return {
      'type': 'list_terminals_response',
      'payload': {
        if (request.cwd != null) 'cwd': request.cwd,
        'terminals': [
          for (final terminal in terminalsForRequest)
            {
              'id': terminal['id'],
              'name': terminal['name'],
              if (terminal['workspaceId'] != null)
                'workspaceId': terminal['workspaceId'],
              if (terminal['title'] != null) 'title': terminal['title'],
              'activity': terminal['activity'],
            },
        ],
        'requestId': request.requestId,
      },
    };
  }

  Future<Map<String, Object?>> _create(CreateTerminalRequest request) async {
    if (request.agentId != null) {
      return _createResponse(
        request.requestId,
        error:
            'Agent-backed terminals are no longer supported for agent ${request.agentId}',
      );
    }
    final workspaceId =
        request.workspaceId ?? await resolveWorkspaceId(request.cwd);
    if (workspaceId == null) {
      return _createResponse(
        request.requestId,
        error: 'workspaceId is required',
      );
    }
    try {
      final legacy = terminals.create(
        cwd: request.cwd,
        workspaceId: workspaceId,
        name: request.name,
        command: request.command,
        arguments: request.args,
        rows: request.size?.rows,
        cols: request.size?.cols,
      );
      final terminal = terminals
          .listV2(workspaceId: workspaceId)
          .firstWhere((entry) => entry['id'] == legacy['terminalId']);
      return _createResponse(request.requestId, terminal: terminal);
    } catch (error) {
      return _createResponse(request.requestId, error: '$error');
    }
  }

  Map<String, Object?> _createResponse(
    String requestId, {
    Map<String, Object?>? terminal,
    String? error,
  }) => {
    'type': 'create_terminal_response',
    'payload': {'terminal': terminal, 'error': error, 'requestId': requestId},
  };

  Map<String, Object?> _kill(KillTerminalRequest request) {
    final success = terminals.contains(request.terminalId);
    if (success) terminals.kill(request.terminalId);
    return {
      'type': 'kill_terminal_response',
      'payload': {
        'terminalId': request.terminalId,
        'success': success,
        'requestId': request.requestId,
      },
    };
  }

  Map<String, Object?> _capture(CaptureTerminalRequest request) {
    final capture = terminals.capture(
      request.terminalId,
      start: request.start,
      end: request.end,
      stripAnsi: request.stripAnsi,
    );
    return {
      'type': 'capture_terminal_response',
      'payload': {
        'terminalId': request.terminalId,
        'lines': capture.lines,
        'totalLines': capture.totalLines,
        'requestId': request.requestId,
      },
    };
  }

  Map<String, Object?>? _input(TerminalInputRequest request) {
    if (!terminals.contains(request.terminalId)) return null;
    switch (request.message) {
      case TerminalInputMessage message:
        terminals.sendInput(request.terminalId, message.data);
      case TerminalResizeMessage message:
        terminals.resize(request.terminalId, message.cols, message.rows);
      case TerminalMouseMessage():
        // Paseo 0.2.0 intentionally ignores mouse messages.
        break;
    }
    return null;
  }

  Map<String, Object?> _subscribe(
    Connection connection,
    SubscribeTerminalRequest request,
  ) {
    final requestId = request.requestId;
    final terminalId = request.terminalId;
    if (!terminals.contains(terminalId)) {
      return {
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': terminalId,
          'error': 'Terminal not found',
          'requestId': requestId,
        },
      };
    }
    final restore = request.restore;
    if (restore?.size case final size?) {
      terminals.resize(terminalId, size.cols, size.rows);
    }
    int slot;
    try {
      slot = terminals.subscribe(
        connection.id,
        terminalId,
        restore: restore,
        includeWrapFlags:
            connection.clientCapabilities['terminal_reflowable_snapshot'] ==
            true,
      );
    } on StateError {
      return {
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': terminalId,
          'error': 'No terminal stream slots available',
          'requestId': requestId,
        },
      };
    }
    return {
      'type': 'subscribe_terminal_response',
      'payload': {
        'terminalId': terminalId,
        'slot': slot,
        'error': null,
        'requestId': requestId,
      },
    };
  }

  Map<String, Object?>? _subscribeTerminals(
    Connection connection,
    SubscribeTerminalsRequest request,
  ) {
    final subscription = _DirectorySubscription(
      connection: connection,
      cwd: request.cwd,
      workspaceId: request.workspaceId,
    );
    (_directorySubscriptions[connection.id] ??= {})[subscription.key] =
        subscription;
    _emitDirectorySnapshot(subscription);
    return null;
  }

  Map<String, Object?>? _unsubscribeTerminals(
    Connection connection,
    UnsubscribeTerminalsRequest request,
  ) {
    final subscriptions = _directorySubscriptions[connection.id];
    subscriptions?.remove(_subscriptionKey(request.cwd, request.workspaceId));
    if (subscriptions?.isEmpty == true) {
      _directorySubscriptions.remove(connection.id);
    }
    return null;
  }

  void _handleTerminalsChanged(TerminalsChangedEvent event) {
    for (final subscriptions in _directorySubscriptions.values) {
      for (final subscription in subscriptions.values) {
        if (_isSameOrDescendant(subscription.cwd, event.cwd)) {
          _emitDirectorySnapshot(subscription);
        }
      }
    }
  }

  void _emitDirectorySnapshot(_DirectorySubscription subscription) {
    final values = terminals.listV2(
      cwd: subscription.cwd,
      workspaceId: subscription.workspaceId,
    );
    subscription.connection.sendJson({
      'type': 'session',
      'message': {
        'type': 'terminals_changed',
        'payload': {
          'cwd': subscription.cwd,
          'terminals': [
            for (final terminal in values)
              {
                'id': terminal['id'],
                'name': terminal['name'],
                if (terminal['workspaceId'] != null)
                  'workspaceId': terminal['workspaceId'],
                if (terminal['title'] != null) 'title': terminal['title'],
                'activity': terminal['activity'],
              },
          ],
        },
      },
    });
  }

  void onConnectionClosed(String connectionId) {
    _directorySubscriptions.remove(connectionId);
  }

  void dispose() {
    _unsubscribeChanged();
    _directorySubscriptions.clear();
  }

  Map<String, Object?>? _unsubscribe(
    Connection connection,
    UnsubscribeTerminalRequest request,
  ) {
    final terminalId = request.terminalId;
    if (terminals.contains(terminalId)) {
      terminals.unsubscribe(connection.id, terminalId);
    }
    return null;
  }

  Map<String, Object?> _rename(Map<String, Object?> message) {
    final requestId = _requiredString(message, 'requestId');
    final terminalId = _requiredString(message, 'terminalId');
    final title = _requiredString(message, 'title').trim();
    final error = switch (title.length) {
      0 => 'Title is required',
      > 200 => 'Title is too long',
      _ when !terminals.contains(terminalId) => 'Terminal not found',
      _ => null,
    };
    if (error == null) terminals.rename(terminalId, title);
    return {
      'type': 'terminal.rename.response',
      'payload': {
        'requestId': requestId,
        'success': error == null,
        'error': error,
      },
    };
  }
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

final class _DirectorySubscription {
  const _DirectorySubscription({
    required this.connection,
    required this.cwd,
    required this.workspaceId,
  });

  final Connection connection;
  final String cwd;
  final String? workspaceId;
  String get key => _subscriptionKey(cwd, workspaceId);
}

String _subscriptionKey(String cwd, String? workspaceId) =>
    '${_normalizedPath(cwd)}\u0000${workspaceId ?? ''}';

bool _isSameOrDescendant(String root, String candidate) {
  final normalizedRoot = _normalizedPath(root);
  final normalizedCandidate = _normalizedPath(candidate);
  return normalizedCandidate == normalizedRoot ||
      normalizedCandidate.startsWith('$normalizedRoot/');
}

String _normalizedPath(String value) {
  final normalized = value
      .replaceAll('\\', '/')
      .replaceAll(RegExp('/+'), '/')
      .replaceAll(RegExp(r'/$'), '');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
