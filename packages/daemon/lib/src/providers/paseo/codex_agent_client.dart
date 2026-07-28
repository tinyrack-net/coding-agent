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
import 'provider_manifest.dart';

typedef CodexExecutableResolver = Future<String?> Function();
typedef CodexConnectionFactory =
    Future<CodexAppServerConnection> Function(JsonlRpcLaunch launch);

/// Provider client that launches the installed Codex CLI in app-server mode.
final class CodexAgentClient
    implements
        AgentClient,
        ImportableAgentClient,
        DraftFeatureListingAgentClient {
  CodexAgentClient({
    ExecutableResolver? executableResolver,
    CodexExecutableResolver? resolveExecutable,
    CodexConnectionFactory? startConnection,
    Map<String, String>? environment,
  }) : _resolveExecutable =
           resolveExecutable ??
           (executableResolver ?? ExecutableResolver()).findCodex,
       _startConnection =
           startConnection ??
           ((launch) => CodexAppServerClient.start(launch: launch)),
       _environment = environment ?? const {};

  final CodexExecutableResolver _resolveExecutable;
  final CodexConnectionFactory _startConnection;
  final Map<String, String> _environment;

  @override
  Future<List<AgentFeature>> listFeatures(
    ListCommandsDraftConfig config,
  ) async => paseoProviderDraftFeatures(config);

  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async {
    final executable = await _resolveExecutable();
    if (executable == null) {
      throw StateError(
        'Codex CLI is not installed or could not be resolved from PATH',
      );
    }
    final cwd = options?.cwd ?? Directory.current.path;
    final connection = await _startConnection(
      JsonlRpcLaunch(
        command: executable,
        args: const ['app-server'],
        cwd: cwd,
        environment: _environment,
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
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    final executable = await _resolveExecutable();
    if (executable == null) {
      throw StateError(
        'Codex CLI is not installed or could not be resolved from PATH',
      );
    }
    final connection = await _startConnection(
      JsonlRpcLaunch(
        command: executable,
        args: const ['app-server'],
        cwd: cwd,
        environment: _environment,
      ),
    );
    final runtime = CodexSessionRuntime(
      client: connection,
      config: CodexRuntimeConfig(
        cwd: cwd,
        modeId: modeId ?? _modeId(mode),
        model: model.trim().isEmpty ? null : model,
        thinkingOptionId: thinkingOptionId,
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
