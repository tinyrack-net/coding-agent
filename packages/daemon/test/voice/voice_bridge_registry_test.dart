import 'package:agent_daemon/src/voice/voice_bridge_registry.dart';
import 'package:agent_daemon/src/voice/voice_types.dart';
import 'package:test/test.dart';

void main() {
  test(
    'registers, replaces, resolves, and unregisters speak handlers',
    () async {
      final registry = VoiceBridgeRegistry();
      final spoken = <String>[];
      Future<void> first({
        required String text,
        required String callerAgentId,
        VoiceAbortSignal? signal,
      }) async {
        spoken.add('first:$callerAgentId:$text');
      }

      Future<void> second({
        required String text,
        required String callerAgentId,
        VoiceAbortSignal? signal,
      }) async {
        spoken.add('second:$callerAgentId:$text');
      }

      registry.registerSpeakHandler('agent-1', first);
      await registry.resolveSpeakHandler('agent-1')!(
        text: 'hello',
        callerAgentId: 'agent-1',
      );
      registry.registerSpeakHandler('agent-1', second);
      await registry.resolveSpeakHandler('agent-1')!(
        text: 'again',
        callerAgentId: 'agent-1',
      );
      expect(spoken, ['first:agent-1:hello', 'second:agent-1:again']);

      registry.unregisterSpeakHandler('agent-1');
      expect(registry.resolveSpeakHandler('agent-1'), isNull);
      registry.unregisterSpeakHandler('agent-1');
    },
  );

  test('caller contexts have an independent lifecycle', () {
    final registry = VoiceBridgeRegistry();
    const context = VoiceCallerContext(
      childAgentDefaultLabels: {'surface': 'voice'},
      lockedCwd: '/repo',
      allowCustomCwd: false,
      enableVoiceTools: true,
    );
    registry.registerCallerContext('agent-1', context);
    expect(registry.resolveCallerContext('agent-1'), same(context));
    expect(registry.resolveSpeakHandler('agent-1'), isNull);

    registry.unregisterCallerContext('agent-1');
    expect(registry.resolveCallerContext('agent-1'), isNull);
    registry.unregisterCallerContext('agent-1');
  });

  test('clear removes handlers and contexts together', () {
    final registry = VoiceBridgeRegistry();
    registry.registerSpeakHandler(
      'agent-1',
      ({
        required String text,
        required String callerAgentId,
        VoiceAbortSignal? signal,
      }) async {},
    );
    registry.registerCallerContext(
      'agent-1',
      const VoiceCallerContext(enableVoiceTools: true),
    );

    registry.clear();
    expect(registry.resolveSpeakHandler('agent-1'), isNull);
    expect(registry.resolveCallerContext('agent-1'), isNull);
  });
}
