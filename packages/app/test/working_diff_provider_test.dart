import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/working_diff_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults follow dirty state and matching manual choices win', () {
    expect(resolveWorkingDiffMode(isDirty: true), CheckoutDiffMode.uncommitted);
    expect(resolveWorkingDiffMode(isDirty: false), CheckoutDiffMode.base);
    expect(
      resolveWorkingDiffMode(
        isDirty: true,
        override: const WorkingDiffOverride(
          mode: CheckoutDiffMode.base,
          isDirtyAtSelection: true,
        ),
      ),
      CheckoutDiffMode.base,
    );
    expect(
      resolveWorkingDiffMode(
        isDirty: false,
        override: const WorkingDiffOverride(
          mode: CheckoutDiffMode.base,
          isDirtyAtSelection: true,
        ),
      ),
      CheckoutDiffMode.base,
    );
  });

  test('dirty flips expire only the matching checkout override', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workingDiffOverrideProvider.notifier);
    notifier
      ..select(
        serverId: 'server-1',
        cwd: '/one',
        mode: CheckoutDiffMode.base,
        isDirty: true,
      )
      ..select(
        serverId: 'server-1',
        cwd: '/two',
        mode: CheckoutDiffMode.uncommitted,
        isDirty: false,
      )
      ..expireIfDirtyChanged(serverId: 'server-1', cwd: '/one', isDirty: false);

    final overrides = container.read(workingDiffOverrideProvider);
    expect(overrides[(serverId: 'server-1', cwd: '/one')], isNull);
    expect(overrides[(serverId: 'server-1', cwd: '/two')], isNotNull);
  });

  test(
    'subscription consumes matching pushes and unsubscribes on disposal',
    () async {
      final client = _FakeClient();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(client.dispose);
      final query = CheckoutDiffQuery(
        serverId: 'server-1',
        cwd: '/repo',
        compare: const CheckoutDiffCompare(mode: CheckoutDiffMode.uncommitted),
      );

      final initial = await container.read(checkoutDiffProvider(query).future);
      final subscriptionId =
          client.requests.single['subscriptionId']! as String;
      expect(initial?.subscriptionId, subscriptionId);
      expect(client.requests.single['type'], SubscribeCheckoutDiffRequest.type);

      client.updates.add(
        CheckoutDiffUpdate(
          CheckoutDiffPayload(
            subscriptionId: subscriptionId,
            cwd: '/repo',
            files: const [
              CheckoutDiffFile(
                path: 'changed.txt',
                isNew: true,
                isDeleted: false,
                additions: 1,
                deletions: 0,
                hunks: [],
              ),
            ],
            error: null,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(checkoutDiffProvider(query)).value?.files.single.path,
        'changed.txt',
      );

      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(client.sent.single, {
        'type': UnsubscribeCheckoutDiffRequest.type,
        'subscriptionId': subscriptionId,
      });
    },
  );
}

final class _FakeClient extends DaemonClient {
  _FakeClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = ServerInfoStatus(
      serverId: 'server-1',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: true,
      features: const {},
    );
  }

  final updates = StreamController<CheckoutDiffUpdate>.broadcast();
  final requests = <Map<String, Object?>>[];
  final sent = <Map<String, Object?>>[];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState => const Stream.empty();

  @override
  Stream<CheckoutDiffUpdate> get checkoutDiffUpdates => updates.stream;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(message);
    return SubscribeCheckoutDiffResponse(
      payload: CheckoutDiffPayload(
        subscriptionId: message['subscriptionId']! as String,
        cwd: message['cwd']! as String,
        files: const [],
        error: null,
      ),
      requestId: message['requestId']! as String,
    ).toJson();
  }

  @override
  void sendSessionMessage(Map<String, Object?> message) => sent.add(message);

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}
