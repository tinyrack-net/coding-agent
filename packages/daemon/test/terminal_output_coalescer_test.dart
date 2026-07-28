import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/terminal/terminal_output_coalescer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  test('flushes the first chunk immediately on the leading edge', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer.handle(_bytes('a'));

      expect(_payloads(flushes), ['a']);
      expect(flushes.single.bytes, 1);
      expect(flushes.single.chars, 1);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('coalesces a burst into one trailing UTF-8-aware flush', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer
        ..handle(_bytes('a'))
        ..handle(_bytes('b'))
        ..handle(_bytes('é'));
      expect(_payloads(flushes), ['a']);
      expect(async.pendingTimers, hasLength(1));

      async.elapse(const Duration(milliseconds: 5));
      expect(_payloads(flushes), ['a', 'bé']);
      expect(flushes.last.bytes, 3);
      expect(flushes.last.chars, 2);
    });
  });

  test('elapsed windows return to the immediate leading path', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer.handle(_bytes('a'));
      async.elapse(const Duration(milliseconds: 5));
      coalescer.handle(_bytes('b'));

      expect(_payloads(flushes), ['a', 'b']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('manual flush drains output and cancels its timer', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer
        ..handle(_bytes('hello'))
        ..handle(_bytes(' world'))
        ..flush();
      async.elapse(const Duration(milliseconds: 5));

      expect(_payloads(flushes), ['hello', ' world']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('dispose drops pending output and ignores later calls', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer
        ..handle(_bytes('done'))
        ..handle(_bytes('pending'))
        ..dispose()
        ..flush()
        ..markFlushed()
        ..handle(_bytes('ignored'));
      async.elapse(const Duration(milliseconds: 5));

      expect(_payloads(flushes), ['done']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('markFlushed keeps the next chunk on the trailing path', () {
    fakeAsync((async) {
      final flushes = <TerminalOutputBatch>[];
      final coalescer = TerminalOutputCoalescer(
        onFlush: flushes.add,
        now: () => async.elapsed.inMilliseconds,
      );

      coalescer
        ..markFlushed()
        ..handle(_bytes('post-snapshot'));
      expect(flushes, isEmpty);
      expect(async.pendingTimers, hasLength(1));

      async.elapse(const Duration(milliseconds: 5));
      expect(_payloads(flushes), ['post-snapshot']);
    });
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

List<String> _payloads(List<TerminalOutputBatch> batches) => [
  for (final batch in batches) utf8.decode(batch.payload),
];
