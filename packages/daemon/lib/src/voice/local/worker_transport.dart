import 'dart:async';

import 'worker_protocol.dart';

final class LocalSpeechWorkerExit {
  const LocalSpeechWorkerExit({this.exitCode, this.signal});

  final int? exitCode;
  final String? signal;
}

abstract interface class LocalSpeechWorkerTransport {
  int? get pid;
  bool get connected;
  bool get killed;
  Stream<LocalSpeechWorkerMessage> get messages;
  Stream<List<int>> get stderr;
  Future<LocalSpeechWorkerExit> get exited;

  Future<void> send(LocalSpeechWorkerRequest request);
  Future<void> shutdown();
}

typedef LocalSpeechWorkerStarter =
    FutureOr<LocalSpeechWorkerTransport> Function();
