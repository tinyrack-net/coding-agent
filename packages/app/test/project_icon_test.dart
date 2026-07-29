import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/projects/project_icon.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('derives the frozen deterministic fallback palette', () {
    expect(deriveProjectIconColor('a'), const Color(0xFFEF4444));
    expect(deriveProjectIconColor('🚀'), const Color(0xFFEF4444));
  });

  testWidgets('renders a deterministic fallback when no icon exists', (
    tester,
  ) async {
    final client = _IconClient(icon: null);
    addTearDown(client.dispose);
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    final fallback = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('project-icon-fallback-project-a')),
    );
    expect(fallback.color, deriveProjectIconColor('project-a'));
    expect(find.text('A'), findsOneWidget);
    expect(client.requestCount, 1);
  });

  testWidgets('renders a daemon-provided SVG project icon', (tester) async {
    final client = _IconClient(
      icon: ProjectIcon(
        data: base64Encode(
          utf8.encode(
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'width="16" height="16"><rect width="16" height="16"/></svg>',
          ),
        ),
        mimeType: 'image/svg+xml',
      ),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('project-icon-image-project-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('project-icon-fallback-project-a')),
      findsNothing,
    );
    expect(client.requestCount, 1);

    client.setConnectionState(DaemonConnectionState.disconnected);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('project-icon-image-project-a')),
      findsOneWidget,
    );
    client.setConnectionState(DaemonConnectionState.connected);
    await tester.pumpAndSettle();
    expect(client.requestCount, 1);
  });

  testWidgets('renders a daemon-provided raster project icon', (tester) async {
    final client = _IconClient(
      icon: const ProjectIcon(
        data:
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lE'
            'QVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        mimeType: 'image/png',
      ),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('project-icon-image-project-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('project-icon-fallback-project-a')),
      findsNothing,
    );
    expect(client.requestCount, 1);
  });
}

Widget _app(_IconClient client) => ProviderScope(
  overrides: [
    hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
  ],
  child: const FluentApp(
    home: Center(
      child: ProjectIconView(
        serverId: 'host-a',
        cwd: '/repo/app',
        projectKey: 'project-a',
        projectName: 'App',
        size: 16,
        borderRadius: 4,
        fontSize: 11,
      ),
    ),
  ),
);

final class _IconClient extends DaemonClient {
  _IconClient({required this.icon}) : super(uri: Uri.parse('ws://fake'));

  final ProjectIcon? icon;
  final _states = StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState _current = DaemonConnectionState.connected;
  int requestCount = 0;

  @override
  DaemonConnectionState get currentState => _current;

  @override
  Stream<DaemonConnectionState> get connectionState => _states.stream;

  void setConnectionState(DaemonConnectionState state) {
    _current = state;
    _states.add(state);
  }

  @override
  Future<ProjectIconResponse> requestProjectIcon(
    String cwd, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requestCount++;
    return ProjectIconResponse(
      cwd: cwd,
      icon: icon,
      error: null,
      requestId: requestId ?? 'icon',
    );
  }

  @override
  void dispose() {
    _states.close();
    super.dispose();
  }
}
