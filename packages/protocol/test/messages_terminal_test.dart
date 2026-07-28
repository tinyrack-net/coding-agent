import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('terminal info round-trips workspace ownership and activity', () {
    const info = TerminalInfo(
      terminalId: 'terminal-1',
      cwd: '/workspace',
      shell: 'zsh',
      workspaceId: 'workspace-1',
      activity: TerminalActivity(
        state: TerminalActivityState.idle,
        attentionReason: TerminalActivityAttentionReason.finished,
        changedAt: 10,
      ),
    );
    expect(TerminalInfo.fromJson(info.toJson()).toJson(), info.toJson());
    expect(
      const TerminalInfo(terminalId: 'terminal-2', cwd: '', shell: '').toJson(),
      {'terminalId': 'terminal-2', 'cwd': '', 'shell': '', 'activity': null},
    );
  });

  test('terminal attention message round-trips complete payload', () {
    const message = TerminalAttentionRequired(
      serverId: 'server-1',
      terminalId: 'terminal-1',
      cwd: '/workspace',
      workspaceId: 'workspace-1',
      reason: TerminalActivityAttentionReason.needsInput,
      title: 'Terminal needs input',
      body: 'zsh',
      shouldNotify: true,
    );
    expect(
      TerminalAttentionRequired.fromJson(message.toJson()).toJson(),
      message.toJson(),
    );
  });

  test('terminal attention rejects wrong type, payload, and reason', () {
    expect(
      () => TerminalAttentionRequired.fromJson(const {'type': 'other'}),
      throwsFormatException,
    );
    expect(
      () => TerminalAttentionRequired.fromJson(const {
        'type': 'terminal_attention_required',
      }),
      throwsFormatException,
    );
    expect(
      () => TerminalAttentionRequired.fromJson(const {
        'type': 'terminal_attention_required',
        'payload': {'reason': 'future'},
      }),
      throwsFormatException,
    );
  });
}
