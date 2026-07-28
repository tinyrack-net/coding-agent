import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_daemon/src/workspace/service_port_allocator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('range allocation skips reserved and occupied ports', () async {
    final attempts = <int>[];
    final port = await allocateWorkspaceServicePort(
      allocation: const ServicePortAllocation(range: '4000-4002'),
      cwd: Directory.systemTemp.path,
      scriptName: 'web',
      workspaceId: 'workspace',
      branchName: 'main',
      reservedPorts: {4000},
      random: Random(0),
      portAvailable: (candidate) async {
        attempts.add(candidate);
        return candidate == 4002;
      },
    );
    expect(port, 4002);
    expect(attempts, isNotEmpty);
  });

  test('range and fallback failures preserve exact boundaries', () async {
    await expectLater(
      allocateWorkspaceServicePort(
        allocation: const ServicePortAllocation(range: 'bad'),
        cwd: '.',
        scriptName: 'web',
        workspaceId: 'workspace',
        branchName: null,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains("Invalid service port range 'bad'"),
        ),
      ),
    );
    await expectLater(
      allocateWorkspaceServicePort(
        allocation: const ServicePortAllocation(range: '4000-4000'),
        cwd: '.',
        scriptName: 'web',
        workspaceId: 'workspace',
        branchName: null,
        portAvailable: (_) async => false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('No available service port'),
        ),
      ),
    );
    expect(
      await allocateWorkspaceServicePort(
        allocation: null,
        cwd: '.',
        scriptName: 'web',
        workspaceId: 'workspace',
        branchName: null,
        findFreePort: () async => 4321,
      ),
      4321,
    );
  });

  test('port script receives branded environment and arguments', () async {
    final directory = Directory.systemTemp.createTempSync('port-script-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final script = File(
      p.join(directory.path, Platform.isWindows ? 'port.cmd' : 'port.sh'),
    );
    if (Platform.isWindows) {
      script.writeAsStringSync(
        '@echo off\r\n'
        '<nul set /p "=%~1|%~2|%~3|%~4" > argv\r\n'
        '<nul set /p "=%TINYRACK_SCRIPTNAME%|%TINYRACK_WORKSPACE_ID%|'
        '%TINYRACK_BRANCH_NAME%|%TINYRACK_WORKTREE_PATH%" > env\r\n'
        'echo 4567\r\n',
      );
    } else {
      script.writeAsStringSync(
        '#!/bin/sh\n'
        'printf "%s|%s|%s|%s" "\$1" "\$2" "\$3" "\$4" > argv\n'
        'printf "%s|%s|%s|%s" "\$TINYRACK_SCRIPTNAME" '
        '"\$TINYRACK_WORKSPACE_ID" "\$TINYRACK_BRANCH_NAME" '
        '"\$TINYRACK_WORKTREE_PATH" > env\n'
        'printf "4567\\n"\n',
      );
      Process.runSync('chmod', ['+x', script.path]);
    }
    expect(
      await allocateWorkspaceServicePort(
        allocation: ServicePortAllocation(portScript: script.path),
        cwd: directory.path,
        scriptName: 'web',
        workspaceId: 'workspace',
        branchName: 'feature/x',
      ),
      4567,
    );
    final expected = 'web|workspace|feature/x|${directory.path}';
    expect(File(p.join(directory.path, 'argv')).readAsStringSync(), expected);
    expect(File(p.join(directory.path, 'env')).readAsStringSync(), expected);
  });

  test(
    'port script rejects invalid, reserved, failing, and timed out output',
    () async {
      Future<File> script(String body) async {
        final directory = Directory.systemTemp.createTempSync('port-invalid-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File(
          p.join(directory.path, Platform.isWindows ? 'run.cmd' : 'run.sh'),
        );
        file.writeAsStringSync(
          Platform.isWindows ? '@echo off\r\n$body\r\n' : '#!/bin/sh\n$body\n',
        );
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', file.path]);
        }
        return file;
      }

      final invalid = await script(
        Platform.isWindows ? 'echo nope' : 'printf "nope\\n"',
      );
      await expectLater(
        allocateWorkspaceServicePort(
          allocation: ServicePortAllocation(portScript: invalid.path),
          cwd: invalid.parent.path,
          scriptName: 'web',
          workspaceId: 'workspace',
          branchName: null,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('must print exactly one TCP port'),
          ),
        ),
      );

      final reserved = await script(
        Platform.isWindows ? 'echo 4567' : 'printf "4567\\n"',
      );
      await expectLater(
        allocateWorkspaceServicePort(
          allocation: ServicePortAllocation(portScript: reserved.path),
          cwd: reserved.parent.path,
          scriptName: 'web',
          workspaceId: 'workspace',
          branchName: null,
          reservedPorts: {4567},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('returned reserved port 4567'),
          ),
        ),
      );

      final failing = await script(Platform.isWindows ? 'exit /b 3' : 'exit 3');
      await expectLater(
        allocateWorkspaceServicePort(
          allocation: ServicePortAllocation(portScript: failing.path),
          cwd: failing.parent.path,
          scriptName: 'web',
          workspaceId: 'workspace',
          branchName: null,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('failed:'),
          ),
        ),
      );

      final slow = await script(
        Platform.isWindows ? 'ping 127.0.0.1 -n 3 > nul' : 'sleep 2',
      );
      await expectLater(
        allocateWorkspaceServicePort(
          allocation: ServicePortAllocation(portScript: slow.path),
          cwd: slow.parent.path,
          scriptName: 'web',
          workspaceId: 'workspace',
          branchName: null,
          scriptTimeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('failed:'),
          ),
        ),
      );
    },
  );

  test('real port availability and free-port finder observe sockets', () async {
    final free = await findAvailableTcpPort();
    expect(await isTcpPortAvailable(free), isTrue);
    final socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      free,
      shared: false,
    );
    expect(await isTcpPortAvailable(free), isFalse);
    await socket.close();
  });
}
