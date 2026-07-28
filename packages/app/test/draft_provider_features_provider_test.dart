import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/providers/draft_provider_features.dart';
import 'package:coding_agent_app/state/draft_provider_features_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = ListCommandsDraftConfig(
  provider: 'codex',
  cwd: r'C:\repo',
  modeId: 'auto-review',
  model: 'gpt-5.4',
  thinkingOptionId: 'high',
);

const _feature = AgentFeatureToggle(
  id: 'fast_mode',
  label: 'Fast',
  value: false,
);

final class _FeaturesClient extends DaemonClient {
  _FeaturesClient() : super(uri: Uri.parse('ws://fake'));

  final connections = StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState current = DaemonConnectionState.connected;
  int calls = 0;
  String? error;

  @override
  DaemonConnectionState get currentState => current;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  @override
  Future<ListProviderFeaturesResponse> listProviderFeatures({
    required ListCommandsDraftConfig draftConfig,
    Duration timeout = const Duration(seconds: 90),
  }) async => ListProviderFeaturesResponse(
    provider: draftConfig.provider,
    features: error == null ? const [_feature] : null,
    error: error,
    fetchedAt: 'now',
    requestId: 'request-${++calls}',
  );

  @override
  void dispose() {
    connections.close();
    super.dispose();
  }
}

void main() {
  test('builds stable Paseo draft feature query identities', () {
    final client = _FeaturesClient();
    addTearDown(client.dispose);
    final scope = DraftProviderFeaturesScope(
      client: client,
      serverId: 'server-1',
      draftConfig: _config,
    );
    final equivalent = DraftProviderFeaturesScope(
      client: client,
      serverId: 'server-1',
      draftConfig: const ListCommandsDraftConfig(
        provider: 'codex',
        cwd: 'C:/repo/',
        modeId: 'auto-review',
        model: 'gpt-5.4',
        thinkingOptionId: 'high',
        featureValues: {'fast_mode': true},
      ),
    );

    expect(scope, equivalent);
    expect(scope.queryKey, [
      'providerFeatures',
      'server-1',
      'codex',
      'C:/repo',
      'auto-review',
      'gpt-5.4',
      'high',
    ]);
  });

  test('loads, caches, reconnects, and retains errors', () async {
    final client = _FeaturesClient();
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = draftProviderFeaturesProvider(
      DraftProviderFeaturesScope(
        client: client,
        serverId: 'server-1',
        draftConfig: _config,
      ),
    );
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final notifier = container.read(provider.notifier);

    await notifier.fetch();
    expect(container.read(provider).features, const [_feature]);
    expect(client.calls, 1);
    await notifier.fetch();
    expect(client.calls, 1);

    client.connections.add(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.calls, 2);

    client.error = 'feature probe failed';
    await notifier.fetch(force: true);
    expect(
      '${container.read(provider).error}',
      contains('feature probe failed'),
    );
    expect(container.read(provider).features, const [_feature]);
  });

  test('disabled and disconnected feature queries are gated', () async {
    final client = _FeaturesClient()
      ..current = DaemonConnectionState.disconnected;
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    for (final enabled in [true, false]) {
      final provider = draftProviderFeaturesProvider(
        DraftProviderFeaturesScope(
          client: client,
          serverId: 'server-1',
          draftConfig: _config,
          enabled: enabled,
        ),
      );
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(provider.notifier).fetch();
      expect(container.read(provider).isLoading, isFalse);
    }
    expect(client.calls, 0);
  });
}
