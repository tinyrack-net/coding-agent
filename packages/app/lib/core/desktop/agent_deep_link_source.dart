import 'dart:async';

typedef AgentDeepLinkHandler = void Function(String uri);

abstract interface class AgentDeepLinkSubscription {
  FutureOr<void> cancel();
}

/// Platform adapters implement this contract without owning route state.
///
/// [listen] completes only after the handler is registered. An adapter may
/// synchronously deliver buffered events before completing the returned
/// future; the hot-route binding keeps its controller non-ready until then.
abstract interface class AgentDeepLinkSource {
  Future<AgentDeepLinkSubscription> listen(AgentDeepLinkHandler onUri);
}
