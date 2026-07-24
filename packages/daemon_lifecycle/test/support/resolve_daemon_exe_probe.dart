// Tiny helper script run as a *separate OS process* by
// daemon_exe_resolver_test.dart so it can exercise resolveDaemonExe() with a
// controlled current working directory via Process.start(workingDirectory:),
// without ever mutating Directory.current in the test runner process itself.
// (Directory.current is process-global; mutating it from a test is unsafe
// under `dart test`'s default concurrent-file execution.)
import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';

Future<void> main() async {
  final result = await resolveDaemonExe();
  stdout.write(result ?? '');
}
