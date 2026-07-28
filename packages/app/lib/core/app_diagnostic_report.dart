import 'package:agent_protocol/agent_protocol.dart';

String formatDiagnosticSection(
  String title,
  Iterable<(String, String)> entries,
) => [
  title,
  for (final entry in entries) '  ${entry.$1}: ${entry.$2}',
].join('\n');

String formatAppDiagnosticHeader({
  required DateTime collectedAt,
  required String? appVersion,
  required String platform,
  required bool isDesktopApp,
  required int hostCount,
}) => formatDiagnosticSection('Tinyrack app diagnostics', [
  ('Collected at', collectedAt.toUtc().toIso8601String()),
  ('App version', appVersion ?? 'unknown'),
  ('Platform', platform),
  ('Desktop app', '$isDesktopApp'),
  ('Saved hosts', '$hostCount'),
]);

String formatHostDiagnosticSection({
  required HostProfile host,
  required String status,
  String activeConnection = 'none',
  String lastError = 'none',
}) {
  final rows = <(String, String)>[
    ('Server ID', host.serverId),
    ('Status', status),
    ('Active connection', activeConnection),
    ('Last error', lastError),
  ];
  for (var index = 0; index < host.connections.length; index += 1) {
    final connection = host.connections[index];
    rows.add((
      'Connection ${index + 1}',
      '${describeConnectionKind(connection)}, '
          '${connection.id == host.preferredConnectionId ? 'active' : 'inactive'}',
    ));
  }
  return formatDiagnosticSection('Host: ${host.label}', rows);
}

String formatServerInfoSection(ServerInfoStatus? serverInfo) {
  if (serverInfo == null) {
    return formatDiagnosticSection('Server info', const [
      ('Status', 'not received'),
    ]);
  }
  final features = serverInfo.features.keys.toList()..sort();
  return formatDiagnosticSection('Server info', [
    ('Server ID', serverInfo.serverId),
    ('Hostname', serverInfo.hostname ?? 'unknown'),
    ('Version', serverInfo.version ?? 'unknown'),
    ('Desktop managed', serverInfo.desktopManaged ? 'yes' : 'no'),
    ('Features', features.isEmpty ? 'none' : features.join(', ')),
  ]);
}

String describeConnectionKind(HostConnection connection) =>
    switch (connection) {
      DirectTcpHostConnection() => 'direct TCP',
      RelayHostConnection() => 'relay',
      DirectSocketHostConnection() => 'local socket',
      DirectPipeHostConnection() => 'local pipe',
    };

String redactAppDiagnosticReport(String report, Iterable<HostProfile> hosts) {
  var redacted = report;
  final sensitive = <String>{};
  for (final host in hosts) {
    for (final connection in host.connections) {
      sensitive.add(connection.id);
      switch (connection) {
        case DirectTcpHostConnection():
          sensitive.add(connection.endpoint);
          if (connection.password != null) sensitive.add(connection.password!);
        case RelayHostConnection():
          sensitive
            ..add(connection.relayEndpoint)
            ..add(connection.daemonPublicKeyB64);
        case DirectSocketHostConnection():
          sensitive.add(connection.path);
        case DirectPipeHostConnection():
          sensitive.add(connection.path);
      }
    }
  }
  for (final value in sensitive.where((value) => value.trim().isNotEmpty)) {
    redacted = redacted.replaceAll(value, '[redacted]');
  }
  return redacted
      .replaceAll(
        RegExp(r'coding-agent://\S+', caseSensitive: false),
        'coding-agent://[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''([?&](?:password|token|secret|key|publicKey|daemonPublicKeyB64)=)[^&\s"']+''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''((?:password|token|secret|authorization|api[_-]?key|daemonPublicKeyB64|relayKey)\s*[:=]\s*)("[^"]+"|'[^']+'|[^\s,}]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      );
}
