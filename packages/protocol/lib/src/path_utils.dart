/// Removes an exact workspace prefix from a file path for compact display.
///
/// This intentionally mirrors Paseo 0.2.0's string-based behavior rather than
/// resolving either path against the host filesystem.
String stripCwdPrefix(String filePath, [String? cwd]) {
  if (cwd == null || cwd.isEmpty || filePath.isEmpty) return filePath;

  final normalizedCwd = cwd
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  final normalizedPath = filePath.replaceAll(r'\', '/');
  final prefix = '$normalizedCwd/';
  if (normalizedPath.startsWith(prefix)) {
    return normalizedPath.substring(prefix.length);
  }
  if (normalizedPath == normalizedCwd) return '.';
  return filePath;
}
