import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

typedef AgentDesktopLauncher =
    Future<void> Function(AgentDeepLinkTarget target);
typedef DesktopProcessStarter =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      required Map<String, String> environment,
      required ProcessStartMode mode,
    });

Future<void> launchDesktopWithAgent(
  AgentDeepLinkTarget target, {
  Map<String, String>? environment,
  String? operatingSystem,
  bool Function(String path)? fileExists,
  DesktopProcessStarter? startProcess,
}) async {
  final env = Map<String, String>.from(environment ?? Platform.environment);
  if (env['TINYRACK_DESKTOP_CLI'] == '1') {
    throw StateError(
      'Cannot open Tinyrack Desktop while running in desktop CLI '
      'passthrough mode.',
    );
  }
  final os = operatingSystem ?? Platform.operatingSystem;
  final desktop = resolveTinyrackDesktopExecutable(
    environment: env,
    operatingSystem: os,
    fileExists: fileExists,
  );
  if (desktop == null) {
    throw StateError(
      'Tinyrack desktop app not found. Install Tinyrack Desktop first.',
    );
  }
  final cleanEnvironment = cleanDesktopLaunchEnvironment(env);
  final deepLink = buildAgentDeepLink(target);
  await _launchDesktop(
    desktop: desktop,
    arguments: [deepLink],
    operatingSystem: os,
    environment: cleanEnvironment,
    startProcess: startProcess,
  );
}

Future<void> launchDesktopWithProject(
  String projectPath, {
  Map<String, String>? environment,
  String? operatingSystem,
  bool Function(String path)? fileExists,
  DesktopProcessStarter? startProcess,
}) async {
  final env = Map<String, String>.from(environment ?? Platform.environment);
  if (env['TINYRACK_DESKTOP_CLI'] == '1') {
    throw StateError(
      'Cannot open Tinyrack Desktop while running in desktop CLI '
      'passthrough mode.',
    );
  }
  final os = operatingSystem ?? Platform.operatingSystem;
  final desktop = resolveTinyrackDesktopExecutable(
    environment: env,
    operatingSystem: os,
    fileExists: fileExists,
  );
  if (desktop == null) {
    throw StateError(
      'Tinyrack desktop app not found. Install Tinyrack Desktop first.',
    );
  }
  await _launchDesktop(
    desktop: desktop,
    arguments: [projectPath],
    operatingSystem: os,
    environment: cleanDesktopLaunchEnvironment(env),
    startProcess: startProcess,
  );
}

Future<void> _launchDesktop({
  required String desktop,
  required List<String> arguments,
  required String operatingSystem,
  required Map<String, String> environment,
  DesktopProcessStarter? startProcess,
}) async {
  final starter = startProcess ?? _startDetached;
  if (operatingSystem == 'macos') {
    await starter(
      'open',
      ['-n', '-g', '-a', desktop, '--args', ...arguments],
      environment: environment,
      mode: ProcessStartMode.detached,
    );
    return;
  }
  await starter(
    desktop,
    arguments,
    environment: environment,
    mode: ProcessStartMode.detached,
  );
}

String? resolveTinyrackDesktopExecutable({
  required Map<String, String> environment,
  required String operatingSystem,
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? (path) => File(path).existsSync();
  final explicit = environment['TINYRACK_DESKTOP_EXECUTABLE']?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    return exists(explicit) ? explicit : null;
  }
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  final pathContext = operatingSystem == 'windows' ? p.windows : p.posix;
  final candidates = switch (operatingSystem) {
    'macos' => [
      '/Applications/Tinyrack.app',
      if (home != null) pathContext.join(home, 'Applications', 'Tinyrack.app'),
    ],
    'linux' => [
      '/usr/bin/tinyrack',
      '/opt/Tinyrack/tinyrack',
      if (home != null)
        pathContext.join(home, 'Applications', 'Tinyrack.AppImage'),
    ],
    'windows' => [
      if (environment['LOCALAPPDATA'] case final localAppData?)
        pathContext.join(
          localAppData,
          'Programs',
          'Tinyrack',
          'coding_agent_app.exe',
        ),
      if (environment['LOCALAPPDATA'] case final localAppData?)
        pathContext.join(localAppData, 'Programs', 'Tinyrack', 'Tinyrack.exe'),
    ],
    _ => const <String>[],
  };
  return candidates.where(exists).firstOrNull;
}

Map<String, String> cleanDesktopLaunchEnvironment(
  Map<String, String> environment,
) => Map.unmodifiable(
  Map<String, String>.from(environment)
    ..remove('ELECTRON_RUN_AS_NODE')
    ..remove('ELECTRON_NO_ATTACH_CONSOLE')
    ..remove('TINYRACK_NODE_ENV'),
);

Future<void> _startDetached(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required ProcessStartMode mode,
}) async {
  await Process.start(
    executable,
    arguments,
    environment: environment,
    mode: mode,
  );
}
