import 'package:agent_daemon/src/permission/permission_broker.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:test/test.dart';

void main() {
  late PermissionBroker broker;

  setUp(() {
    broker = PermissionBroker();
  });

  test('hasPending reflects registration and resolution', () async {
    expect(broker.hasPending, isFalse);
    PermissionDecision? responded;
    broker.register(
      permissionId: 'p1',
      agentId: 'a1',
      respond: (decision, {String? message}) async => responded = decision,
      onResolved: (_) {},
    );
    expect(broker.hasPending, isTrue);

    await broker.respond('p1', 'allow');
    expect(responded, PermissionDecision.allow);
    expect(broker.hasPending, isFalse);
  });

  test('respond maps "allow_always" to allow', () async {
    PermissionDecision? responded;
    broker.register(
      permissionId: 'p1',
      agentId: 'a1',
      respond: (decision, {String? message}) async => responded = decision,
      onResolved: (_) {},
    );
    await broker.respond('p1', 'allow_always');
    expect(responded, PermissionDecision.allow);
  });

  test('respond maps "deny" to deny and invokes onResolved with the decision',
      () async {
    PermissionDecision? responded;
    PermissionDecision? resolved;
    broker.register(
      permissionId: 'p1',
      agentId: 'a1',
      respond: (decision, {String? message}) async => responded = decision,
      onResolved: (decision) => resolved = decision,
    );
    await broker.respond('p1', 'deny');
    expect(responded, PermissionDecision.deny);
    expect(resolved, PermissionDecision.deny);
  });

  test('respond with unknown decision string throws invalid_payload',
      () async {
    broker.register(
      permissionId: 'p1',
      agentId: 'a1',
      respond: (decision, {String? message}) async {},
      onResolved: (_) {},
    );
    await expectLater(
      broker.respond('p1', 'maybe'),
      throwsA(isA<RpcException>().having(
        (e) => e.error.code,
        'code',
        'invalid_payload',
      )),
    );
    // The pending entry is still there (removed before validation fails, so
    // a follow-up respond with a valid decision will not find it either).
    await expectLater(
      broker.respond('p1', 'allow'),
      throwsA(isA<RpcException>().having(
        (e) => e.error.code,
        'code',
        'not_found',
      )),
    );
  });

  test('respond for an unknown permission id throws not_found', () async {
    await expectLater(
      broker.respond('nope', 'allow'),
      throwsA(isA<RpcException>().having(
        (e) => e.error.code,
        'code',
        'not_found',
      )),
    );
  });

  test('responding twice for the same id fails the second time', () async {
    broker.register(
      permissionId: 'p1',
      agentId: 'a1',
      respond: (decision, {String? message}) async {},
      onResolved: (_) {},
    );
    await broker.respond('p1', 'allow');
    await expectLater(
      broker.respond('p1', 'allow'),
      throwsA(isA<RpcException>()),
    );
  });

  test('autoDenyForAgent denies only pending permissions for that agent',
      () async {
    final responses = <String, PermissionDecision>{};
    final resolutions = <String, PermissionDecision>{};
    broker.register(
      permissionId: 'a-perm-1',
      agentId: 'agent-a',
      respond: (decision, {String? message}) async =>
          responses['a-perm-1'] = decision,
      onResolved: (decision) => resolutions['a-perm-1'] = decision,
    );
    broker.register(
      permissionId: 'a-perm-2',
      agentId: 'agent-a',
      respond: (decision, {String? message}) async =>
          responses['a-perm-2'] = decision,
      onResolved: (decision) => resolutions['a-perm-2'] = decision,
    );
    broker.register(
      permissionId: 'b-perm-1',
      agentId: 'agent-b',
      respond: (decision, {String? message}) async =>
          responses['b-perm-1'] = decision,
      onResolved: (decision) => resolutions['b-perm-1'] = decision,
    );

    await broker.autoDenyForAgent('agent-a');

    expect(responses['a-perm-1'], PermissionDecision.deny);
    expect(responses['a-perm-2'], PermissionDecision.deny);
    expect(responses.containsKey('b-perm-1'), isFalse);
    expect(resolutions['a-perm-1'], PermissionDecision.deny);
    expect(resolutions['a-perm-2'], PermissionDecision.deny);
    expect(broker.hasPending, isTrue); // b-perm-1 still pending

    // b's permission is untouched and can still be resolved normally.
    await broker.respond('b-perm-1', 'allow');
    expect(responses['b-perm-1'], PermissionDecision.allow);
  });

  test('autoDenyForAgent swallows errors thrown by respond and still '
      'calls onResolved', () async {
    var resolvedCalled = false;
    broker.register(
      permissionId: 'p1',
      agentId: 'agent-a',
      respond: (decision, {String? message}) async {
        throw StateError('boom');
      },
      onResolved: (_) => resolvedCalled = true,
    );

    await broker.autoDenyForAgent('agent-a');
    expect(resolvedCalled, isTrue);
    expect(broker.hasPending, isFalse);
  });

  test('autoDenyForAgent is a no-op when nothing is pending for the agent',
      () async {
    await broker.autoDenyForAgent('nobody');
    expect(broker.hasPending, isFalse);
  });
}
