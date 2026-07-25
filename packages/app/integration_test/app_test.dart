// E2E test: boots the real app on Windows, lets it spawn/find the real
// daemon executable (see DaemonSupervisor.ensureRunning /
// daemon_lifecycle's resolveDaemonExe, which looks for
// packages/daemon/build/daemon.exe — build it first via
// `pwsh tool/build_daemon.ps1`; otherwise falls back to the in-process
// embedded daemon spawner), and drives genuine UI flows against that live
// process. No fakes here — packages/app/test/ covers isolated
// widget/provider behavior with FakeDaemonClient; this suite exists to catch
// wiring problems those tests can't see (real WebSocket handshake, real
// process spawn, real RPC round trips).
//
// Run locally: `flutter test integration_test -d windows` from
// packages/app.
//
// Agent creation/chat/terminal flows depend on a native provider (Codex/
// DeepSeek/OpenRouter) having a stored API key (providerListProvider only
// reports providers with `configured: true`), so this suite doesn't assume
// one is present — it asserts on whichever real state the daemon reports.
//
// This also doesn't assume an empty agent list: DaemonSupervisor reuses an
// already-running same-version daemon rather than spawning a fresh one (see
// daemon_supervisor.dart), so on a dev machine that already has one running
// (with its own ~/.tinyrack-agent data dir), this test observes real
// pre-existing agents. Assertions below only rely on state that's true
// regardless of prior agent history.

import 'package:coding_agent_app/main.dart' as app;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// fluent_ui defines its own `Tooltip` widget, distinct from
// `package:flutter/material.dart`'s — `find.byTooltip()` only matches the
// Material one, so every tooltip lookup here goes through this predicate
// instead (the same pattern already used throughout packages/app/test/).
Finder byTooltipMessage(String message) =>
    find.byWidgetPredicate((w) => w is Tooltip && w.message == message);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app boots, connects to the real daemon, and core screens work',
    (tester) async {
      await app.main(const []);
      await tester.pumpAndSettle(const Duration(seconds: 20));

      expect(find.text('Daemon connected'), findsOneWidget);
      expect(find.text('New workspace'), findsOneWidget);

      // Opening "New workspace" triggers a real providerList RPC round trip
      // to the live daemon; accept whichever real outcome it reports
      // instead of assuming a specific CLI is installed on the test
      // machine. The session-composer form (with its "Create" button) only
      // renders once at least one provider is configured; otherwise a
      // guidance message renders instead.
      await tester.tap(find.text('New workspace'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      final noProvidersMessage = find.textContaining(
        'No providers are configured yet',
      );
      final createButton = find.text('Create');
      final hasNoProviders = noProvidersMessage.evaluate().isNotEmpty;
      expect(
        hasNoProviders || createButton.evaluate().isNotEmpty,
        isTrue,
        reason: 'expected either the no-providers message or the '
            'session form (with its Create button) to render',
      );
      // ScaffoldPage has no automatic back affordance the way a Material
      // Scaffold's AppBar does — `tester.pageBack()` specifically looks for
      // a Material/Cupertino back button widget, neither of which this
      // fluent_ui app uses, so it never finds one here. Tap the app's own
      // `PageBackButton` (a Tooltip-wrapped IconButton) directly instead.
      await tester.tap(byTooltipMessage('Back'));
      await tester.pumpAndSettle();

      // Projects & worktrees screen: lists registered projects. The
      // sidebar's own "Projects & worktrees" nav row stays visible
      // alongside the pushed screen's title, so this appears twice.
      await tester.tap(find.text('Projects & worktrees'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.text('Projects & worktrees'), findsWidgets);
      // ScaffoldPage has no automatic back affordance the way a Material
      // Scaffold's AppBar does — `tester.pageBack()` specifically looks for
      // a Material/Cupertino back button widget, neither of which this
      // fluent_ui app uses, so it never finds one here. Tap the app's own
      // `PageBackButton` (a Tooltip-wrapped IconButton) directly instead.
      await tester.tap(byTooltipMessage('Back'));
      await tester.pumpAndSettle();

      // Status screen: same live connection, same provider RPC. The
      // sidebar's own persistent connection footer shows the same text, so
      // it appears twice (footer + this screen's own copy).
      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.text('Daemon connected'), findsWidgets);
      // ScaffoldPage has no automatic back affordance the way a Material
      // Scaffold's AppBar does — `tester.pageBack()` specifically looks for
      // a Material/Cupertino back button widget, neither of which this
      // fluent_ui app uses, so it never finds one here. Tap the app's own
      // `PageBackButton` (a Tooltip-wrapped IconButton) directly instead.
      await tester.tap(byTooltipMessage('Back'));
      await tester.pumpAndSettle();

      // Settings screen: form is pre-filled from persisted connection
      // settings and saving reconnects without crashing the app.
      await tester.tap(byTooltipMessage('Connection settings'));
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
