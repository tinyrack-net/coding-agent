import 'dart:async';

import 'package:flutter/services.dart';

import 'agent_deep_link_source.dart';

final class WindowsAgentDeepLinkSource implements AgentDeepLinkSource {
  WindowsAgentDeepLinkSource()
    : _channel = const MethodChannel('tinyrack/agent_navigation');

  WindowsAgentDeepLinkSource.withChannel(this._channel);

  final MethodChannel _channel;
  bool _listening = false;

  @override
  Future<AgentDeepLinkSubscription> listen(AgentDeepLinkHandler onUri) async {
    if (_listening) {
      throw StateError('Agent deep-link listener is already active.');
    }
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        onUri(call.arguments as String);
      }
    });

    try {
      final pending = await _channel.invokeMethod<String>('listen');
      if (pending != null) {
        onUri(pending);
      }
      return _WindowsAgentDeepLinkSubscription(() async {
        if (!_listening) return;
        _listening = false;
        _channel.setMethodCallHandler(null);
        await _channel.invokeMethod<void>('cancel');
      });
    } on Object {
      _listening = false;
      _channel.setMethodCallHandler(null);
      rethrow;
    }
  }
}

final class _WindowsAgentDeepLinkSubscription
    implements AgentDeepLinkSubscription {
  _WindowsAgentDeepLinkSubscription(this._onCancel);

  final Future<void> Function() _onCancel;
  Future<void>? _cancellation;

  @override
  Future<void> cancel() => _cancellation ??= _onCancel();
}
