import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/agent_daemon.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    final request = LocalSpeechWorkerRequest.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (request case LocalSpeechTtsSynthesizeRequest(text: 'malformed')) {
      stdout.writeln('[]');
      await stdout.flush();
      continue;
    }
    stderr.writeln('received ${request.type}');
    Object? result;
    if (request is LocalSpeechTtsSynthesizeRequest) {
      result = LocalSpeechTtsResult(
        audio: Uint8List.fromList(request.text.codeUnits),
        format: 'pcm;rate=24000',
      ).toJson();
    }
    stdout.writeln(
      jsonEncode(
        LocalSpeechWorkerResponse.success(
          requestId: request.requestId,
          result: result,
        ).toJson(),
      ),
    );
    await stdout.flush();
    await stderr.flush();
  }
}
