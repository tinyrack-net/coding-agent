import 'dart:math' as math;
import 'dart:typed_data';

final class ParsedPcm16MonoWav {
  const ParsedPcm16MonoWav({required this.sampleRate, required this.pcm16});

  final int sampleRate;
  final Uint8List pcm16;
}

ParsedPcm16MonoWav parsePcm16MonoWav(Uint8List buffer) {
  if (_ascii(buffer, 0, 4) != 'RIFF' || _ascii(buffer, 8, 12) != 'WAVE') {
    throw const FormatException('Invalid WAV header');
  }

  var offset = 12;
  _WavFormat? format;
  Uint8List? dataChunk;
  final bytes = ByteData.sublistView(buffer);

  while (offset + 8 <= buffer.length) {
    final id = _ascii(buffer, offset, offset + 4);
    final size = bytes.getUint32(offset + 4, Endian.little);
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + size;
    if (payloadEnd > buffer.length) break;

    if (id == 'fmt ') {
      format = _WavFormat(
        audioFormat: bytes.getUint16(payloadStart, Endian.little),
        channels: bytes.getUint16(payloadStart + 2, Endian.little),
        sampleRate: bytes.getUint32(payloadStart + 4, Endian.little),
        bitsPerSample: bytes.getUint16(payloadStart + 14, Endian.little),
      );
    } else if (id == 'data') {
      dataChunk = Uint8List.sublistView(buffer, payloadStart, payloadEnd);
    }

    offset = payloadEnd + (size % 2);
  }

  if (format == null || dataChunk == null) {
    throw const FormatException('Missing WAV fmt/data chunks');
  }
  if (format.audioFormat != 1) {
    throw FormatException(
      'Unsupported WAV encoding (audioFormat=${format.audioFormat})',
    );
  }
  if (format.channels != 1 || format.bitsPerSample != 16) {
    throw FormatException(
      'Unexpected WAV format: channels=${format.channels} '
      'rate=${format.sampleRate} bits=${format.bitsPerSample}',
    );
  }
  if (dataChunk.length.isOdd) {
    throw const FormatException('WAV PCM16 data length must be even');
  }
  return ParsedPcm16MonoWav(sampleRate: format.sampleRate, pcm16: dataChunk);
}

int? parsePcmRateFromFormat(String format, [int? fallback]) {
  final match = RegExp(
    r'(?:^|[;,\s])rate\s*=\s*(\d+)(?:$|[;,\s])',
    caseSensitive: false,
  ).firstMatch(format);
  if (match == null) return fallback;
  final rate = int.tryParse(match.group(1)!);
  return rate != null && rate > 0 ? rate : fallback;
}

int pcm16lePeakAbs(Uint8List pcm16le) {
  if (pcm16le.isEmpty) return 0;
  _requireEvenPcm16(pcm16le);
  final bytes = ByteData.sublistView(pcm16le);
  var peak = 0;
  for (var offset = 0; offset < pcm16le.length; offset += 2) {
    final value = bytes.getInt16(offset, Endian.little);
    final absolute = value < 0 ? -value : value;
    if (absolute > peak) {
      peak = absolute;
      if (peak >= 32767) break;
    }
  }
  return peak;
}

Float32List pcm16leToFloat32(Uint8List pcm16le, {double gain = 1}) {
  _requireEvenPcm16(pcm16le);
  final bytes = ByteData.sublistView(pcm16le);
  final output = Float32List(pcm16le.length ~/ 2);
  for (var index = 0; index < output.length; index += 1) {
    final value = (bytes.getInt16(index * 2, Endian.little) / 32768) * gain;
    output[index] = value.clamp(-1, 1).toDouble();
  }
  return output;
}

Uint8List float32ToPcm16le(Float32List samples) {
  final output = Uint8List(samples.length * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index += 1) {
    final clamped = samples[index].clamp(-1, 1).toDouble();
    bytes.setInt16(index * 2, _javascriptRound(clamped * 32767), Endian.little);
  }
  return output;
}

List<Uint8List> chunkAudioBuffer(Uint8List buffer, int chunkBytes) {
  if (chunkBytes <= 0) return [buffer];
  return [
    for (var offset = 0; offset < buffer.length; offset += chunkBytes)
      Uint8List.sublistView(
        buffer,
        offset,
        math.min(buffer.length, offset + chunkBytes),
      ),
  ];
}

String _ascii(Uint8List bytes, int start, int end) {
  if (start < 0 || end > bytes.length || end < start) return '';
  return String.fromCharCodes(bytes.sublist(start, end));
}

void _requireEvenPcm16(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw FormatException(
      'PCM16 chunk byteLength must be even, got ${bytes.length}',
    );
  }
}

int _javascriptRound(double value) => (value + 0.5).floor();

final class _WavFormat {
  const _WavFormat({
    required this.audioFormat,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
  });

  final int audioFormat;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
}
