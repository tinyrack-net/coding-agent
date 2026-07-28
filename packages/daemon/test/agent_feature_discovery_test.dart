import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _feature = AgentFeatureToggle(
  id: 'dynamic',
  label: 'Dynamic',
  value: true,
);

final class _FeatureClient implements DraftFeatureListingAgentClient {
  ListCommandsDraftConfig? received;

  @override
  Future<List<AgentFeature>> listFeatures(
    ListCommandsDraftConfig config,
  ) async {
    received = config;
    return const [_feature];
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) => throw UnimplementedError();
}

final class _FeatureSession implements FeatureListingAgentSession {
  final controller = StreamController<ProviderEvent>.broadcast();
  bool disposed = false;

  @override
  Stream<ProviderEvent> get events => controller.stream;

  @override
  List<AgentFeature> get features => const [_feature];

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> prompt(String text) async {}
}

final class _SessionClient implements AgentClient {
  final session = _FeatureSession();
  Map<String, Object?>? receivedFeatures;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    receivedFeatures = featureValues;
    return session;
  }
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('agent-features-');
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {}
  });

  AgentManager manager(Map<String, AgentClient> clients) => AgentManager(
    clients: clients,
    store: AgentStore(dataDir: temp.path, debounce: Duration.zero),
  );

  test('uses a provider draft feature probe when available', () async {
    final client = _FeatureClient();
    final subject = manager({'dynamic': client});
    addTearDown(subject.dispose);

    final features = await subject.listFeatures(
      const ListCommandsDraftConfig(
        provider: 'dynamic',
        cwd: '/repo',
        model: 'model',
      ),
    );

    expect(features, const [_feature]);
    expect(client.received?.cwd, '/repo');
  });

  test('falls back to a temporary session and always disposes it', () async {
    final client = _SessionClient();
    final subject = manager({'dynamic': client});
    addTearDown(subject.dispose);

    final features = await subject.listFeatures(
      const ListCommandsDraftConfig(
        provider: 'dynamic',
        cwd: '/repo',
        model: 'model',
        featureValues: {'dynamic': false},
      ),
    );

    expect(features, const [_feature]);
    expect(client.receivedFeatures, {'dynamic': false});
    expect(client.session.disposed, isTrue);
  });

  test(
    'returns no features without a model and rejects missing providers',
    () async {
      final subject = manager(const {});
      addTearDown(subject.dispose);

      expect(
        await subject.listFeatures(
          const ListCommandsDraftConfig(provider: 'missing', cwd: '/repo'),
        ),
        isEmpty,
      );
      expect(
        () => subject.listFeatures(
          const ListCommandsDraftConfig(
            provider: 'missing',
            cwd: '/repo',
            model: 'model',
          ),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}
