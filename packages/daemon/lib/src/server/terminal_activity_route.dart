import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:shelf/shelf.dart';

import '../terminal/terminal_manager.dart';

/// Paseo-compatible loopback hook endpoint used by provider CLI integrations.
final class TerminalActivityRoute {
  const TerminalActivityRoute(this.terminals);

  final TerminalManager terminals;

  Future<Response> call(Request request) async {
    if (request.method != 'POST') return Response.notFound('Not found');
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    if (info == null || !info.remoteAddress.isLoopback) {
      return _json(403, {'error': 'Forbidden'});
    }

    final Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is! Map) throw const FormatException();
      payload = decoded.cast<String, Object?>();
    } catch (_) {
      return _json(400, {'error': 'Invalid terminal activity report'});
    }

    final terminalId = payload['terminalId'];
    final token = payload['token'];
    final state = payload['state'];
    if (terminalId is! String ||
        terminalId.isEmpty ||
        token is! String ||
        token.isEmpty ||
        state is! String ||
        !const {'running', 'idle', 'needs-input'}.contains(state)) {
      return _json(400, {'error': 'Invalid terminal activity report'});
    }

    if (terminals.validateActivityToken(terminalId, token) !=
        TerminalActivityTokenValidation.valid) {
      return _json(403, {'error': 'Forbidden'});
    }

    try {
      terminals.setActivity(terminalId, switch (state) {
        'running' => TerminalActivityState.working,
        'needs-input' => TerminalActivityState.attention,
        _ => TerminalActivityState.idle,
      });
      return Response(204);
    } catch (_) {
      return _json(500, {'error': 'Failed to update terminal activity'});
    }
  }
}

Response _json(int status, Map<String, Object?> body) => Response(
  status,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json'},
);
