import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/status_screen.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Non-desktop-shell-scoped fake: `daemonLifecycleProvider` returns null
/// quickly (see `desktopShellProvider.overrideWithValue(false)` below), so
/// the screen's status/providers rendering can be exercised without spinning
/// up any real supervisor/tray code.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    this._state = DaemonConnectionState.connected,
    this.rejectedHelloOverride,
  }) : super(uri: Uri.parse('ws://fake'));

  final DaemonConnectionState _state;
  final ServerHello? rejectedHelloOverride;
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;

  @override
  ServerHello? get rejectedHello => rejectedHelloOverride;

  @override
  DaemonConnectionState get currentState => _state;

  @override
  Stream<DaemonConnectionState> get connectionState => Stream.value(_state);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return onRequest?.call(type, payload) ?? const {};
  }
}

Future<void> pumpStatusScreen(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      desktopShellProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const FluentApp(home: StatusScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connected: shows the connected banner and provider list', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    client.onRequest = (type, payload) {
      expect(type, MessageTypes.providerListRequest);
      return {
        'providers': [
          const ProviderInfo(
            id: 'openai',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.openai.example/v1',
            displayName: 'Codex',
            configured: true,
            models: [
              ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
            ],
          ).toJson(),
          const ProviderInfo(
            id: 'deepseek',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.deepseek.example/v1',
            displayName: 'DeepSeek',
            configured: false,
            unavailableReason: 'not installed',
          ).toJson(),
        ],
      };
    };
    await pumpStatusScreen(tester, client);

    expect(find.text('Daemon connected'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.textContaining('1 models available'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('not installed'), findsOneWidget);
  });

  testWidgets('disconnected: shows the retrying banner', (tester) async {
    final client = FakeDaemonClient(state: DaemonConnectionState.disconnected);
    await pumpStatusScreen(tester, client);

    expect(find.text('Daemon not reachable (retrying)'), findsOneWidget);
  });

  testWidgets('connecting: shows the connecting banner', (tester) async {
    final client = FakeDaemonClient(state: DaemonConnectionState.connecting);
    await pumpStatusScreen(tester, client);

    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('version mismatch: shows the incompatible banner and guidance', (
    tester,
  ) async {
    final client = FakeDaemonClient(
      state: DaemonConnectionState.versionMismatch,
      rejectedHelloOverride: const ServerHello(
        daemonVersion: '9.0.0',
        protocolVersion: 1,
      ),
    );
    await pumpStatusScreen(tester, client);

    expect(find.text('Incompatible daemon version'), findsOneWidget);
    expect(find.textContaining('원격 데몬 v9.0.0'), findsOneWidget);
  });

  testWidgets('no providers reported yet shows the empty-state text', (
    tester,
  ) async {
    final client = FakeDaemonClient()..onRequest = (type, payload) => const {};
    await pumpStatusScreen(tester, client);

    expect(find.text('No providers reported yet.'), findsOneWidget);
  });

  testWidgets('a failed provider list request shows an inline error', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        throw StateError('daemon unreachable');
      };
    await pumpStatusScreen(tester, client);

    expect(find.textContaining('Failed to list providers'), findsOneWidget);
  });

  testWidgets(
    'a local daemon spawn failure surfaces the "Failed to start local '
    'daemon" banner',
    (tester) async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.providerListRequest);
        return const {'providers': []};
      };
      final supervisor = _SpawnFailingSupervisor();
      final container = ProviderContainer(
        overrides: [
          daemonClientProvider.overrideWithValue(client),
          desktopShellProvider.overrideWithValue(true),
          daemonSupervisorFactoryProvider.overrideWithValue((_) => supervisor),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FluentApp(home: StatusScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Failed to start local daemon'),
        findsOneWidget,
      );
      expect(find.textContaining('spawn exploded'), findsOneWidget);
    },
  );
}

class _SpawnFailingSupervisor extends DaemonSupervisor {
  _SpawnFailingSupervisor() : super(host: '127.0.0.1', port: 6868);

  @override
  Future<DaemonStatus> ensureRunning() async {
    throw DaemonSpawnException('spawn exploded', logTail: 'boom');
  }
}
