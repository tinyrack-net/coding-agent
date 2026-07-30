import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/changes_preferences_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/diff/diff_pane.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cwd = '/work/demo';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  final sessionRequests = <Map<String, Object?>>[];
  bool failNextGet = false;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<CheckoutDiffUpdate> get checkoutDiffUpdates => const Stream.empty();

  @override
  Stream<CheckoutStatusUpdate> get checkoutStatusUpdates =>
      const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.diffGetRequest) {
      if (failNextGet) {
        failNextGet = false;
        throw StateError('diff unavailable');
      }
      return const DiffResponse(files: []).toJson();
    }
    return const {};
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sessionRequests.add(message);
    if (message['type'] == CheckoutStatusRequest.type) {
      return CheckoutStatusResponse(
        CheckoutStatusGitNonPaseo(
          cwd: message['cwd']! as String,
          repoRoot: _cwd,
          mainRepoRoot: null,
          currentBranch: 'feature',
          isDirty: false,
          baseRef: 'main',
          aheadBehind: null,
          aheadOfOrigin: null,
          behindOfOrigin: null,
          hasRemote: false,
          remoteUrl: null,
          error: null,
          requestId: message['requestId']! as String,
        ),
      ).toJson();
    }
    if (message['type'] == SubscribeCheckoutDiffRequest.type) {
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
    return const {};
  }
}

Future<ProviderContainer> pumpDiffPane(
  WidgetTester tester, {
  FakeDaemonClient? client,
  bool live = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client ?? FakeDaemonClient()),
      changesPreferencesStorageProvider.overrideWithValue(
        _MemoryChangesStorage(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: DiffPane(
            cwd: _cwd,
            serverId: live ? 'server-1' : null,
            workspaceId: live ? 'workspace-1' : null,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('renders the diff and the cwd label', (tester) async {
    await pumpDiffPane(tester);

    expect(find.text('No changes'), findsOneWidget);
    expect(find.text(_cwd), findsOneWidget);
  });

  testWidgets('the refresh button re-issues diff.get.request', (tester) async {
    final client = FakeDaemonClient();
    final container = await pumpDiffPane(tester, client: client);
    expect(container.read(daemonClientProvider), same(client));

    client.requests.clear();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Refresh diff',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.diffGetRequest),
      isTrue,
    );
  });

  testWidgets('a fetch failure shows an inline error', (tester) async {
    final client = FakeDaemonClient()..failNextGet = true;
    await pumpDiffPane(tester, client: client);

    expect(find.textContaining('Failed to load diff'), findsOneWidget);
  });

  testWidgets('layout toggle persists the requested split preference', (
    tester,
  ) async {
    final container = await pumpDiffPane(tester);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message == 'Switch to split diff',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('changes-toggle-layout')));
    await tester.pumpAndSettle();

    expect(
      container.read(changesPreferencesProvider).requireValue.layout,
      ChangesLayout.split,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message == 'Switch to unified diff',
      ),
      findsOneWidget,
    );
  });

  testWidgets('live mode follows base status and toggles whitespace compare', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpDiffPane(tester, client: client, live: true);

    expect(find.text('Against main'), findsOneWidget);
    expect(find.text('−WS'), findsOneWidget);
    expect(
      client.sessionRequests
          .where(
            (request) => request['type'] == SubscribeCheckoutDiffRequest.type,
          )
          .single['compare'],
      {'mode': 'base', 'baseRef': 'main'},
    );

    await tester.tap(find.text('−WS'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final diffRequests = client.sessionRequests
        .where(
          (request) => request['type'] == SubscribeCheckoutDiffRequest.type,
        )
        .toList();
    expect(diffRequests, hasLength(2));
    expect(diffRequests.last['compare'], {
      'mode': 'base',
      'baseRef': 'main',
      'ignoreWhitespace': true,
    });
  });
}

final class _MemoryChangesStorage implements ChangesPreferencesStorage {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}
