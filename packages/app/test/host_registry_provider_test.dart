import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer container() {
    final result = ProviderContainer();
    addTearDown(result.dispose);
    return result;
  }

  test('loads profiles and restores a valid active host', () async {
    final profile = _profile('server-a', 'a.example:443', useTls: true);
    SharedPreferences.setMockInitialValues({
      hostRegistryStorageKey: jsonEncode([profile.toJson()]),
      activeHostStorageKey: 'server-a',
    });
    final scope = container()..read(hostRegistryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = scope.read(hostRegistryProvider);
    expect(state.loaded, isTrue);
    expect(state.activeHost?.serverId, 'server-a');
    expect(
      state.activeHost?.connections.single,
      isA<DirectTcpHostConnection>(),
    );
  });

  test('drops malformed stored profiles independently', () async {
    SharedPreferences.setMockInitialValues({
      hostRegistryStorageKey: jsonEncode([
        {'serverId': 'invalid'},
        _profile('valid', 'localhost:6868').toJson(),
      ]),
    });
    final scope = container()..read(hostRegistryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(scope.read(hostRegistryProvider).hosts.single.serverId, 'valid');
  });

  test('upserts, selects, renames and removes hosts persistently', () async {
    SharedPreferences.setMockInitialValues({});
    final scope = container()..read(hostRegistryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final actions = scope.read(hostRegistryProvider.notifier);

    await actions.upsertDirectConnection(
      serverId: 'server-a',
      endpoint: '127.0.0.1:6868',
      label: 'Local',
      now: DateTime.utc(2026, 7, 26),
    );
    await actions.upsertDirectConnection(
      serverId: 'server-b',
      endpoint: 'remote.example:443',
      useTls: true,
      password: 'secret',
      now: DateTime.utc(2026, 7, 26, 1),
    );
    await actions.selectHost('server-b');
    await actions.renameHost('server-b', 'Remote');

    var state = scope.read(hostRegistryProvider);
    expect(state.hosts, hasLength(2));
    expect(state.activeHost?.label, 'Remote');
    expect(
      scope.read(effectiveConnectionSettingsProvider),
      const ConnectionSettings(
        host: 'remote.example',
        port: 443,
        token: 'secret',
        useTls: true,
      ),
    );

    final remoteConnection = state.activeHost!.connections.single;
    await actions.removeConnection('server-b', remoteConnection.id);
    state = scope.read(hostRegistryProvider);
    expect(state.hosts.map((host) => host.serverId), ['server-a']);
    expect(state.activeServerId, 'server-a');

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(activeHostStorageKey), 'server-a');
  });

  test('pairing offers create relay profiles with the Paseo id', () async {
    SharedPreferences.setMockInitialValues({});
    final scope = container()..read(hostRegistryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final profile = await scope
        .read(hostRegistryProvider.notifier)
        .upsertConnectionOffer(
          const ConnectionOffer(
            serverId: 'paired',
            daemonPublicKeyB64: 'key',
            relay: ConnectionOfferRelay(endpoint: 'relay.example:443'),
          ),
          now: DateTime.utc(2026, 7, 26),
        );

    final relay = profile.connections.single as RelayHostConnection;
    expect(relay.id, 'relay:wss:relay.example:443');
    expect(relay.useTls, isTrue);
  });

  test(
    'reconcileServerId merges connections and preserves active host',
    () async {
      SharedPreferences.setMockInitialValues({});
      final scope = container()..read(hostRegistryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final actions = scope.read(hostRegistryProvider.notifier);
      await actions.upsertDirectConnection(
        serverId: 'provisional',
        endpoint: 'local.example:6868',
        label: 'Provisional',
        now: DateTime.utc(2026, 7, 26),
      );
      await actions.upsertDirectConnection(
        serverId: 'authoritative',
        endpoint: 'remote.example:6868',
        label: 'Existing',
        now: DateTime.utc(2026, 7, 26, 1),
      );
      await actions.selectHost('provisional');

      await actions.reconcileServerId(
        oldServerId: 'provisional',
        newServerId: 'authoritative',
        label: 'Connected host',
        now: DateTime.utc(2026, 7, 26, 2),
      );

      final state = scope.read(hostRegistryProvider);
      expect(state.hosts, hasLength(1));
      expect(state.activeServerId, 'authoritative');
      expect(state.activeHost?.label, 'Connected host');
      expect(
        state.activeHost?.connections
            .map((connection) => connection.id)
            .toSet(),
        {'direct:remote.example:6868', 'direct:local.example:6868'},
      );
    },
  );

  test('selectHost rejects unknown server ids', () async {
    SharedPreferences.setMockInitialValues({});
    final scope = container()..read(hostRegistryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      () => scope.read(hostRegistryProvider.notifier).selectHost('missing'),
      throwsArgumentError,
    );
  });

  test('state falls back from stale active ids and can clear selection', () {
    final profile = _profile('server-a', 'localhost:6868');
    final state = HostRegistryState(
      hosts: [profile],
      activeServerId: 'stale',
      loaded: true,
    );
    expect(state.activeHost, profile);
    expect(state.copyWith(clearActiveServerId: true).activeServerId, isNull);
  });

  test('settings host resolution skips a stopped remembered local daemon', () {
    final remote = _profile('server-remote', 'remote.example:6868');
    expect(
      resolveActiveHostServerId(
        selectedServerId: null,
        localServerId: 'server-local-stopped',
        hosts: [remote],
        orderedHosts: [remote],
      ),
      'server-remote',
    );
    expect(
      resolveActiveHostServerId(
        selectedServerId: 'stale-selection',
        localServerId: 'server-local-stopped',
        hosts: [remote],
        orderedHosts: [remote],
      ),
      'server-remote',
    );
    expect(
      resolveActiveHostServerId(
        selectedServerId: null,
        localServerId: 'server-local-stopped',
        hosts: const [],
        orderedHosts: const [],
      ),
      isNull,
    );
  });

  test(
    'rename validates labels and removeHost maintains active selection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final scope = container()..read(hostRegistryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final actions = scope.read(hostRegistryProvider.notifier);
      await actions.upsertDirectConnection(
        serverId: 'server-a',
        endpoint: 'a.example:6868',
      );
      await actions.upsertDirectConnection(
        serverId: 'server-b',
        endpoint: 'b.example:6868',
      );

      expect(() => actions.renameHost('server-a', ' '), throwsArgumentError);
      await actions.removeHost('server-b');
      expect(scope.read(hostRegistryProvider).activeServerId, 'server-a');
      await actions.removeHost('server-a');
      expect(scope.read(hostRegistryProvider).activeServerId, isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey(activeHostStorageKey), isFalse);
    },
  );

  test(
    'removing a non-active connection preserves host and preference',
    () async {
      SharedPreferences.setMockInitialValues({});
      final scope = container()..read(hostRegistryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final actions = scope.read(hostRegistryProvider.notifier);
      await actions.upsertDirectConnection(
        serverId: 'server-a',
        endpoint: 'a.example:6868',
      );
      await actions.upsertConnection(
        serverId: 'server-a',
        connection: const DirectSocketHostConnection(
          id: 'socket:/tmp/agent.sock',
          path: '/tmp/agent.sock',
        ),
      );
      await actions.removeConnection('server-a', 'socket:/tmp/agent.sock');
      final host = scope.read(hostRegistryProvider).activeHost!;
      expect(host.connections.single.id, 'direct:a.example:6868');
      expect(host.preferredConnectionId, 'direct:a.example:6868');
    },
  );

  test('effective settings select a preferred relay with its E2EE key', () {
    final direct = _profile(
      'server-a',
      'direct.example:6868',
    ).connections.single;
    const relay = RelayHostConnection(
      id: 'relay:wss:relay.example:443',
      relayEndpoint: 'relay.example:443',
      useTls: true,
      daemonPublicKeyB64: 'key',
    );
    final withDirect = HostProfile(
      serverId: 'server-a',
      label: 'A',
      connections: [relay, direct],
      preferredConnectionId: relay.id,
      createdAt: '2026-07-26T00:00:00.000Z',
      updatedAt: '2026-07-26T00:00:00.000Z',
    );
    final scope = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(() => _StaticRegistry(withDirect)),
      ],
    );
    addTearDown(scope.dispose);
    final settings = scope.read(effectiveConnectionSettingsProvider);
    expect(settings.host, 'relay.example');
    expect(settings.port, 443);
    expect(settings.useTls, isTrue);
    expect(settings.relayServerId, 'server-a');
    expect(settings.daemonPublicKeyB64, 'key');
    expect(
      settings.uri,
      Uri.parse('wss://relay.example:443/ws?serverId=server-a&role=client&v=2'),
    );

    final relayOnlyScope = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(
          () => _StaticRegistry(
            HostProfile(
              serverId: 'server-a',
              label: 'A',
              connections: const [relay],
              preferredConnectionId: relay.id,
              createdAt: '2026-07-26T00:00:00.000Z',
              updatedAt: '2026-07-26T00:00:00.000Z',
            ),
          ),
        ),
      ],
    );
    addTearDown(relayOnlyScope.dispose);
    expect(
      relayOnlyScope.read(effectiveConnectionSettingsProvider).isRelay,
      isTrue,
    );
  });

  test('effective settings fall back to the first direct connection', () {
    final profile = HostProfile(
      serverId: 'server-a',
      label: 'A',
      connections: const [
        DirectSocketHostConnection(
          id: 'socket:/tmp/agent.sock',
          path: '/tmp/agent.sock',
        ),
        DirectTcpHostConnection(
          id: 'direct:fallback.example:7000',
          endpoint: 'fallback.example:7000',
          password: 'secret',
          useTls: true,
        ),
      ],
      preferredConnectionId: 'missing-connection',
      createdAt: '2026-07-26T00:00:00.000Z',
      updatedAt: '2026-07-26T00:00:00.000Z',
    );
    final scope = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(() => _StaticRegistry(profile)),
      ],
    );
    addTearDown(scope.dispose);

    expect(
      scope.read(effectiveConnectionSettingsProvider),
      const ConnectionSettings(
        host: 'fallback.example',
        port: 7000,
        token: 'secret',
        useTls: true,
      ),
    );
  });

  test('effective settings retain legacy target when no TCP route exists', () {
    final profile = HostProfile(
      serverId: 'server-a',
      label: 'A',
      connections: const [
        DirectSocketHostConnection(
          id: 'socket:/tmp/agent.sock',
          path: '/tmp/agent.sock',
        ),
      ],
      preferredConnectionId: null,
      createdAt: '2026-07-26T00:00:00.000Z',
      updatedAt: '2026-07-26T00:00:00.000Z',
    );
    final scope = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(() => _StaticRegistry(profile)),
        connectionSettingsProvider.overrideWith(
          () => _StaticConnectionSettings(),
        ),
      ],
    );
    addTearDown(scope.dispose);

    expect(
      scope.read(effectiveConnectionSettingsProvider),
      const ConnectionSettings(host: 'legacy.example', port: 9000),
    );
  });
}

class _StaticRegistry extends HostRegistryNotifier {
  _StaticRegistry(this.profile);

  final HostProfile profile;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [profile],
    activeServerId: profile.serverId,
    loaded: true,
  );
}

class _StaticConnectionSettings extends ConnectionSettingsNotifier {
  @override
  ConnectionSettings build() =>
      const ConnectionSettings(host: 'legacy.example', port: 9000);
}

HostProfile _profile(String serverId, String endpoint, {bool useTls = false}) {
  final connection = DirectTcpHostConnection(
    id: 'direct:$endpoint',
    endpoint: endpoint,
    useTls: useTls,
  );
  return HostProfile(
    serverId: serverId,
    label: serverId,
    connections: [connection],
    preferredConnectionId: connection.id,
    createdAt: '2026-07-26T00:00:00.000Z',
    updatedAt: '2026-07-26T00:00:00.000Z',
  );
}
