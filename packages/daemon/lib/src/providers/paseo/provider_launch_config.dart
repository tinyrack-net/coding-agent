import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'executable_resolver.dart';

enum ProviderCommandMode { defaultMode, append, replace }

final class ProviderCommand {
  const ProviderCommand._({
    required this.mode,
    this.args = const [],
    this.argv = const [],
  });

  const ProviderCommand.defaultMode()
    : this._(mode: ProviderCommandMode.defaultMode);

  const ProviderCommand.append([List<String> args = const []])
    : this._(mode: ProviderCommandMode.append, args: args);

  const ProviderCommand.replace(List<String> argv)
    : this._(mode: ProviderCommandMode.replace, argv: argv);

  final ProviderCommandMode mode;
  final List<String> args;
  final List<String> argv;

  factory ProviderCommand.fromJson(Map<String, Object?> json) {
    return switch (json['mode']) {
      'default' => const ProviderCommand.defaultMode(),
      'append' => ProviderCommand.append(
        _optionalStringList(json['args'], 'provider command args'),
      ),
      'replace' => ProviderCommand.replace(
        _nonEmptyStringList(json['argv'], 'provider command argv'),
      ),
      final value => throw FormatException(
        'Unknown provider command mode: $value',
      ),
    };
  }

  Map<String, Object?> toJson() => switch (mode) {
    ProviderCommandMode.defaultMode => const {'mode': 'default'},
    ProviderCommandMode.append => {
      'mode': 'append',
      if (args.isNotEmpty) 'args': args,
    },
    ProviderCommandMode.replace => {'mode': 'replace', 'argv': argv},
  };
}

final class ProviderRuntimeSettings {
  const ProviderRuntimeSettings({
    this.command,
    this.environment = const {},
    this.disallowedTools = const [],
  });

  final ProviderCommand? command;
  final Map<String, String> environment;
  final List<String> disallowedTools;

  factory ProviderRuntimeSettings.fromJson(Map<String, Object?> json) {
    final command = json['command'];
    return ProviderRuntimeSettings(
      command: command == null
          ? null
          : ProviderCommand.fromJson(_object(command, 'provider command')),
      environment: _optionalStringMap(json['env'], 'provider env'),
      disallowedTools: _optionalStringList(
        json['disallowedTools'],
        'provider disallowedTools',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    if (command != null) 'command': command!.toJson(),
    if (environment.isNotEmpty) 'env': environment,
    if (disallowedTools.isNotEmpty) 'disallowedTools': disallowedTools,
  };
}

final class ProviderLaunchDefault {
  const ProviderLaunchDefault({required this.command, this.resolvePath});

  final String command;
  final Future<String?> Function()? resolvePath;
}

enum ProviderLaunchSource { defaultSource, append, override }

final class ResolvedProviderLaunch {
  const ResolvedProviderLaunch({
    required this.command,
    required this.args,
    required this.source,
  });

  final String command;
  final List<String> args;
  final ProviderLaunchSource source;
}

final class ProviderLaunchAvailability {
  const ProviderLaunchAvailability({
    required this.available,
    required this.resolvedPath,
  });

  final bool available;
  final String? resolvedPath;
}

typedef ProviderDefaultCommandResolver = Future<String> Function();
typedef ProviderRuntimeSettingsResolver = ProviderRuntimeSettings? Function();

Future<ResolvedProviderLaunch> resolveProviderLaunch({
  ProviderCommand? commandConfig,
  Object? defaultBinary,
}) async {
  if (commandConfig?.mode == ProviderCommandMode.replace) {
    if (commandConfig!.argv.isEmpty) {
      throw const FormatException(
        'Provider replacement command requires at least one argv entry',
      );
    }
    return ResolvedProviderLaunch(
      command: commandConfig.argv.first,
      args: List.unmodifiable(commandConfig.argv.skip(1)),
      source: ProviderLaunchSource.override,
    );
  }
  if (defaultBinary == null) {
    throw StateError(
      'defaultBinary is required when provider command is not replaced',
    );
  }
  final normalizedDefault = _normalizeLaunchDefault(defaultBinary);
  final append = commandConfig?.mode == ProviderCommandMode.append;
  return ResolvedProviderLaunch(
    command: normalizedDefault.command,
    args: List.unmodifiable(append ? commandConfig!.args : const <String>[]),
    source: append
        ? ProviderLaunchSource.append
        : ProviderLaunchSource.defaultSource,
  );
}

Future<ProviderLaunchAvailability> checkProviderLaunchAvailable(
  ResolvedProviderLaunch launch, {
  ProviderLaunchDefault? defaultBinary,
  ExecutableResolver? executableResolver,
}) async {
  final resolver = executableResolver ?? ExecutableResolver();
  final resolvedPath =
      defaultBinary != null && launch.source != ProviderLaunchSource.override
      ? await _resolveDefaultLaunchPath(defaultBinary, resolver)
      : await _resolveLaunchPath(launch.command, resolver);
  return ProviderLaunchAvailability(
    available: resolvedPath != null,
    resolvedPath: resolvedPath,
  );
}

Future<ResolvedProviderLaunch> resolveProviderCommandPrefix(
  ProviderCommand? commandConfig,
  ProviderDefaultCommandResolver resolveDefaultCommand,
) async {
  if (commandConfig?.mode == ProviderCommandMode.replace) {
    return resolveProviderLaunch(commandConfig: commandConfig);
  }
  final defaultCommand = await resolveDefaultCommand();
  return resolveProviderLaunch(
    commandConfig: commandConfig,
    defaultBinary: ProviderLaunchDefault(
      command: defaultCommand,
      resolvePath: () async => defaultCommand,
    ),
  );
}

Future<bool> isProviderCommandAvailable(
  ProviderCommand? commandConfig,
  ProviderDefaultCommandResolver resolveDefaultCommand, {
  ExecutableResolver? executableResolver,
}) async {
  try {
    if (commandConfig?.mode == ProviderCommandMode.replace) {
      final launch = await resolveProviderLaunch(commandConfig: commandConfig);
      return (await checkProviderLaunchAvailable(
        launch,
        executableResolver: executableResolver,
      )).available;
    }
    final defaultCommand = await resolveDefaultCommand();
    final defaultBinary = ProviderLaunchDefault(
      command: defaultCommand,
      resolvePath: () async => defaultCommand,
    );
    final launch = await resolveProviderLaunch(
      commandConfig: commandConfig,
      defaultBinary: defaultBinary,
    );
    return (await checkProviderLaunchAvailable(
      launch,
      defaultBinary: defaultBinary,
      executableResolver: executableResolver,
    )).available;
  } on Object {
    return false;
  }
}

Map<String, String>? _cachedShellEnvironment;

Map<String, String> resolveShellEnvironment() =>
    _cachedShellEnvironment ??= Map<String, String>.from(Platform.environment);

const parentClaudeSessionEnvironmentVariables = {
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_SSE_PORT',
  'CLAUDE_AGENT_SDK_VERSION',
};

const externalRuntimeControlEnvironmentVariables = {
  'PASEO_NODE_ENV',
  'PASEO_DESKTOP_MANAGED',
  'PASEO_SUPERVISED',
  'TINYRACK_NODE_ENV',
  'TINYRACK_DESKTOP_MANAGED',
  'TINYRACK_SUPERVISED',
  'ELECTRON_RUN_AS_NODE',
  'ELECTRON_NO_ATTACH_CONSOLE',
};

final class ProviderEnvironmentSpec {
  const ProviderEnvironmentSpec({
    this.baseEnvironment,
    required this.environmentOverlay,
  });

  final Map<String, String?>? baseEnvironment;
  final Map<String, String?> environmentOverlay;
}

ProviderEnvironmentSpec createProviderEnvironmentSpec({
  Map<String, String?>? baseEnvironment,
  ProviderRuntimeSettings? runtimeSettings,
  List<Map<String, String?>?> overlays = const [],
}) {
  final environmentOverlay = <String, String?>{
    ...?runtimeSettings?.environment,
    for (final overlay in overlays)
      if (overlay != null) ...overlay,
    for (final key in parentClaudeSessionEnvironmentVariables) key: null,
  };
  return ProviderEnvironmentSpec(
    baseEnvironment: baseEnvironment,
    environmentOverlay: environmentOverlay,
  );
}

Map<String, String> createProviderEnvironment({
  Map<String, String?>? baseEnvironment,
  ProviderRuntimeSettings? runtimeSettings,
  List<Map<String, String?>?> overlays = const [],
}) {
  final spec = createProviderEnvironmentSpec(
    baseEnvironment: baseEnvironment,
    runtimeSettings: runtimeSettings,
    overlays: overlays,
  );
  final environment = <String, String?>{
    ...(spec.baseEnvironment ?? Platform.environment),
    ...spec.environmentOverlay,
  };
  for (final key in externalRuntimeControlEnvironmentVariables) {
    environment.remove(key);
  }
  environment.removeWhere((_, value) => value == null);
  return Map.unmodifiable(environment.cast<String, String>());
}

ProviderRuntimeSettings? providerRuntimeSettingsFromOverride(
  MutableDaemonProviderConfig? override,
) {
  if (override == null) return null;
  final command = override.extra['command'];
  final environment = override.extra['env'];
  final disallowedTools = override.extra['disallowedTools'];
  return ProviderRuntimeSettings(
    command: command == null
        ? null
        : ProviderCommand.replace(
            _nonEmptyStringList(command, 'provider command'),
          ),
    environment: _optionalStringMap(environment, 'provider env'),
    disallowedTools: _optionalStringList(
      disallowedTools,
      'provider disallowedTools',
    ),
  );
}

Map<String, Map<String, Object?>> migrateProviderSettings(
  Map<String, Object?> raw,
  List<String> builtinProviderIds,
) {
  final migrated = <String, Map<String, Object?>>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (value is! Map) continue;
    final record = Map<String, Object?>.from(value);
    if (_looksLikeProviderOverride(record)) {
      migrated[entry.key] = _normalizeProviderOverride(record);
      continue;
    }
    ProviderRuntimeSettings settings;
    try {
      settings = ProviderRuntimeSettings.fromJson(record);
    } on FormatException {
      continue;
    }
    if (settings.command?.mode == ProviderCommandMode.append) continue;
    migrated[entry.key] = {
      if (settings.command?.mode == ProviderCommandMode.replace)
        'command': settings.command!.argv,
      if (settings.environment.isNotEmpty) 'env': settings.environment,
    };
  }
  return Map.unmodifiable(migrated);
}

ProviderLaunchDefault _normalizeLaunchDefault(Object value) {
  if (value is String) return ProviderLaunchDefault(command: value);
  if (value is ProviderLaunchDefault) return value;
  throw ArgumentError.value(value, 'defaultBinary');
}

Future<String?> _resolveDefaultLaunchPath(
  ProviderLaunchDefault defaultBinary,
  ExecutableResolver resolver,
) =>
    defaultBinary.resolvePath?.call() ??
    _resolveLaunchPath(defaultBinary.command, resolver);

Future<String?> _resolveLaunchPath(
  String command,
  ExecutableResolver resolver,
) async {
  final found = await resolver.find(command);
  if (found != null) return found;
  if (p.isAbsolute(command)) return resolver.exists(command);
  return null;
}

bool _looksLikeProviderOverride(Map<String, Object?> value) {
  final command = value['command'];
  if (command is Map) return false;
  return command is List ||
      value.keys.any(
        const {
          'extends',
          'label',
          'description',
          'params',
          'models',
          'additionalModels',
          'disallowedTools',
          'enabled',
          'order',
        }.contains,
      );
}

Map<String, Object?> _normalizeProviderOverride(Map<String, Object?> value) {
  if (value['command'] case final command?) {
    _nonEmptyStringList(command, 'provider command');
  }
  if (value['env'] case final environment?) {
    _optionalStringMap(environment, 'provider env');
  }
  return Map.unmodifiable(Map<String, Object?>.from(value));
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

List<String> _optionalStringList(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$field must be an array of strings');
  }
  return List.unmodifiable(value.cast<String>());
}

List<String> _nonEmptyStringList(Object? value, String field) {
  final result = _optionalStringList(value, field);
  if (result.isEmpty || result.any((entry) => entry.isEmpty)) {
    throw FormatException('$field must contain non-empty strings');
  }
  return result;
}

Map<String, String> _optionalStringMap(Object? value, String field) {
  if (value == null) return const {};
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.values.any((entry) => entry is! String)) {
    throw FormatException('$field must be a string map');
  }
  return Map.unmodifiable(value.cast<String, String>());
}
