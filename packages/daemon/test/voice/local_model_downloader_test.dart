import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/voice/local/model_catalog.dart';
import 'package:agent_daemon/src/voice/local/model_downloader.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tinyrack-speech-models-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('model directory maps ids to frozen extracted directories', () {
    expect(
      getLocalSpeechModelDirectory(home.path, 'parakeet-tdt-0.6b-v2-int8'),
      p.join(home.path, 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8'),
    );
    expect(
      getLocalSpeechModelDirectory(home.path, 'kokoro-en-v0_19'),
      p.join(home.path, 'kokoro-en-v0_19'),
    );
  });

  test('complete existing model skips download and extraction', () async {
    await _writeCompleteModel(home.path, 'kokoro-en-v0_19');
    var downloads = 0;
    var extractions = 0;

    final result = await ensureLocalSpeechModel(
      modelsDirectory: home.path,
      modelId: 'kokoro-en-v0_19',
      downloadArchive: (_, _) async => downloads += 1,
      extractArchive: (_, _) async => extractions += 1,
    );

    expect(result, getLocalSpeechModelDirectory(home.path, 'kokoro-en-v0_19'));
    expect(downloads, 0);
    expect(extractions, 0);
    expect(
      await hasRequiredLocalSpeechModelFiles(home.path, 'kokoro-en-v0_19'),
      isTrue,
    );
  });

  test(
    'zero-byte files are missing while required directories are valid',
    () async {
      final modelDirectory = Directory(
        getLocalSpeechModelDirectory(home.path, 'kokoro-en-v0_19'),
      );
      await modelDirectory.create(recursive: true);
      await Directory(p.join(modelDirectory.path, 'espeak-ng-data')).create();
      await File(p.join(modelDirectory.path, 'model.onnx')).writeAsBytes([]);
      await File(p.join(modelDirectory.path, 'voices.bin')).writeAsString('x');
      await File(p.join(modelDirectory.path, 'tokens.txt')).writeAsString('x');

      expect(
        await hasRequiredLocalSpeechModelFiles(home.path, 'kokoro-en-v0_19'),
        isFalse,
      );
      expect(
        await findMissingLocalSpeechModels(home.path, [
          'kokoro-en-v0_19',
          'kokoro-en-v0_19',
        ]),
        ['kokoro-en-v0_19'],
      );
    },
  );

  test(
    'downloads, verifies, atomically replaces, and removes archive',
    () async {
      final modelDirectory = Directory(
        getLocalSpeechModelDirectory(home.path, 'kokoro-en-v0_19'),
      );
      await modelDirectory.create(recursive: true);
      await File(
        p.join(modelDirectory.path, 'old.partial'),
      ).writeAsString('old');
      final log = _RecordingLogger();
      var downloads = 0;
      var sawOldDuringExtraction = false;

      final result = await ensureLocalSpeechModel(
        modelsDirectory: home.path,
        modelId: 'kokoro-en-v0_19',
        logger: log,
        downloadArchive: (_, destination) async {
          downloads += 1;
          await destination.parent.create(recursive: true);
          await destination.writeAsString('archive');
        },
        extractArchive: (_, destination) async {
          sawOldDuringExtraction = await File(
            p.join(modelDirectory.path, 'old.partial'),
          ).exists();
          await _writeCompleteModel(destination.path, 'kokoro-en-v0_19');
        },
      );

      expect(result, modelDirectory.path);
      expect(downloads, 1);
      expect(sawOldDuringExtraction, isTrue);
      expect(
        File(p.join(modelDirectory.path, 'old.partial')).existsSync(),
        isFalse,
      );
      expect(
        await hasRequiredLocalSpeechModelFiles(home.path, 'kokoro-en-v0_19'),
        isTrue,
      );
      expect(Directory(p.join(home.path, '.downloads')).listSync(), isEmpty);
      expect(
        home.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.extract-'),
        ),
        isEmpty,
      );
      expect(log.messages, contains('Model download completed'));
    },
  );

  test('reuses nonempty cached archive after a failed extraction', () async {
    final spec = getLocalSpeechModelSpec('kokoro-en-v0_19');
    final archive = File(
      p.join(home.path, '.downloads', p.basename(spec.archiveUrl.path)),
    );
    await archive.parent.create(recursive: true);
    await archive.writeAsString('cached');
    var downloads = 0;

    await expectLater(
      ensureLocalSpeechModel(
        modelsDirectory: home.path,
        modelId: 'kokoro-en-v0_19',
        downloadArchive: (_, _) async => downloads += 1,
        extractArchive: (_, _) async {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('required files are still missing'),
        ),
      ),
    );

    expect(downloads, 0);
    expect(archive.existsSync(), isTrue);
    expect(
      home.listSync().where(
        (entry) => p.basename(entry.path).startsWith('.extract-'),
      ),
      isEmpty,
    );
  });

  test('concurrent requests for the same model share one operation', () async {
    final release = Completer<void>();
    var downloads = 0;
    var extractions = 0;
    Future<void> download(Uri _, File destination) async {
      downloads += 1;
      await destination.parent.create(recursive: true);
      await destination.writeAsString('archive');
      await release.future;
    }

    final first = ensureLocalSpeechModel(
      modelsDirectory: home.path,
      modelId: 'kokoro-en-v0_19',
      downloadArchive: download,
      extractArchive: (_, destination) async {
        extractions += 1;
        await _writeCompleteModel(destination.path, 'kokoro-en-v0_19');
      },
    );
    final second = ensureLocalSpeechModel(
      modelsDirectory: home.path,
      modelId: 'kokoro-en-v0_19',
      downloadArchive: download,
      extractArchive: (_, _) async => extractions += 1,
    );
    await Future<void>.delayed(Duration.zero);
    release.complete();

    expect(await first, await second);
    expect(downloads, 1);
    expect(extractions, 1);
  });

  test(
    'multi-model ensure deduplicates ids and downloads in parallel',
    () async {
      final active = <String>{};
      var maxActive = 0;
      Future<void> download(Uri url, File destination) async {
        final name = p.basename(url.path);
        active.add(name);
        if (active.length > maxActive) maxActive = active.length;
        await destination.parent.create(recursive: true);
        await destination.writeAsString(name);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active.remove(name);
      }

      final result = await ensureLocalSpeechModels(
        modelsDirectory: home.path,
        modelIds: const [
          'parakeet-tdt-0.6b-v2-int8',
          'kokoro-en-v0_19',
          'kokoro-en-v0_19',
        ],
        downloadArchive: download,
        extractArchive: (_, destination) async {
          final modelId = p.basename(destination.path).contains('kokoro')
              ? 'kokoro-en-v0_19'
              : null;
          if (modelId != null) {
            await _writeCompleteModel(destination.path, modelId);
            return;
          }
          // The staging directory name contains the requested model id.
          final requested = p.basename(destination.path);
          final id = requested.contains('parakeet-tdt-0.6b-v2-int8')
              ? 'parakeet-tdt-0.6b-v2-int8'
              : 'kokoro-en-v0_19';
          await _writeCompleteModel(destination.path, id);
        },
      );

      expect(result.keys, {'parakeet-tdt-0.6b-v2-int8', 'kokoro-en-v0_19'});
      expect(maxActive, 2);
    },
  );

  test(
    'HTTP downloader streams success and cleans failed temporary files',
    () async {
      var requests = 0;
      final successful = MockClient((request) async {
        requests += 1;
        expect(request.method, 'GET');
        return http.Response.bytes([1, 2, 3], 200);
      });

      await ensureLocalSpeechModel(
        modelsDirectory: home.path,
        modelId: 'kokoro-en-v0_19',
        httpClient: successful,
        extractArchive: (archive, destination) async {
          expect(await archive.readAsBytes(), [1, 2, 3]);
          await _writeCompleteModel(destination.path, 'kokoro-en-v0_19');
        },
      );
      expect(requests, 1);

      final otherHome = Directory.systemTemp.createTempSync(
        'tinyrack-speech-failed-',
      );
      addTearDown(() {
        if (otherHome.existsSync()) otherHome.deleteSync(recursive: true);
      });
      await expectLater(
        ensureLocalSpeechModel(
          modelsDirectory: otherHome.path,
          modelId: 'kokoro-en-v0_19',
          httpClient: MockClient(
            (_) async =>
                http.Response('denied', 403, reasonPhrase: 'Forbidden'),
          ),
          extractArchive: (_, _) async {},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('403 Forbidden'),
          ),
        ),
      );
      final downloads = Directory(p.join(otherHome.path, '.downloads'));
      expect(downloads.existsSync() ? downloads.listSync() : const [], isEmpty);
    },
  );

  test('HTTP stream failure deletes temporary download', () async {
    await expectLater(
      ensureLocalSpeechModel(
        modelsDirectory: home.path,
        modelId: 'kokoro-en-v0_19',
        httpClient: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.error(StateError('stream failed')),
            200,
          ),
        ),
        extractArchive: (_, _) async {},
      ),
      throwsA(isA<StateError>()),
    );

    final downloads = Directory(p.join(home.path, '.downloads'));
    expect(downloads.existsSync() ? downloads.listSync() : const [], isEmpty);
  });

  test('owned default HTTP client is closed after download', () async {
    final client = _TrackingClient(
      MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
    );

    await ensureLocalSpeechModel(
      modelsDirectory: home.path,
      modelId: 'kokoro-en-v0_19',
      createHttpClient: () => client,
      extractArchive: (_, destination) async {
        await _writeCompleteModel(destination.path, 'kokoro-en-v0_19');
      },
    );

    expect(client.closed, isTrue);
  });

  test('default tar extractor installs a real tar.bz2 fixture', () async {
    final source = Directory(p.join(home.path, 'source'));
    await _writeCompleteModel(source.path, 'kokoro-en-v0_19');
    final fixtureArchive = File(p.join(home.path, 'fixture.tar.bz2'));
    final tar = await Process.run('tar', [
      'cjf',
      fixtureArchive.path,
      '-C',
      source.path,
      getLocalSpeechModelSpec('kokoro-en-v0_19').extractedDirectory,
    ]);
    expect(tar.exitCode, 0, reason: '${tar.stderr}');
    await Directory(p.join(home.path, 'source')).delete(recursive: true);

    final result = await ensureLocalSpeechModel(
      modelsDirectory: home.path,
      modelId: 'kokoro-en-v0_19',
      downloadArchive: (_, destination) async {
        await destination.parent.create(recursive: true);
        await fixtureArchive.copy(destination.path);
      },
    );

    expect(
      await hasRequiredLocalSpeechModelFiles(home.path, 'kokoro-en-v0_19'),
      isTrue,
    );
    expect(result, getLocalSpeechModelDirectory(home.path, 'kokoro-en-v0_19'));
  });

  test('default tar extractor reports nonzero exit', () async {
    await expectLater(
      ensureLocalSpeechModel(
        modelsDirectory: home.path,
        modelId: 'kokoro-en-v0_19',
        downloadArchive: (_, destination) async {
          await destination.parent.create(recursive: true);
          await destination.writeAsString('not an archive');
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('tar exited with code'),
        ),
      ),
    );
  });
}

Future<void> _writeCompleteModel(String root, String modelId) async {
  final spec = getLocalSpeechModelSpec(modelId);
  final modelDirectory = Directory(p.join(root, spec.extractedDirectory));
  await modelDirectory.create(recursive: true);
  for (final relative in spec.requiredFiles) {
    final path = p.join(modelDirectory.path, relative);
    if (relative == 'espeak-ng-data') {
      await Directory(path).create(recursive: true);
    } else {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('x');
    }
  }
}

final class _RecordingLogger implements SpeechLogger {
  final messages = <String>[];

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) =>
      messages.add(message);

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) =>
      messages.add(message);

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      messages.add(message);

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) =>
      messages.add(message);
}

final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.delegate);

  final http.Client delegate;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);

  @override
  void close() {
    closed = true;
    delegate.close();
    super.close();
  }
}
