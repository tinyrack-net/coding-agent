import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/widgets/host_daemon_update_card.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('version comparison matches Paseo normalization', () {
    expect(daemonVersionsMismatch('v0.2.0', '0.2.0'), isFalse);
    expect(daemonVersionsMismatch('0.2.0', '0.1.9'), isTrue);
    expect(daemonVersionsMismatch('0.2.0', null), isFalse);
  });

  testWidgets('keeps a remote update failure visible and retryable', (
    tester,
  ) async {
    final transport = _FakeTransport(
      response: const DaemonUpdateResponse(
        requestId: 'update-1',
        success: false,
        error: 'npm install failed',
        previousVersion: '0.1.9',
      ),
    );
    await _pumpCard(tester, transport);

    await tester.tap(find.byKey(const ValueKey('host-page-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('host-page-update-error')),
      findsOneWidget,
    );
    expect(find.text('Update failed'), findsOneWidget);
    expect(
      find.text('Failed to update the daemon: npm install failed'),
      findsOneWidget,
    );
    final button = tester.widget<Button>(
      find.byKey(const ValueKey('host-page-update-button')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('shows progress and disables the action while updating', (
    tester,
  ) async {
    final pending = Completer<DaemonUpdateResponse>();
    final transport = _FakeTransport(pending: pending);
    await _pumpCard(tester, transport);

    await tester.tap(find.byKey(const ValueKey('host-page-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump();
    transport.emitProgress(
      DaemonUpdatePhase.downloading,
      requestId: transport.lastRequestId!,
    );
    await tester.pump();

    expect(find.text('Downloading packages...'), findsOneWidget);
    final button = tester.widget<Button>(
      find.byKey(const ValueKey('host-page-update-button')),
    );
    expect(button.onPressed, isNull);

    pending.complete(
      const DaemonUpdateResponse(requestId: 'update-1', success: false),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('ignores progress belonging to another update request', (
    tester,
  ) async {
    final pending = Completer<DaemonUpdateResponse>();
    final transport = _FakeTransport(pending: pending);
    await _pumpCard(tester, transport);

    await tester.tap(find.byKey(const ValueKey('host-page-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump();

    transport.emitProgress(
      DaemonUpdatePhase.downloading,
      requestId: 'another-card-update',
    );
    await tester.pump();
    expect(find.text('Preparing update...'), findsOneWidget);
    expect(find.text('Downloading packages...'), findsNothing);

    transport.emitProgress(
      DaemonUpdatePhase.installing,
      requestId: transport.lastRequestId!,
    );
    await tester.pump();
    expect(find.text('Installing...'), findsOneWidget);

    pending.complete(
      const DaemonUpdateResponse(requestId: 'update-1', success: false),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('explains Desktop ownership and disables self-update', (
    tester,
  ) async {
    final transport = _FakeTransport(desktopManaged: true);
    await _pumpCard(tester, transport);

    expect(
      find.text(
        'This daemon is managed by Tinyrack Desktop. '
        'Update Tinyrack Desktop on the host.',
      ),
      findsOneWidget,
    );
    final button = tester.widget<Button>(
      find.byKey(const ValueKey('host-page-update-button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('shows the exact reconnect recovery after a successful update', (
    tester,
  ) async {
    final transport = _FakeTransport(
      response: const DaemonUpdateResponse(
        requestId: 'update-1',
        success: true,
        previousVersion: '0.1.9',
        newVersion: '0.2.0',
      ),
    );
    await _pumpCard(
      tester,
      transport,
      reconnectTimeout: const Duration(milliseconds: 20),
    );

    await tester.tap(find.byKey(const ValueKey('host-page-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Unable to reconnect'), findsOneWidget);
    expect(
      find.text(
        'Build host did not come back online after updating. '
        'Please verify the daemon restarted.',
      ),
      findsOneWidget,
    );
  });
}

Future<void> _pumpCard(
  WidgetTester tester,
  _FakeTransport transport, {
  Duration reconnectTimeout = const Duration(seconds: 1),
}) {
  return tester.pumpWidget(
    FluentApp(
      home: ScaffoldPage(
        content: HostDaemonUpdateCard(
          hostLabel: 'Build host',
          transport: transport,
          reconnectTimeout: reconnectTimeout,
        ),
      ),
    ),
  );
}

final class _FakeTransport implements DaemonUpdateTransport {
  _FakeTransport({this.response, this.pending, bool desktopManaged = false})
    : serverInfo = ServerInfoStatus(
        serverId: 'remote',
        hostname: 'build-host',
        version: '0.1.9',
        desktopManaged: desktopManaged,
        features: {'daemonSelfUpdate': !desktopManaged},
      );

  final DaemonUpdateResponse? response;
  final Completer<DaemonUpdateResponse>? pending;
  final _states = StreamController<DaemonConnectionState>.broadcast();
  final _progress = StreamController<DaemonUpdateProgress>.broadcast();
  String? lastRequestId;

  @override
  final ServerInfoStatus serverInfo;

  @override
  DaemonConnectionState currentState = DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionStates => _states.stream;

  @override
  Stream<DaemonUpdateProgress> get progress => _progress.stream;

  void emitProgress(DaemonUpdatePhase phase, {required String requestId}) =>
      _progress.add(DaemonUpdateProgress(requestId: requestId, phase: phase));

  @override
  Future<DaemonUpdateResponse> update(String requestId) {
    lastRequestId = requestId;
    return pending?.future ??
        Future.value(
          response ??
              const DaemonUpdateResponse(requestId: 'update-1', success: false),
        );
  }
}
