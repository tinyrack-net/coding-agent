import 'package:coding_agent_app/core/desktop/agent_deep_link_source.dart';
import 'package:coding_agent_app/core/desktop/agent_hot_route_startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('routes a running Windows agent activation after startup', (
    tester,
  ) async {
    final source = _FakeSource();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const SizedBox(key: ValueKey('home')),
        ),
        GoRoute(
          path: '/h/:serverId/agent/:agentId',
          builder: (_, state) => Text(
            '${state.pathParameters['serverId']}:'
            '${state.pathParameters['agentId']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      bindAgentHotRoutes(
        router: router,
        source: source,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    source.emit('coding-agent://h/server-1/agent/agent-2');
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server-1/agent/agent-2',
    );
    expect(find.text('server-1:agent-2'), findsOneWidget);
  });

  testWidgets('preserves the cold-start child when no source is available', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/cold',
      routes: [
        GoRoute(path: '/cold', builder: (_, _) => const Text('cold-start')),
      ],
    );
    addTearDown(router.dispose);
    final child = MaterialApp.router(routerConfig: router);

    await tester.pumpWidget(
      bindAgentHotRoutes(child: child, router: router, source: null),
    );

    expect(find.text('cold-start'), findsOneWidget);
  });
}

final class _FakeSource implements AgentDeepLinkSource {
  AgentDeepLinkHandler? _handler;

  @override
  Future<AgentDeepLinkSubscription> listen(AgentDeepLinkHandler onUri) async {
    _handler = onUri;
    return _FakeSubscription(() {
      if (identical(_handler, onUri)) _handler = null;
    });
  }

  void emit(String uri) => _handler?.call(uri);
}

final class _FakeSubscription implements AgentDeepLinkSubscription {
  _FakeSubscription(this._cancel);

  final void Function() _cancel;

  @override
  void cancel() => _cancel();
}
