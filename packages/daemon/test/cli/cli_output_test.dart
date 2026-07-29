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

  test('renders one serializer-aware compact JSON line for streaming', () {
    expect(
      renderCliJsonLine({
        'id': 'agent-1',
        'status': 'running',
        'message': 'line one\nline two',
      }),
      '{"id":"agent-1","status":"running","message":"line one\\nline two"}',
    );
    expect(
      renderCliJsonLine<Map<String, Object?>>(
        {'id': 'agent-2', 'status': 'idle'},
        serialize: (item) => {
          'agent': item['id'],
          'ready': item['status'] == 'idle',
        },
      ),
      '{"agent":"agent-2","ready":true}',
    );
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
    expect(
      encodeCliYaml({
        'numericString': '123456789',
        'dateString': '2026-07-30',
        'actualNumber': 123456789,
      }),
      'numericString: "123456789"\n'
      'dateString: "2026-07-30"\n'
      'actualNumber: 123456789',
    );
  });

  test('renders one serializer-aware YAML document for streaming', () {
    expect(
      renderCliYamlDocument({
        'id': 'agent-1',
        'status': 'running',
        'labels': ['core'],
      }),
      'id: agent-1\nstatus: running\nlabels:\n  - core',
    );
    expect(
      renderCliYamlDocument<Map<String, Object?>>(
        {'id': 'agent-2', 'status': 'idle'},
        serialize: (item) => {
          'agent': item['id'],
          'ready': item['status'] == 'idle',
          'numericText': '001',
        },
      ),
      'agent: agent-2\nready: true\nnumericText: "001"',
    );
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

  test('renders ANSI colors without corrupting visible column widths', () {
    final colorSchema = CliOutputSchema(
      idField: (row) => '${row['id']}',
      columns: [
        CliOutputColumn(
          header: 'STATE',
          field: (row) => row['state'],
          width: 8,
          color: (value, _) => value == 'ok' ? 'green' : 'red',
        ),
        CliOutputColumn(
          header: 'COUNT',
          field: (row) => row['count'],
          alignment: CliOutputAlignment.right,
        ),
      ],
    );
    final result = CliOutputResult.list(
      rows: const [
        {'id': 'one', 'state': 'ok', 'count': 2},
        {'id': 'two', 'state': 'failed', 'count': 10},
      ],
      schema: colorSchema,
    );

    final colored = renderCliOutput(
      result,
      const CliOutputOptions(colorEnabled: true),
    );
    expect(colored, startsWith('\x1b[1mSTATE'));
    expect(colored, contains('\x1b[32mok\x1b[39m'));
    expect(colored, contains('\x1b[31mfailed\x1b[39m'));
    expect(
      colored.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''),
      'STATE     COUNT\n'
      'ok            2\n'
      'failed       10',
    );

    final plain = renderCliOutput(
      result,
      const CliOutputOptions(colorEnabled: true, noColor: true),
    );
    expect(plain, isNot(contains('\x1b[')));
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
