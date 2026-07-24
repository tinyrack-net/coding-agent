/// Single source of truth for the daemon version. The desktop app compiles
/// against the same workspace commit as its bundled daemon exe, so this const
/// doubles as the "bundled daemon version" on the app side.
const String daemonVersion = '0.2.0';

int majorOf(String version) {
  final match = RegExp(r'^v?(\d+)').firstMatch(version.trim());
  return match == null ? -1 : int.parse(match.group(1)!);
}

/// Remote-connection gate: same major version required.
bool majorCompatible(String a, String b) {
  final majorA = majorOf(a);
  return majorA >= 0 && majorA == majorOf(b);
}
