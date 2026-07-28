/// Shell escaping used when filesystem paths are dropped on a terminal.
///
/// This intentionally mirrors Paseo 0.2.0. It is conservative rather than a
/// general-purpose shell escaper: characters which can start shell expansion
/// or redirection are removed on non-Windows hosts.
enum TerminalHostPlatform { windows, nonWindows }

final _dangerousNonWindowsPathCharacters = RegExp(r'[`$|&>~#!^*;<]');

String prepareDroppedPathForTerminal(
  String path,
  TerminalHostPlatform platform,
) {
  if (platform == TerminalHostPlatform.windows) {
    return path.contains(' ') ? '"$path"' : path;
  }

  var escaped = path.replaceAll(r'\', r'\\');
  escaped = escaped.replaceAll(_dangerousNonWindowsPathCharacters, '');
  if (escaped.contains("'") && escaped.contains('"')) {
    return "\$'${escaped.replaceAll("'", r"\'")}'";
  }
  if (escaped.contains("'")) {
    return "'${escaped.replaceAll("'", r"\'")}'";
  }
  return "'$escaped'";
}

String prepareDroppedPathsForTerminal(
  Iterable<String> paths,
  TerminalHostPlatform platform,
) => paths
    .map((path) => prepareDroppedPathForTerminal(path, platform))
    .join(' ');
