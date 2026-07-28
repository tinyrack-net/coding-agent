import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum AgentHookProvider { claude, codex, opencode }

final class AgentHookInstallOptions {
  const AgentHookInstallOptions({
    this.environment,
    this.homeDir,
    this.configDir,
  });

  final Map<String, String>? environment;
  final String? homeDir;
  final String? configDir;
}

final class AgentHookInstallResult {
  const AgentHookInstallResult({
    required this.provider,
    required this.configPath,
    required this.changed,
  });

  final AgentHookProvider provider;
  final String configPath;
  final bool changed;
}

typedef AgentHookWarningLogger =
    void Function(AgentHookProvider provider, Object error);

const _events = <AgentHookProvider, List<String>>{
  AgentHookProvider.claude: [
    'UserPromptSubmit',
    'Stop',
    'StopFailure',
    'SessionEnd',
    'Notification',
  ],
  AgentHookProvider.codex: [
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'PermissionRequest',
    'Stop',
  ],
  AgentHookProvider.opencode: [
    'session.status.busy',
    'session.status.retry',
    'session.status.idle',
    'permission.asked',
    'permission.replied',
  ],
};

List<AgentHookInstallResult> installRegisteredAgentHooks({
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
  AgentHookWarningLogger? onWarning,
}) {
  final results = <AgentHookInstallResult>[];
  for (final provider in AgentHookProvider.values) {
    try {
      results.add(installAgentHooks(provider, options: options));
    } catch (error) {
      onWarning?.call(provider, error);
    }
  }
  return results;
}

void uninstallRegisteredAgentHooks({
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) {
  for (final provider in AgentHookProvider.values) {
    uninstallAgentHooks(provider, options: options);
  }
}

bool registeredAgentHooksAreInstalled({
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) => AgentHookProvider.values.every(
  (provider) => agentHooksAreInstalled(provider, options: options),
);

AgentHookInstallResult installAgentHooks(
  AgentHookProvider provider, {
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) {
  final configPath = resolveAgentHookConfigPath(provider, options: options);
  if (provider == AgentHookProvider.opencode) {
    final file = File(configPath);
    final current = file.existsSync() ? file.readAsStringSync() : null;
    final next = _normalizeRawConfig(tinyrackOpenCodePluginSource);
    final changed = current == null || _normalizeRawConfig(current) != next;
    if (changed) _writePrivateFileAtomic(file, next);
    return AgentHookInstallResult(
      provider: provider,
      configPath: configPath,
      changed: changed,
    );
  }

  return _updateJsonConfig(provider, configPath, install: true);
}

AgentHookInstallResult uninstallAgentHooks(
  AgentHookProvider provider, {
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) {
  final configPath = resolveAgentHookConfigPath(provider, options: options);
  if (provider == AgentHookProvider.opencode) {
    final file = File(configPath);
    final changed = file.existsSync();
    if (changed) file.deleteSync();
    return AgentHookInstallResult(
      provider: provider,
      configPath: configPath,
      changed: changed,
    );
  }
  return _updateJsonConfig(provider, configPath, install: false);
}

bool agentHooksAreInstalled(
  AgentHookProvider provider, {
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) {
  final file = File(resolveAgentHookConfigPath(provider, options: options));
  if (!file.existsSync()) return false;
  if (provider == AgentHookProvider.opencode) {
    return _normalizeRawConfig(file.readAsStringSync()) ==
        _normalizeRawConfig(tinyrackOpenCodePluginSource);
  }
  final config = _parseJsonObject(file.readAsStringSync());
  final hooks = _normalizeObject(config['hooks']);
  return _events[provider]!.every((event) {
    for (final matcher in _normalizeObjectList(hooks[event])) {
      for (final hook in _normalizeObjectList(matcher['hooks'])) {
        if (_hasCompleteHookCommands(provider, hook)) return true;
      }
    }
    return false;
  });
}

String resolveAgentHookConfigPath(
  AgentHookProvider provider, {
  AgentHookInstallOptions options = const AgentHookInstallOptions(),
}) {
  final env = options.environment ?? Platform.environment;
  final home =
      options.homeDir ??
      env['USERPROFILE'] ??
      env['HOME'] ??
      Directory.current.path;
  final explicit = options.configDir;
  if (explicit != null) {
    return p.join(explicit, _configFile(provider));
  }
  return switch (provider) {
    AgentHookProvider.claude => p.join(
      env['CLAUDE_CONFIG_DIR'] ?? p.join(home, '.claude'),
      'settings.json',
    ),
    AgentHookProvider.codex => p.join(
      env['CODEX_HOME'] ?? p.join(home, '.codex'),
      'hooks.json',
    ),
    AgentHookProvider.opencode => p.join(
      env['OPENCODE_CONFIG_DIR'] ??
          p.join(env['XDG_CONFIG_HOME'] ?? p.join(home, '.config'), 'opencode'),
      'plugins',
      'tinyrack-terminal-activity.js',
    ),
  };
}

String buildAgentHookShellCommand(AgentHookProvider provider, String event) {
  final hookCommand =
      '"\${TINYRACK_HOOK_CLI:-coding-agent}" hooks '
      '${_shellToken(provider.name)} ${_shellToken(event)}';
  return 'if [ -n "\$TINYRACK_TERMINAL_ID" ]; then $hookCommand; fi';
}

String buildAgentHookWindowsCommand(AgentHookProvider provider, String event) {
  final args = 'hooks ${_windowsToken(provider.name)} ${_windowsToken(event)}';
  return 'if defined TINYRACK_TERMINAL_ID '
      '(if defined TINYRACK_HOOK_CLI '
      '("%TINYRACK_HOOK_CLI%" $args) else (coding-agent $args)) '
      'else (exit /b 0)';
}

AgentHookInstallResult _updateJsonConfig(
  AgentHookProvider provider,
  String configPath, {
  required bool install,
}) {
  final file = File(configPath);
  final currentRaw = file.existsSync() ? file.readAsStringSync() : null;
  final config = currentRaw == null
      ? <String, Object?>{}
      : _parseJsonObject(currentRaw);
  final hooks = _normalizeObject(config['hooks']);
  for (final event in _events[provider]!) {
    final userEntries = _removeTinyrackHooks(provider, hooks[event]);
    if (install) {
      hooks[event] = [
        ...userEntries,
        {
          'matcher': '',
          'hooks': [
            {
              'type': 'command',
              'command': buildAgentHookShellCommand(provider, event),
              if (provider == AgentHookProvider.codex)
                'commandWindows': buildAgentHookWindowsCommand(provider, event),
              'timeout': 10,
            },
          ],
        },
      ];
    } else if (userEntries.isEmpty) {
      hooks.remove(event);
    } else {
      hooks[event] = userEntries;
    }
  }
  final next =
      '${const JsonEncoder.withIndent('  ').convert({...config, 'hooks': hooks})}\n';
  final changed = currentRaw == null || next != _normalizeRawConfig(currentRaw);
  if (changed) _writePrivateFileAtomic(file, next);
  return AgentHookInstallResult(
    provider: provider,
    configPath: configPath,
    changed: changed,
  );
}

List<Map<String, Object?>> _removeTinyrackHooks(
  AgentHookProvider provider,
  Object? value,
) {
  final entries = <Map<String, Object?>>[];
  for (final matcher in _normalizeObjectList(value)) {
    final remaining = [
      for (final hook in _normalizeObjectList(matcher['hooks']))
        if (!_containsHookMarker(provider, hook)) hook,
    ];
    if (remaining.isNotEmpty) {
      entries.add({...matcher, 'hooks': remaining});
    }
  }
  return entries;
}

bool _hasCompleteHookCommands(
  AgentHookProvider provider,
  Map<String, Object?> hook,
) {
  final shell = hook['command'];
  final hasShell = shell is String && shell.contains('hooks ${provider.name}');
  if (provider != AgentHookProvider.codex) return hasShell;
  final windows = hook['commandWindows'] ?? hook['command_windows'];
  return hasShell &&
      windows is String &&
      windows.contains('hooks ${provider.name}');
}

bool _containsHookMarker(
  AgentHookProvider provider,
  Map<String, Object?> hook,
) {
  final marker = 'hooks ${provider.name}';
  return [
    hook['command'],
    hook['commandWindows'],
    hook['command_windows'],
  ].any((value) => value is String && value.contains(marker));
}

Map<String, Object?> _parseJsonObject(String raw) {
  final decoded = jsonDecode(raw);
  return decoded is Map
      ? Map<String, Object?>.from(decoded)
      : <String, Object?>{};
}

Map<String, Object?> _normalizeObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

List<Map<String, Object?>> _normalizeObjectList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) Map<String, Object?>.from(item),
      ]
    : const [];

String _configFile(AgentHookProvider provider) => switch (provider) {
  AgentHookProvider.claude => 'settings.json',
  AgentHookProvider.codex => 'hooks.json',
  AgentHookProvider.opencode => p.join(
    'plugins',
    'tinyrack-terminal-activity.js',
  ),
};

String _normalizeRawConfig(String raw) => raw.endsWith('\n') ? raw : '$raw\n';

void _writePrivateFileAtomic(File file, String contents) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp-$pid');
  temporary.writeAsStringSync(contents, flush: true);
  // coverage:ignore-start
  // POSIX permission enforcement is validated on Linux/macOS CI.
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', temporary.path]);
  }
  // coverage:ignore-end
  if (file.existsSync()) file.deleteSync();
  temporary.renameSync(file.path);
}

String _shellToken(String value) {
  if (RegExp(r'^[A-Za-z0-9_./:-]+$').hasMatch(value)) return value;
  return "'${value.replaceAll("'", "'\\''")}'";
}

String _windowsToken(String value) {
  if (RegExp(r'^[A-Za-z0-9_./:-]+$').hasMatch(value)) return value;
  return '"${value.replaceAll('"', '\\"')}"';
}

const tinyrackOpenCodePluginSource = '''
const STATUS_EVENTS = {
  busy: "session.status.busy",
  retry: "session.status.retry",
  idle: "session.status.idle",
};

function tinyrackEventFor(event) {
  if (event?.type === "permission.asked") return "permission.asked";
  if (event?.type === "permission.replied") return "permission.replied";
  if (event?.type !== "session.status") return null;
  return STATUS_EVENTS[event?.properties?.status?.type] ?? null;
}

function runTinyrackHook(event) {
  if (!process.env.TINYRACK_TERMINAL_ID) return;
  try {
    const cli = process.env.TINYRACK_HOOK_CLI ?? "coding-agent";
    const child = Bun.spawn([cli, "hooks", "opencode", event], {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
    });
    void child.exited.catch(() => {});
  } catch {}
}

export default async () => ({
  event: async ({ event }) => {
    const tinyrackEvent = tinyrackEventFor(event);
    if (tinyrackEvent) runTinyrackHook(tinyrackEvent);
  },
});
''';
