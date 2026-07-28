import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/terminal/agent_hook_installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-agent-hooks-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AgentHookInstallOptions options([String? configDir]) =>
      AgentHookInstallOptions(
        configDir: configDir ?? root.path,
        homeDir: p.join(root.path, 'home'),
        environment: const {},
      );

  Map<String, Object?> readJson(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as Map)
          .cast<String, Object?>();

  List<Map<String, Object?>> commandHooks(
    Map<String, Object?> config,
    String event,
  ) {
    final hooks = config['hooks'] as Map;
    final entries = hooks[event] as List;
    return [
      for (final entry in entries)
        for (final hook in (entry as Map)['hooks'] as List)
          (hook as Map).cast<String, Object?>(),
    ];
  }

  test('installs every provider idempotently with Tinyrack commands', () {
    final first = installRegisteredAgentHooks(options: options());
    final second = installRegisteredAgentHooks(options: options());

    expect(first, hasLength(3));
    expect(first.every((result) => result.changed), isTrue);
    expect(second.every((result) => !result.changed), isTrue);
    expect(registeredAgentHooksAreInstalled(options: options()), isTrue);

    final claude = readJson(p.join(root.path, 'settings.json'));
    for (final event in const [
      'UserPromptSubmit',
      'Stop',
      'StopFailure',
      'SessionEnd',
      'Notification',
    ]) {
      expect(commandHooks(claude, event), [
        {
          'type': 'command',
          'command':
              'if [ -n "\$TINYRACK_TERMINAL_ID" ]; then '
              '"\${TINYRACK_HOOK_CLI:-coding-agent}" hooks claude $event; fi',
          'timeout': 10,
        },
      ]);
    }

    final codex = readJson(p.join(root.path, 'hooks.json'));
    final stop = commandHooks(codex, 'Stop').single;
    expect(stop['command'], contains('coding-agent}" hooks codex Stop'));
    expect(
      stop['commandWindows'],
      'if defined TINYRACK_TERMINAL_ID '
      '(if defined TINYRACK_HOOK_CLI '
      '("%TINYRACK_HOOK_CLI%" hooks codex Stop) '
      'else (coding-agent hooks codex Stop)) else (exit /b 0)',
    );

    final plugin = File(
      p.join(root.path, 'plugins', 'tinyrack-terminal-activity.js'),
    );
    expect(plugin.readAsStringSync(), tinyrackOpenCodePluginSource);
    expect(plugin.readAsStringSync(), contains('TINYRACK_HOOK_CLI'));
  });

  test('preserves unrelated settings and removes only marker hooks', () {
    final claudePath = p.join(root.path, 'settings.json');
    File(claudePath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'theme': 'dark',
        'hooks': {
          'Stop': [
            {
              'matcher': 'user',
              'hooks': [
                {'type': 'command', 'command': 'say done', 'timeout': 5},
              ],
            },
          ],
        },
      })}\n',
    );

    installAgentHooks(AgentHookProvider.claude, options: options());
    var config = readJson(claudePath);
    expect(config['theme'], 'dark');
    expect(
      commandHooks(config, 'Stop').map((hook) => hook['command']),
      containsAll(['say done', contains('hooks claude Stop')]),
    );

    final result = uninstallAgentHooks(
      AgentHookProvider.claude,
      options: options(),
    );
    expect(result.changed, isTrue);
    config = readJson(claudePath);
    expect(config['theme'], 'dark');
    expect(commandHooks(config, 'Stop').map((hook) => hook['command']), [
      'say done',
    ]);
    expect(
      agentHooksAreInstalled(AgentHookProvider.claude, options: options()),
      isFalse,
    );
  });

  test('Codex requires both POSIX and Windows commands', () {
    final result = installAgentHooks(
      AgentHookProvider.codex,
      options: options(),
    );
    final config = readJson(result.configPath);
    final stop = commandHooks(config, 'Stop').single;
    stop.remove('commandWindows');
    File(result.configPath).writeAsStringSync(jsonEncode(config));

    expect(
      agentHooksAreInstalled(AgentHookProvider.codex, options: options()),
      isFalse,
    );
    final reinstall = installAgentHooks(
      AgentHookProvider.codex,
      options: options(),
    );
    expect(reinstall.changed, isTrue);
    expect(
      agentHooksAreInstalled(AgentHookProvider.codex, options: options()),
      isTrue,
    );
  });

  test('OpenCode uninstall is scoped and missing uninstall is unchanged', () {
    final installed = installAgentHooks(
      AgentHookProvider.opencode,
      options: options(),
    );
    expect(installed.changed, isTrue);
    expect(File(installed.configPath).existsSync(), isTrue);

    final removed = uninstallAgentHooks(
      AgentHookProvider.opencode,
      options: options(),
    );
    expect(removed.changed, isTrue);
    expect(File(installed.configPath).existsSync(), isFalse);
    expect(
      uninstallAgentHooks(
        AgentHookProvider.opencode,
        options: options(),
      ).changed,
      isFalse,
    );
  });

  test('resolves provider overrides, XDG, home, and explicit config dir', () {
    final home = p.join(root.path, 'home');
    final xdg = p.join(root.path, 'xdg');
    final override = p.join(root.path, 'override');
    expect(
      resolveAgentHookConfigPath(
        AgentHookProvider.claude,
        options: AgentHookInstallOptions(
          homeDir: home,
          environment: {'CLAUDE_CONFIG_DIR': override},
        ),
      ),
      p.join(override, 'settings.json'),
    );
    expect(
      resolveAgentHookConfigPath(
        AgentHookProvider.codex,
        options: AgentHookInstallOptions(
          homeDir: home,
          environment: {'CODEX_HOME': override},
        ),
      ),
      p.join(override, 'hooks.json'),
    );
    expect(
      resolveAgentHookConfigPath(
        AgentHookProvider.opencode,
        options: AgentHookInstallOptions(
          homeDir: home,
          environment: {'XDG_CONFIG_HOME': xdg},
        ),
      ),
      p.join(xdg, 'opencode', 'plugins', 'tinyrack-terminal-activity.js'),
    );
    expect(
      resolveAgentHookConfigPath(
        AgentHookProvider.opencode,
        options: AgentHookInstallOptions(homeDir: home, environment: const {}),
      ),
      p.join(
        home,
        '.config',
        'opencode',
        'plugins',
        'tinyrack-terminal-activity.js',
      ),
    );
    expect(
      resolveAgentHookConfigPath(
        AgentHookProvider.opencode,
        options: options(override),
      ),
      p.join(override, 'plugins', 'tinyrack-terminal-activity.js'),
    );
  });

  test('registry logs one provider failure and continues with the others', () {
    final blocked = File(p.join(root.path, 'blocked'))..writeAsStringSync('x');
    final warnings = <(AgentHookProvider, Object)>[];
    final results = installRegisteredAgentHooks(
      options: AgentHookInstallOptions(
        homeDir: p.join(root.path, 'home'),
        environment: {
          'CLAUDE_CONFIG_DIR': blocked.path,
          'CODEX_HOME': p.join(root.path, 'codex'),
          'OPENCODE_CONFIG_DIR': p.join(root.path, 'opencode'),
        },
      ),
      onWarning: (provider, error) => warnings.add((provider, error)),
    );

    expect(results.map((result) => result.provider), [
      AgentHookProvider.codex,
      AgentHookProvider.opencode,
    ]);
    expect(warnings, hasLength(1));
    expect(warnings.single.$1, AgentHookProvider.claude);
    expect(warnings.single.$2, isA<FileSystemException>());
  });

  test('non-object JSON normalizes and malformed JSON is rejected', () {
    final path = p.join(root.path, 'settings.json');
    File(path).writeAsStringSync('[]');
    expect(
      installAgentHooks(AgentHookProvider.claude, options: options()).changed,
      isTrue,
    );
    expect(readJson(path)['hooks'], isA<Map>());

    File(path).writeAsStringSync('{bad');
    expect(
      () => installAgentHooks(AgentHookProvider.claude, options: options()),
      throwsFormatException,
    );
  });

  test('command token builders quote unsafe values', () {
    expect(
      buildAgentHookShellCommand(AgentHookProvider.claude, "event with 'quote"),
      contains("'event with '\\''quote'"),
    );
    expect(
      buildAgentHookWindowsCommand(AgentHookProvider.codex, 'event "quoted"'),
      contains('"event \\"quoted\\""'),
    );
  });
}
