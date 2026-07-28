import 'package:agent_protocol/agent_protocol.dart';

bool isVoicePermissionAllowed({required String kind, required String name}) {
  if (kind != 'tool') return false;
  final normalizedName = name.trim().toLowerCase();
  if (normalizedName.isEmpty) return false;
  return isSpeakToolName(normalizedName);
}
