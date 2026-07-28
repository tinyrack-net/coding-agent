import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
}

void main() {
  test(
    'installed ACP provider is executable through the live daemon manager',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-custom-acp-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      DaemonConfigStore(home: home.path).patch(
        MutableDaemonConfigPatch(
          providers: {
            'fixture-acp': MutableDaemonProviderConfig(
              extra: {
                'extends': 'acp',
                'label': 'Fixture ACP',
                'command': [Platform.resolvedExecutable, fixturePath()],
                'env': const {'ACP_FIXTURE_ENV': 'configured'},
                'params': const {'supportsMcpServers': false},
              },
            ),
          },
        ),
      );

      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        log: (_) {},
      );
      addTearDown(handle.stop);

      expect(handle.manager.isProviderAvailable('fixture-acp'), isTrue);
      final created = await handle.manager.createAgent(
        cwd: Directory.current.path,
        provider: 'fixture-acp',
        model: '',
        mode: AgentMode.normal,
        title: 'Custom ACP',
      );
      await pumpEventQueue();

      expect(created.provider, 'fixture-acp');
      expect(handle.manager.get(created.agentId)?.sessionId, 'session-1');
      expect(
        (await handle.manager.listCommands(agentId: created.agentId)).single,
        isA<AgentSlashCommand>().having(
          (command) => command.name,
          'command',
          'review',
        ),
      );
    },
  );
}
