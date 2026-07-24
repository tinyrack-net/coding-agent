import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake with a controllable connectionState stream and scriptable request().
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({DaemonConnectionState initial = DaemonConnectionState.disconnected})
      : _state = initial,
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

void main() {
  group('daemonClientProvider', () {
    test('non-desktop shell: constructs and connects a client from settings',
        () {
      final container = ProviderContainer(
        overrides: [desktopShellProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      final client = container.read(daemonClientProvider);

      expect(client.uri, const ConnectionSettings().uri);
      expect(client.token, isNull);
    });

    test('recreates the client when connection settings change', () {
      final container = ProviderContainer(
        overrides: [desktopShellProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      final before = container.read(daemonClientProvider);
      container.read(connectionSettingsProvider.notifier).save(
            host: '10.2.2.2',
            port: 7777,
          );
      final after = container.read(daemonClientProvider);

      expect(identical(before, after), isFalse);
      expect(after.uri.host, '10.2.2.2');
      expect(after.uri.port, 7777);
    });

    test(
        'desktop + loopback: the client is only created after the lifecycle '
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

      final sub = container.listen(connectionStateProvider, (_, __) {});
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
                id: ProviderId.claude,
                displayName: 'Claude',
                available: true,
              ).toJson(),
            ],
          };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(providerListProvider, (_, __) {});
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
              id: ProviderId.claude,
              displayName: 'Claude',
              available: true,
            ).toJson(),
          ],
        };
      };
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(providerListProvider, (_, __) {});
      addTearDown(sub.close);

      fake.setState(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final providers = sub.read().value;
      expect(providers, isNotNull);
      expect(providers!.single.displayName, 'Claude');
    });
  });
}
