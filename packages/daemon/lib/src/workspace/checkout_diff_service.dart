import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_service.dart';
import '../server/connection.dart';
import 'workspace_git_observer_service.dart';

/// Session-scoped live checkout diffs matching Paseo's frozen subscription
/// contract. A single backend watch is shared by cwd while subscription ids
/// remain isolated per connection.
final class CheckoutDiffService {
  CheckoutDiffService({
    required this.git,
    required this.backend,
    this.debounce = const Duration(milliseconds: 150),
  });

  final GitService git;
  final WorkspaceGitObserverBackend backend;
  final Duration debounce;
  final Map<({String connectionId, String subscriptionId}), _DiffSubscription>
  _subscriptions = {};

  Future<Map<String, Object?>> subscribe(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    final request = SubscribeCheckoutDiffRequest.fromJson(message);
    final key = (
      connectionId: connection.id,
      subscriptionId: request.subscriptionId,
    );
    _remove(key);
    final subscription = _DiffSubscription(
      connection: connection,
      request: request,
    );
    _subscriptions[key] = subscription;
    subscription.gitSubscription = backend.registerWorkspace(
      request.cwd,
      (_) => _scheduleRefresh(key, subscription),
    );
    final payload = await _load(subscription);
    if (identical(_subscriptions[key], subscription)) {
      subscription
        ..fingerprint = jsonEncode(payload.toJson())
        ..ready = true;
    }
    return SubscribeCheckoutDiffResponse(
      payload: payload,
      requestId: request.requestId,
    ).toJson();
  }

  void unsubscribe(String connectionId, Map<String, Object?> message) {
    final request = UnsubscribeCheckoutDiffRequest.fromJson(message);
    _remove((
      connectionId: connectionId,
      subscriptionId: request.subscriptionId,
    ));
  }

  void onConnectionClosed(String connectionId) {
    final keys = _subscriptions.keys
        .where((key) => key.connectionId == connectionId)
        .toList(growable: false);
    for (final key in keys) {
      _remove(key);
    }
  }

  void dispose() {
    for (final key in _subscriptions.keys.toList(growable: false)) {
      _remove(key);
    }
  }

  void _scheduleRefresh(
    ({String connectionId, String subscriptionId}) key,
    _DiffSubscription subscription,
  ) {
    if (!subscription.ready || !identical(_subscriptions[key], subscription)) {
      return;
    }
    subscription.debounceTimer?.cancel();
    subscription.debounceTimer = Timer(debounce, () {
      subscription.debounceTimer = null;
      unawaited(_refresh(key, subscription));
    });
  }

  Future<void> _refresh(
    ({String connectionId, String subscriptionId}) key,
    _DiffSubscription subscription,
  ) async {
    if (subscription.refreshing) {
      subscription.refreshAgain = true;
      return;
    }
    subscription.refreshing = true;
    try {
      do {
        subscription.refreshAgain = false;
        final payload = await _load(subscription);
        if (!identical(_subscriptions[key], subscription)) return;
        final fingerprint = jsonEncode(payload.toJson());
        if (fingerprint != subscription.fingerprint) {
          subscription.fingerprint = fingerprint;
          subscription.connection.sendJson({
            'type': 'session',
            'message': CheckoutDiffUpdate(payload).toJson(),
          });
        }
      } while (subscription.refreshAgain);
    } finally {
      subscription.refreshing = false;
    }
  }

  Future<CheckoutDiffPayload> _load(_DiffSubscription subscription) async {
    try {
      final diff = await git.checkoutDiff(
        subscription.request.cwd,
        subscription.request.compare,
      );
      return checkoutDiffPayloadFromLegacy(
        subscriptionId: subscription.request.subscriptionId,
        cwd: subscription.request.cwd,
        diff: diff,
      );
    } on Object catch (error) {
      return checkoutDiffPayloadFromLegacy(
        subscriptionId: subscription.request.subscriptionId,
        cwd: subscription.request.cwd,
        diff: const DiffResponse(files: []),
        error: CheckoutError(
          code: CheckoutErrorCode.unknown,
          message: '$error',
        ),
      );
    }
  }

  void _remove(({String connectionId, String subscriptionId}) key) {
    final subscription = _subscriptions.remove(key);
    subscription?.debounceTimer?.cancel();
    subscription?.gitSubscription?.unsubscribe();
  }
}

final class _DiffSubscription {
  _DiffSubscription({required this.connection, required this.request});

  final Connection connection;
  final SubscribeCheckoutDiffRequest request;
  WorkspaceGitSubscription? gitSubscription;
  Timer? debounceTimer;
  String? fingerprint;
  bool ready = false;
  bool refreshing = false;
  bool refreshAgain = false;
}
