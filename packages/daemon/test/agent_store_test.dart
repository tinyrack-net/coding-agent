import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_store_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  PersistedAgent record({
    String agentId = 'agent-1',
    String cwd = r'C:\proj',
    bool internal = false,
  }) => PersistedAgent(
    summary: AgentSummary(
      agentId: agentId,
      title: 'Test agent',
      cwd: cwd,
      provider: 'claude',
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 123,
      sessionId: 'sess-1',
    ),
    archived: false,
    epoch: 2,
    lastSeq: 3,
    items: const [
      UserMessageItem(id: 'u1', text: 'hello'),
      AssistantMessageItem(id: 'm1', text: 'world', complete: true),
      ToolCallItem(
        id: 'tool-1',
        toolName: 'Bash',
        status: ToolCallStatus.success,
        detail: ShellDetail(command: 'ls', output: 'a\nb'),
      ),
    ],
    rows: const [
      TimelineRow(
        seq: 1,
        timestamp: '2026-07-28T00:00:00.000Z',
        item: UserMessageItem(id: 'u1', text: 'hello'),
      ),
    ],
    internal: internal,
  );

  group('AgentStore', () {
    test('save + loadAll round-trips summary, epoch, seq, and items', () async {
      final store = AgentStore(dataDir: tempDir.path);
      await store.save(record());

      final loaded = await AgentStore(dataDir: tempDir.path).loadAll();
      expect(loaded, hasLength(1));
      final r = loaded.single;
      expect(r.summary.agentId, 'agent-1');
      expect(r.summary.sessionId, 'sess-1');
      expect(r.summary.cwd, r'C:\proj');
      expect(r.archived, isFalse);
      expect(r.epoch, 2);
      expect(r.lastSeq, 3);
      expect(r.items, hasLength(3));
      expect(r.rows, hasLength(1));
      expect(r.rows.single.seq, 1);
      expect(r.items[0], isA<UserMessageItem>());
      final tool = r.items[2] as ToolCallItem;
      expect(tool.status, ToolCallStatus.success);
      expect((tool.detail as ShellDetail).output, 'a\nb');
    });

    test(
      'internal marker round-trips and defaults false for legacy JSON',
      () async {
        final store = AgentStore(dataDir: tempDir.path);
        await store.save(record(internal: true));

        final loaded = await store.loadAll();
        expect(loaded.single.internal, isTrue);
        final legacy = PersistedAgent.fromJson({
          ...record().toJson()..remove('internal'),
        });
        expect(legacy.internal, isFalse);
      },
    );

    test('scheduleSave debounces and flush() forces the write', () async {
      final store = AgentStore(
        dataDir: tempDir.path,
        debounce: const Duration(seconds: 30),
      );
      store.scheduleSave(record());
      expect(await store.loadAll(), isEmpty); // debounce still pending

      await store.flush();
      expect(await store.loadAll(), hasLength(1));
    });

    test('latest scheduled record wins', () async {
      final store = AgentStore(
        dataDir: tempDir.path,
        debounce: const Duration(milliseconds: 20),
      );
      store.scheduleSave(record());
      final updated = PersistedAgent(
        summary: record().summary.copyWith(title: 'renamed'),
        archived: true,
        epoch: 5,
        lastSeq: 9,
        items: const [],
      );
      store.scheduleSave(updated);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final loaded = await store.loadAll();
      expect(loaded.single.summary.title, 'renamed');
      expect(loaded.single.archived, isTrue);
      expect(loaded.single.epoch, 5);
    });

    test('agents in different cwds land in distinct directories', () async {
      final store = AgentStore(dataDir: tempDir.path);
      await store.save(record(agentId: 'a1', cwd: r'C:\proj one'));
      await store.save(record(agentId: 'a2', cwd: r'C:\proj two'));

      final loaded = await store.loadAll();
      expect(loaded, hasLength(2));
      expect(
        AgentStore.sanitizeCwd(r'C:\proj one'),
        isNot(AgentStore.sanitizeCwd(r'C:\proj two')),
      );
    });

    test('defaultDataDir resolves under the user home directory', () {
      final dir = AgentStore.defaultDataDir();
      expect(dir, endsWith('.tinyrack-agent'));

      // Constructing without an explicit dataDir goes through the same
      // default-resolution path.
      final store = AgentStore();
      expect(store.dataDir, dir);
    });
  });
}
