import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_config_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeConfigDaemonClient extends DaemonClient {
  FakeConfigDaemonClient() : super(uri: Uri.parse('ws://127.0.0.1:6868'));

  final connections = StreamController<DaemonConnectionState>.broadcast();
  final changes = StreamController<DaemonConfigChangedStatus>.broadcast();
  DaemonConnectionState connection = DaemonConnectionState.connected;
  MutableDaemonConfig config = const MutableDaemonConfig(
    injectMcpIntoAgents: false,
  );
  int getCalls = 0;

  @override
  DaemonConnectionState get currentState => connection;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  @override
  Stream<DaemonConfigChangedStatus> get daemonConfigChanges => changes.stream;

  @override
  Future<MutableDaemonConfig> getDaemonConfig({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    getCalls++;
    return config;
  }

  @override
  Future<MutableDaemonConfig> patchDaemonConfig(
    MutableDaemonConfigPatch patch, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    config = MutableDaemonConfig(
      injectMcpIntoAgents: config.injectMcpIntoAgents,
      enableTerminalAgentHooks:
          patch.enableTerminalAgentHooks ?? config.enableTerminalAgentHooks,
    );
    return config;
  }

  Future<void> closeFake() async {
    await connections.close();
    await changes.close();
  }
}

void main() {
  late FakeConfigDaemonClient client;
  late ProviderContainer container;

  setUp(() {
    client = FakeConfigDaemonClient();
    container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
  });

  tearDown(() async {
    container.dispose();
    client.dispose();
    await client.closeFake();
  });

  test('loads, patches, and applies pushed replica changes', () async {
    expect(
      (await container.read(
        daemonConfigProvider.future,
      ))!.enableTerminalAgentHooks,
      isFalse,
    );
    expect(client.getCalls, 1);

    await container
        .read(daemonConfigProvider.notifier)
        .setTerminalAgentHooks(true);
    expect(
      container
          .read(daemonConfigProvider)
          .requireValue!
          .enableTerminalAgentHooks,
      isTrue,
    );

    client.changes.add(
      const DaemonConfigChangedStatus(
        config: MutableDaemonConfig(
          injectMcpIntoAgents: false,
          enableTerminalAgentHooks: false,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container
          .read(daemonConfigProvider)
          .requireValue!
          .enableTerminalAgentHooks,
      isFalse,
    );
  });

  test(
    'disconnect clears and reconnect refreshes the config replica',
    () async {
      await container.read(daemonConfigProvider.future);

      client
        ..connection = DaemonConnectionState.disconnected
        ..connections.add(DaemonConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(daemonConfigProvider).requireValue, isNull);

      client
        ..config = const MutableDaemonConfig(
          injectMcpIntoAgents: false,
          enableTerminalAgentHooks: true,
        )
        ..connection = DaemonConnectionState.connected
        ..connections.add(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        container
            .read(daemonConfigProvider)
            .requireValue!
            .enableTerminalAgentHooks,
        isTrue,
      );
      expect(client.getCalls, 2);
    },
  );

  test('explicit refresh while disconnected keeps the replica empty', () async {
    client.connection = DaemonConnectionState.disconnected;
    expect(await container.read(daemonConfigProvider.future), isNull);

    expect(
      await container.read(daemonConfigProvider.notifier).refresh(),
      isNull,
    );
    expect(container.read(daemonConfigProvider).requireValue, isNull);
    expect(client.getCalls, 0);
  });
}
