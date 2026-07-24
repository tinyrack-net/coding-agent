/// Abstract provider session: one live provider process/conversation.
library;

import 'provider_event.dart';

abstract interface class AgentSession {
  /// Normalized event stream; closes after [SessionExited].
  Stream<ProviderEvent> get events;

  /// Send a user prompt, starting (or continuing) a turn.
  Future<void> prompt(String text);

  /// Ask the provider to stop the current turn.
  Future<void> interrupt();

  /// Tear the session down, killing the underlying process if needed.
  Future<void> dispose();
}
