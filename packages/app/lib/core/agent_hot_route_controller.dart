import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import 'desktop/agent_navigation_inbox.dart';

enum AgentHotRouteDisposition { ignored, queued, navigated }

typedef AgentRouteNavigator = void Function(String route);
typedef AgentWindowActivator = FutureOr<void> Function();

/// Applies running-app existing-agent links without owning a platform channel.
///
/// A later platform adapter feeds URI strings or parsed targets into this
/// controller. Navigation stays synchronous; window activation is best effort
/// and deliberately not awaited so activation completion order cannot reorder
/// routes.
final class AgentHotRouteController {
  factory AgentHotRouteController({
    required AgentNavigationInbox inbox,
    required int windowId,
    required AgentRouteNavigator navigate,
    AgentWindowActivator? activateWindow,
  }) => AgentHotRouteController._(inbox, windowId, navigate, activateWindow);

  AgentHotRouteController._(
    this._inbox,
    this._windowId,
    this._navigate,
    this._activateWindow,
  );

  final AgentNavigationInbox _inbox;
  final int _windowId;
  final AgentRouteNavigator _navigate;
  final AgentWindowActivator? _activateWindow;

  bool _disposed = false;

  AgentHotRouteDisposition receiveUri(String uri) {
    if (_disposed) return AgentHotRouteDisposition.ignored;
    final target = parseAgentDeepLink(uri);
    return target == null
        ? AgentHotRouteDisposition.ignored
        : receiveTarget(target);
  }

  AgentHotRouteDisposition receiveTarget(AgentDeepLinkTarget target) {
    if (_disposed) return AgentHotRouteDisposition.ignored;
    if (!_isValid(target)) return AgentHotRouteDisposition.ignored;

    _activateBestEffort();
    final deliverable = _inbox.deliverOrQueue(_windowId, target);
    if (deliverable == null) return AgentHotRouteDisposition.queued;
    _navigate(buildAgentDeepLinkRoute(deliverable));
    return AgentHotRouteDisposition.navigated;
  }

  void markLoading() {
    if (_disposed) return;
    _inbox.windowLoading(_windowId);
  }

  AgentHotRouteDisposition markReady() {
    if (_disposed) return AgentHotRouteDisposition.ignored;
    final pending = _inbox.windowReady(_windowId);
    if (pending == null) return AgentHotRouteDisposition.ignored;
    _navigate(buildAgentDeepLinkRoute(pending));
    return AgentHotRouteDisposition.navigated;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inbox.removeWindow(_windowId);
  }

  bool _isValid(AgentDeepLinkTarget target) {
    try {
      buildAgentDeepLinkRoute(target);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  void _activateBestEffort() {
    final activate = _activateWindow;
    if (activate == null) return;
    try {
      final activation = activate();
      if (activation is Future<void>) {
        unawaited(activation.catchError((Object _, StackTrace _) {}));
      }
    } on Object {
      // Window activation must never prevent route delivery.
    }
  }
}
