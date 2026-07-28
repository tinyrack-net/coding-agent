import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent_client.dart';
import '../agent_session.dart';
import 'claude_agent_session.dart';
import 'claude_history.dart';
import 'claude_process_config.dart';
import 'claude_stream_connection.dart';
import 'executable_resolver.dart';
import 'jsonl_rpc_process.dart';
import 'provider_manifest.dart';

typedef ClaudeExecutableResolver = Future<String?> Function();
typedef ClaudeConnectionFactory =
    Future<ClaudeStreamConnection> Function(JsonlRpcLaunch launch);

final class ClaudeAgentClient
    implements
        AgentClient,
        ImportableAgentClient,
        DraftFeatureListingAgentClient {
  ClaudeAgentClient({
    ExecutableResolver? executableResolver,
    ClaudeExecutableResolver? resolveExecutable,
    ClaudeConnectionFactory? startConnection,
    Map<String, String>? environment,
  }) : _resolveExecutable =
           resolveExecutable ??
           (() => (executableResolver ?? ExecutableResolver()).find('claude')),
       _startConnection =
           startConnection ??
           ((launch) => ClaudeJsonlConnection.start(launch: launch)),
       _environment = environment ?? const {};

  final ClaudeExecutableResolver _resolveExecutable;
  final ClaudeConnectionFactory _startConnection;
  final Map<String, String> _environment;

  @override
  Future<List<AgentFeature>> listFeatures(
    ListCommandsDraftConfig config,
  ) async => paseoProviderDraftFeatures(config);

  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async {
    final environment = {...Platform.environment, ..._environment};
    final configDir =
        environment['CLAUDE_CONFIG_DIR'] ??
        p.join(
          environment['HOME'] ??
              environment['USERPROFILE'] ??
              Directory.current.path,
          '.claude',
        );
    final root = options?.cwd == null
        ? p.join(configDir, 'projects')
        : claudeProjectDir(options!.cwd!, configDir: configDir);
    final limit = options?.limit ?? 20;
    final candidates = await _recentClaudeSessionFiles(
      root,
      limit * 3,
      rootIsProjectDir: options?.cwd != null,
    );
    final result = <ImportableProviderSession>[];
    for (final candidate in candidates) {
      final descriptor = await _parseClaudeSessionDescriptor(candidate);
      if (descriptor != null) result.add(descriptor);
      if (result.length == limit) break;
    }
    return result;
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
  }) async {
    final executable = await _resolveExecutable();
    if (executable == null) {
      throw StateError(
        'Claude Code CLI is not installed or could not be resolved from PATH',
      );
    }
    final config = ClaudeProcessConfig(
      cwd: cwd,
      permissionMode: modeId ?? _modeId(mode),
      fastMode: featureValues['fast_mode'] == true,
      model: _normalize(model),
      thinkingOptionId: normalizeClaudeThinkingOption(thinkingOptionId),
      systemPrompt: _normalize(systemPrompt),
      sessionId: _normalize(sessionId),
    );
    final history = config.sessionId == null
        ? null
        : await loadClaudeHistorySnapshot(
            cwd: cwd,
            sessionId: config.sessionId!,
            environment: {...Platform.environment, ..._environment},
          );
    final connection = await _launch(executable, config);
    final session = ClaudeAgentSession(
      connection,
      config: config,
      restartConnection: (nextConfig) => _launch(executable, nextConfig),
      restoredHistory: history?.timeline,
      restoredProviderSubagents: history?.providerSubagents ?? const [],
    );
    session.initialize();
    return session;
  }

  Future<ClaudeStreamConnection> _launch(
    String executable,
    ClaudeProcessConfig config,
  ) {
    final args = <String>[
      '--output-format',
      'stream-json',
      '--verbose',
      '--input-format',
      'stream-json',
      '--permission-prompt-tool',
      'stdio',
      '--permission-mode',
      config.permissionMode,
      '--allow-dangerously-skip-permissions',
      '--include-partial-messages',
      '--setting-sources=user,project,local',
      if (config.model case final model?) ...['--model', model],
      if (config.systemPrompt case final prompt?) ...[
        '--append-system-prompt',
        prompt,
      ],
      if (config.thinkingOptionId == 'off') ...[
        '--thinking',
        'disabled',
      ] else if (config.thinkingOptionId != null) ...[
        '--thinking',
        'adaptive',
      ],
      if (config.thinkingOptionId case final thinking?
          when thinking != 'off' && thinking != 'ultracode') ...[
        '--effort',
        thinking,
      ],
      if (config.sessionId case final resume?) '--resume=$resume',
      if (config.fastMode || config.thinkingOptionId == 'ultracode')
        '--settings=${_claudeSettings(config)}',
    ];
    return _startConnection(
      JsonlRpcLaunch(
        command: executable,
        args: args,
        cwd: config.cwd,
        environment: {
          'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING': 'true',
          'CLAUDE_CODE_ENTRYPOINT': 'sdk-ts',
          'MCP_TIMEOUT': '600000',
          'MCP_TOOL_TIMEOUT': '600000',
          ..._environment,
        },
      ),
    );
  }
}

final class _ClaudeSessionFile {
  const _ClaudeSessionFile(this.file, this.modified);

  final File file;
  final DateTime modified;
}

Future<List<_ClaudeSessionFile>> _recentClaudeSessionFiles(
  String root,
  int limit, {
  required bool rootIsProjectDir,
}) async {
  final directory = Directory(root);
  if (!await directory.exists()) return const [];
  final files = <File>[];
  try {
    if (rootIsProjectDir) {
      await for (final entity in directory.list()) {
        if (entity is File && p.extension(entity.path) == '.jsonl') {
          files.add(entity);
        }
      }
    } else {
      await for (final project in directory.list()) {
        if (project is! Directory) continue;
        try {
          await for (final entity in project.list()) {
            if (entity is File && p.extension(entity.path) == '.jsonl') {
              files.add(entity);
            }
          }
        } on FileSystemException {
          // A concurrently removed project directory is ignored.
        }
      }
    }
  } on FileSystemException {
    return const [];
  }
  final candidates = <_ClaudeSessionFile>[];
  for (final file in files) {
    try {
      candidates.add(_ClaudeSessionFile(file, (await file.stat()).modified));
    } on FileSystemException {
      // A concurrently removed session is ignored.
    }
  }
  candidates.sort((a, b) => b.modified.compareTo(a.modified));
  return candidates.take(limit).toList(growable: false);
}

Future<ImportableProviderSession?> _parseClaudeSessionDescriptor(
  _ClaudeSessionFile candidate,
) async {
  List<String> lines;
  try {
    lines = await candidate.file.readAsLines();
  } on FileSystemException {
    return null;
  }
  String? sessionId;
  String? cwd;
  String? title;
  String? firstPromptPreview;
  String? lastPromptPreview;
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    Map<String, Object?>? entry;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) entry = decoded.cast<String, Object?>();
    } on FormatException {
      continue;
    }
    if (entry == null || entry['isSidechain'] == true) continue;
    if (entry['type'] == 'user' &&
        (entry['isSynthetic'] == true ||
            entry['isMeta'] == true ||
            entry['toolUseResult'] != null)) {
      continue;
    }
    if (sessionId == null && entry['sessionId'] is String) {
      sessionId = entry['sessionId'] as String;
    }
    if (cwd == null && entry['cwd'] is String) {
      cwd = entry['cwd'] as String;
    }
    final message = entry['message'];
    if (entry['type'] == 'user' && message != null) {
      final text = _extractClaudeDescriptorUserText(message);
      if (text != null) {
        title ??= text;
        final preview = _promptPreview(text);
        firstPromptPreview ??= preview;
        lastPromptPreview = preview;
      }
    }
    if (sessionId != null && cwd != null && title != null) break;
  }
  if (sessionId == null || cwd == null) return null;
  return ImportableProviderSession(
    providerHandleId: sessionId,
    cwd: cwd,
    title: title?.trim().isNotEmpty == true
        ? title
        : 'Claude session '
              '${sessionId.substring(0, sessionId.length < 8 ? sessionId.length : 8)}',
    firstPromptPreview: firstPromptPreview,
    lastPromptPreview: lastPromptPreview,
    lastActivityAt: candidate.modified,
  );
}

String? _extractClaudeDescriptorUserText(Object message) {
  if (message is! Map) return null;
  final content = message['content'];
  return extractClaudeUserMessageText(content);
}

String? _promptPreview(String text) {
  final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  return normalized.length > 160 ? normalized.substring(0, 160) : normalized;
}

String _modeId(AgentMode mode) => switch (mode) {
  AgentMode.plan => 'plan',
  AgentMode.normal => 'auto',
  AgentMode.fullAccess => 'bypassPermissions',
};

String? _normalize(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _claudeSettings(ClaudeProcessConfig config) {
  final settings = <String>[
    if (config.fastMode) '"fastMode":true',
    if (config.thinkingOptionId == 'ultracode') '"ultracode":true',
  ];
  return '{${settings.join(',')}}';
}
