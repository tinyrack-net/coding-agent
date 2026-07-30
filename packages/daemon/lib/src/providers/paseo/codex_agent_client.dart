import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent_client.dart';
import '../agent_session.dart';
import 'codex_agent_session.dart';
import 'codex_app_server_client.dart';
import 'codex_session_runtime.dart';
import 'executable_resolver.dart';
import 'jsonl_rpc_process.dart';
import 'provider_launch_config.dart';
import 'provider_manifest.dart';

typedef CodexExecutableResolver = Future<String?> Function();
typedef CodexConnectionFactory =
    Future<CodexAppServerConnection> Function(JsonlRpcLaunch launch);
typedef CodexVersionResolver =
    Future<String> Function(ResolvedProviderLaunch launch);

const _codexAutoReviewMinimumVersion = (major: 0, minor: 115, patch: 0);

/// Provider client that launches the installed Codex CLI in app-server mode.
final class CodexAgentClient
    implements
        AgentClient,
        EnvironmentAgentClient,
        DefaultModeResolvingAgentClient,
        ImportableAgentClient,
        DraftFeatureListingAgentClient {
  CodexAgentClient({
    ExecutableResolver? executableResolver,
    CodexExecutableResolver? resolveExecutable,
    CodexConnectionFactory? startConnection,
    Map<String, String>? environment,
    ProviderRuntimeSettings? runtimeSettings,
    ProviderRuntimeSettingsResolver? runtimeSettingsResolver,
    CodexVersionResolver? resolveVersion,
  }) : _resolveExecutable =
           resolveExecutable ??
           (executableResolver ?? ExecutableResolver()).findCodex,
       _startConnection =
           startConnection ??
           ((launch) => CodexAppServerClient.start(launch: launch)),
       _environment = environment ?? const {},
       _runtimeSettingsResolver =
           runtimeSettingsResolver ?? (() => runtimeSettings),
       _resolveVersion = resolveVersion ?? _readCodexVersion;

  final CodexExecutableResolver _resolveExecutable;
  final CodexConnectionFactory _startConnection;
  final Map<String, String> _environment;
  final ProviderRuntimeSettingsResolver _runtimeSettingsResolver;
  final CodexVersionResolver _resolveVersion;
  final Map<String, Future<bool>> _autoReviewLoads = {};

  @override
  Future<String> resolveDefaultModeId(
    ResolveAgentDefaultModeInput input,
  ) async => await _resolveAutoReviewEnabled() ? 'auto-review' : 'auto';

  @override
  Future<List<AgentFeature>> listFeatures(
    ListCommandsDraftConfig config,
  ) async => paseoProviderDraftFeatures(config);

  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async {
    final resolvedLaunch = await _resolveLaunch();
    final launch = resolvedLaunch.launch;
    final cwd = options?.cwd ?? Directory.current.path;
    final connection = await _startConnection(
      JsonlRpcLaunch(
        command: launch.command,
        args: [...launch.args, 'app-server'],
        cwd: cwd,
        environment: createProviderEnvironment(
          baseEnvironment: Platform.environment,
          runtimeSettings: resolvedLaunch.runtimeSettings,
          overlays: [_environment],
        ),
        includeParentEnvironment: false,
      ),
    );
    try {
      await connection.request('initialize', codexInitializeParams);
      connection.notify('initialized', <String, Object?>{});
      final limit = options?.limit ?? 20;
      final response = await connection.request('thread/list', {
        'limit': options?.cwd == null ? limit : (limit < 50 ? 50 : limit),
        if (options?.cwd != null) 'cwd': options!.cwd,
      });
      final record = response is Map
          ? response.cast<String, Object?>()
          : const <String, Object?>{};
      final rawRows = record['data'];
      if (rawRows is! List) return const [];
      final rows = <Map<String, Object?>>[];
      for (final raw in rawRows) {
        if (raw is! Map) continue;
        final row = raw.cast<String, Object?>();
        if (options?.cwd != null) {
          final rowCwd = row['cwd'];
          if (rowCwd is! String || !_sameCodexPath(options!.cwd!, rowCwd)) {
            continue;
          }
        }
        rows.add(row);
      }
      return [for (final row in rows.take(limit)) _codexImportableSession(row)];
    } finally {
      await connection.dispose();
    }
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) => createSessionWithEnvironment(
    cwd: cwd,
    model: model,
    mode: mode,
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    featureValues: featureValues,
    systemPrompt: systemPrompt,
    sessionId: sessionId,
    initialHistory: initialHistory,
  );

  @override
  Future<AgentSession> createSessionWithEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, String> environment = const {},
  }) async {
    final resolvedLaunch = await _resolveLaunch();
    final launch = resolvedLaunch.launch;
    final connection = await _startConnection(
      JsonlRpcLaunch(
        command: launch.command,
        args: [...launch.args, 'app-server'],
        cwd: cwd,
        environment: createProviderEnvironment(
          baseEnvironment: Platform.environment,
          runtimeSettings: resolvedLaunch.runtimeSettings,
          overlays: [_environment, environment],
        ),
        includeParentEnvironment: false,
      ),
    );
    final runtime = CodexSessionRuntime(
      client: connection,
      config: CodexRuntimeConfig(
        cwd: cwd,
        modeId: modeId ?? _modeId(mode),
        model: model.trim().isEmpty ? null : model,
        thinkingOptionId: thinkingOptionId,
        systemPrompt: systemPrompt,
      ),
      resumeThreadId: sessionId,
    );
    final session = CodexAgentSession(runtime);
    try {
      await runtime.connect();
      return session;
    } on Object {
      await session.dispose();
      rethrow;
    }
  }

  Future<
    ({ResolvedProviderLaunch launch, ProviderRuntimeSettings? runtimeSettings})
  >
  _resolveLaunch() async {
    final runtimeSettings = _runtimeSettingsResolver();
    final defaultBinary = ProviderLaunchDefault(
      command: 'codex',
      resolvePath: _resolveExecutable,
    );
    final launch = await resolveProviderLaunch(
      commandConfig: runtimeSettings?.command,
      defaultBinary: defaultBinary,
    );
    final availability = await checkProviderLaunchAvailable(
      launch,
      defaultBinary: defaultBinary,
    );
    if (!availability.available) {
      throw StateError(
        'Codex CLI is not installed or could not be resolved from PATH',
      );
    }
    return (
      launch: ResolvedProviderLaunch(
        command: availability.resolvedPath ?? launch.command,
        args: launch.args,
        source: launch.source,
      ),
      runtimeSettings: runtimeSettings,
    );
  }

  Future<bool> _resolveAutoReviewEnabled() async {
    try {
      final launch = (await _resolveLaunch()).launch;
      final key = [launch.command, ...launch.args].join('\u0000');
      return await _autoReviewLoads.putIfAbsent(key, () async {
        final output = await _resolveVersion(launch);
        return _codexVersionAtLeast(
          output,
          minimum: _codexAutoReviewMinimumVersion,
        );
      });
    } on Object {
      return false;
    }
  }
}

ImportableProviderSession _codexImportableSession(Map<String, Object?> thread) {
  final preview = thread['preview'] is String
      ? thread['preview'] as String
      : null;
  final rawName = thread['name'];
  final title = rawName is String && rawName.trim().isNotEmpty
      ? rawName
      : preview;
  final rawTimestamp = thread['updatedAt'] is num
      ? thread['updatedAt'] as num
      : thread['createdAt'] is num
      ? thread['createdAt'] as num
      : 0;
  return ImportableProviderSession(
    providerHandleId: thread['id'] is String ? thread['id'] as String : '',
    cwd: thread['cwd'] is String
        ? thread['cwd'] as String
        : Directory.current.path,
    title: title,
    firstPromptPreview: preview,
    lastPromptPreview: preview,
    lastActivityAt: DateTime.fromMillisecondsSinceEpoch(
      (rawTimestamp * 1000).toInt(),
      isUtc: true,
    ),
  );
}

bool _sameCodexPath(String left, String right) {
  String canonical(String value) {
    try {
      return Directory(value).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(p.absolute(value));
    }
  }

  final a = canonical(left);
  final b = canonical(right);
  return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
}

String _modeId(AgentMode mode) {
  return switch (mode) {
    AgentMode.plan => 'read-only',
    AgentMode.normal => 'auto-review',
    AgentMode.fullAccess => 'full-access',
  };
}

bool _codexVersionAtLeast(
  String output, {
  required ({int major, int minor, int patch}) minimum,
}) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return false;
  final version = (
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
  );
  if (version.major != minimum.major) {
    return version.major > minimum.major;
  }
  if (version.minor != minimum.minor) {
    return version.minor > minimum.minor;
  }
  return version.patch >= minimum.patch;
}

Future<String> _readCodexVersion(ResolvedProviderLaunch launch) async {
  final process = await Process.start(
    launch.command,
    [...launch.args, '--version'],
    runInShell:
        Platform.isWindows &&
        const {'.cmd', '.bat'}.contains(p.extension(launch.command)),
  );
  final stdout = process.stdout.transform(systemEncoding.decoder).join();
  final stderr = process.stderr.transform(systemEncoding.decoder).join();
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      process.kill();
      throw TimeoutException('Timed out while reading Codex version');
    },
  );
  final output = '${await stdout}\n${await stderr}'.trim();
  if (exitCode != 0) {
    throw ProcessException(
      launch.command,
      [...launch.args, '--version'],
      output,
      exitCode,
    );
  }
  return output;
}
