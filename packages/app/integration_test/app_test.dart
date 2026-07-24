// E2E test: boots the real app on Windows, lets it spawn/find the real
// daemon executable (see DaemonSupervisor.ensureRunning /
// daemon_lifecycle's resolveDaemonExe, which looks for
// packages/daemon/build/daemon.exe — build it first via
// `pwsh tool/build_daemon.ps1`), and drives genuine UI flows against that
// live process. No fakes here — packages/app/test/ covers isolated
// widget/provider behavior with FakeDaemonClient; this suite exists to catch
// wiring problems those tests can't see (real WebSocket handshake, real
// process spawn, real RPC round trips).
//
// Run locally: `flutter test integration_test -d windows` from
// packages/app (after building the daemon executable).
//
// Agent creation/chat/terminal flows depend on a Claude/Codex CLI being
// installed on the machine (providerListProvider only reports providers it
// can actually find), so this suite doesn't assume one is present — it
// asserts on whichever real state the daemon reports.
//
// This also doesn't assume an empty agent list: DaemonSupervisor reuses an
// already-running same-version daemon rather than spawning a fresh one (see
// daemon_supervisor.dart), so on a dev machine that already has one running
// (with its own ~/.tinyrack-agent data dir), this test observes real
// pre-existing agents. Assertions below only rely on state that's true
// regardless of prior agent history.

import 'package:coding_agent_app/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app boots, connects to the real daemon, and core screens work',
    (tester) async {
      await app.main(const []);
      await tester.pumpAndSettle(const Duration(seconds: 20));

      expect(find.text('Daemon connected'), findsOneWidget);
      expect(find.text('New Agent'), findsOneWidget);

      // Opening "New Agent" triggers a real providerList RPC round trip to
      // the live daemon; accept whichever real outcome it reports instead of
      // assuming a specific CLI is installed on the test machine.
      await tester.tap(find.text('New Agent'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      final noProvidersMessage = find.textContaining(
        'No providers are available on this machine',
      );
      // The provider dropdown's InputDecoration renders its labelText as a
      // findable Text once the field has content (avoid depending on the
      // dropdown's generic type parameter, which is ProviderId not String).
      final providerForm = find.text('Provider');
      expect(
        noProvidersMessage.evaluate().isNotEmpty ||
            providerForm.evaluate().isNotEmpty,
        isTrue,
        reason: 'expected either the no-providers message or the '
            'provider/model form to render',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Status screen: same live connection, same provider RPC.
      await tester.tap(find.byTooltip('Daemon status'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.text('Daemon connected'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Settings screen: form is pre-filled from persisted connection
      // settings and saving reconnects without crashing the app.
      await tester.tap(find.byTooltip('Connection settings'));
      await tester.pumpAndSettle();
      expect(find.text('Connection Settings'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save & Reconnect'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.text('Settings saved. Reconnecting…'), findsOneWidget);

      await tester.pumpAndSettle(const Duration(seconds: 10));
      // The settings screen renders connection status as "Connected —
      // <uri>" (distinct wording from the home/status screens' "Daemon
      // connected").
      expect(find.textContaining('Connected —'), findsOneWidget);
    },
  );
}
