import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/chat_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'chat CLI persists a complete room/message/wait lifecycle over WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-chat-e2e-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      var handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: const {},
      );
      var stopped = false;
      var password = <String, String>{};
      addTearDown(() async {
        if (!stopped) await handle.stop();
      });

      Future<Object?> chat(List<String> arguments) async {
        final output = StringBuffer();
        final errors = StringBuffer();
        final code = await runChatCommand(
          arguments: [
            ...arguments,
            '--host',
            '127.0.0.1:${handle.server.port}',
            '--json',
          ],
          environment: {'TINYRACK_AGENT_ID': 'agent-e2e', ...password},
          writeOutput: output.write,
          writeError: errors.write,
        );
        expect(code, 0, reason: errors.toString());
        return jsonDecode(output.toString());
      }

      final created =
          (await chat(['create', 'Review', '--purpose', 'Coordinate']))!
              as List;
      final roomId = (created.single as Map)['id'] as String;
      expect((created.single as Map)['name'], 'Review');

      final posted =
          (await chat(['post', roomId, 'first @agent-missing']))! as List;
      final firstMessageId = (posted.single as Map)['id'] as String;
      expect((posted.single as Map)['author'], 'agent-e2e');

      final waitFuture = chat(['wait', roomId, '--timeout', '5s']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await chat(['post', roomId, 'second', '--reply-to', firstMessageId]);
      final waited = (await waitFuture)! as List;
      expect(waited, hasLength(1));
      expect((waited.single as Map)['body'], 'second');
      expect((waited.single as Map)['replyTo'], firstMessageId);

      final read = (await chat(['read', 'Review', '--limit', '20']))! as List;
      expect(read, hasLength(2));

      await handle.stop();
      stopped = true;
      handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        passwordHash: hashDaemonPassword('secret'),
        agentClients: const {},
      );
      stopped = false;
      password = {'TINYRACK_PASSWORD': 'secret'};
      final roomsAfterRestart = (await chat(['ls']))! as List;
      expect(roomsAfterRestart, hasLength(1));
      expect((roomsAfterRestart.single as Map)['messages'], 2);

      final deleted = (await chat(['delete', roomId]))! as List;
      expect((deleted.single as Map)['name'], 'Review');
      expect(await chat(['ls']), isEmpty);

      final errors = StringBuffer();
      expect(
        await runChatCommand(
          arguments: [
            'inspect',
            roomId,
            '--host',
            '127.0.0.1:${handle.server.port}',
          ],
          environment: password,
          writeError: errors.write,
        ),
        1,
      );
      expect(errors.toString(), contains('chat_room_not_found'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
