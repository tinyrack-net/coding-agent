/// Tracks pending permission prompts and routes decisions back to the
/// provider session that raised them.
library;

import '../providers/provider_event.dart';
import '../server/rpc_router.dart';

final class _PendingPermission {
  _PendingPermission({
    required this.agentId,
    required this.respond,
    required this.onResolved,
  });

  final String agentId;
  final PermissionRespond respond;

  /// Post-decision hook supplied by the agent manager (timeline + state
  /// updates and the `permission.resolved` broadcast).
  final void Function(PermissionDecision decision) onResolved;
}

class PermissionBroker {
  final Map<String, _PendingPermission> _pending = {};

  bool get hasPending => _pending.isNotEmpty;

  void register({
    required String permissionId,
    required String agentId,
    required PermissionRespond respond,
    required void Function(PermissionDecision decision) onResolved,
  }) {
    _pending[permissionId] = _PendingPermission(
      agentId: agentId,
      respond: respond,
      onResolved: onResolved,
    );
  }

  /// Resolve a pending permission. [decision] is the wire string:
  /// `allow`, `allow_always` (treated as allow for M1) or `deny`.
  Future<void> respond(String permissionId, String decision) async {
    await respondDetailed(permissionId: permissionId, behavior: decision);
  }

  Future<void> respondDetailed({
    required String permissionId,
    required String behavior,
    String? agentId,
    String? message,
    String? selectedActionId,
    Map<String, Object?>? updatedInput,
    List<Map<String, Object?>>? updatedPermissions,
    bool? interrupt,
  }) async {
    final parsed = switch (behavior) {
      'allow' || 'allow_always' => PermissionDecision.allow,
      'deny' => PermissionDecision.deny,
      _ => throw RpcException(
        'invalid_payload',
        'unknown decision "$behavior"',
      ),
    };
    final pending = _pending.remove(permissionId);
    if (pending == null) {
      throw RpcException('not_found', 'no pending permission $permissionId');
    }
    if (agentId != null && pending.agentId != agentId) {
      _pending[permissionId] = pending;
      throw RpcException(
        'not_found',
        'no pending permission $permissionId for agent $agentId',
      );
    }
    await pending.respond(
      parsed,
      message: message,
      selectedActionId: selectedActionId,
      updatedInput: updatedInput,
      updatedPermissions: updatedPermissions,
      interrupt: interrupt,
    );
    pending.onResolved(parsed);
  }

  /// Deny every pending permission for [agentId] (session died/disposed).
  Future<void> autoDenyForAgent(String agentId) async {
    final ids = _pending.entries
        .where((e) => e.value.agentId == agentId)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      final pending = _pending.remove(id)!;
      try {
        await pending.respond(
          PermissionDecision.deny,
          message: 'session ended',
        );
      } catch (_) {}
      pending.onResolved(PermissionDecision.deny);
    }
  }
}
