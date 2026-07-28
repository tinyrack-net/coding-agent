import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../speech_provider.dart';
import 'model_catalog.dart';

typedef ModelArchiveDownloader =
    Future<void> Function(Uri url, File destination);
typedef ModelArchiveExtractor =
    Future<void> Function(File archive, Directory destination);

final _downloadsInFlight = <String, Future<String>>{};

String getLocalSpeechModelDirectory(String modelsDirectory, String modelId) {
  final spec = getLocalSpeechModelSpec(modelId);
  return p.join(modelsDirectory, spec.extractedDirectory);
}

Future<bool> hasRequiredLocalSpeechModelFiles(
  String modelsDirectory,
  String modelId,
) async {
  final spec = getLocalSpeechModelSpec(modelId);
  return _hasRequiredFiles(
    getLocalSpeechModelDirectory(modelsDirectory, modelId),
    spec.requiredFiles,
  );
}

Future<List<String>> findMissingLocalSpeechModels(
  String modelsDirectory,
  List<String> requiredModelIds,
) async {
  final uniqueIds = <String>{...requiredModelIds}.toList(growable: false);
  final present = await Future.wait([
    for (final modelId in uniqueIds)
      hasRequiredLocalSpeechModelFiles(modelsDirectory, modelId),
  ]);
  return [
    for (var index = 0; index < uniqueIds.length; index += 1)
      if (!present[index]) uniqueIds[index],
  ];
}

Future<String> ensureLocalSpeechModel({
  required String modelsDirectory,
  required String modelId,
  SpeechLogger logger = const NullSpeechLogger(),
  http.Client? httpClient,
  http.Client Function()? createHttpClient,
  ModelArchiveDownloader? downloadArchive,
  ModelArchiveExtractor? extractArchive,
  Uuid uuid = const Uuid(),
}) {
  final key = p.normalize(
    p.absolute(getLocalSpeechModelDirectory(modelsDirectory, modelId)),
  );
  return _downloadsInFlight.putIfAbsent(key, () {
    final task = _ensureLocalSpeechModel(
      modelsDirectory: modelsDirectory,
      modelId: modelId,
      logger: logger,
      downloadArchive:
          downloadArchive ??
          (url, destination) => _downloadWithOptionalClient(
            url,
            destination,
            httpClient,
            createHttpClient ?? http.Client.new,
          ),
      extractArchive: extractArchive ?? _extractTarArchive,
      uuid: uuid,
    );
    unawaited(
      task.then<void>(
        (_) => _downloadsInFlight.remove(key),
        onError: (Object _, StackTrace _) {
          _downloadsInFlight.remove(key);
        },
      ),
    );
    return task;
  });
}

Future<Map<String, String>> ensureLocalSpeechModels({
  required String modelsDirectory,
  required List<String> modelIds,
  SpeechLogger logger = const NullSpeechLogger(),
  http.Client? httpClient,
  http.Client Function()? createHttpClient,
  ModelArchiveDownloader? downloadArchive,
  ModelArchiveExtractor? extractArchive,
}) async {
  final uniqueIds = <String>{...modelIds};
  final entries = await Future.wait([
    for (final modelId in uniqueIds)
      ensureLocalSpeechModel(
        modelsDirectory: modelsDirectory,
        modelId: modelId,
        logger: logger,
        httpClient: httpClient,
        createHttpClient: createHttpClient,
        downloadArchive: downloadArchive,
        extractArchive: extractArchive,
      ).then((directory) => MapEntry(modelId, directory)),
  ]);
  return Map.unmodifiable(Map.fromEntries(entries));
}

Future<String> _ensureLocalSpeechModel({
  required String modelsDirectory,
  required String modelId,
  required SpeechLogger logger,
  required ModelArchiveDownloader downloadArchive,
  required ModelArchiveExtractor extractArchive,
  required Uuid uuid,
}) async {
  final scopedLogger = logger.child({
    'module': 'speech',
    'provider': 'local',
    'component': 'model-downloader',
    'modelId': modelId,
  });
  final spec = getLocalSpeechModelSpec(modelId);
  final modelDirectory = getLocalSpeechModelDirectory(modelsDirectory, modelId);
  if (await _hasRequiredFiles(modelDirectory, spec.requiredFiles)) {
    return modelDirectory;
  }

  scopedLogger.info(
    'Starting model download',
    fields: {'modelsDir': modelsDirectory},
  );
  final downloadsDirectory = Directory(p.join(modelsDirectory, '.downloads'));
  final archiveName = p.basename(spec.archiveUrl.path);
  final archive = File(p.join(downloadsDirectory.path, archiveName));
  final staging = Directory(
    p.join(modelsDirectory, '.extract-$modelId-${uuid.v4()}'),
  );
  try {
    if (!await _isNonEmptyFile(archive)) {
      await downloadArchive(spec.archiveUrl, archive);
    }
    scopedLogger.info(
      'Extracting model archive',
      fields: {
        'modelId': modelId,
        'archivePath': archive.path,
        'modelDir': modelDirectory,
      },
    );
    await staging.create(recursive: true);
    await extractArchive(archive, staging);
    final stagedModelDirectory = p.join(staging.path, spec.extractedDirectory);
    scopedLogger.info(
      'Verifying downloaded model files',
      fields: {'modelId': modelId, 'modelDir': stagedModelDirectory},
    );
    if (!await _hasRequiredFiles(stagedModelDirectory, spec.requiredFiles)) {
      throw StateError(
        'Downloaded and extracted $archiveName, but required files are still '
        'missing in $modelDirectory.',
      );
    }

    scopedLogger.info(
      'Finalizing model artifacts',
      fields: {'modelId': modelId, 'archivePath': archive.path},
    );
    final installed = Directory(modelDirectory);
    if (await installed.exists()) {
      await installed.delete(recursive: true);
    }
    await Directory(stagedModelDirectory).rename(modelDirectory);
    try {
      await archive.delete();
    } on FileSystemException {
      // Frozen behavior treats archive cleanup as best effort.
    }
    scopedLogger.info(
      'Model download completed',
      fields: {'modelDir': modelDirectory},
    );
    return modelDirectory;
  } on Object catch (error) {
    scopedLogger.error('Model download failed', fields: {'error': error});
    rethrow;
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

Future<bool> _hasRequiredFiles(
  String modelDirectory,
  List<String> requiredFiles,
) async {
  final checks = await Future.wait([
    for (final relativePath in requiredFiles)
      _isRequiredPathPresent(p.join(modelDirectory, relativePath)),
  ]);
  return checks.every((present) => present);
}

Future<bool> _isRequiredPathPresent(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: true);
  if (type == FileSystemEntityType.directory) return true;
  if (type != FileSystemEntityType.file) return false;
  try {
    return await File(path).length() > 0;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _isNonEmptyFile(File file) async {
  try {
    return await file.exists() && await file.length() > 0;
  } on FileSystemException {
    return false;
  }
}

Future<void> _downloadToFile(
  Uri url,
  File destination, {
  required http.Client client,
}) async {
  await destination.parent.create(recursive: true);
  final temporary = File(
    '${destination.path}.tmp-${DateTime.now().millisecondsSinceEpoch}',
  );
  try {
    final request = http.Request('GET', url);
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw StateError(
        'Failed to download $url: ${response.statusCode} '
                '${response.reasonPhrase ?? ''}'
            .trimRight(),
      );
    }
    final sink = temporary.openWrite();
    await response.stream.pipe(sink);
    await temporary.rename(destination.path);
  } on Object {
    if (await temporary.exists()) {
      await temporary.delete();
    }
    rethrow;
  }
}

Future<void> _downloadWithOptionalClient(
  Uri url,
  File destination,
  http.Client? suppliedClient,
  http.Client Function() createClient,
) async {
  if (suppliedClient != null) {
    await _downloadToFile(url, destination, client: suppliedClient);
    return;
  }
  final client = createClient();
  try {
    await _downloadToFile(url, destination, client: client);
  } finally {
    client.close();
  }
}

Future<void> _extractTarArchive(File archive, Directory destination) async {
  final result = await Process.run('tar', [
    'xf',
    archive.path,
    '-C',
    destination.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('tar exited with code ${result.exitCode}');
  }
}
