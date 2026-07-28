import 'dart:typed_data';

import 'package:agent_daemon/src/voice/pcm16_resampler.dart';
import 'package:test/test.dart';

void main() {
  test('identity-rate streaming matches one-shot output across chunks', () {
    final samples = [0, 1000, 2000, 3000, 4000, 5000];
    final oneShot = Pcm16MonoResampler(
      inputRate: 24000,
      outputRate: 24000,
    ).processChunk(_pcm16(samples));
    final streaming = Pcm16MonoResampler(inputRate: 24000, outputRate: 24000);
    final chunked = Uint8List.fromList([
      ...streaming.processChunk(_pcm16(samples.sublist(0, 2))),
      ...streaming.processChunk(_pcm16(samples.sublist(2, 4))),
      ...streaming.processChunk(_pcm16(samples.sublist(4))),
    ]);

    expect(_decodePcm16(chunked), _decodePcm16(oneShot));
    expect(_decodePcm16(oneShot), samples.take(samples.length - 1).toList());
  });

  test('single-sample carry is emitted with the next chunk', () {
    final resampler = Pcm16MonoResampler(inputRate: 24000, outputRate: 24000);

    expect(resampler.processChunk(_pcm16([1000])), isEmpty);
    expect(_decodePcm16(resampler.processChunk(_pcm16([2000]))), [1000]);
  });

  test('linearly upsamples and can reset state', () {
    final resampler = Pcm16MonoResampler(inputRate: 12000, outputRate: 24000);
    final first = _decodePcm16(resampler.processChunk(_pcm16([0, 10000])));
    resampler.reset();
    final second = _decodePcm16(resampler.processChunk(_pcm16([0, 10000])));

    expect(first, [0, closeTo(5000, 1)]);
    expect(second, first);
  });

  test('returns empty audio and rejects odd PCM byte counts', () {
    final resampler = Pcm16MonoResampler(inputRate: 24000, outputRate: 16000);
    expect(resampler.processChunk(Uint8List(0)), isEmpty);
    expect(
      () => resampler.processChunk(Uint8List.fromList([1])),
      throwsFormatException,
    );
  });
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
