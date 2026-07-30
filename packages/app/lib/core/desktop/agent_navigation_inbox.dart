import 'package:agent_protocol/agent_protocol.dart';

/// Finds the first valid existing-agent deep link in a process argument list.
AgentDeepLinkTarget? parseAgentDeepLinkFromArguments(
  Iterable<String> arguments,
) {
  for (final argument in arguments) {
    final target = parseAgentDeepLink(argument);
    if (target != null) return target;
  }
  return null;
}

/// Coordinates existing-agent navigation across independently loading windows.
///
/// Each non-ready window retains one pending target. A newer target replaces
/// the older one so a startup burst always lands on the user's latest intent.
final class AgentNavigationInbox {
  final Set<int> _readyWindows = {};
  final Map<int, AgentDeepLinkTarget> _pendingByWindow = {};

  void windowLoading(int windowId) {
    _readyWindows.remove(windowId);
  }

  AgentDeepLinkTarget? windowReady(int windowId) {
    _readyWindows.add(windowId);
    return _pendingByWindow.remove(windowId);
  }

  AgentDeepLinkTarget? deliverOrQueue(
    int windowId,
    AgentDeepLinkTarget target,
  ) {
    if (_readyWindows.contains(windowId)) return target;
    _pendingByWindow[windowId] = target;
    return null;
  }

  void removeWindow(int windowId) {
    _readyWindows.remove(windowId);
    _pendingByWindow.remove(windowId);
  }
}
