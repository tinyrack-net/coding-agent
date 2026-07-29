import 'dart:io';

import 'package:agent_daemon/src/cli/desktop_launch.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows launch uses Tinyrack executable and sanitized environment',
    () async {
      String? executable;
      List<String>? arguments;
      Map<String, String>? launchedEnvironment;
      ProcessStartMode? startedMode;
      await launchDesktopWithAgent(
        const AgentDeepLinkTarget(
          serverId: 'server/main',
          agentId: 'agent 123',
        ),
        environment: const {
          'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
          'ELECTRON_RUN_AS_NODE': '1',
          'ELECTRON_NO_ATTACH_CONSOLE': '1',
          'TINYRACK_NODE_ENV': 'desktop',
          'KEEP': 'yes',
        },
        operatingSystem: 'windows',
        fileExists: (path) => path.endsWith('coding_agent_app.exe'),
        startProcess:
            (
              value,
              valueArguments, {
              required environment,
              required mode,
            }) async {
              executable = value;
              arguments = valueArguments;
              launchedEnvironment = environment;
              startedMode = mode;
            },
      );

      expect(executable, endsWith(r'Tinyrack\coding_agent_app.exe'));
      expect(arguments, ['coding-agent://h/server%2Fmain/agent/agent%20123']);
      expect(launchedEnvironment, {'LOCALAPPDATA': isNotEmpty, 'KEEP': 'yes'});
      expect(startedMode, ProcessStartMode.detached);
    },
  );

  test('macOS uses open with a new background app instance', () async {
    String? executable;
    List<String>? arguments;
    await launchDesktopWithAgent(
      const AgentDeepLinkTarget(serverId: 'server', agentId: 'agent'),
      environment: const {},
      operatingSystem: 'macos',
      fileExists: (path) => path == '/Applications/Tinyrack.app',
      startProcess:
          (value, valueArguments, {required environment, required mode}) async {
            executable = value;
            arguments = valueArguments;
          },
    );
    expect(executable, 'open');
    expect(arguments, [
      '-n',
      '-g',
      '-a',
      '/Applications/Tinyrack.app',
      '--args',
      'coding-agent://h/server/agent/agent',
    ]);
  });

  test('passthrough and missing desktop failures are explicit', () async {
    expect(
      launchDesktopWithAgent(
        const AgentDeepLinkTarget(serverId: 'server', agentId: 'agent'),
        environment: const {'TINYRACK_DESKTOP_CLI': '1'},
        operatingSystem: 'linux',
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      launchDesktopWithAgent(
        const AgentDeepLinkTarget(serverId: 'server', agentId: 'agent'),
        environment: const {},
        operatingSystem: 'linux',
        fileExists: (_) => false,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
