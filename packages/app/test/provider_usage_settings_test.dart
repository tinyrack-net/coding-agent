import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/provider_usage_provider.dart';
import 'package:coding_agent_app/widgets/provider_usage_settings_section.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'provider settings loads usage and refreshes without stale rows',
    (tester) async {
      final client = _UsageDaemonClient()
        ..serverInfo = const ServerInfoStatus(
          serverId: 'host-1',
          hostname: 'host',
          version: '0.2.0',
          desktopManaged: false,
          features: {'providerUsageList': true},
        );
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FluentApp(home: SettingsScreen(section: 'providers')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Plan usage'), findsOneWidget);
      expect(find.text('Codex'), findsNWidgets(2));
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('96%'), findsOneWidget);
      expect(client.usageRequests, 1);

      await tester.tap(find.byKey(const ValueKey('provider-usage-refresh')));
      await tester.pumpAndSettle();
      expect(client.usageRequests, 2);
      expect(find.text('Codex'), findsNWidgets(2));
    },
  );

  testWidgets('host usage section reads the requested host scope', (
    tester,
  ) async {
    const response = ProviderUsageListResponse(
      requestId: 'host-usage',
      fetchedAt: '2026-07-22T12:00:00.000Z',
      providers: [
        ProviderUsage(
          providerId: 'claude',
          displayName: 'Claude',
          status: ProviderUsageStatus.available,
          planLabel: 'Max',
          windows: [
            ProviderUsageWindow(
              id: 'session',
              label: 'Session',
              usedPct: 75,
              tone: ProviderUsageTone.warning,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostProviderUsageProvider(
            'host-2',
          ).overrideWith((ref) async => response),
        ],
        child: const FluentApp(
          home: ScaffoldPage(
            content: ProviderUsageSettingsSection(serverId: 'host-2'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
  });
}

final class _UsageDaemonClient extends DaemonClient {
  _UsageDaemonClient() : super(uri: Uri.parse('ws://fake'));

  int usageRequests = 0;

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
    if (type == MessageTypes.providerListRequest) {
      return const ProviderListResponse(providers: []).toJson();
    }
    return const {};
  }

  @override
  Future<ProviderUsageListResponse> listProviderUsage({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    usageRequests += 1;
    return ProviderUsageListResponse(
      requestId: '$usageRequests',
      fetchedAt: '2026-07-22T12:00:00.000Z',
      providers: const [
        ProviderUsage(
          providerId: 'codex',
          displayName: 'Codex',
          status: ProviderUsageStatus.available,
          planLabel: 'Plus',
          windows: [
            ProviderUsageWindow(
              id: 'weekly',
              label: 'Weekly',
              usedPct: 96,
              tone: ProviderUsageTone.danger,
            ),
          ],
        ),
      ],
    );
  }
}
