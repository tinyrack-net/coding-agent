import 'dart:typed_data';

import 'speech_provider.dart';

final class TurnDetectionSessionParameters {
  const TurnDetectionSessionParameters({required this.logger});

  final SpeechLogger logger;
}

abstract interface class TurnDetectionSession {
  int get requiredSampleRate;

  Stream<void> get speechStartedEvents;
  Stream<void> get speechStoppedEvents;
  Stream<Object?> get errors;

  Future<void> connect();
  void appendPcm16(Uint8List pcm16le);
  void flush();
  void reset();
  void close();
}

abstract interface class TurnDetectionProvider {
  String get id;

  TurnDetectionSession createSession(TurnDetectionSessionParameters parameters);
}

typedef TurnDetectionResolver = TurnDetectionProvider? Function();
