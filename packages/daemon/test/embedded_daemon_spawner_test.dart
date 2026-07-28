import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('failed embedded startup is logged, timed out, and reaped', () async {
    final temp = await Directory.systemTemp.createTemp('embedded-daemon-');
    addTearDown(() => temp.delete(recursive: true));
    final paths = DaemonPaths(dataDir: temp.path);

    await expectLater(
      spawnEmbeddedDaemon(
        paths: paths,
        host: 'invalid.invalid',
        port: 65534,
        timeout: const Duration(milliseconds: 450),
      ),
      throwsA(
        isA<DaemonSpawnException>().having(
          (error) => error.message,
          'message',
          contains('did not become healthy'),
        ),
      ),
    );

    final log = File(paths.logFile);
    expect(await log.exists(), isTrue);
    expect(await log.readAsString(), contains('embedded daemon failed'));
  });
}
