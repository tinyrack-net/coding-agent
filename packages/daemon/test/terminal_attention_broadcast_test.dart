import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('terminal attention requests push only for a real attention reason', () {
    final server = WsServer(router: RpcRouter(), serverId: 'server-1');
    expect(
      broadcastTerminalAttention(
        server: server,
        transition: const TerminalActivityTransition(
          terminalId: 'terminal-1',
          terminalName: 'Shell',
          cwd: '/workspace',
          workspaceId: null,
          activity: TerminalActivity(
            state: TerminalActivityState.idle,
            attentionReason: TerminalActivityAttentionReason.finished,
            changedAt: 2,
          ),
          previous: TerminalActivity(
            state: TerminalActivityState.working,
            changedAt: 1,
          ),
        ),
        nowMs: 2,
      ),
      isTrue,
    );
    expect(
      broadcastTerminalAttention(
        server: server,
        transition: const TerminalActivityTransition(
          terminalId: 'terminal-1',
          terminalName: 'Shell',
          cwd: '/workspace',
          workspaceId: null,
          activity: TerminalActivity(
            state: TerminalActivityState.idle,
            changedAt: 3,
          ),
          previous: null,
        ),
        nowMs: 3,
      ),
      isFalse,
    );
  });
}
