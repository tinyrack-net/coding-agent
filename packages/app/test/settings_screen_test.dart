import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    DaemonConnectionState state = DaemonConnectionState.connected,
    this.rejectedHelloOverride,
  })  : _state = state,
        super(uri: Uri.parse('ws://fake'));

  final DaemonConnectionState _state;
  final ServerHello? rejectedHelloOverride;

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
  }) async =>
      const {};
}

Future<ProviderContainer> pumpSettingsScreen(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('shows the current connection and the daemon uri',
      (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    expect(find.text('Connected — ws://127.0.0.1:6868'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Host'), findsOneWidget);
  });

  testWidgets('validation: empty host is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host').first,
      '',
    );
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Host is required'), findsOneWidget);
    expect(find.text('Settings saved. Reconnecting…'), findsNothing);
  });

  testWidgets('validation: out-of-range port is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    final portField = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(portField, '99999');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
  });

  testWidgets('valid input saves settings and shows a confirmation snackbar',
      (tester) async {
    final container = await pumpSettingsScreen(tester, FakeDaemonClient());

    final hostField = find.ancestor(
      of: find.text('Host'),
      matching: find.byType(TextFormField),
    );
    final portField = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(hostField, '10.0.0.5');
    await tester.enterText(portField, '7000');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Settings saved. Reconnecting…'), findsOneWidget);
    final settings = container.read(connectionSettingsProvider);
    expect(settings.host, '10.0.0.5');
    expect(settings.port, 7000);
  });

  testWidgets('version mismatch shows the guidance card', (tester) async {
    await pumpSettingsScreen(
      tester,
      FakeDaemonClient(
        state: DaemonConnectionState.versionMismatch,
        rejectedHelloOverride: const ServerHello(
          daemonVersion: '9.0.0',
          protocolVersion: 1,
        ),
      ),
    );

    expect(find.textContaining('Version mismatch'), findsOneWidget);
    expect(find.textContaining('원격 데몬 v9.0.0'), findsOneWidget);
  });

  testWidgets('desktop section: toggling keep-running persists the setting',
      (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    // This test host is Windows, so the desktop settings section renders.
    expect(find.text('Keep daemon running after quit'), findsOneWidget);
    final keepRunningSwitch = find.widgetWithText(
      SwitchListTile,
      'Keep daemon running after quit',
    );
    final before = tester.widget<SwitchListTile>(keepRunningSwitch).value;
    expect(before, isTrue);

    await tester.tap(keepRunningSwitch);
    await tester.pump();

    final after = tester.widget<SwitchListTile>(keepRunningSwitch).value;
    expect(after, isFalse);
  });
}
