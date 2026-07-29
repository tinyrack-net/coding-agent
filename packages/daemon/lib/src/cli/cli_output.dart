import 'dart:convert';

enum CliOutputAlignment { left, right, center }

final class CliOutputOptions {
  const CliOutputOptions({
    this.format = 'table',
    this.quiet = false,
    this.noHeaders = false,
    this.noColor = false,
  });

  final String format;
  final bool quiet;
  final bool noHeaders;
  final bool noColor;

  CliOutputOptions copyWith({
    String? format,
    bool? quiet,
    bool? noHeaders,
    bool? noColor,
  }) => CliOutputOptions(
    format: format ?? this.format,
    quiet: quiet ?? this.quiet,
    noHeaders: noHeaders ?? this.noHeaders,
    noColor: noColor ?? this.noColor,
  );
}

final class CliOutputColumn {
  const CliOutputColumn({
    required this.header,
    required this.field,
    this.width,
    this.alignment = CliOutputAlignment.left,
  });

  final String header;
  final Object? Function(Map<String, Object?> row) field;
  final int? width;
  final CliOutputAlignment alignment;
}

typedef CliHumanRenderer =
    String Function(List<Map<String, Object?>> rows, CliOutputOptions options);
typedef CliOutputSerializer = Object? Function(Map<String, Object?> row);

final class CliOutputSchema {
  const CliOutputSchema({
    required this.idField,
    required this.columns,
    this.renderHuman,
    this.serialize,
  });

  final String Function(Map<String, Object?> row) idField;
  final List<CliOutputColumn> columns;
  final CliHumanRenderer? renderHuman;
  final CliOutputSerializer? serialize;
}

final class CliOutputResult {
  const CliOutputResult.list({required this.rows, required this.schema})
    : isList = true,
      singleRow = null;

  const CliOutputResult.single({
    required Map<String, Object?> row,
    required this.schema,
  }) : rows = const [],
       singleRow = row,
       isList = false;

  final bool isList;
  final List<Map<String, Object?>> rows;
  final Map<String, Object?>? singleRow;
  final CliOutputSchema schema;

  List<Map<String, Object?>> get allRows => isList ? rows : [singleRow!];

  Object? get structuredData {
    final serialize = schema.serialize;
    if (serialize == null) return isList ? rows : singleRow!;
    if (!isList) return serialize(singleRow!);
    final serialized = rows.map(serialize).toList(growable: false);
    if (serialized.isNotEmpty) {
      final first = jsonEncode(serialized.first);
      if (serialized.every((value) => jsonEncode(value) == first)) {
        return serialized.first;
      }
    }
    return serialized;
  }
}

String normalizeCliOutputFormat(String raw) {
  final value = raw.trim().toLowerCase();
  if (value == 'cli') return 'table';
  if (const {'table', 'json', 'yaml'}.contains(value)) return value;
  throw FormatException('Unsupported output format: $raw');
}

String renderCliOutput(CliOutputResult result, CliOutputOptions options) {
  if (options.quiet) {
    return result.allRows.map(result.schema.idField).join('\n');
  }
  return switch (options.format) {
    'json' => const JsonEncoder.withIndent('  ').convert(result.structuredData),
    'yaml' => encodeCliYaml(result.structuredData),
    _ when result.schema.renderHuman != null => result.schema.renderHuman!(
      result.allRows,
      options,
    ),
    _ => _renderCliTable(result, options),
  };
}

String renderCliError({
  required String code,
  required String message,
  String? details,
  required CliOutputOptions options,
}) {
  final error = <String, Object?>{
    'code': code,
    'message': message,
    if (details != null) 'details': details,
  };
  if (options.format == 'json') {
    return const JsonEncoder.withIndent('  ').convert({'error': error});
  }
  if (options.format == 'yaml') {
    return encodeCliYaml({'error': error});
  }
  return details == null ? 'Error: $message' : 'Error: $message\n$details';
}

String _renderCliTable(CliOutputResult result, CliOutputOptions options) {
  final rows = result.allRows;
  if (rows.isEmpty) return '';
  final columns = result.schema.columns;
  final includeHeaders = !options.noHeaders;
  final widths = [
    for (final column in columns)
      [
        if (includeHeaders) column.header.length else 0,
        if (column.width != null) column.width!,
        for (final row in rows) '${column.field(row) ?? ''}'.length,
      ].reduce((left, right) => left > right ? left : right),
  ];

  String renderRow(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      _alignCliCell(cells[index], widths[index], columns[index].alignment),
  ].join('  ');

  return [
    if (includeHeaders)
      renderRow([for (final column in columns) column.header]),
    for (final row in rows)
      renderRow([for (final column in columns) '${column.field(row) ?? ''}']),
  ].join('\n');
}

String _alignCliCell(String value, int width, CliOutputAlignment alignment) {
  final padding = width > value.length ? width - value.length : 0;
  return switch (alignment) {
    CliOutputAlignment.right => '${' ' * padding}$value',
    CliOutputAlignment.center =>
      '${' ' * (padding ~/ 2)}$value${' ' * (padding - padding ~/ 2)}',
    CliOutputAlignment.left => '$value${' ' * padding}',
  };
}

String encodeCliYaml(Object? value) {
  final lines = <String>[];
  _writeCliYaml(value, lines, indent: 0);
  return lines.join('\n');
}

void _writeCliYaml(Object? value, List<String> lines, {required int indent}) {
  final prefix = ' ' * indent;
  if (value is List) {
    if (value.isEmpty) {
      lines.add('${prefix}[]');
      return;
    }
    for (final item in value) {
      if (item is Map) {
        final entries = item.entries.toList(growable: false);
        if (entries.isEmpty) {
          lines.add('$prefix- {}');
          continue;
        }
        final first = entries.first;
        final firstEmpty = _cliYamlInlineEmpty(first.value);
        if (firstEmpty != null) {
          lines.add('$prefix- ${first.key}: $firstEmpty');
        } else if (_isCliYamlScalar(first.value)) {
          lines.add('$prefix- ${first.key}: ${_cliYamlScalar(first.value)}');
        } else {
          lines.add('$prefix- ${first.key}:');
          _writeCliYaml(first.value, lines, indent: indent + 4);
        }
        for (final entry in entries.skip(1)) {
          _writeCliYamlMapEntry(entry, lines, indent: indent + 2);
        }
      } else if (_isCliYamlScalar(item)) {
        lines.add('$prefix- ${_cliYamlScalar(item)}');
      } else {
        lines.add('$prefix-');
        _writeCliYaml(item, lines, indent: indent + 2);
      }
    }
    return;
  }
  if (value is Map) {
    if (value.isEmpty) {
      lines.add('${prefix}{}');
      return;
    }
    for (final entry in value.entries) {
      _writeCliYamlMapEntry(entry, lines, indent: indent);
    }
    return;
  }
  lines.add('$prefix${_cliYamlScalar(value)}');
}

void _writeCliYamlMapEntry(
  MapEntry<Object?, Object?> entry,
  List<String> lines, {
  required int indent,
}) {
  final prefix = ' ' * indent;
  final empty = _cliYamlInlineEmpty(entry.value);
  if (empty != null) {
    lines.add('$prefix${entry.key}: $empty');
  } else if (_isCliYamlScalar(entry.value)) {
    lines.add('$prefix${entry.key}: ${_cliYamlScalar(entry.value)}');
  } else {
    lines.add('$prefix${entry.key}:');
    _writeCliYaml(entry.value, lines, indent: indent + 2);
  }
}

bool _isCliYamlScalar(Object? value) =>
    value == null || value is String || value is num || value is bool;

String? _cliYamlInlineEmpty(Object? value) {
  if (value is List && value.isEmpty) return '[]';
  if (value is Map && value.isEmpty) return '{}';
  return null;
}

String _cliYamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  final text = '$value';
  if (text.isNotEmpty &&
      !RegExp(
        r'''[:#\[\]{},&*!|>'"%@`]|^\s|\s$|^(null|true|false|~)$''',
        caseSensitive: false,
      ).hasMatch(text)) {
    return text;
  }
  return jsonEncode(text);
}
