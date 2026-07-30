import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../git/git_service.dart';
import '../server/connection.dart';
import 'workspace_git_observer_service.dart';

final class CheckoutDiffMetrics {
  const CheckoutDiffMetrics({
    required this.targetCount,
    required this.subscriptionCount,
  });

  final int targetCount;
  final int subscriptionCount;
}

/// Paseo-compatible live checkout diff manager.
///
/// Equivalent cwd/compare subscriptions share one Git watch, initial load,
/// debounce timer, refresh queue, and snapshot fingerprint. Subscription ids
/// remain isolated per connection and are projected only at the wire edge.
final class CheckoutDiffService {
  CheckoutDiffService({
    required this.git,
    required this.backend,
    this.debounce = const Duration(milliseconds: 150),
  });

  final GitService git;
  final WorkspaceGitObserverBackend backend;
  final Duration debounce;
  final Map<({String connectionId, String subscriptionId}), _DiffListener>
  _subscriptions = {};
  final Map<String, _DiffTarget> _targets = {};

  CheckoutDiffMetrics get metrics => CheckoutDiffMetrics(
    targetCount: _targets.length,
    subscriptionCount: _subscriptions.length,
  );

  Future<Map<String, Object?>> subscribe(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    final request = SubscribeCheckoutDiffRequest.fromJson(message);
    final subscriptionKey = (
      connectionId: connection.id,
      subscriptionId: request.subscriptionId,
    );
    _remove(subscriptionKey);

    final compare = request.compare.normalized();
    final cwd = p.normalize(p.absolute(_expandTilde(request.cwd)));
    final targetKey = _targetKey(cwd, compare);
    final target = _targets.putIfAbsent(
      targetKey,
      () => _DiffTarget(key: targetKey, cwd: cwd, compare: compare),
    );
    final listener = _DiffListener(
      connection: connection,
      request: request,
      target: target,
    );
    _subscriptions[subscriptionKey] = listener;
    target.listeners[subscriptionKey] = listener;
    target.gitSubscription ??= backend.registerWorkspace(
      cwd,
      (_) => _scheduleRefresh(target),
    );

    target.openFuture ??= _open(target);
    final snapshot = await target.openFuture!;
    return SubscribeCheckoutDiffResponse(
      payload: _payloadFor(listener, snapshot),
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
    for (final target in _targets.values) {
      _closeTarget(target);
    }
    _targets.clear();
    _subscriptions.clear();
  }

  Future<_DiffSnapshot> _open(_DiffTarget target) async {
    final snapshot = await _load(target);
    if (identical(_targets[target.key], target)) {
      target
        ..latest = snapshot
        ..fingerprint = jsonEncode(snapshot.toJson())
        ..ready = true;
    }
    return snapshot;
  }

  void _scheduleRefresh(_DiffTarget target) {
    if (!target.ready || !identical(_targets[target.key], target)) return;
    target.debounceTimer?.cancel();
    target.debounceTimer = Timer(debounce, () {
      target.debounceTimer = null;
      unawaited(_refresh(target));
    });
  }

  Future<void> _refresh(_DiffTarget target) async {
    if (target.refreshing) {
      target.refreshAgain = true;
      return;
    }
    target.refreshing = true;
    try {
      do {
        target.refreshAgain = false;
        final snapshot = await _load(target);
        if (!identical(_targets[target.key], target)) return;
        target.latest = snapshot;
        final fingerprint = jsonEncode(snapshot.toJson());
        if (fingerprint != target.fingerprint) {
          target.fingerprint = fingerprint;
          for (final listener in target.listeners.values.toList(
            growable: false,
          )) {
            listener.connection.sendJson({
              'type': 'session',
              'message': CheckoutDiffUpdate(
                _payloadFor(listener, snapshot),
              ).toJson(),
            });
          }
        }
      } while (target.refreshAgain);
    } finally {
      target.refreshing = false;
    }
  }

  Future<_DiffSnapshot> _load(_DiffTarget target) async {
    try {
      final diff = await git.checkoutDiff(target.cwd, target.compare);
      final payload = checkoutDiffPayloadFromLegacy(
        subscriptionId: '',
        cwd: target.cwd,
        diff: diff,
      );
      return _DiffSnapshot(files: payload.files, error: null);
    } on Object catch (error) {
      return _DiffSnapshot(
        files: const [],
        error: CheckoutError(
          code: CheckoutErrorCode.unknown,
          message: '$error',
        ),
      );
    }
  }

  CheckoutDiffPayload _payloadFor(
    _DiffListener listener,
    _DiffSnapshot snapshot,
  ) => CheckoutDiffPayload(
    subscriptionId: listener.request.subscriptionId,
    cwd: listener.request.cwd,
    files: snapshot.files,
    error: snapshot.error,
  );

  void _remove(({String connectionId, String subscriptionId}) key) {
    final listener = _subscriptions.remove(key);
    if (listener == null) return;
    final target = listener.target;
    target.listeners.remove(key);
    if (target.listeners.isEmpty) {
      _closeTarget(target);
      if (identical(_targets[target.key], target)) {
        _targets.remove(target.key);
      }
    }
  }

  void _closeTarget(_DiffTarget target) {
    target.debounceTimer?.cancel();
    target.gitSubscription?.unsubscribe();
    target.gitSubscription = null;
    target.listeners.clear();
  }
}

String _targetKey(String cwd, CheckoutDiffCompare compare) => jsonEncode([
  cwd,
  compare.mode.name,
  compare.mode == CheckoutDiffMode.base ? compare.baseRef ?? '' : '',
  compare.ignoreWhitespace,
]);

String _expandTilde(String value) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return value;
  return value == '~' ? home : p.join(home, value.substring(2));
}

final class _DiffSnapshot {
  const _DiffSnapshot({required this.files, required this.error});

  final List<CheckoutDiffFile> files;
  final CheckoutError? error;

  Map<String, Object?> toJson() => {
    'files': files.map((file) => file.toJson()).toList(),
    'error': error?.toJson(),
  };
}

final class _DiffTarget {
  _DiffTarget({required this.key, required this.cwd, required this.compare});

  final String key;
  final String cwd;
  final CheckoutDiffCompare compare;
  final Map<({String connectionId, String subscriptionId}), _DiffListener>
  listeners = {};
  WorkspaceGitSubscription? gitSubscription;
  Timer? debounceTimer;
  Future<_DiffSnapshot>? openFuture;
  _DiffSnapshot? latest;
  String? fingerprint;
  bool ready = false;
  bool refreshing = false;
  bool refreshAgain = false;
}

final class _DiffListener {
  const _DiffListener({
    required this.connection,
    required this.request,
    required this.target,
  });

  final Connection connection;
  final SubscribeCheckoutDiffRequest request;
  final _DiffTarget target;
}
