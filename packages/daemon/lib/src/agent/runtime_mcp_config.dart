const internalTinyrackMcpServerName = 'tinyrack';
const internalPaseoMcpServerName = 'paseo';
const agentMcpPath = '/mcp/agents';

Map<String, Object?> stripInternalAgentMcpServers(
  Map<String, Object?> mcpServers,
) {
  if (mcpServers.isEmpty) return mcpServers;
  final next = <String, Object?>{...mcpServers};
  var changed = false;
  for (final name in const [
    internalTinyrackMcpServerName,
    internalPaseoMcpServerName,
  ]) {
    final value = next[name];
    if (value is Map && _isInternalAgentMcpServer(value)) {
      next.remove(name);
      changed = true;
    }
  }
  return changed ? Map.unmodifiable(next) : mcpServers;
}

Map<String, Object?> withRuntimeTinyrackMcpServer({
  required Map<String, Object?> storedMcpServers,
  required String agentId,
  required String? mcpBaseUrl,
  required String? mcpAuthToken,
}) {
  final stripped = stripInternalAgentMcpServers(storedMcpServers);
  if (mcpBaseUrl == null ||
      stripped.containsKey(internalTinyrackMcpServerName)) {
    return stripped;
  }
  final url = '$mcpBaseUrl?callerAgentId=$agentId';
  return Map.unmodifiable({
    internalTinyrackMcpServerName: <String, Object?>{
      'type': 'http',
      'url': url,
      if (mcpAuthToken != null)
        'headers': <String, Object?>{'Authorization': 'Bearer $mcpAuthToken'},
    },
    ...stripped,
  });
}

bool _isInternalAgentMcpServer(Map<dynamic, dynamic> config) {
  final type = config['type'];
  final url = config['url'];
  if ((type != 'http' && type != 'sse') || url is! String) return false;
  final parsed = Uri.tryParse(url);
  return parsed != null && parsed.hasScheme && parsed.path == agentMcpPath;
}
