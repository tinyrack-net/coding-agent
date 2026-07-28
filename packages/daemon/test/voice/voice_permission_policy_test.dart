import 'dart:async';

import 'package:agent_daemon/src/voice/voice_permission_policy.dart';
import 'package:agent_daemon/src/voice/voice_types.dart';
import 'package:test/test.dart';

final class _Signal implements VoiceAbortSignal {
  _Signal(this.aborted);

  @override
  final bool aborted;

  @override
  Future<void> get onAbort => Completer<void>().future;
}

void main() {
  test('allows direct speak tool names across provider conventions', () {
    for (final name in [
      'speak',
      ' paseo_voice.speak ',
      'MCP__PASEO_VOICE__SPEAK',
    ]) {
      expect(
        isVoicePermissionAllowed(kind: 'tool', name: name),
        isTrue,
        reason: name,
      );
    }
  });

  test('denies non-speak, blank, and non-tool permission requests', () {
    for (final name in [
      'mcp__paseo__create_agent',
      'paseo_create_agent',
      '',
      '   ',
    ]) {
      expect(
        isVoicePermissionAllowed(kind: 'tool', name: name),
        isFalse,
        reason: name,
      );
    }
    expect(isVoicePermissionAllowed(kind: 'mode', name: 'speak'), isFalse);
  });

  test('denies wrapper tools even when they may reference speak elsewhere', () {
    expect(isVoicePermissionAllowed(kind: 'tool', name: 'codextool'), isFalse);
  });

  test(
    'voice handler and caller context preserve the frozen type contract',
    () async {
      String? spoken;
      String? caller;
      VoiceAbortSignal? receivedSignal;
      final VoiceSpeakHandler handler =
          ({required text, required callerAgentId, signal}) async {
            spoken = text;
            caller = callerAgentId;
            receivedSignal = signal;
          };
      final signal = _Signal(false);
      await handler(text: 'Ready', callerAgentId: 'agent-1', signal: signal);
      expect(spoken, 'Ready');
      expect(caller, 'agent-1');
      expect(receivedSignal, same(signal));

      const context = VoiceCallerContext(
        childAgentDefaultLabels: {'voice': 'true'},
        lockedCwd: '/workspace',
        allowCustomCwd: false,
        enableVoiceTools: true,
      );
      expect(context.childAgentDefaultLabels, {'voice': 'true'});
      expect(context.lockedCwd, '/workspace');
      expect(context.allowCustomCwd, isFalse);
      expect(context.enableVoiceTools, isTrue);
      expect(signal.aborted, isFalse);
    },
  );
}
