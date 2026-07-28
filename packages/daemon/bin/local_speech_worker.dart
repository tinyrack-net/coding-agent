import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';

Future<void> main() async {
  final logger = CallbackSpeechLogger(stderr.writeln);
  var outputClosed = false;
  void send(LocalSpeechWorkerMessage message) {
    if (outputClosed) return;
    try {
      stdout.writeln(jsonEncode(message.toJson()));
    } on Object {
      outputClosed = true;
    }
  }

  late final LocalSpeechWorkerDispatcher dispatcher;
  try {
    dispatcher = LocalSpeechWorkerDispatcher(
      send: send,
      nativeFactory: SherpaOnnxNativeFactory(),
      logger: logger,
    );
  } on Object catch (error) {
    stderr.writeln('Failed to initialize Tinyrack Voice worker: $error');
    exitCode = 1;
    return;
  }

  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('Worker request must be an object');
        }
        await dispatcher.handle(
          LocalSpeechWorkerRequest.fromJson(Map<String, Object?>.from(decoded)),
        );
        await stdout.flush();
      } on Object catch (error) {
        stderr.writeln('Invalid local speech worker request: $error');
      }
    }
  } finally {
    outputClosed = true;
    await dispatcher.close();
  }
}
