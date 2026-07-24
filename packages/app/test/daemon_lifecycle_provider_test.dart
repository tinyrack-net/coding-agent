import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSupervisor extends DaemonSupervisor {
  FakeSupervisor({this.spawnError, DaemonStatus? initial})
      : _status = initial ??
            const DaemonStatus(
              health: DaemonHealth.running,
              hello: ServerHello(
                daemonVersion: '0.2.0',
                protocolVersion: 1,
                pid: 4242,
                desktopManaged: true,
              ),
            );

  final DaemonSpawnException? spawnError;
  DaemonStatus _status;
  int ensureCalls = 0;
  int restartCalls = 0;
  int stopCalls = 0;

  @override
  Future<DaemonStatus> status() async => _status;

  @override
  Future<DaemonStatus> ensureRunning() async {
    ensureCalls++;
    final error = spawnError;
    if (error != null) throw error;
    return _status;
  }

  @override
  Future<DaemonStatus> restart() async {
    restartCalls++;
    return _status;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _status = const DaemonStatus(health: DaemonHealth.stopped);
  }
}

ProviderContainer makeContainer({
  required bool desktop,
  required FakeSupervisor supervisor,
}) {
  final container = ProviderContainer(
    overrides: [
      desktopShellProvider.overrideWithValue(desktop),
      daemonSupervisorFactoryProvider.overrideWithValue((_) => supervisor),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('desktop + loopback: ensures the daemon and exposes its status',
      () async {
    final supervisor = FakeSupervisor();
    final container = makeContainer(desktop: true, supervisor: supervisor);

    final status = await container.read(daemonLifecycleProvider.future);

    expect(supervisor.ensureCalls, 1);
    expect(status, isNotNull);
    expect(status!.isRunning, isTrue);
    expect(status.hello?.pid, 4242);
  });

  test('non-desktop shell: state is null and no supervisor call is made',
      () async {
    final supervisor = FakeSupervisor();
    final container = makeContainer(desktop: false, supervisor: supervisor);

    final status = await container.read(daemonLifecycleProvider.future);

    expect(status, isNull);
    expect(supervisor.ensureCalls, 0);
  });

  test('remote host: state is null and no supervisor call is made', () async {
    final supervisor = FakeSupervisor();
    final container = makeContainer(desktop: true, supervisor: supervisor);
    container.read(connectionSettingsProvider.notifier).save(
          host: '192.168.0.10',
          port: 6868,
        );

    final status = await container.read(daemonLifecycleProvider.future);

    expect(status, isNull);
    expect(supervisor.ensureCalls, 0);
  });

  test('spawn failure surfaces as AsyncError with message and log tail',
      () async {
    final supervisor = FakeSupervisor(
      spawnError: DaemonSpawnException('port 6868 in use', logTail: 'boom'),
    );
    final container = makeContainer(desktop: true, supervisor: supervisor);

    await expectLater(
      container.read(daemonLifecycleProvider.future),
      throwsA(isA<DaemonSpawnException>()),
    );
    final state = container.read(daemonLifecycleProvider);
    expect(state, isA<AsyncError<DaemonStatus?>>());
    expect('${state.error}', contains('port 6868 in use'));
    expect('${state.error}', contains('boom'));
  });

  test('restart() delegates to the supervisor and updates state', () async {
    final supervisor = FakeSupervisor();
    final container = makeContainer(desktop: true, supervisor: supervisor);
    await container.read(daemonLifecycleProvider.future);

    await container.read(daemonLifecycleProvider.notifier).restart();

    expect(supervisor.restartCalls, 1);
    expect(container.read(daemonLifecycleProvider).value?.isRunning, isTrue);
  });

  test('stopDaemon() stops and reflects the stopped status', () async {
    final supervisor = FakeSupervisor();
    final container = makeContainer(desktop: true, supervisor: supervisor);
    await container.read(daemonLifecycleProvider.future);

    await container.read(daemonLifecycleProvider.notifier).stopDaemon();

    expect(supervisor.stopCalls, 1);
    expect(container.read(daemonLifecycleProvider).value?.isRunning, isFalse);
  });
}
