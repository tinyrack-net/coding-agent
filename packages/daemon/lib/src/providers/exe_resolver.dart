import 'dart:io';

/// Resolves provider CLI executables on PATH.
///
/// On Windows, `Process.start('claude', ...)` fails for `.cmd`/`.bat` shims,
/// so we always resolve to a concrete file first (`where` / `which`) and, if
/// the match is a batch shim, callers must spawn it via `cmd /c`.
class ExeResolver {
  final Map<String, String?> _cache = {};

  /// Returns the absolute path of [command], or null if not found.
  Future<String?> resolve(String command) async {
    if (_cache.containsKey(command)) return _cache[command];
    final lookup = Platform.isWindows
        ? await Process.run('where', [command])
        : await Process.run('which', [command]);
    String? path;
    if (lookup.exitCode == 0) {
      final lines = (lookup.stdout as String)
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        // Prefer a real executable over a batch shim when both exist.
        path = lines.firstWhere(
          (l) => l.toLowerCase().endsWith('.exe'),
          orElse: () => lines.first,
        ).trim();
      }
    }
    _cache[command] = path;
    return path;
  }

  static bool isBatchShim(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.cmd') || lower.endsWith('.bat');
  }
}
