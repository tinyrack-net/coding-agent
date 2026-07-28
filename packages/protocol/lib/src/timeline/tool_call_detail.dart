/// Typed tool-call details so clients can render rich cards without knowing
/// provider-specific tool names.
library;

import '../messages/workspace_setup.dart';

sealed class ToolCallDetail {
  const ToolCallDetail();

  String get kind;

  Map<String, Object?> toJson();

  /// Encodes the frozen Paseo 0.2.0 `ToolCallDetail` discriminated union.
  Map<String, Object?> toPaseoJson() {
    return switch (this) {
      WorktreeSetupToolDetail(
        :final worktreePath,
        :final branchName,
        :final log,
        :final commands,
        :final truncated,
      ) =>
        {
          'type': 'worktree_setup',
          'worktreePath': worktreePath,
          'branchName': branchName,
          'log': log,
          'commands': commands.map((command) => command.toJson()).toList(),
          if (truncated) 'truncated': true,
        },
      ShellDetail(:final command, :final cwd, :final output, :final exitCode) =>
        {
          'type': 'shell',
          'command': command,
          if (cwd != null) 'cwd': cwd,
          if (output != null) 'output': output,
          if (exitCode != null) 'exitCode': exitCode,
        },
      ReadDetail(:final path, :final content, :final offset, :final limit) => {
        'type': 'read',
        'filePath': path,
        if (content != null) 'content': content,
        if (offset != null) 'offset': offset,
        if (limit != null) 'limit': limit,
      },
      EditDetail(
        :final path,
        :final oldString,
        :final newString,
        :final diff,
      ) =>
        {
          'type': 'edit',
          'filePath': path,
          if (oldString != null) 'oldString': oldString,
          if (newString != null) 'newString': newString,
          if (diff != null) 'unifiedDiff': diff,
        },
      WriteDetail(:final path, :final contentPreview) => {
        'type': 'write',
        'filePath': path,
        if (contentPreview != null) 'content': contentPreview,
      },
      SearchDetail(
        :final query,
        :final toolName,
        :final content,
        :final filePaths,
        :final webResults,
        :final annotations,
        :final numFiles,
        :final numMatches,
        :final durationMs,
        :final durationSeconds,
        :final truncated,
        :final mode,
      ) =>
        {
          'type': 'search',
          'query': query,
          if (toolName != null) 'toolName': toolName,
          if (content != null) 'content': content,
          if (filePaths.isNotEmpty) 'filePaths': filePaths,
          if (webResults.isNotEmpty)
            'webResults': webResults
                .map((result) => result.toJson())
                .toList(growable: false),
          if (annotations.isNotEmpty) 'annotations': annotations,
          if (numFiles != null) 'numFiles': numFiles,
          if (numMatches != null) 'numMatches': numMatches,
          if (durationMs != null) 'durationMs': durationMs,
          if (durationSeconds != null) 'durationSeconds': durationSeconds,
          if (truncated != null) 'truncated': truncated,
          if (mode != null) 'mode': mode,
        },
      FetchDetail(
        :final url,
        :final prompt,
        :final result,
        :final code,
        :final codeText,
        :final bytes,
        :final durationMs,
      ) =>
        {
          'type': 'fetch',
          'url': url,
          if (prompt != null) 'prompt': prompt,
          if (result != null) 'result': result,
          if (code != null) 'code': code,
          if (codeText != null) 'codeText': codeText,
          if (bytes != null) 'bytes': bytes,
          if (durationMs != null) 'durationMs': durationMs,
        },
      SubAgentDetail(
        :final subAgentType,
        :final description,
        :final childSessionId,
        :final log,
        :final actions,
      ) =>
        {
          'type': 'sub_agent',
          if (subAgentType != null) 'subAgentType': subAgentType,
          if (description != null) 'description': description,
          if (childSessionId != null) 'childSessionId': childSessionId,
          'log': log,
          if (actions.isNotEmpty)
            'actions': actions.map((action) => action.toJson()).toList(),
        },
      PlainTextDetail(:final label, :final text, :final icon) => {
        'type': 'plain_text',
        if (label != null) 'label': label,
        if (text != null) 'text': text,
        if (icon != null) 'icon': icon,
      },
      PlanDetail(:final text) => {'type': 'plan', 'text': text},
      GenericDetail(:final input, :final output) => {
        'type': 'unknown',
        'input': input,
        'output': output,
      },
    };
  }

  static ToolCallDetail fromJson(Map<String, Object?> json) {
    return switch (json['kind'] as String?) {
      'worktree_setup' => WorktreeSetupToolDetail(
        worktreePath: (json['worktreePath'] as String?) ?? '',
        branchName: (json['branchName'] as String?) ?? '',
        log: (json['log'] as String?) ?? '',
        commands: ((json['commands'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (command) => WorkspaceSetupCommand.fromJson(
                command.cast<String, Object?>(),
              ),
            )
            .toList(growable: false),
        truncated: json['truncated'] == true,
      ),
      'shell' => ShellDetail(
        command: (json['command'] as String?) ?? '',
        cwd: json['cwd'] as String?,
        output: json['output'] as String?,
        exitCode: (json['exitCode'] as num?)?.toInt(),
      ),
      'read' => ReadDetail(
        path: (json['path'] as String?) ?? '',
        content: json['content'] as String?,
        offset: (json['offset'] as num?)?.toInt(),
        limit: (json['limit'] as num?)?.toInt(),
      ),
      'edit' => EditDetail(
        path: (json['path'] as String?) ?? '',
        oldString: json['oldString'] as String?,
        newString: json['newString'] as String?,
        diff: json['diff'] as String?,
      ),
      'write' => WriteDetail(
        path: (json['path'] as String?) ?? '',
        contentPreview: json['contentPreview'] as String?,
      ),
      'search' => SearchDetail(
        query: (json['query'] as String?) ?? '',
        path: json['path'] as String?,
        toolName: json['toolName'] as String?,
        content: json['content'] as String?,
        filePaths: ((json['filePaths'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        webResults: ((json['webResults'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (result) =>
                  SearchWebResult.fromJson(result.cast<String, Object?>()),
            )
            .toList(growable: false),
        annotations: ((json['annotations'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        numFiles: (json['numFiles'] as num?)?.toInt(),
        numMatches: (json['numMatches'] as num?)?.toInt(),
        durationMs: json['durationMs'] as num?,
        durationSeconds: json['durationSeconds'] as num?,
        truncated: json['truncated'] as bool?,
        mode: json['mode'] as String?,
      ),
      'fetch' => FetchDetail(
        url: (json['url'] as String?) ?? '',
        prompt: json['prompt'] as String?,
        result: json['result'] as String?,
        code: (json['code'] as num?)?.toInt(),
        codeText: json['codeText'] as String?,
        bytes: (json['bytes'] as num?)?.toInt(),
        durationMs: json['durationMs'] as num?,
      ),
      'sub_agent' => SubAgentDetail(
        subAgentType: json['subAgentType'] as String?,
        description: json['description'] as String?,
        childSessionId: json['childSessionId'] as String?,
        log: (json['log'] as String?) ?? '',
        actions: ((json['actions'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (action) =>
                  SubAgentAction.fromJson(action.cast<String, Object?>()),
            )
            .toList(growable: false),
      ),
      'plain_text' => PlainTextDetail(
        label: json['label'] as String?,
        text: json['text'] as String?,
        icon: json['icon'] as String?,
      ),
      'plan' => PlanDetail(text: (json['text'] as String?) ?? ''),
      _ => GenericDetail(
        input: json['input'] as Map<String, Object?>? ?? {},
        output: json['output'],
        errorMessage: json['errorMessage'] as String?,
      ),
    };
  }

  /// Decodes the frozen Paseo 0.2.0 `ToolCallDetail` wire shape.
  static ToolCallDetail fromPaseoJson(Map<String, Object?> json) {
    final type = _requiredString(json, 'type');
    return switch (type) {
      'worktree_setup' => WorktreeSetupToolDetail(
        worktreePath: _requiredString(json, 'worktreePath'),
        branchName: _requiredString(json, 'branchName'),
        log: _requiredString(json, 'log'),
        commands: _mapList(
          json,
          'commands',
        ).map(WorkspaceSetupCommand.fromJson).toList(growable: false),
        truncated: json['truncated'] == true,
      ),
      'shell' => ShellDetail(
        command: _requiredString(json, 'command'),
        cwd: _optionalString(json, 'cwd'),
        output: _optionalString(json, 'output'),
        exitCode: _optionalInt(json, 'exitCode'),
      ),
      'read' => ReadDetail(
        path: _requiredString(json, 'filePath'),
        content: _optionalString(json, 'content'),
        offset: _optionalInt(json, 'offset'),
        limit: _optionalInt(json, 'limit'),
      ),
      'edit' => EditDetail(
        path: _requiredString(json, 'filePath'),
        oldString: _optionalString(json, 'oldString'),
        newString: _optionalString(json, 'newString'),
        diff: _optionalString(json, 'unifiedDiff'),
      ),
      'write' => WriteDetail(
        path: _requiredString(json, 'filePath'),
        contentPreview: _optionalString(json, 'content'),
      ),
      'search' => SearchDetail(
        query: _requiredString(json, 'query'),
        toolName: _optionalString(json, 'toolName'),
        content: _optionalString(json, 'content'),
        filePaths: _stringList(json, 'filePaths'),
        webResults: _mapList(
          json,
          'webResults',
          optional: true,
        ).map(SearchWebResult.fromJson).toList(growable: false),
        annotations: _stringList(json, 'annotations'),
        numFiles: _optionalInt(json, 'numFiles'),
        numMatches: _optionalInt(json, 'numMatches'),
        durationMs: _optionalNum(json, 'durationMs'),
        durationSeconds: _optionalNum(json, 'durationSeconds'),
        truncated: _optionalBool(json, 'truncated'),
        mode: _optionalString(json, 'mode'),
      ),
      'fetch' => FetchDetail(
        url: _requiredString(json, 'url'),
        prompt: _optionalString(json, 'prompt'),
        result: _optionalString(json, 'result'),
        code: _optionalInt(json, 'code'),
        codeText: _optionalString(json, 'codeText'),
        bytes: _optionalInt(json, 'bytes'),
        durationMs: _optionalNum(json, 'durationMs'),
      ),
      'sub_agent' => SubAgentDetail(
        subAgentType: _optionalString(json, 'subAgentType'),
        description: _optionalString(json, 'description'),
        childSessionId: _optionalString(json, 'childSessionId'),
        log: _requiredString(json, 'log'),
        actions: _mapList(
          json,
          'actions',
          optional: true,
        ).map(SubAgentAction.fromJson).toList(growable: false),
      ),
      'plain_text' => PlainTextDetail(
        label: _optionalString(json, 'label'),
        text: _optionalString(json, 'text'),
        icon: _optionalString(json, 'icon'),
      ),
      'plan' => PlanDetail(text: _requiredString(json, 'text')),
      'unknown' => GenericDetail(
        input: _unknownMap(json['input']),
        output: json.containsKey('output') ? json['output'] : null,
      ),
      _ => throw FormatException('Unknown Paseo tool detail type: $type'),
    };
  }
}

final class WorktreeSetupToolDetail extends ToolCallDetail {
  const WorktreeSetupToolDetail({
    required this.worktreePath,
    required this.branchName,
    required this.log,
    required this.commands,
    this.truncated = false,
  });

  final String worktreePath;
  final String branchName;
  final String log;
  final List<WorkspaceSetupCommand> commands;
  final bool truncated;

  @override
  String get kind => 'worktree_setup';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'worktreePath': worktreePath,
    'branchName': branchName,
    'log': log,
    'commands': commands.map((command) => command.toJson()).toList(),
    if (truncated) 'truncated': true,
  };
}

final class ShellDetail extends ToolCallDetail {
  const ShellDetail({
    required this.command,
    this.cwd,
    this.output,
    this.exitCode,
  });

  final String command;
  final String? cwd;
  final String? output;
  final int? exitCode;

  @override
  String get kind => 'shell';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'command': command,
    if (cwd != null) 'cwd': cwd,
    if (output != null) 'output': output,
    if (exitCode != null) 'exitCode': exitCode,
  };
}

final class ReadDetail extends ToolCallDetail {
  const ReadDetail({required this.path, this.content, this.offset, this.limit});

  final String path;
  final String? content;
  final int? offset;
  final int? limit;

  @override
  String get kind => 'read';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    if (content != null) 'content': content,
    if (offset != null) 'offset': offset,
    if (limit != null) 'limit': limit,
  };
}

final class EditDetail extends ToolCallDetail {
  const EditDetail({
    required this.path,
    this.oldString,
    this.newString,
    this.diff,
  });

  final String path;
  final String? oldString;
  final String? newString;
  final String? diff;

  @override
  String get kind => 'edit';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    if (oldString != null) 'oldString': oldString,
    if (newString != null) 'newString': newString,
    if (diff != null) 'diff': diff,
  };
}

final class WriteDetail extends ToolCallDetail {
  const WriteDetail({required this.path, this.contentPreview});

  final String path;
  final String? contentPreview;

  @override
  String get kind => 'write';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    if (contentPreview != null) 'contentPreview': contentPreview,
  };
}

final class SearchDetail extends ToolCallDetail {
  const SearchDetail({
    required this.query,
    this.path,
    this.toolName,
    this.content,
    this.filePaths = const [],
    this.webResults = const [],
    this.annotations = const [],
    this.numFiles,
    this.numMatches,
    this.durationMs,
    this.durationSeconds,
    this.truncated,
    this.mode,
  });

  final String query;
  final String? path;
  final String? toolName;
  final String? content;
  final List<String> filePaths;
  final List<SearchWebResult> webResults;
  final List<String> annotations;
  final int? numFiles;
  final int? numMatches;
  final num? durationMs;
  final num? durationSeconds;
  final bool? truncated;
  final String? mode;

  @override
  String get kind => 'search';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'query': query,
    if (path != null) 'path': path,
    if (toolName != null) 'toolName': toolName,
    if (content != null) 'content': content,
    if (filePaths.isNotEmpty) 'filePaths': filePaths,
    if (webResults.isNotEmpty)
      'webResults': webResults.map((result) => result.toJson()).toList(),
    if (annotations.isNotEmpty) 'annotations': annotations,
    if (numFiles != null) 'numFiles': numFiles,
    if (numMatches != null) 'numMatches': numMatches,
    if (durationMs != null) 'durationMs': durationMs,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    if (truncated != null) 'truncated': truncated,
    if (mode != null) 'mode': mode,
  };
}

final class SearchWebResult {
  const SearchWebResult({required this.title, required this.url});

  final String title;
  final String url;

  factory SearchWebResult.fromJson(Map<String, Object?> json) =>
      SearchWebResult(
        title: _requiredString(json, 'title'),
        url: _requiredString(json, 'url'),
      );

  Map<String, Object?> toJson() => {'title': title, 'url': url};
}

final class FetchDetail extends ToolCallDetail {
  const FetchDetail({
    required this.url,
    this.prompt,
    this.result,
    this.code,
    this.codeText,
    this.bytes,
    this.durationMs,
  });

  final String url;
  final String? prompt;
  final String? result;
  final int? code;
  final String? codeText;
  final int? bytes;
  final num? durationMs;

  @override
  String get kind => 'fetch';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'url': url,
    if (prompt != null) 'prompt': prompt,
    if (result != null) 'result': result,
    if (code != null) 'code': code,
    if (codeText != null) 'codeText': codeText,
    if (bytes != null) 'bytes': bytes,
    if (durationMs != null) 'durationMs': durationMs,
  };
}

final class PlainTextDetail extends ToolCallDetail {
  const PlainTextDetail({this.label, this.text, this.icon});

  final String? label;
  final String? text;
  final String? icon;

  @override
  String get kind => 'plain_text';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (label != null) 'label': label,
    if (text != null) 'text': text,
    if (icon != null) 'icon': icon,
  };
}

final class PlanDetail extends ToolCallDetail {
  const PlanDetail({required this.text});

  final String text;

  @override
  String get kind => 'plan';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'text': text};
}

final class SubAgentAction {
  const SubAgentAction({
    required this.index,
    required this.toolName,
    this.summary,
  });

  final int index;
  final String toolName;
  final String? summary;

  static SubAgentAction fromJson(Map<String, Object?> json) => SubAgentAction(
    index: (json['index'] as num?)?.toInt() ?? 0,
    toolName: (json['toolName'] as String?) ?? '',
    summary: json['summary'] as String?,
  );

  Map<String, Object?> toJson() => {
    'index': index,
    'toolName': toolName,
    if (summary != null) 'summary': summary,
  };
}

/// Paseo's canonical provider-managed subagent tool detail.
///
/// The child timeline is intentionally transported through the dedicated
/// provider-subagent RPC surface; [log] is only the curated parent-card
/// activity summary.
final class SubAgentDetail extends ToolCallDetail {
  const SubAgentDetail({
    this.subAgentType,
    this.description,
    this.childSessionId,
    this.log = '',
    this.actions = const [],
  });

  final String? subAgentType;
  final String? description;
  final String? childSessionId;
  final String log;
  final List<SubAgentAction> actions;

  @override
  String get kind => 'sub_agent';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (subAgentType != null) 'subAgentType': subAgentType,
    if (description != null) 'description': description,
    if (childSessionId != null) 'childSessionId': childSessionId,
    'log': log,
    if (actions.isNotEmpty)
      'actions': actions.map((action) => action.toJson()).toList(),
  };
}

final class GenericDetail extends ToolCallDetail {
  const GenericDetail({required this.input, this.output, this.errorMessage});

  final Map<String, Object?> input;
  final Object? output;
  final String? errorMessage;

  @override
  String get kind => 'generic';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'input': input,
    if (output != null) 'output': output,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value == value.toInt()) return value.toInt();
  throw FormatException('$key must be an integer');
}

num? _optionalNum(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is num) return value as num?;
  throw FormatException('$key must be a number');
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is bool) return value as bool?;
  throw FormatException('$key must be a boolean');
}

List<Map<String, Object?>> _mapList(
  Map<String, Object?> json,
  String key, {
  bool optional = false,
}) {
  final value = json[key];
  if (value == null && optional) return const [];
  if (value is! List) throw FormatException('$key must be an array');
  return value
      .map((entry) {
        if (entry is! Map) {
          throw FormatException('$key entries must be objects');
        }
        return entry.cast<String, Object?>();
      })
      .toList(growable: false);
}

List<String> _stringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$key must be an array of strings');
  }
  return value.cast<String>();
}

Map<String, Object?> _unknownMap(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  return {'value': value};
}
