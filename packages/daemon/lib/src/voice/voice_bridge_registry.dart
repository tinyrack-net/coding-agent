import 'voice_types.dart';

final class VoiceBridgeRegistry {
  final Map<String, VoiceSpeakHandler> _speakHandlers = {};
  final Map<String, VoiceCallerContext> _callerContexts = {};

  void registerSpeakHandler(String agentId, VoiceSpeakHandler handler) {
    _speakHandlers[agentId] = handler;
  }

  void unregisterSpeakHandler(String agentId) {
    _speakHandlers.remove(agentId);
  }

  VoiceSpeakHandler? resolveSpeakHandler(String agentId) =>
      _speakHandlers[agentId];

  void registerCallerContext(String agentId, VoiceCallerContext context) {
    _callerContexts[agentId] = context;
  }

  void unregisterCallerContext(String agentId) {
    _callerContexts.remove(agentId);
  }

  VoiceCallerContext? resolveCallerContext(String agentId) =>
      _callerContexts[agentId];

  void clear() {
    _speakHandlers.clear();
    _callerContexts.clear();
  }
}
