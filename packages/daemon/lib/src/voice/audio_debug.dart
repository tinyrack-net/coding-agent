String inferAudioExtension(String? format) {
  final normalized = (format ?? 'webm').toLowerCase();
  if (normalized.contains('webm')) return 'webm';
  if (normalized.contains('ogg')) return 'ogg';
  if (normalized.contains('mp3')) return 'mp3';
  if (normalized.contains('wav')) return 'wav';
  if (normalized.contains('m4a') || normalized.contains('aac')) return 'm4a';
  if (normalized.contains('mp4')) return 'mp4';
  if (normalized.contains('flac')) return 'flac';
  return 'webm';
}

String sanitizeForFilename(String? segment, String fallback) {
  final value = segment != null && segment.isNotEmpty ? segment : fallback;
  return value
      .replaceAll(RegExp(r'[^a-zA-Z0-9-_]'), '_')
      .substring(0, value.length.clamp(0, 64));
}
