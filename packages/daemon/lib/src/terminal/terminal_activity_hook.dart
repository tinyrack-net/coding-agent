import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef TerminalHookEnvironment = Map<String, String>;

String? resolveTerminalHookActivity({
  required String provider,
  required String event,
  String? input,
  bool inputIsTerminal = false,
}) {
  switch (provider.toLowerCase()) {
    case 'claude':
      if (event == 'Notification') {
        if (inputIsTerminal || input == null || input.isEmpty) return null;
        try {
          final decoded = jsonDecode(input);
          if (decoded is Map &&
              (decoded['matcher'] == 'idle_prompt' ||
                  decoded['reason'] == 'idle_prompt')) {
            return 'needs-input';
          }
        } catch (_) {
          return null;
        }
        return null;
      }
      return const {
        'UserPromptSubmit': 'running',
        'Stop': 'idle',
        'StopFailure': 'idle',
        'SessionEnd': 'idle',
      }[event];
    case 'codex':
      return const {
        'UserPromptSubmit': 'running',
        'PreToolUse': 'running',
        'PostToolUse': 'running',
        'PermissionRequest': 'needs-input',
        'Stop': 'idle',
      }[event];
    case 'opencode':
      return const {
        'session.status.busy': 'running',
        'session.status.retry': 'running',
        'session.status.idle': 'idle',
        'permission.asked': 'needs-input',
        'permission.replied': 'running',
      }[event];
    default:
      return null;
  }
}

Future<void> reportTerminalHookActivity({
  required String provider,
  required String event,
  required TerminalHookEnvironment environment,
  String? input,
  bool inputIsTerminal = false,
  http.Client? client,
}) async {
  final terminalId = environment['TINYRACK_TERMINAL_ID'];
  final token = environment['TINYRACK_ACTIVITY_TOKEN'];
  final rawUrl = environment['TINYRACK_TERMINAL_ACTIVITY_URL'];
  if (terminalId == null ||
      terminalId.isEmpty ||
      token == null ||
      token.isEmpty ||
      rawUrl == null ||
      rawUrl.isEmpty) {
    return;
  }
  final url = Uri.tryParse(rawUrl);
  if (url == null || !url.hasScheme || url.host.isEmpty) return;
  final state = resolveTerminalHookActivity(
    provider: provider,
    event: event,
    input: input,
    inputIsTerminal: inputIsTerminal,
  );
  if (state == null) return;

  final ownedClient = client == null;
  final resolvedClient = client ?? http.Client();
  try {
    await resolvedClient
        .post(
          url,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'terminalId': terminalId,
            'token': token,
            'state': state,
          }),
        )
        .timeout(const Duration(milliseconds: 500));
  } catch (_) {
    // Hooks are best-effort and must never break provider execution.
  } finally {
    if (ownedClient) resolvedClient.close();
  }
}
