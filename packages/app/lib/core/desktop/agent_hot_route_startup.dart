import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../agent_hot_route_controller.dart';
import 'agent_deep_link_source.dart';
import 'agent_hot_route_binding.dart';
import 'agent_navigation_inbox.dart';

Widget bindAgentHotRoutes({
  required Widget child,
  required GoRouter router,
  required AgentDeepLinkSource? source,
}) {
  if (source == null) return child;
  return AgentHotRouteBinding(
    source: source,
    controller: AgentHotRouteController(
      inbox: AgentNavigationInbox(),
      windowId: 1,
      navigate: router.go,
    ),
    child: child,
  );
}
