import 'dart:async';

final class SpeechStreamResult {
  SpeechStreamResult({
    required this.stream,
    required this.format,
    FutureOr<void> Function()? onDestroy,
  }) : _onDestroy = onDestroy;

  final Stream<List<int>> stream;
  final String format;
  final FutureOr<void> Function()? _onDestroy;
  bool _destroyed = false;

  bool get destroyed => _destroyed;

  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    await _onDestroy?.call();
  }
}

abstract interface class TextToSpeechProvider {
  Future<SpeechStreamResult> synthesizeSpeech(String text);
}

typedef TextToSpeechResolver = TextToSpeechProvider? Function();
