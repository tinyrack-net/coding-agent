import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/host_status_dot.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpHostDot(
  WidgetTester tester,
  DaemonConnectionState state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        hostConnectionStateProvider.overrideWith(
          (ref, serverId) => Stream.value(state),
        ),
      ],
      child: FluentApp(
        theme: buildAppTheme(),
        home: const Center(child: HostStatusDot(serverId: 'server-a')),
      ),
    ),
  );
  await tester.pump();
}

BoxDecoration dotDecoration(WidgetTester tester) =>
    tester.widget<DecoratedBox>(find.byType(DecoratedBox).last).decoration
        as BoxDecoration;

final class _StateClient extends DaemonClient {
  _StateClient(this.state) : super(uri: Uri.parse('ws://host-status-test'));

  final DaemonConnectionState state;

  @override
  DaemonConnectionState get currentState => state;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      const Stream<DaemonConnectionState>.empty();
}

void main() {
  test('maps daemon states to the frozen runtime statuses', () {
    expect(
      hostRuntimeConnectionStatusFromDaemon(null),
      HostRuntimeConnectionStatus.connecting,
    );
    expect(
      hostRuntimeConnectionStatusFromDaemon(DaemonConnectionState.connecting),
      HostRuntimeConnectionStatus.connecting,
    );
    expect(
      hostRuntimeConnectionStatusFromDaemon(DaemonConnectionState.connected),
      HostRuntimeConnectionStatus.online,
    );
    expect(
      hostRuntimeConnectionStatusFromDaemon(DaemonConnectionState.disconnected),
      HostRuntimeConnectionStatus.offline,
    );
    expect(
      hostRuntimeConnectionStatusFromDaemon(
        DaemonConnectionState.versionMismatch,
      ),
      HostRuntimeConnectionStatus.error,
    );
  });

  test('maps the complete frozen runtime palette', () {
    expect(
      hostStatusDotColor(HostRuntimeConnectionStatus.online),
      hostStatusOnlineColor,
    );
    expect(
      hostStatusDotColor(HostRuntimeConnectionStatus.connecting),
      hostStatusConnectingColor,
    );
    for (final status in const [
      HostRuntimeConnectionStatus.idle,
      HostRuntimeConnectionStatus.offline,
      HostRuntimeConnectionStatus.error,
    ]) {
      expect(hostStatusDotColor(status), hostStatusOfflineColor);
    }
  });

  testWidgets('renders an exact 8px online dot', (tester) async {
    await pumpHostDot(tester, DaemonConnectionState.connected);

    final dot = find.byType(HostStatusDot);
    expect(tester.getSize(dot), const Size.square(8));
    expect(dotDecoration(tester).color, hostStatusOnlineColor);
    expect(dotDecoration(tester).shape, BoxShape.circle);
  });

  testWidgets('uses the current host snapshot before a stream event', (
    tester,
  ) async {
    final client = _StateClient(DaemonConnectionState.connected);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
        ],
        child: FluentApp(
          theme: buildAppTheme(),
          home: const Center(child: HostStatusDot(serverId: 'server-a')),
        ),
      ),
    );
    await tester.pump();

    expect(dotDecoration(tester).color, hostStatusOnlineColor);
  });

  testWidgets('renders connecting and failure colors reactively', (
    tester,
  ) async {
    await pumpHostDot(tester, DaemonConnectionState.connecting);
    expect(dotDecoration(tester).color, hostStatusConnectingColor);

    await pumpHostDot(tester, DaemonConnectionState.disconnected);
    expect(dotDecoration(tester).color, hostStatusOfflineColor);

    await pumpHostDot(tester, DaemonConnectionState.versionMismatch);
    expect(dotDecoration(tester).color, hostStatusOfflineColor);
  });
}
