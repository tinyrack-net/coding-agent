import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/acp_client_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String terminalFixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'acp_terminal_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'acp_terminal_child.dart',
  );
}

void main() {
  test('builds frozen default and overridden ACP client capabilities', () {
    expect(buildAcpClientCapabilities(const {}), {
      'fs': {'readTextFile': false, 'writeTextFile': false},
      'terminal': false,
    });
    expect(
      buildAcpClientCapabilities(const {
        'clientCapabilities': {
          'fs': {'readTextFile': true},
          'terminal': true,
        },
      }),
      {
        'fs': {'readTextFile': true, 'writeTextFile': false},
        'terminal': true,
      },
    );
    expect(acpSupportsMcpServers(const {}), isTrue);
    expect(acpSupportsMcpServers(const {'supportsMcpServers': false}), isFalse);
  });

  test('normalizes stdio, HTTP, and SSE MCP servers', () {
    expect(
      normalizeAcpMcpServers(const {
        'local': {
          'type': 'stdio',
          'command': 'dart',
          'args': ['run', 'server.dart'],
          'env': {'TOKEN': 'secret'},
        },
        'remote': {
          'type': 'http',
          'url': 'http://127.0.0.1/mcp',
          'headers': {'Authorization': 'Bearer test'},
        },
        'events': {'type': 'sse', 'url': 'http://127.0.0.1/events'},
      }),
      [
        {
          'name': 'local',
          'command': 'dart',
          'args': ['run', 'server.dart'],
          'env': [
            {'name': 'TOKEN', 'value': 'secret'},
          ],
        },
        {
          'type': 'http',
          'name': 'remote',
          'url': 'http://127.0.0.1/mcp',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer test'},
          ],
        },
        {
          'type': 'sse',
          'name': 'events',
          'url': 'http://127.0.0.1/events',
          'headers': <Object?>[],
        },
      ],
    );
    expect(
      () => normalizeAcpMcpServers(const {
        'broken': {'type': 'unknown'},
      }),
      throwsFormatException,
    );
  });

  test('serves ACP filesystem reads and recursive writes', () async {
    final temp = Directory.systemTemp.createTempSync('acp-client-fs-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final runtime = AcpClientRuntime(cwd: temp.path, environment: const {});
    addTearDown(runtime.dispose);
    final file = p.join(temp.path, 'nested', 'sample.txt');

    expect(
      await runtime.handle('fs/write_text_file', {
        'path': file,
        'content': 'one\r\ntwo\nthree',
      }),
      isEmpty,
    );
    expect(
      await runtime.handle('fs/read_text_file', {
        'path': file,
        'line': 2,
        'limit': 2,
      }),
      {'content': 'two\nthree'},
    );
    expect(await runtime.handle('fs/read_text_file', {'path': file}), {
      'content': 'one\r\ntwo\nthree',
    });
  });

  test('owns ACP terminal output, exit, kill, and release lifecycle', () async {
    final temp = Directory.systemTemp.createTempSync('acp-client-terminal-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final runtime = AcpClientRuntime(
      cwd: temp.path,
      environment: const {'ACP_TERMINAL_ENV': 'base'},
    );
    addTearDown(runtime.dispose);

    final created =
        await runtime.handle('terminal/create', {
              'command': Platform.resolvedExecutable,
              'args': [terminalFixturePath(), 'emit'],
              'env': [
                {'name': 'ACP_TERMINAL_ENV', 'value': 'override'},
              ],
              'outputByteLimit': 18,
            })
            as Map<String, Object?>;
    final terminalId = created['terminalId']! as String;
    final exit =
        await runtime.handle('terminal/wait_for_exit', {
              'terminalId': terminalId,
            })
            as Map<String, Object?>;
    expect(exit['exitCode'], 0);
    final output =
        await runtime.handle('terminal/output', {'terminalId': terminalId})
            as Map<String, Object?>;
    expect(output['truncated'], isTrue);
    expect(
      utf8.encode(output['output']! as String).length,
      lessThanOrEqualTo(18),
    );
    expect(output['exitStatus'], exit);

    final unicode =
        await runtime.handle('terminal/create', {
              'command': Platform.resolvedExecutable,
              'args': [terminalFixturePath(), 'unicode'],
              'outputByteLimit': 5,
            })
            as Map<String, Object?>;
    final unicodeId = unicode['terminalId']! as String;
    await runtime.handle('terminal/wait_for_exit', {'terminalId': unicodeId});
    expect(
      await runtime.handle('terminal/output', {'terminalId': unicodeId}),
      containsPair('output', '🙂'),
    );

    final waiting =
        await runtime.handle('terminal/create', {
              'command': Platform.resolvedExecutable,
              'args': [terminalFixturePath(), 'wait'],
            })
            as Map<String, Object?>;
    final waitingId = waiting['terminalId']! as String;
    expect(
      await runtime.handle('terminal/kill', {'terminalId': waitingId}),
      isEmpty,
    );
    await runtime.handle('terminal/release', {'terminalId': waitingId});
    await expectLater(
      runtime.handle('terminal/output', {'terminalId': waitingId}),
      throwsStateError,
    );
  });
}
