enum LocalSpeechModelKind { sttOffline, tts }

final class LocalSpeechModelSpec {
  const LocalSpeechModelSpec({
    required this.id,
    required this.kind,
    required this.archiveUrl,
    required this.extractedDirectory,
    required this.requiredFiles,
    required this.description,
    this.defaultFor,
  });

  final String id;
  final LocalSpeechModelKind kind;
  final Uri archiveUrl;
  final String extractedDirectory;
  final List<String> requiredFiles;
  final String description;
  final LocalSpeechModelKind? defaultFor;
}

final localSpeechModelCatalog = <String, LocalSpeechModelSpec>{
  'parakeet-tdt-0.6b-v2-int8': LocalSpeechModelSpec(
    id: 'parakeet-tdt-0.6b-v2-int8',
    kind: LocalSpeechModelKind.sttOffline,
    archiveUrl: Uri.parse(
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2',
    ),
    extractedDirectory: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',
    requiredFiles: const [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ],
    description: 'NVIDIA Parakeet TDT v2 (offline NeMo transducer, English).',
    defaultFor: LocalSpeechModelKind.sttOffline,
  ),
  'parakeet-tdt-0.6b-v3-int8': LocalSpeechModelSpec(
    id: 'parakeet-tdt-0.6b-v3-int8',
    kind: LocalSpeechModelKind.sttOffline,
    archiveUrl: Uri.parse(
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    ),
    extractedDirectory: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    requiredFiles: const [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ],
    description:
        'NVIDIA Parakeet TDT v3 (offline NeMo transducer, 25 European '
        'languages, auto-detected).',
  ),
  'kokoro-en-v0_19': LocalSpeechModelSpec(
    id: 'kokoro-en-v0_19',
    kind: LocalSpeechModelKind.tts,
    archiveUrl: Uri.parse(
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
      'kokoro-en-v0_19.tar.bz2',
    ),
    extractedDirectory: 'kokoro-en-v0_19',
    requiredFiles: const [
      'model.onnx',
      'voices.bin',
      'tokens.txt',
      'espeak-ng-data',
    ],
    description: 'Kokoro TTS (higher quality; larger).',
    defaultFor: LocalSpeechModelKind.tts,
  ),
};

List<String> get localSttModelIds => List.unmodifiable(
  localSpeechModelCatalog.values
      .where((model) => model.kind == LocalSpeechModelKind.sttOffline)
      .map((model) => model.id),
);

List<String> get localTtsModelIds => List.unmodifiable(
  localSpeechModelCatalog.values
      .where((model) => model.kind == LocalSpeechModelKind.tts)
      .map((model) => model.id),
);

String get defaultLocalSttModel =>
    _defaultModel(LocalSpeechModelKind.sttOffline);

String get defaultLocalTtsModel => _defaultModel(LocalSpeechModelKind.tts);

List<LocalSpeechModelSpec> listLocalSpeechModels() =>
    List.unmodifiable(localSpeechModelCatalog.values);

LocalSpeechModelSpec getLocalSpeechModelSpec(String modelId) {
  final spec = localSpeechModelCatalog[modelId];
  if (spec == null) {
    throw StateError('Unknown local speech model id: $modelId');
  }
  return spec;
}

String parseLocalSttModelId(Object? value) =>
    _parseModelId(value, localSttModelIds);

String parseLocalTtsModelId(Object? value) =>
    _parseModelId(value, localTtsModelIds);

String _defaultModel(LocalSpeechModelKind role) {
  for (final model in localSpeechModelCatalog.values) {
    if (model.defaultFor == role) return model.id;
  }
  throw StateError("No default model configured for role '${role.name}'");
}

String _parseModelId(Object? value, List<String> validIds) {
  if (value is! String) throw const FormatException('Invalid model id');
  final normalized = value.trim().toLowerCase();
  if (!validIds.contains(normalized)) {
    throw const FormatException('Invalid model id');
  }
  return normalized;
}
