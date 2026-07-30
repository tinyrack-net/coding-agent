import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/agent_hot_route_controller.dart';
import 'package:coding_agent_app/core/desktop/agent_navigation_inbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup burst navigates only to the newest queued target', () {
    final routes = <String>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
    );
    addTearDown(controller.dispose);

    expect(
      controller.receiveUri('coding-agent://h/server-1/agent/agent-1'),
      AgentHotRouteDisposition.queued,
    );
    expect(
      controller.receiveUri('coding-agent://h/server-1/agent/agent-2'),
      AgentHotRouteDisposition.queued,
    );
    expect(controller.markReady(), AgentHotRouteDisposition.navigated);
    expect(routes, ['/h/server-1/agent/agent-2']);
    expect(controller.markReady(), AgentHotRouteDisposition.ignored);
  });

  test('ready window navigates valid hot links immediately', () {
    final routes = <String>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
    );
    addTearDown(controller.dispose);
    controller.markReady();

    expect(
      controller.receiveUri('coding-agent://h/server%2Fmain/agent/agent%20123'),
      AgentHotRouteDisposition.navigated,
    );
    expect(routes, ['/h/server%2Fmain/agent/agent%20123']);
  });

  test('loading queues a new newest target until ready again', () {
    final routes = <String>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
    );
    addTearDown(controller.dispose);
    controller.markReady();
    controller.markLoading();

    controller.receiveUri('coding-agent://h/server/agent/agent-1');
    controller.receiveUri('coding-agent://h/server/agent/agent-2');
    expect(routes, isEmpty);

    controller.markReady();
    expect(routes, ['/h/server/agent/agent-2']);
  });

  test('malformed, foreign, and empty targets are ignored', () {
    final routes = <String>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
    );
    addTearDown(controller.dispose);
    controller.markReady();

    expect(
      controller.receiveUri('https://h/server/agent/agent-1'),
      AgentHotRouteDisposition.ignored,
    );
    expect(
      controller.receiveUri(
        'coding-agent://h/server/agent/agent-1?message=hello',
      ),
      AgentHotRouteDisposition.ignored,
    );
    expect(
      controller.receiveTarget(
        const AgentDeepLinkTarget(serverId: ' ', agentId: 'agent-1'),
      ),
      AgentHotRouteDisposition.ignored,
    );
    expect(routes, isEmpty);
  });

  test('slow activation cannot reorder immediate navigation', () async {
    final routes = <String>[];
    final activations = <Completer<void>>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
      activateWindow: () {
        final activation = Completer<void>();
        activations.add(activation);
        return activation.future;
      },
    );
    addTearDown(controller.dispose);
    controller.markReady();

    controller.receiveUri('coding-agent://h/server/agent/agent-1');
    controller.receiveUri('coding-agent://h/server/agent/agent-2');
    expect(routes, ['/h/server/agent/agent-1', '/h/server/agent/agent-2']);

    activations.last.complete();
    await Future<void>.delayed(Duration.zero);
    activations.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(routes.last, '/h/server/agent/agent-2');
  });

  test('activation failure does not prevent navigation', () async {
    final routes = <String>[];
    final controller = AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 7,
      navigate: routes.add,
      activateWindow: () => Future<void>.error(StateError('focus failed')),
    );
    addTearDown(controller.dispose);
    controller.markReady();

    expect(
      controller.receiveUri('coding-agent://h/server/agent/agent-1'),
      AgentHotRouteDisposition.navigated,
    );
    await Future<void>.delayed(Duration.zero);
    expect(routes, ['/h/server/agent/agent-1']);
  });

  test('dispose removes pending navigation and ignores later delivery', () {
    final routes = <String>[];
    final inbox = AgentNavigationInbox();
    final controller = AgentHotRouteController(
      inbox: inbox,
      windowId: 7,
      navigate: routes.add,
    );
    controller.receiveUri('coding-agent://h/server/agent/agent-1');
    controller.dispose();

    expect(controller.markReady(), AgentHotRouteDisposition.ignored);
    expect(
      controller.receiveUri('coding-agent://h/server/agent/agent-2'),
      AgentHotRouteDisposition.ignored,
    );
    expect(inbox.windowReady(7), isNull);
    expect(routes, isEmpty);
  });
}
