import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/widgets/provider_diagnostic_dialog.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

final class _DiagnosticClient extends DaemonClient {
  _DiagnosticClient({this.error, this.diagnostic})
    : super(uri: Uri.parse('ws://fake'));

  final Object? error;
  final String? diagnostic;
  int calls = 0;

  @override
  Future<ProviderDiagnosticResponse> getProviderDiagnostic(
    String provider, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return ProviderDiagnosticResponse(
      provider: provider,
      diagnostic:
          diagnostic ?? 'Claude Code\n  Models: $calls\n  Status: Ready',
      requestId: requestId ?? 'diagnostic-$calls',
    );
  }
}

Widget _app(DaemonClient client) => FluentApp(
  home: ProviderDiagnosticDialog(client: client, provider: 'claude'),
);

void main() {
  testWidgets('uses the frozen compact 50 percent diagnostic snap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.reset);
    final client = _DiagnosticClient();

    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(const ValueKey('adaptive-modal-sheet-card'))),
      const Rect.fromLTWH(0, 400, 500, 400),
    );
  });

  testWidgets('loads and refreshes a provider diagnostic', (tester) async {
    final client = _DiagnosticClient();

    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(client.calls, 1);
    expect(find.byKey(const Key('provider-diagnostic-dialog')), findsOneWidget);
    expect(find.textContaining('Models: 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('refresh-provider-diagnostic')));
    await tester.pumpAndSettle();

    expect(client.calls, 2);
    expect(find.textContaining('Models: 2'), findsOneWidget);
  });

  testWidgets('shows diagnostic request failures inline', (tester) async {
    final client = _DiagnosticClient(error: StateError('provider unavailable'));

    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(client.calls, 1);
    expect(find.textContaining('provider unavailable'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('refresh-provider-diagnostic')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('shows the frozen empty diagnostic state', (tester) async {
    final client = _DiagnosticClient(diagnostic: '');

    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(find.text('No diagnostic available'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('copy-provider-diagnostic')))
          .onPressed,
      isNull,
    );
  });
}
