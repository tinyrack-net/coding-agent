import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/diff/diff_pane.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cwd = '/work/demo';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  bool failNextGet = false;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

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
}

Future<ProviderContainer> pumpDiffPane(
  WidgetTester tester, {
  FakeDaemonClient? client,
}) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client ?? FakeDaemonClient())],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const FluentApp(
        home: ScaffoldPage(content: DiffPane(cwd: _cwd)),
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
    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Refresh diff'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.requests.any((r) => r.$1 == MessageTypes.diffGetRequest), isTrue);
  });

  testWidgets('a fetch failure shows an inline error', (tester) async {
    final client = FakeDaemonClient()..failNextGet = true;
    await pumpDiffPane(tester, client: client);

    expect(find.textContaining('Failed to load diff'), findsOneWidget);
  });
}
