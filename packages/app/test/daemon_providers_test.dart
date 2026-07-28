import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake with a controllable connectionState stream and scriptable request().
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    DaemonConnectionState initial = DaemonConnectionState.disconnected,
  }) : _state = initial,
       super(uri: Uri.parse('ws://fake'));

  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState _state;
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      connectionController.stream;

  @override
  DaemonConnectionState get currentState => _state;

  void setState(DaemonConnectionState state) {
    _state = state;
    connectionController.add(state);
  }

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return onRequest?.call(type, payload) ?? const {};
  }
}

class FakeSupervisor extends DaemonSupervisor {
  int ensureCalls = 0;

  @override
  Future<DaemonStatus> ensureRunning() async {
    ensureCalls++;
    return const DaemonStatus(health: DaemonHealth.running);
  }
}

class TrackingDaemonClient extends DaemonClient {
  TrackingDaemonClient(Uri uri) : super(uri: uri);

  int connectCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
  }

  @override
  void dispose() {
    disposeCalls++;
  }
}

class MultiHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      _host('server-a', 'a.example:7001'),
      _host('server-b', 'b.example:7002'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

void main() {
  group('daemonClientProvider', () {
    test(
      'host runtime keeps every registered client alive across selection',
      () async {
        final created = <String, TrackingDaemonClient>{};
        final container = ProviderContainer(
          overrides: [
            desktopShellProvider.overrideWithValue(false),
            hostRegistryProvider.overrideWith(MultiHostRegistry.new),
            daemonClientFactoryProvider.overrideWithValue(
              (settings) => created.putIfAbsent(
                settings.host,
                () => TrackingDaemonClient(settings.uri),
              ),
            ),
          ],
        );

        final sessions = container.read(hostRuntimeClientsProvider);
        expect(sessions.keys, {'server-a', 'server-b'});
        expect(created.keys, {'a.example', 'b.example'});
        expect(
          created.values.map((client) => client.connectCalls),
          everyElement(1),
        );
        expect(
          container.read(daemonClientProvider),
          same(sessions['server-a']),
        );

        await container
            .read(hostRegistryProvider.notifier)
            .selectHost('server-b');
        final after = container.read(hostRuntimeClientsProvider);
        expect(after['server-a'], same(sessions['server-a']));
        expect(after['server-b'], same(sessions['server-b']));
        expect(
          container.read(daemonClientProvider),
          same(sessions['server-b']),
        );
        expect(
          created.values.map((client) => client.disposeCalls),
          everyElement(0),
        );

        await container
            .read(hostRegistryProvider.notifier)
            .removeHost('server-a');
        await container.pump();
        expect(container.read(hostRuntimeClientsProvider).keys, {'server-b'});
        expect(created['a.example']!.disposeCalls, 1);
        expect(created['b.example']!.disposeCalls, 0);

        container.dispose();
        expect(created['a.example']!.disposeCalls, 1);
        expect(created['b.example']!.disposeCalls, 1);
      },
    );

    test(
      'non-desktop shell: constructs and connects a client from settings',
      () {
        final container = ProviderContainer(
          overrides: [desktopShellProvider.overrideWithValue(false)],
        );
        addTearDown(container.dispose);

        final client = container.read(daemonClientProvider);

        expect(client.uri, const ConnectionSettings().uri);
        expect(client.token, isNull);
      },
    );

    test('recreates the client when connection settings change', () {
      final container = ProviderContainer(
        overrides: [desktopShellProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      final before = container.read(daemonClientProvider);
      container
          .read(connectionSettingsProvider.notifier)
          .save(host: '10.2.2.2', port: 7777);
      final after = container.read(daemonClientProvider);

      expect(identical(before, after), isFalse);
      expect(after.uri.host, '10.2.2.2');
      expect(after.uri.port, 7777);
    });

    test('desktop + loopback: the client is only created after the lifecycle '
        "provider's ensureRunning() resolves", () async {
      final supervisor = FakeSupervisor();
      final container = ProviderContainer(
        overrides: [
          desktopShellProvider.overrideWithValue(true),
          daemonSupervisorFactoryProvider.overrideWithValue((_) => supervisor),
        ],
      );
      addTearDown(container.dispose);

      // Reading the client while the lifecycle provider is still resolving
      // must not throw, and the supervisor is consulted exactly once overall
      // (by the lifecycle provider's own build(), not by the client).
      container.read(daemonClientProvider);
      await container.read(daemonLifecycleProvider.future);
      // The lifecycle resolving invalidates/rebuilds daemonClientProvider,
      // which is now free to connect; re-reading it must not re-run
      // ensureRunning() a second time.
      container.read(daemonClientProvider);
      expect(supervisor.ensureCalls, 1);
    });
  });

  group('connectionStateProvider', () {
    test('mirrors the client connectionState stream', () async {
      final fake = FakeDaemonClient();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(connectionStateProvider, (_, _) {});
      addTearDown(sub.close);

      fake.setState(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(sub.read().value, DaemonConnectionState.connected);

      fake.setState(DaemonConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(sub.read().value, DaemonConnectionState.disconnected);
    });
  });

  group('providerListProvider', () {
    test('returns an empty list until the client is connected', () async {
      final fake = FakeDaemonClient();
      fake.onRequest = (type, payload) => {
        'providers': [
          const ProviderInfo(
            id: ProviderId.openai,
            displayName: 'Codex',
            configured: true,
          ).toJson(),
        ],
      };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(providerListProvider, (_, _) {});
      addTearDown(sub.close);
      // Emit the (disconnected) initial state so connectionStateProvider's
      // future resolves; providerListProvider should then settle on `[]`
      // without ever calling provider.list.request.
      fake.setState(DaemonConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(sub.read().value, isEmpty);
    });

    test('fetches provider.list once connected', () async {
      final fake = FakeDaemonClient();
      fake.onRequest = (type, payload) {
        expect(type, MessageTypes.providerListRequest);
        return {
          'providers': [
            const ProviderInfo(
              id: ProviderId.openai,
              displayName: 'Codex',
              configured: true,
            ).toJson(),
          ],
        };
      };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(providerListProvider, (_, _) {});
      addTearDown(sub.close);

      fake.setState(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final providers = sub.read().value;
      expect(providers, isNotNull);
      expect(providers!.single.displayName, 'Codex');
    });
  });

  group('ProviderCredentialActions', () {
    test(
      'setKey sends providerId/apiKey and invalidates the provider list',
      () async {
        final fake = FakeDaemonClient();
        final calls = <(String, Map<String, Object?>)>[];
        fake.onRequest = (type, payload) {
          calls.add((type, payload));
          return const {};
        };
        final container = ProviderContainer(
          overrides: [daemonClientProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        await container
            .read(providerCredentialActionsProvider)
            .setKey(ProviderId.deepseek, 'sk-test');

        final call = calls.singleWhere(
          (c) => c.$1 == MessageTypes.providerCredentialSetRequest,
        );
        expect(call.$2['providerId'], 'deepseek');
        expect(call.$2['apiKey'], 'sk-test');
      },
    );

    test('clearKey sends providerId only', () async {
      final fake = FakeDaemonClient();
      final calls = <(String, Map<String, Object?>)>[];
      fake.onRequest = (type, payload) {
        calls.add((type, payload));
        return const {};
      };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      await container
          .read(providerCredentialActionsProvider)
          .clearKey(ProviderId.openrouter);

      final call = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerCredentialClearRequest,
      );
      expect(call.$2['providerId'], 'openrouter');
    });

    test(
      'testKey returns the parsed result and omits apiKey when not given',
      () async {
        final fake = FakeDaemonClient();
        Map<String, Object?>? capturedPayload;
        fake.onRequest = (type, payload) {
          capturedPayload = payload;
          return {'ok': true};
        };
        final container = ProviderContainer(
          overrides: [daemonClientProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        final result = await container
            .read(providerCredentialActionsProvider)
            .testKey(ProviderId.openai);

        expect(result.ok, isTrue);
        expect(capturedPayload!.containsKey('apiKey'), isFalse);
      },
    );

    test('testKey includes apiKey when explicitly given', () async {
      final fake = FakeDaemonClient();
      Map<String, Object?>? capturedPayload;
      fake.onRequest = (type, payload) {
        capturedPayload = payload;
        return {'ok': false, 'error': 'bad key'};
      };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(providerCredentialActionsProvider)
          .testKey(ProviderId.openai, apiKey: 'sk-try-me');

      expect(result.ok, isFalse);
      expect(result.error, 'bad key');
      expect(capturedPayload!['apiKey'], 'sk-try-me');
    });
  });
}

HostProfile _host(String serverId, String endpoint) => HostProfile(
  serverId: serverId,
  label: serverId,
  connections: [
    DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
  ],
  preferredConnectionId: 'direct:$endpoint',
  createdAt: '2026-07-28T00:00:00.000Z',
  updatedAt: '2026-07-28T00:00:00.000Z',
);
