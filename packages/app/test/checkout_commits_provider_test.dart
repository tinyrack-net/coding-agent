// The commit providers gate through the ported predicates in
// `git/paseo_git_queries.dart`. These tests pin the gate at the provider
// boundary, because an inline copy of it previously drifted: it trimmed
// `cwd`, so a whitespace-only checkout sat idle where Paseo sends the
// request and surfaces the daemon's error.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/checkout_commits_provider.dart';
import 'package:coding_agent_app/state/workspace_checkout_status_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient extends DaemonClient {
  _FakeClient({this.connected = true, bool supportsCommits = true})
    : super(uri: Uri.parse('ws://fake')) {
    serverInfo = ServerInfoStatus(
      serverId: 'local',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: supportsCommits
          ? const {'commitsList': true, 'commitBaseClassification': true}
          : const {},
    );
  }

  final bool connected;
  final List<Map<String, Object?>> sent = [];

  @override
  DaemonConnectionState get currentState => connected
      ? DaemonConnectionState.connected
      : DaemonConnectionState.disconnected;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sent.add(message);
    return CheckoutCommitsListResponse(
      cwd: message['cwd']! as String,
      commits: const [],
      baseRef: 'main',
      error: null,
      requestId: message['requestId']! as String,
    ).toJson();
  }
}

ProviderContainer _containerFor(_FakeClient client) {
  final container = ProviderContainer(
    overrides: [
      checkoutStatusDaemonClientProvider.overrideWith((ref, _) => client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a whitespace-only cwd still sends, matching Boolean(cwd)', () async {
    final client = _FakeClient();
    final container = _containerFor(client);

    await container.read(
      checkoutCommitsProvider((serverId: 'local', cwd: '   ')).future,
    );

    expect(client.sent, hasLength(1));
    expect(client.sent.single['cwd'], '   ');
  });

  test('an empty cwd is rejected without sending', () async {
    final client = _FakeClient();
    final container = _containerFor(client);

    final result = await container.read(
      checkoutCommitsProvider((serverId: 'local', cwd: '')).future,
    );

    expect(result, isNull);
    expect(client.sent, isEmpty);
  });

  test('a host without the capability is rejected without sending', () async {
    final client = _FakeClient(supportsCommits: false);
    final container = _containerFor(client);

    final result = await container.read(
      checkoutCommitsProvider((serverId: 'local', cwd: '/repo')).future,
    );

    expect(result, isNull);
    expect(client.sent, isEmpty);
  });

  test('a disconnected host is rejected without sending', () async {
    final client = _FakeClient(connected: false);
    final container = _containerFor(client);

    final result = await container.read(
      checkoutCommitsProvider((serverId: 'local', cwd: '/repo')).future,
    );

    expect(result, isNull);
    expect(client.sent, isEmpty);
  });

  test('the file diff gate rejects a blank sha or path', () async {
    final client = _FakeClient();
    final container = _containerFor(client);

    for (final key in const [
      (serverId: 'local', cwd: '/repo', sha: '', path: 'a.dart'),
      (serverId: 'local', cwd: '/repo', sha: 'abc', path: ''),
      (serverId: 'local', cwd: '', sha: 'abc', path: 'a.dart'),
    ]) {
      expect(
        await container.read(checkoutCommitFileDiffProvider(key).future),
        isNull,
      );
    }
    expect(client.sent, isEmpty);
  });
}
