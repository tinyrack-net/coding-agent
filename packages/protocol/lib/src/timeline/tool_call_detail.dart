/// Typed tool-call details so clients can render rich cards without knowing
/// provider-specific tool names.
library;

sealed class ToolCallDetail {
  const ToolCallDetail();

  String get kind;

  Map<String, Object?> toJson();

  static ToolCallDetail fromJson(Map<String, Object?> json) {
    return switch (json['kind'] as String?) {
      'shell' => ShellDetail(
          command: (json['command'] as String?) ?? '',
          output: json['output'] as String?,
          exitCode: (json['exitCode'] as num?)?.toInt(),
        ),
      'read' => ReadDetail(path: (json['path'] as String?) ?? ''),
      'edit' => EditDetail(
          path: (json['path'] as String?) ?? '',
          diff: json['diff'] as String?,
        ),
      'write' => WriteDetail(
          path: (json['path'] as String?) ?? '',
          contentPreview: json['contentPreview'] as String?,
        ),
      'search' => SearchDetail(
          query: (json['query'] as String?) ?? '',
          path: json['path'] as String?,
        ),
      _ => GenericDetail(input: json['input'] as Map<String, Object?>? ?? {}),
    };
  }
}

final class ShellDetail extends ToolCallDetail {
  const ShellDetail({required this.command, this.output, this.exitCode});

  final String command;
  final String? output;
  final int? exitCode;

  @override
  String get kind => 'shell';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'command': command,
        if (output != null) 'output': output,
        if (exitCode != null) 'exitCode': exitCode,
      };
}

final class ReadDetail extends ToolCallDetail {
  const ReadDetail({required this.path});

  final String path;

  @override
  String get kind => 'read';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'path': path};
}

final class EditDetail extends ToolCallDetail {
  const EditDetail({required this.path, this.diff});

  final String path;
  final String? diff;

  @override
  String get kind => 'edit';

  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'path': path, if (diff != null) 'diff': diff};
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
  const SearchDetail({required this.query, this.path});

  final String query;
  final String? path;

  @override
  String get kind => 'search';

  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'query': query, if (path != null) 'path': path};
}

final class GenericDetail extends ToolCallDetail {
  const GenericDetail({required this.input});

  final Map<String, Object?> input;

  @override
  String get kind => 'generic';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'input': input};
}
