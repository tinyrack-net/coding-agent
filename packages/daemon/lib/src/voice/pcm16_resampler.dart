import 'dart:typed_data';

final class Pcm16MonoResampler {
  Pcm16MonoResampler({required this.inputRate, required this.outputRate})
    : step = inputRate / outputRate;

  final int inputRate;
  final int outputRate;
  final double step;
  double _position = 0;
  int? _carrySample;

  void reset() {
    _position = 0;
    _carrySample = null;
  }

  Uint8List processChunk(Uint8List pcm16le) {
    if (pcm16le.isEmpty) return Uint8List(0);
    if (pcm16le.length.isOdd) {
      throw FormatException(
        'PCM16 chunk byteLength must be even, got ${pcm16le.length}',
      );
    }

    final chunkBytes = ByteData.sublistView(pcm16le);
    final chunkLength = pcm16le.length ~/ 2;
    final hasCarry = _carrySample != null;
    final sourceLength = chunkLength + (hasCarry ? 1 : 0);
    if (sourceLength < 2) {
      if (chunkLength > 0) {
        _carrySample = chunkBytes.getInt16(0, Endian.little);
      }
      return Uint8List(0);
    }

    final source = Float32List(sourceLength);
    var sourceOffset = 0;
    if (hasCarry) {
      source[0] = _carrySample! / 32768;
      sourceOffset = 1;
    }
    for (var index = 0; index < chunkLength; index += 1) {
      source[sourceOffset + index] =
          chunkBytes.getInt16(index * 2, Endian.little) / 32768;
    }

    final output = <int>[];
    final maxPosition = source.length - 1;
    while (_position < maxPosition) {
      final index = _position.floor();
      final fraction = _position - index;
      final first = source[index];
      final second = source[index + 1];
      final sample = first + (second - first) * fraction;
      final clamped = sample.clamp(-1, 1).toDouble();
      output.add((clamped * 32767 + 0.5).floor());
      _position += step;
    }

    _carrySample = chunkBytes.getInt16((chunkLength - 1) * 2, Endian.little);
    _position -= source.length - 1;
    if (_position < 0) _position = 0;

    final encoded = Uint8List(output.length * 2);
    final encodedBytes = ByteData.sublistView(encoded);
    for (var index = 0; index < output.length; index += 1) {
      encodedBytes.setInt16(index * 2, output[index], Endian.little);
    }
    return encoded;
  }
}
