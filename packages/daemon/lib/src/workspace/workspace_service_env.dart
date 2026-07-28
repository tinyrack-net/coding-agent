import 'service_proxy_names.dart';

final class WorkspaceServicePeer {
  const WorkspaceServicePeer({required this.scriptName, required this.port});

  final String scriptName;
  final int port;
}

String normalizeServiceEnvName(String scriptName) => scriptName
    .toUpperCase()
    .replaceAll(RegExp('[^A-Z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

Map<String, String> buildWorkspaceServiceEnv({
  required String scriptName,
  required String projectSlug,
  required String? branchName,
  required int? daemonPort,
  required String? daemonListenHost,
  String? serviceProxyPublicBaseUrl,
  required List<WorkspaceServicePeer> peers,
}) {
  assertNoServiceEnvNameCollisions(
    peers.map((peer) => peer.scriptName).toList(),
  );
  final self = peers.where((peer) => peer.scriptName == scriptName).firstOrNull;
  if (self == null) {
    throw StateError(
      "Service '$scriptName' is missing from workspace service peers",
    );
  }
  final environment = <String, String>{
    'HOST': resolveServiceBindHost(daemonListenHost),
    'TINYRACK_PORT': '${self.port}',
  };
  final selfUrl = projectServiceProxyUrls(
    projectSlug: projectSlug,
    branchName: branchName,
    scriptName: scriptName,
    daemonPort: daemonPort,
    publicBaseUrl: serviceProxyPublicBaseUrl,
  ).proxyUrl;
  if (selfUrl != null) environment['TINYRACK_URL'] = selfUrl;

  for (final peer in peers) {
    final name = normalizeServiceEnvName(peer.scriptName);
    environment['TINYRACK_SERVICE_${name}_PORT'] = '${peer.port}';
    final url = projectServiceProxyUrls(
      projectSlug: projectSlug,
      branchName: branchName,
      scriptName: peer.scriptName,
      daemonPort: daemonPort,
      publicBaseUrl: serviceProxyPublicBaseUrl,
    ).proxyUrl;
    if (url != null) environment['TINYRACK_SERVICE_${name}_URL'] = url;
  }
  return environment;
}

String resolveServiceBindHost(String? daemonListenHost) {
  if (daemonListenHost == null || daemonListenHost.trim().isEmpty) {
    return '127.0.0.1';
  }
  return switch (daemonListenHost.trim().toLowerCase()) {
    'localhost' || '127.0.0.1' || '::1' || '[::1]' => '127.0.0.1',
    _ => '0.0.0.0',
  };
}

void assertNoServiceEnvNameCollisions(List<String> scriptNames) {
  final namesByEnvironment = <String, List<String>>{};
  for (final scriptName in scriptNames) {
    final name = normalizeServiceEnvName(scriptName);
    (namesByEnvironment[name] ??= []).add(scriptName);
  }
  final collisions = <String>[
    for (final entry in namesByEnvironment.entries)
      if (entry.value.length > 1)
        'Service env name collision for ${entry.key}: '
            '${entry.value.join(', ')}',
  ];
  if (collisions.isNotEmpty) {
    throw StateError(collisions.join('; '));
  }
}
