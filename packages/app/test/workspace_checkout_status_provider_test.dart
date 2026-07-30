import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_checkout_status_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _checkout = (serverId: 'server-1', cwd: '/repo');

final class _FakeClient extends DaemonClient {
  _FakeClient({
    this.connection = DaemonConnectionState.connected,
    this.fail = false,
  }) : super(uri: Uri.parse('ws://fake')) {
    serverInfo = ServerInfoStatus(
      serverId: 'server-1',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: true,
      features: const {},
    );
  }

  DaemonConnectionState connection;
  final bool fail;
  final updates = StreamController<CheckoutStatusUpdate>.broadcast();
  final connections = StreamController<DaemonConnectionState>.broadcast();
  final requests = <Map<String, Object?>>[];

  @override
  DaemonConnectionState get currentState => connection;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  void setConnection(DaemonConnectionState connection) {
    this.connection = connection;
    connections.add(connection);
  }

  @override
  Stream<CheckoutStatusUpdate> get checkoutStatusUpdates => updates.stream;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(message);
    if (fail) throw StateError('status unavailable');
    return CheckoutStatusResponse(
      _gitStatus(requestId: message['requestId']! as String),
    ).toJson();
  }

  @override
  void dispose() {
    unawaited(updates.close());
    unawaited(connections.close());
    super.dispose();
  }
}

void main() {
  test('fetches one status for the active checkout identity', () async {
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);

    final status = await container.read(
      workspaceCheckoutStatusProvider(_checkout).future,
    );

    expect(status, isA<CheckoutStatusGitNonPaseo>());
    expect(status?.isDirty, isFalse);
    expect(client.requests, hasLength(1));
    expect(client.requests.single['type'], CheckoutStatusRequest.type);
    expect(client.requests.single['cwd'], '/repo');
  });

  test('push updates replace only the matching checkout cache', () async {
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);
    await container.read(workspaceCheckoutStatusProvider(_checkout).future);

    client.updates.add(
      CheckoutStatusUpdate(
        payload: _gitStatus(
          requestId: 'subscription:/other',
          cwd: '/other',
          isDirty: true,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(workspaceCheckoutStatusProvider(_checkout)).value?.isDirty,
      isFalse,
    );

    client.updates.add(
      CheckoutStatusUpdate(
        payload: _gitStatus(requestId: 'subscription:/repo', isDirty: true),
      ),
    );
    await _waitForDirtyStatus(container, isDirty: true);
    expect(
      container.read(workspaceCheckoutStatusProvider(_checkout)).value?.isDirty,
      isTrue,
    );
    expect(container.read(checkoutCommitsInvalidationProvider)[_checkout], 1);
  });

  test('push router retains embedded PR status by host and cwd', () async {
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);
    await container.read(workspaceCheckoutStatusProvider(_checkout).future);

    client.updates.add(
      CheckoutStatusUpdate(
        payload: _gitStatus(requestId: 'subscription:/repo'),
        prStatus: CheckoutPrStatusResponse(
          cwd: '/repo',
          status: const CheckoutPrStatus(
            forge: 'github',
            projectPath: 'acme/repo',
            number: 7,
            url: 'https://github.com/acme/repo/pull/7',
            title: 'Push cache',
            state: 'open',
            baseRefName: 'main',
            headRefName: 'feature',
            isMerged: false,
            isDraft: false,
            mergeable: 'MERGEABLE',
            checks: [],
          ),
          githubFeaturesEnabled: true,
          authState: 'authenticated',
          forge: 'github',
          error: null,
          requestId: 'subscription:/repo',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final cached = container.read(checkoutStatusPushCacheProvider)[_checkout];
    expect(cached?.prStatus?.status?.number, 7);
    expect(cached?.prStatus?.status?.title, 'Push cache');
    expect(container.read(checkoutCommitsInvalidationProvider)[_checkout], 1);
  });

  test('disconnected checkout stays disabled without a request', () async {
    final client = _FakeClient(connection: DaemonConnectionState.disconnected);
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);

    expect(
      await container.read(workspaceCheckoutStatusProvider(_checkout).future),
      isNull,
    );
    expect(client.requests, isEmpty);
  });

  test('disconnect retains the last fetched checkout status', () async {
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);

    final fetched = await container.read(
      workspaceCheckoutStatusProvider(_checkout).future,
    );
    expect(fetched?.isGit, isTrue);

    client.setConnection(DaemonConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(workspaceCheckoutStatusProvider(_checkout)).value?.isGit,
      isTrue,
    );
    expect(client.requests, hasLength(1));
  });

  test('request failures remain observable query errors', () async {
    final client = _FakeClient(fail: true);
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);

    await expectLater(
      container.read(workspaceCheckoutStatusProvider(_checkout).future),
      throwsStateError,
    );
    expect(
      container.read(workspaceCheckoutStatusProvider(_checkout)).hasError,
      isTrue,
    );
  });
}

CheckoutStatusGitNonPaseo _gitStatus({
  required String requestId,
  String cwd = '/repo',
  bool isDirty = false,
}) => CheckoutStatusGitNonPaseo(
  cwd: cwd,
  repoRoot: cwd,
  mainRepoRoot: null,
  currentBranch: 'main',
  isDirty: isDirty,
  baseRef: null,
  aheadBehind: null,
  aheadOfOrigin: 0,
  behindOfOrigin: 0,
  hasRemote: false,
  remoteUrl: null,
  error: null,
  requestId: requestId,
);

Future<void> _waitForDirtyStatus(
  ProviderContainer container, {
  required bool isDirty,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (container
            .read(workspaceCheckoutStatusProvider(_checkout))
            .value
            ?.isDirty ==
        isDirty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw TimeoutException('checkout status push did not settle');
}
