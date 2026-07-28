import 'package:agent_daemon/src/agent/provider_subagent_store.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('upserts descriptors and appends canonical timeline revisions', () {
    final updates = <ProviderSubagentUpdate>[];
    final store = ProviderSubagentStore(onUpdate: updates.add);
    final first = store.upsert(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      title: 'Explore',
      status: ProviderSubagentStatus.running,
    );
    final second = store.upsert(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      description: 'Inspect files',
      status: ProviderSubagentStatus.completed,
      toolCallId: 'call',
      cwd: 'C:/repo',
    );
    expect(second.createdAt, first.createdAt);
    expect(second.title, 'Explore');
    expect(second.description, 'Inspect files');
    final third = store.upsert(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      status: ProviderSubagentStatus.completed,
    );
    expect(third.description, 'Inspect files');
    expect(third.toolCallId, 'call');
    expect(third.cwd, 'C:/repo');
    expect(
      store.list('parent').single.status,
      ProviderSubagentStatus.completed,
    );

    store.appendTimeline(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      item: const AssistantMessageItem(
        id: 'message',
        text: 'stream',
        complete: false,
      ),
      timestamp: '2026-07-26T00:00:00.000Z',
    );
    store.appendTimeline(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      item: const AssistantMessageItem(
        id: 'message',
        text: 'complete',
        complete: true,
      ),
    );
    final snapshot = store.timeline('parent', 'child')!;
    expect(snapshot.rows, hasLength(2));
    expect(snapshot.rows.map((row) => row.seq), [1, 2]);
    expect((snapshot.rows.last.item as AssistantMessageItem).text, 'complete');
    expect(updates.whereType<ProviderSubagentUpsert>(), hasLength(3));
    expect(updates.whereType<ProviderSubagentTimelineUpdate>(), hasLength(2));
  });

  test('replace restores native snapshots and clear emits removals', () {
    final updates = <ProviderSubagentUpdate>[];
    final store = ProviderSubagentStore(onUpdate: updates.add);
    store.replace('parent', 'codex', const [
      RestoredProviderSubagent(
        id: 'child',
        title: 'Research',
        description: 'Find tests',
        status: ProviderSubagentStatus.canceled,
        toolCallId: 'call',
        cwd: 'C:/repo',
        timeline: [UserMessageItem(id: 'user', text: 'Investigate')],
      ),
    ]);
    expect(store.list('parent').single.title, 'Research');
    expect(store.timeline('parent', 'child')!.rows, hasLength(1));
    expect(store.timeline('other', 'child'), isNull);
    expect(
      () => store.appendTimeline(
        parentAgentId: 'missing',
        provider: 'codex',
        subagentId: 'child',
        item: const ErrorItem(id: 'e', message: 'x'),
      ),
      throwsStateError,
    );

    store.clear('parent');
    expect(store.list('parent'), isEmpty);
    expect(updates.last, isA<ProviderSubagentRemove>());
    store.clear('parent');
  });

  test('fetches tail, before, after, stale cursor, and gap windows', () {
    final store = ProviderSubagentStore();
    store.upsert(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'child',
      status: ProviderSubagentStatus.running,
    );
    for (var index = 1; index <= 5; index += 1) {
      store.appendTimeline(
        parentAgentId: 'parent',
        provider: 'codex',
        subagentId: 'child',
        item: ErrorItem(id: 'item-$index', message: '$index'),
      );
    }

    final tail = store.fetchTimeline('parent', 'child', limit: 2)!;
    expect(tail.rows.map((row) => row.seq), [4, 5]);
    expect(tail.hasOlder, isTrue);
    expect(tail.window.toJson(), {'minSeq': 1, 'maxSeq': 5, 'nextSeq': 6});

    final before = store.fetchTimeline(
      'parent',
      'child',
      direction: ProviderSubagentTimelineDirection.before,
      cursor: ProviderSubagentTimelineCursor(
        epoch: tail.epoch,
        seq: tail.rows.first.seq,
      ),
      limit: 2,
    )!;
    expect(before.rows.map((row) => row.seq), [2, 3]);
    expect(before.hasOlder, isTrue);
    expect(before.hasNewer, isTrue);

    final after = store.fetchTimeline(
      'parent',
      'child',
      direction: ProviderSubagentTimelineDirection.after,
      cursor: ProviderSubagentTimelineCursor(epoch: tail.epoch, seq: 2),
      limit: 2,
    )!;
    expect(after.rows.map((row) => row.seq), [3, 4]);
    expect(after.hasNewer, isTrue);
    expect(
      store
          .fetchTimeline(
            'parent',
            'child',
            direction: ProviderSubagentTimelineDirection.after,
            cursor: ProviderSubagentTimelineCursor(epoch: tail.epoch, seq: 2),
            limit: 0,
          )!
          .rows
          .map((row) => row.seq),
      [3, 4, 5],
    );
    expect(
      store
          .fetchTimeline(
            'parent',
            'child',
            direction: ProviderSubagentTimelineDirection.after,
            cursor: ProviderSubagentTimelineCursor(epoch: tail.epoch, seq: 5),
          )!
          .rows,
      isEmpty,
    );

    final stale = store.fetchTimeline(
      'parent',
      'child',
      direction: ProviderSubagentTimelineDirection.after,
      cursor: const ProviderSubagentTimelineCursor(epoch: 'old', seq: 5),
      limit: 2,
    )!;
    expect(stale.reset, isTrue);
    expect(stale.staleCursor, isTrue);
    expect(stale.rows.map((row) => row.seq), [4, 5]);

    expect(
      store.fetchTimeline('parent', 'child', limit: 0)!.rows,
      hasLength(5),
    );
    store.upsert(
      parentAgentId: 'parent',
      provider: 'codex',
      subagentId: 'empty',
      status: ProviderSubagentStatus.running,
    );
    expect(store.fetchTimeline('parent', 'empty')!.rows, isEmpty);

    // The wire validator rejects negative cursors. Calling the store directly
    // still verifies its retained-window gap reset branch.
    final gap = store.fetchTimeline(
      'parent',
      'child',
      direction: ProviderSubagentTimelineDirection.after,
      cursor: ProviderSubagentTimelineCursor(epoch: tail.epoch, seq: -1),
      limit: 2,
    )!;
    expect(gap.gap, isTrue);
    expect(gap.reset, isTrue);
    expect(store.fetchTimeline('missing', 'child'), isNull);
    expect(store.get('parent', 'child'), isNotNull);
  });
}
