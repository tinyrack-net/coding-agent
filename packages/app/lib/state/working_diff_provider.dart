import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'workspace_checkout_status_provider.dart';

final class WorkingDiffOverride {
  const WorkingDiffOverride({
    required this.serverId,
    required this.cwd,
    required this.mode,
    required this.isDirtyAtSelection,
  });

  final String serverId;
  final String cwd;
  final CheckoutDiffMode mode;
  final bool isDirtyAtSelection;
}

final class WorkingDiffOverrideNotifier
    extends Notifier<Map<String, WorkingDiffOverride>> {
  @override
  Map<String, WorkingDiffOverride> build() => const {};

  void select({
    required String scopeKey,
    required String serverId,
    required String cwd,
    required CheckoutDiffMode mode,
    required bool isDirty,
  }) {
    state = Map.unmodifiable({
      ...state,
      scopeKey: WorkingDiffOverride(
        serverId: serverId,
        cwd: cwd,
        mode: mode,
        isDirtyAtSelection: isDirty,
      ),
    });
  }

  void expireIfDirtyChanged({
    required String serverId,
    required String cwd,
    required bool isDirty,
  }) {
    final staleKeys = state.entries
        .where(
          (entry) =>
              entry.value.serverId == serverId &&
              entry.value.cwd == cwd &&
              entry.value.isDirtyAtSelection != isDirty,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (staleKeys.isEmpty) return;
    final next = Map<String, WorkingDiffOverride>.from(state);
    for (final key in staleKeys) {
      next.remove(key);
    }
    state = Map.unmodifiable(next);
  }
}

final workingDiffOverrideProvider =
    NotifierProvider<
      WorkingDiffOverrideNotifier,
      Map<String, WorkingDiffOverride>
    >(WorkingDiffOverrideNotifier.new);

String buildWorkingDiffScopeKey({
  required String serverId,
  required String cwd,
  String? workspaceId,
  String? baseRef,
  required bool ignoreWhitespace,
}) {
  final normalizedWorkspaceId = workspaceId?.trim();
  final placement =
      normalizedWorkspaceId != null && normalizedWorkspaceId.isNotEmpty
      ? 'workspace=${Uri.encodeComponent(normalizedWorkspaceId)}'
      : 'cwd=${Uri.encodeComponent(_normalizeCwd(cwd))}';
  return [
    'review',
    'server=${Uri.encodeComponent(serverId.trim())}',
    placement,
    'base=${Uri.encodeComponent(baseRef?.trim() ?? '')}',
    'ignoreWhitespace=$ignoreWhitespace',
  ].join(':');
}

CheckoutDiffMode resolveWorkingDiffMode({
  required bool isDirty,
  WorkingDiffOverride? override,
}) {
  if (override != null && override.isDirtyAtSelection == isDirty) {
    return override.mode;
  }
  return isDirty ? CheckoutDiffMode.uncommitted : CheckoutDiffMode.base;
}

final class CheckoutDiffQuery {
  const CheckoutDiffQuery({
    required this.serverId,
    required this.cwd,
    required this.compare,
  });

  final String serverId;
  final String cwd;
  final CheckoutDiffCompare compare;

  @override
  bool operator ==(Object other) =>
      other is CheckoutDiffQuery &&
      other.serverId == serverId &&
      other.cwd == cwd &&
      other.compare.mode == compare.mode &&
      other.compare.baseRef == compare.baseRef &&
      other.compare.ignoreWhitespace == compare.ignoreWhitespace;

  @override
  int get hashCode => Object.hash(
    serverId,
    cwd,
    compare.mode,
    compare.baseRef,
    compare.ignoreWhitespace,
  );
}

final class CheckoutDiffNotifier extends AsyncNotifier<CheckoutDiffPayload?> {
  CheckoutDiffNotifier(this.query);

  final CheckoutDiffQuery query;

  @override
  Future<CheckoutDiffPayload?> build() async {
    final client = ref.watch(
      checkoutStatusDaemonClientProvider(query.serverId),
    );
    final connection = ref
        .watch(checkoutStatusConnectionProvider(query.serverId))
        .value;
    if (client == null || query.cwd.trim().isEmpty) return null;
    if ((connection ?? client.currentState) !=
        DaemonConnectionState.connected) {
      return state.value;
    }

    final subscriptionId = _stableSubscriptionId(query);
    var active = true;
    final updates = client.checkoutDiffUpdates.listen((update) {
      if (active && update.payload.subscriptionId == subscriptionId) {
        state = AsyncData(update.payload);
      }
    });
    ref.onDispose(() {
      active = false;
      unawaited(updates.cancel());
      if (client.currentState == DaemonConnectionState.connected) {
        try {
          client.sendSessionMessage(
            UnsubscribeCheckoutDiffRequest(
              subscriptionId: subscriptionId,
            ).toJson(),
          );
        } on StateError {
          // Disconnect won the disposal race; server session cleanup owns it.
        }
      }
    });

    final requestId = const Uuid().v4();
    final response = SubscribeCheckoutDiffResponse.fromJson(
      await client.requestSessionMessage(
        SubscribeCheckoutDiffRequest(
          subscriptionId: subscriptionId,
          cwd: query.cwd,
          compare: query.compare,
          requestId: requestId,
        ).toJson(),
      ),
    );
    if (response.requestId != requestId) {
      throw FormatException(
        'Checkout diff response requestId mismatch: ${response.requestId}',
      );
    }
    return response.payload;
  }
}

final checkoutDiffProvider =
    AsyncNotifierProvider.family<
      CheckoutDiffNotifier,
      CheckoutDiffPayload?,
      CheckoutDiffQuery
    >(CheckoutDiffNotifier.new);

String _stableSubscriptionId(CheckoutDiffQuery query) {
  final source = [
    query.serverId,
    query.cwd,
    query.compare.mode.name,
    query.compare.baseRef ?? '',
    query.compare.ignoreWhitespace,
  ].join('\u0000');
  var hash = 0xcbf29ce484222325;
  for (final codeUnit in source.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return 'checkout-diff-${hash.toRadixString(16)}';
}

String _normalizeCwd(String cwd) {
  final trimmed = cwd.trim();
  if (trimmed == '/' || RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(trimmed)) {
    return trimmed;
  }
  return trimmed.replaceFirst(RegExp(r'[\\/]+$'), '');
}
