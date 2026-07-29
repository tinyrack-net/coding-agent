import 'cli_output.dart';

/// Frozen Paseo 0.2.0 `agentRunSchema`, shared by `run` and `import`.
CliOutputSchema agentRunOutputSchema({
  CliOutputSerializer? serialize,
}) => CliOutputSchema(
  idField: (row) => '${row['agentId']}',
  columns: [
    CliOutputColumn(
      header: 'AGENT ID',
      field: (row) => row['agentId'],
      width: 12,
    ),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status'], width: 10),
    CliOutputColumn(
      header: 'PROVIDER',
      field: (row) => row['provider'],
      width: 10,
    ),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 30),
    CliOutputColumn(header: 'TITLE', field: (row) => row['title'], width: 20),
  ],
  serialize: serialize,
);
