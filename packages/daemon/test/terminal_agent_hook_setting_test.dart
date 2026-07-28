import 'dart:io';

import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_daemon/src/terminal/agent_hook_installer.dart';
import 'package:agent_daemon/src/terminal/terminal_agent_hook_setting.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AgentHookInstallOptions installOptions;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-hook-setting-');
    installOptions = AgentHookInstallOptions(
      configDir: p.join(root.path, 'hooks'),
      homeDir: root.path,
      environment: const {},
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('disabled startup leaves provider configs untouched', () {
    final store = DaemonConfigStore(
      home: p.join(root.path, 'home'),
      enableTerminalAgentHooks: false,
    );

    applyTerminalAgentHookSetting(store: store, installOptions: installOptions);

    expect(registeredAgentHooksAreInstalled(options: installOptions), isFalse);
    expect(Directory(p.join(root.path, 'hooks')).existsSync(), isFalse);
  });

  test('enabled startup installs all provider hooks', () {
    final store = DaemonConfigStore(
      home: p.join(root.path, 'home'),
      enableTerminalAgentHooks: true,
    );

    applyTerminalAgentHookSetting(store: store, installOptions: installOptions);

    expect(registeredAgentHooksAreInstalled(options: installOptions), isTrue);
  });

  test('live enable installs and disable removes marker hooks', () {
    final store = DaemonConfigStore(
      home: p.join(root.path, 'home'),
      enableTerminalAgentHooks: false,
    );
    final unsubscribe = applyTerminalAgentHookSetting(
      store: store,
      installOptions: installOptions,
    );

    store.setEnableTerminalAgentHooks(true);
    expect(registeredAgentHooksAreInstalled(options: installOptions), isTrue);

    store.setEnableTerminalAgentHooks(false);
    expect(registeredAgentHooksAreInstalled(options: installOptions), isFalse);
    expect(
      File(
        resolveAgentHookConfigPath(
          AgentHookProvider.opencode,
          options: installOptions,
        ),
      ).existsSync(),
      isFalse,
    );

    unsubscribe();
    store.setEnableTerminalAgentHooks(true);
    expect(registeredAgentHooksAreInstalled(options: installOptions), isFalse);
  });

  test('uninstall failures are reported without escaping the patch', () {
    final blocked = File(p.join(root.path, 'blocked'))..writeAsStringSync('x');
    final store = DaemonConfigStore(
      home: p.join(root.path, 'home'),
      enableTerminalAgentHooks: true,
    );
    final errors = <Object>[];
    applyTerminalAgentHookSetting(
      store: store,
      installOptions: AgentHookInstallOptions(
        homeDir: root.path,
        environment: {
          'CLAUDE_CONFIG_DIR': blocked.path,
          'CODEX_HOME': p.join(root.path, 'codex'),
          'OPENCODE_CONFIG_DIR': p.join(root.path, 'opencode'),
        },
      ),
      onUninstallWarning: errors.add,
    );

    expect(() => store.setEnableTerminalAgentHooks(false), returnsNormally);
    expect(errors, hasLength(1));
    expect(errors.single, isA<FileSystemException>());
  });
}
