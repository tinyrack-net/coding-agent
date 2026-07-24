// Tiny helper script run as a *separate OS process* by daemon_paths_test.dart
// so it can exercise DaemonPaths.defaultDataDir()'s USERPROFILE/HOME fallback
// chain with a controlled environment (via Process.run(environment: ...,
// includeParentEnvironment: false)), without mutating the real process
// environment of the test runner (dart:io has no supported API for that).
import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';

void main() {
  stdout.write(DaemonPaths.defaultDataDir());
}
