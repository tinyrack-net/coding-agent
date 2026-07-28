import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/voice/local/sherpa/runtime_env.dart';
import 'package:agent_daemon/src/voice/local/worker_process_transport.dart';
import 'package:agent_daemon/src/voice/local/worker_protocol.dart';
import 'package:agent_daemon/src/voice/local/worker_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'pinned Sherpa worker loads native libraries and executes bundled Silero VAD',
    () async {
      if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
        return;
      }
      expect(resolveSherpaLibraryDirectory(), isNotNull);
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-native-vad-',
      );
      LocalSpeechWorkerTransport? worker;
      try {
        worker = await startLocalSpeechWorkerProcess();
        final response = Completer<LocalSpeechWorkerResponse>();
        final stderr = <int>[];
        final messageSubscription = worker.messages.listen((message) {
          if (message is LocalSpeechWorkerResponse &&
              message.requestId == 'native-vad' &&
              !response.isCompleted) {
            response.complete(message);
          }
        });
        final stderrSubscription = worker.stderr.listen(stderr.addAll);
        await worker.send(
          LocalSpeechSessionCreateRequest(
            requestId: 'native-vad',
            config: LocalSpeechWorkerConfig(
              modelsDirectory: temporary.path,
              voiceSttModel: 'parakeet-tdt-0.6b-v2-int8',
              dictationSttModel: 'parakeet-tdt-0.6b-v2-int8',
              voiceTtsModel: 'kokoro-en-v0_19',
            ),
            sessionId: 'vad-1',
            kind: LocalSpeechSessionKind.vad,
          ),
        );
        final result =
            await Future.any<LocalSpeechWorkerResponse>([
              response.future,
              worker.exited.then(
                (exit) => throw StateError(
                  'Local speech worker exited with ${exit.exitCode}: '
                  '${String.fromCharCodes(stderr)}',
                ),
              ),
            ]).timeout(
              const Duration(seconds: 50),
              onTimeout: () => throw TimeoutException(
                'Local speech worker did not answer: '
                '${String.fromCharCodes(stderr)}',
              ),
            );
        expect(result.ok, isTrue, reason: String.fromCharCodes(stderr));
        expect(
          LocalSpeechCreateSessionResult.fromJson(
            result.result,
          ).requiredSampleRate,
          16000,
        );
        expect(
          File(
            p.join(temporary.path, 'silero-vad', 'silero_vad.onnx'),
          ).existsSync(),
          isTrue,
        );
        await worker.send(
          LocalSpeechSessionCommandRequest(
            requestId: 'close-vad',
            sessionId: 'vad-1',
            type: 'session.close',
          ),
        );
        await messageSubscription.cancel();
        await stderrSubscription.cancel();
      } finally {
        await worker?.shutdown();
        if (temporary.existsSync()) {
          await temporary.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
