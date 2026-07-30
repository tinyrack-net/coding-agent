import 'dart:async';

import 'package:flutter/widgets.dart';

import '../agent_hot_route_controller.dart';
import 'agent_deep_link_source.dart';

/// Binds running-app link events to one hot-route controller.
///
/// Cold-start routing remains the caller's responsibility. This widget never
/// accepts or replays an initial location.
final class AgentHotRouteBinding extends StatefulWidget {
  const AgentHotRouteBinding({
    super.key,
    required this.source,
    required this.controller,
    required this.child,
    this.retryDelay = const Duration(seconds: 1),
  });

  final AgentDeepLinkSource source;
  final AgentHotRouteController controller;
  final Widget child;
  final Duration retryDelay;

  @override
  State<AgentHotRouteBinding> createState() => _AgentHotRouteBindingState();
}

class _AgentHotRouteBindingState extends State<AgentHotRouteBinding> {
  late final AgentDeepLinkSource _source = widget.source;
  late final AgentHotRouteController _controller = widget.controller;

  AgentDeepLinkSubscription? _subscription;
  Timer? _retryTimer;
  var _firstFrameComplete = false;
  var _listenerReady = false;
  var _controllerReady = false;
  var _connecting = false;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _firstFrameComplete = true;
      _markReadyIfPossible();
    });
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_disposed || _connecting || _subscription != null) return;
    _connecting = true;
    try {
      final subscription = await _source.listen(_controller.receiveUri);
      if (_disposed) {
        await _cancelSafely(subscription);
        return;
      }
      _subscription = subscription;
      _listenerReady = true;
      _markReadyIfPossible();
    } on Object {
      if (!_disposed) {
        _retryTimer?.cancel();
        _retryTimer = Timer(widget.retryDelay, () {
          _retryTimer = null;
          unawaited(_connect());
        });
      }
    } finally {
      _connecting = false;
    }
  }

  void _markReadyIfPossible() {
    if (_disposed ||
        _controllerReady ||
        !_firstFrameComplete ||
        !_listenerReady) {
      return;
    }
    _controllerReady = true;
    _controller.markReady();
  }

  Future<void> _cancelSafely(AgentDeepLinkSubscription subscription) async {
    try {
      await subscription.cancel();
    } on Object {
      // Listener teardown is best effort during widget disposal.
    }
  }

  @override
  void didUpdateWidget(covariant AgentHotRouteBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      identical(oldWidget.source, widget.source) &&
          identical(oldWidget.controller, widget.controller),
      'AgentHotRouteBinding owns stable source and controller instances.',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(_cancelSafely(subscription));
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
