import 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;

/// Resolves the version reported by the coding-agent CLI.
///
/// The bundled daemon and CLI are released from the same workspace version,
/// which is the Dart equivalent of Paseo reading its CLI package metadata.
String resolveCliVersion([Object? packageVersion = daemonVersion]) {
  if (packageVersion is String && packageVersion.trim().isNotEmpty) {
    return packageVersion.trim();
  }
  throw StateError(
    'Unable to resolve coding-agent CLI version from package metadata.',
  );
}
