import 'dart:convert';

import 'package:agent_daemon/src/terminal/terminal_activity_hook.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('maps frozen Paseo provider hook events', () {
    expect(
      resolveTerminalHookActivity(
        provider: 'claude',
        event: 'UserPromptSubmit',
      ),
      'running',
    );
    expect(
      resolveTerminalHookActivity(
        provider: 'codex',
        event: 'PermissionRequest',
      ),
      'needs-input',
    );
    expect(
      resolveTerminalHookActivity(
        provider: 'opencode',
        event: 'session.status.idle',
      ),
      'idle',
    );
    expect(
      resolveTerminalHookActivity(provider: 'unknown', event: 'Stop'),
      isNull,
    );
    expect(
      resolveTerminalHookActivity(provider: 'codex', event: 'Unknown'),
      isNull,
    );
  });

  test('Claude idle notification requires matching non-TTY JSON', () {
    expect(
      resolveTerminalHookActivity(
        provider: 'claude',
        event: 'Notification',
        input: '{"matcher":"idle_prompt"}',
      ),
      'needs-input',
    );
    expect(
      resolveTerminalHookActivity(
        provider: 'claude',
        event: 'Notification',
        input: '{"reason":"idle_prompt"}',
      ),
      'needs-input',
    );
    expect(
      resolveTerminalHookActivity(
        provider: 'claude',
        event: 'Notification',
        input: '{bad',
      ),
      isNull,
    );
    expect(
      resolveTerminalHookActivity(
        provider: 'claude',
        event: 'Notification',
        input: '{"matcher":"idle_prompt"}',
        inputIsTerminal: true,
      ),
      isNull,
    );
  });

  test('posts Tinyrack terminal identity, token, and mapped state', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('', 204);
    });

    await reportTerminalHookActivity(
      provider: 'codex',
      event: 'PreToolUse',
      environment: const {
        'TINYRACK_TERMINAL_ID': 'terminal-1',
        'TINYRACK_ACTIVITY_TOKEN': 'token-1',
        'TINYRACK_TERMINAL_ACTIVITY_URL':
            'http://127.0.0.1:6868/api/terminal-activity',
      },
      client: client,
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/terminal-activity');
    expect(jsonDecode(captured.body), {
      'terminalId': 'terminal-1',
      'token': 'token-1',
      'state': 'running',
    });
  });

  test(
    'missing environment, ignored events, and transport errors are no-ops',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        throw StateError('offline');
      });

      await reportTerminalHookActivity(
        provider: 'codex',
        event: 'Stop',
        environment: const {},
        client: client,
      );
      await reportTerminalHookActivity(
        provider: 'codex',
        event: 'Unknown',
        environment: const {
          'TINYRACK_TERMINAL_ID': 'terminal-1',
          'TINYRACK_ACTIVITY_TOKEN': 'token-1',
          'TINYRACK_TERMINAL_ACTIVITY_URL': 'not a url',
        },
        client: client,
      );
      await reportTerminalHookActivity(
        provider: 'codex',
        event: 'Stop',
        environment: const {
          'TINYRACK_TERMINAL_ID': 'terminal-1',
          'TINYRACK_ACTIVITY_TOKEN': 'token-1',
          'TINYRACK_TERMINAL_ACTIVITY_URL':
              'http://127.0.0.1:6868/api/terminal-activity',
        },
        client: client,
      );

      expect(requests, 1);
    },
  );
}
