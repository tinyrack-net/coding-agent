import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('TimelineStore', () {
    test('assigns monotonic seq and starts at epoch 1', () {
      final emitted = <(int, int, TimelineItem)>[];
      final store = TimelineStore(
        agentId: 'a1',
        onItem: (agentId, epoch, seq, item) =>
            emitted.add((epoch, seq, item)),
      );
      store.upsert(const UserMessageItem(id: 'u1', text: 'hi'));
      store.upsert(const TurnItem(id: 't1', phase: TurnPhase.started));

      expect(store.epoch, 1);
      expect(store.lastSeq, 2);
      expect(emitted.map((e) => e.$2), [1, 2]);
      expect(emitted.map((e) => e.$1), [1, 1]);
    });

    test('upsert re-emits same item id under a new seq', () {
      final store = TimelineStore(agentId: 'a1');
      store.upsert(const UserMessageItem(id: 'u1', text: 'hi'));
      store.upsert(
        const AssistantMessageItem(id: 'm1', text: 'He', complete: false),
      );
      store.upsert(
        const AssistantMessageItem(id: 'm1', text: 'Hello', complete: true),
      );

      expect(store.lastSeq, 3);
      final items = store.snapshot();
      expect(items, hasLength(2));
      // The upserted item moved to the end (highest seq).
      expect(items.last.id, 'm1');
      expect((items.last as AssistantMessageItem).text, 'Hello');
    });

    test('fetch(afterSeq) returns only newer versions', () {
      final store = TimelineStore(agentId: 'a1');
      store.upsert(const UserMessageItem(id: 'u1', text: 'hi')); // seq 1
      store.upsert(
        const AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      ); // seq 2
      store.upsert(
        const AssistantMessageItem(id: 'm1', text: 'ab', complete: true),
      ); // seq 3

      final catchUp = store.fetch(afterSeq: 2);
      expect(catchUp.epoch, 1);
      expect(catchUp.lastSeq, 3);
      expect(catchUp.items, hasLength(1));
      expect((catchUp.items.single as AssistantMessageItem).text, 'ab');

      final full = store.fetch();
      expect(full.items, hasLength(2));
    });

    test('restores persisted items with sequential seqs', () {
      final store = TimelineStore(
        agentId: 'a1',
        epoch: 3,
        items: const [
          UserMessageItem(id: 'u1', text: 'hi'),
          AssistantMessageItem(id: 'm1', text: 'yo', complete: true),
        ],
      );
      expect(store.epoch, 3);
      expect(store.lastSeq, 2);
      expect(store.snapshot(), hasLength(2));
    });

    test('rebuild bumps epoch and resets seq', () {
      final store = TimelineStore(agentId: 'a1');
      store.upsert(const UserMessageItem(id: 'u1', text: 'hi'));
      store.rebuild(const [UserMessageItem(id: 'u2', text: 'again')]);

      expect(store.epoch, 2);
      expect(store.lastSeq, 1);
      expect(store.snapshot().single.id, 'u2');
    });

    test('coalesces rapid updates: leading edge immediate, trailing on timer',
        () async {
      final emitted = <TimelineItem>[];
      final store = TimelineStore(
        agentId: 'a1',
        coalesceWindow: const Duration(milliseconds: 40),
        onItem: (_, __, ___, item) => emitted.add(item),
      );

      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'ab', complete: false),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'abc', complete: false),
      );

      // Leading edge flushed immediately; the rest is buffered.
      expect(emitted, hasLength(1));
      expect((emitted.first as AssistantMessageItem).text, 'a');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(emitted, hasLength(2));
      expect((emitted.last as AssistantMessageItem).text, 'abc');
    });

    test('upsert flushes final version immediately, dropping buffered delta',
        () async {
      final emitted = <TimelineItem>[];
      final store = TimelineStore(
        agentId: 'a1',
        coalesceWindow: const Duration(milliseconds: 200),
        onItem: (_, __, ___, item) => emitted.add(item),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'ab', complete: false),
      );
      store.upsert(
        const AssistantMessageItem(id: 'm1', text: 'abc!', complete: true),
      );

      expect(emitted, hasLength(2));
      expect((emitted.last as AssistantMessageItem).text, 'abc!');
      expect((emitted.last as AssistantMessageItem).complete, isTrue);

      // No stale flush after the window elapses.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(emitted, hasLength(2));
    });

    test('rebuild cancels any pending coalesce timer', () async {
      final store = TimelineStore(
        agentId: 'a1',
        coalesceWindow: const Duration(milliseconds: 200),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'ab', complete: false),
      );

      store.rebuild(const [UserMessageItem(id: 'u2', text: 'again')]);
      expect(store.epoch, 2);
      expect(store.snapshot().single.id, 'u2');

      // The buffered 'ab' delta must not resurrect after rebuild.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(store.snapshot(), hasLength(1));
      expect(store.snapshot().single.id, 'u2');
    });

    test('flushAll commits buffered coalesced updates and cancels timers',
        () async {
      final emitted = <TimelineItem>[];
      final store = TimelineStore(
        agentId: 'a1',
        coalesceWindow: const Duration(milliseconds: 200),
        onItem: (_, __, ___, item) => emitted.add(item),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      );
      store.upsertCoalesced(
        const AssistantMessageItem(id: 'm1', text: 'ab', complete: false),
      );
      store.flushAll();

      expect(emitted, hasLength(2));
      expect((emitted.last as AssistantMessageItem).text, 'ab');

      // The cancelled timer must not fire a stale flush afterwards.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(emitted, hasLength(2));
    });
  });
}
