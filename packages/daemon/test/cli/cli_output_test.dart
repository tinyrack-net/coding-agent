import 'dart:convert';

import 'package:agent_daemon/src/cli/cli_output.dart';
import 'package:test/test.dart';

void main() {
  final schema = CliOutputSchema(
    idField: (row) => '${row['id']}',
    columns: [
      CliOutputColumn(header: 'ID', field: (row) => row['id'], width: 4),
      CliOutputColumn(
        header: 'COUNT',
        field: (row) => row['count'],
        alignment: CliOutputAlignment.right,
      ),
    ],
  );
  final rows = <Map<String, Object?>>[
    {
      'id': 'a',
      'count': 2,
      'labels': ['x', 'y'],
      'note': null,
    },
    {'id': 'long-id', 'count': 10, 'labels': <String>[], 'note': '@quoted'},
  ];

  test('renders frozen single and list JSON shapes', () {
    final single = renderCliOutput(
      CliOutputResult.single(row: rows.first, schema: schema),
      const CliOutputOptions(format: 'json'),
    );
    final list = renderCliOutput(
      CliOutputResult.list(rows: rows, schema: schema),
      const CliOutputOptions(format: 'json'),
    );

    expect(jsonDecode(single), isA<Map<String, dynamic>>());
    expect(jsonDecode(list), isA<List<dynamic>>());
    expect(single, contains('\n  "id": "a"'));
  });

  test('renders recursive YAML with stable scalar rules', () {
    final yaml = renderCliOutput(
      CliOutputResult.list(rows: rows, schema: schema),
      const CliOutputOptions(format: 'yaml'),
    );

    expect(yaml, contains('- id: a'));
    expect(yaml, contains('  labels:\n    - x\n    - y'));
    expect(yaml, contains('  labels: []'));
    expect(yaml, contains('  note: "@quoted"'));
  });

  test('applies frozen schema serialization and collapses identical lists', () {
    final serializedSchema = CliOutputSchema(
      idField: (row) => '${row['key']}',
      columns: [CliOutputColumn(header: 'KEY', field: (row) => row['key'])],
      serialize: (_) => {'id': 'schedule-1', 'runs': <Object?>[]},
    );
    final result = CliOutputResult.list(
      rows: const [
        {'key': 'Id'},
        {'key': 'Status'},
      ],
      schema: serializedSchema,
    );

    expect(
      jsonDecode(
        renderCliOutput(result, const CliOutputOptions(format: 'json')),
      ),
      {'id': 'schedule-1', 'runs': <Object?>[]},
    );
    expect(
      renderCliOutput(result, const CliOutputOptions(format: 'yaml')),
      'id: schedule-1\nruns: []',
    );

    final distinct = CliOutputResult.list(
      rows: const [
        {'key': 'one', 'value': 1},
        {'key': 'two', 'value': 2},
      ],
      schema: CliOutputSchema(
        idField: (row) => '${row['key']}',
        columns: [CliOutputColumn(header: 'KEY', field: (row) => row['key'])],
        serialize: (row) => row['value'],
      ),
    );
    expect(
      jsonDecode(
        renderCliOutput(distinct, const CliOutputOptions(format: 'json')),
      ),
      [1, 2],
    );
  });

  test('renders quiet IDs and content-sized tables without clipping', () {
    final result = CliOutputResult.list(rows: rows, schema: schema);
    expect(
      renderCliOutput(result, const CliOutputOptions(quiet: true)),
      'a\nlong-id',
    );

    final table = renderCliOutput(result, const CliOutputOptions());
    expect(table, contains('ID'));
    expect(table, contains('long-id'));
    expect(table, isNot(contains('…')));

    final noHeaders = renderCliOutput(
      result,
      const CliOutputOptions(noHeaders: true),
    );
    expect(noHeaders, isNot(contains('COUNT')));
    expect(noHeaders, contains('long-id'));
  });

  test('normalizes supported formats and rejects unknown values', () {
    expect(normalizeCliOutputFormat(' CLI '), 'table');
    expect(normalizeCliOutputFormat('JSON'), 'json');
    expect(normalizeCliOutputFormat('yaml'), 'yaml');
    expect(
      () => normalizeCliOutputFormat('xml'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported output format'),
        ),
      ),
    );
  });

  test('renders structured JSON YAML and human errors', () {
    final json = renderCliError(
      code: 'BROKEN',
      message: 'Failed',
      details: 'Try again',
      options: const CliOutputOptions(format: 'json'),
    );
    expect(
      (jsonDecode(json) as Map<String, dynamic>)['error'],
      containsPair('code', 'BROKEN'),
    );

    final yaml = renderCliError(
      code: 'BROKEN',
      message: 'Failed',
      details: 'Try again',
      options: const CliOutputOptions(format: 'yaml'),
    );
    expect(
      yaml,
      'error:\n  code: BROKEN\n  message: Failed\n  details: Try again',
    );

    expect(
      renderCliError(
        code: 'BROKEN',
        message: 'Failed',
        details: 'Try again',
        options: const CliOutputOptions(),
      ),
      'Error: Failed\nTry again',
    );
  });
}
