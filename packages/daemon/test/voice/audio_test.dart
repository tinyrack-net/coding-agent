import 'dart:typed_data';

import 'package:agent_daemon/src/voice/audio.dart';
import 'package:test/test.dart';

void main() {
  test('parses PCM16 mono WAV chunks including padded unknown chunks', () {
    final pcm = _pcm16([0, 1000, -1000]);
    final wav = _wav(
      pcm: pcm,
      sampleRate: 16000,
      extraChunks: [
        ('JUNK', Uint8List.fromList([1, 2, 3])),
      ],
    );

    final parsed = parsePcm16MonoWav(wav);

    expect(parsed.sampleRate, 16000);
    expect(parsed.pcm16, pcm);
  });

  test('WAV parser rejects malformed and unsupported boundaries', () {
    expect(
      () => parsePcm16MonoWav(Uint8List(12)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Invalid WAV header',
        ),
      ),
    );
    expect(
      () => parsePcm16MonoWav(Uint8List.fromList('RIFF0000WAVE'.codeUnits)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Missing WAV fmt/data chunks',
        ),
      ),
    );
    expect(
      () => parsePcm16MonoWav(_wav(pcm: _pcm16([1]), audioFormat: 3)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported WAV encoding'),
        ),
      ),
    );
    expect(
      () => parsePcm16MonoWav(_wav(pcm: _pcm16([1]), channels: 2)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected WAV format'),
        ),
      ),
    );
    expect(
      () => parsePcm16MonoWav(
        _wav(pcm: Uint8List.fromList([1]), bitsPerSample: 16),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'WAV PCM16 data length must be even',
        ),
      ),
    );
  });

  test('parses PCM rates with frozen delimiters and fallbacks', () {
    expect(parsePcmRateFromFormat('audio/pcm;rate=24000'), 24000);
    expect(parsePcmRateFromFormat('AUDIO/PCM, RATE = 16000 '), 16000);
    expect(parsePcmRateFromFormat('audio/pcm;crate=100', 48000), 48000);
    expect(parsePcmRateFromFormat('audio/pcm;rate=0', 48000), 48000);
    expect(parsePcmRateFromFormat('audio/pcm'), isNull);
  });

  test('finds PCM16 peak and rejects odd byte counts', () {
    expect(pcm16lePeakAbs(Uint8List(0)), 0);
    expect(pcm16lePeakAbs(_pcm16([0, -32768, 100])), 32768);
    expect(
      () => pcm16lePeakAbs(Uint8List.fromList([1])),
      throwsFormatException,
    );
  });

  test('converts PCM16 and float32 with gain, clamping, and JS rounding', () {
    final floats = pcm16leToFloat32(
      _pcm16([-32768, -16384, 0, 16384, 32767]),
      gain: 2,
    );
    expect(floats, [-1, -1, 0, 1, 1]);

    final pcm = float32ToPcm16le(Float32List.fromList([-2, -0.5, 0, 0.5, 2]));
    expect(_decodePcm16(pcm), [-32767, -16383, 0, 16384, 32767]);
    expect(
      () => pcm16leToFloat32(Uint8List.fromList([1])),
      throwsFormatException,
    );
  });

  test('chunks byte buffers and preserves zero/negative chunk behavior', () {
    final source = Uint8List.fromList([1, 2, 3, 4, 5]);
    expect(chunkAudioBuffer(source, 2), [
      [1, 2],
      [3, 4],
      [5],
    ]);
    expect(chunkAudioBuffer(source, 0), [source]);
    expect(chunkAudioBuffer(Uint8List(0), 2), isEmpty);
  });
}

Uint8List _wav({
  required Uint8List pcm,
  int sampleRate = 24000,
  int audioFormat = 1,
  int channels = 1,
  int bitsPerSample = 16,
  List<(String, Uint8List)> extraChunks = const [],
}) {
  final format = Uint8List(16);
  ByteData.sublistView(format)
    ..setUint16(0, audioFormat, Endian.little)
    ..setUint16(2, channels, Endian.little)
    ..setUint32(4, sampleRate, Endian.little)
    ..setUint32(8, sampleRate * channels * bitsPerSample ~/ 8, Endian.little)
    ..setUint16(12, channels * bitsPerSample ~/ 8, Endian.little)
    ..setUint16(14, bitsPerSample, Endian.little);
  final chunks = <(String, Uint8List)>[
    ('fmt ', format),
    ...extraChunks,
    ('data', pcm),
  ];
  final bodyLength = chunks.fold<int>(
    0,
    (total, chunk) => total + 8 + chunk.$2.length + (chunk.$2.length % 2),
  );
  final output = Uint8List(12 + bodyLength);
  output.setRange(0, 4, 'RIFF'.codeUnits);
  ByteData.sublistView(output).setUint32(4, bodyLength + 4, Endian.little);
  output.setRange(8, 12, 'WAVE'.codeUnits);
  var offset = 12;
  for (final (id, payload) in chunks) {
    output.setRange(offset, offset + 4, id.codeUnits);
    ByteData.sublistView(
      output,
    ).setUint32(offset + 4, payload.length, Endian.little);
    output.setRange(offset + 8, offset + 8 + payload.length, payload);
    offset += 8 + payload.length + (payload.length % 2);
  }
  return output;
}

Uint8List _pcm16(List<int> samples) {
  final output = Uint8List(samples.length * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index += 1) {
    bytes.setInt16(index * 2, samples[index], Endian.little);
  }
  return output;
}

List<int> _decodePcm16(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var offset = 0; offset < bytes.length; offset += 2)
      data.getInt16(offset, Endian.little),
  ];
}
