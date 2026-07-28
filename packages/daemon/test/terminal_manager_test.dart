import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/terminal/pty/pty.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

class FakePty implements Pty {
  FakePty({this.shell = 'fake-shell'});

  @override
  final String shell;

  final outputController = StreamController<Uint8List>();
  final exitCompleter = Completer<int>();

  final List<Uint8List> written = [];
  final List<(int, int)> resizes = [];
  bool killed = false;

  @override
  Stream<Uint8List> get output => outputController.stream;

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  void write(Uint8List data) => written.add(data);

  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));

  @override
  void kill() {
    killed = true;
    if (!exitCompleter.isCompleted) exitCompleter.complete(1);
    outputController.close();
  }

  void emit(String text) => outputController.add(utf8.encode(text));

  void exitWith(int code) {
    if (!exitCompleter.isCompleted) exitCompleter.complete(code);
    outputController.close();
  }
}

void main() {
  late TerminalManager manager;
  late List<FakePty> spawned;
  late Map<String, List<TerminalFrame>> received;
  late List<(String, int?)> exits;
  late List<String?> contributionChanges;
  late List<Map<String, String>?> spawnedEnvironments;
  late List<String?> spawnedShells;
  late List<List<String>?> spawnedArguments;
  late List<TerminalActivityTransition> activityChanges;
  late List<(String, String)> streamExits;
  late int? bufferedAmount;
  late int now;

  setUp(() {
    spawned = [];
    received = {};
    exits = [];
    contributionChanges = [];
    spawnedEnvironments = [];
    spawnedShells = [];
    spawnedArguments = [];
    activityChanges = [];
    streamExits = [];
    bufferedAmount = null;
    now = 1000;
    manager = TerminalManager(
      spawn:
          ({
            required String cwd,
            int cols = 80,
            int rows = 24,
            String? shell,
            List<String>? arguments,
            Map<String, String>? environment,
          }) {
            final pty = FakePty();
            spawned.add(pty);
            spawnedEnvironments.add(environment);
            spawnedShells.add(shell);
            spawnedArguments.add(arguments);
            return pty;
          },
      sendBinary: (connectionId, bytes) {
        final frame = TerminalFrame.decode(bytes);
        expect(frame, isNotNull, reason: 'daemon must emit valid frames');
        (received[connectionId] ??= []).add(frame!);
      },
      onExited: (terminalId, exitCode) => exits.add((terminalId, exitCode)),
      onWorkspaceContributionChanged: contributionChanges.add,
      onActivityChanged: activityChanges.add,
      onStreamExited: (connectionId, terminalId) =>
          streamExits.add((connectionId, terminalId)),
      getClientBufferedAmount: (_) => bufferedAmount,
      getTerminalActivityUrl: () =>
          'http://127.0.0.1:6868/api/terminal-activity',
      activityTokenFactory: () => 'activity-token',
      activityClock: () => now,
      scrollbackLimit: 1024,
    );
  });

  String create() => manager.create(cwd: 'C:/tmp')['terminalId'] as String;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('create returns terminalId, cwd and shell; list reflects it', () {
    final info = manager.create(cwd: 'C:/tmp');
    expect(info['terminalId'], isA<String>());
    expect(info['cwd'], 'C:/tmp');
    expect(info['shell'], 'fake-shell');
    expect(manager.list(), [info]);
    expect(spawnedEnvironments.single, {
      'TINYRACK_TERMINAL_ID': info['terminalId'],
      'TINYRACK_ACTIVITY_TOKEN': 'activity-token',
      'TINYRACK_TERMINAL_ACTIVITY_URL':
          'http://127.0.0.1:6868/api/terminal-activity',
    });
    expect(
      manager.validateActivityToken(
        info['terminalId']! as String,
        'activity-token',
      ),
      TerminalActivityTokenValidation.valid,
    );
    expect(
      manager.validateActivityToken(info['terminalId']! as String, 'wrong'),
      TerminalActivityTokenValidation.invalid,
    );
    expect(
      manager.validateActivityToken('missing', 'activity-token'),
      TerminalActivityTokenValidation.unknown,
    );
  });

  test(
    'v2 metadata, command arguments, rename, resize, and filtering match',
    () {
      final first = manager.create(
        cwd: 'C:/repo',
        workspaceId: 'w1',
        name: 'Build',
        title: 'Initial',
        command: 'dart',
        arguments: const ['test', '--reporter=compact'],
        cols: 100,
        rows: 30,
      );
      manager.create(cwd: 'C:/other', workspaceId: 'w2');
      expect(spawnedShells.first, 'dart');
      expect(spawnedArguments.first, ['test', '--reporter=compact']);
      final id = first['terminalId']! as String;
      expect(manager.listV2(cwd: 'C:/repo', workspaceId: 'w1'), [
        {
          'id': id,
          'name': 'Build',
          'cwd': 'C:/repo',
          'workspaceId': 'w1',
          'title': 'Initial',
          'activity': null,
        },
      ]);
      expect(manager.rename(id, 'Tests'), isTrue);
      manager.resize(id, 120, 40);
      expect(spawned.first.resizes, [(120, 40)]);
      expect(manager.listV2().first['title'], 'Tests');
    },
  );

  test(
    'capture applies terminal carriage returns, ANSI, signed ranges',
    () async {
      final id = create();
      spawned.single.emit('one\rONE\n\x1b[31mtwo\x1b[0m   \nthree\nfour');
      await pump();

      expect(manager.capture(id).lines, ['ONE', 'two', 'three', 'four']);
      expect(manager.capture(id, start: -2, end: -1).lines, ['three', 'four']);
      expect(manager.capture(id, start: 3, end: 1).lines, isEmpty);
      expect(manager.capture(id, start: -99, end: 99).totalLines, 4);
      expect(manager.capture(id, stripAnsi: false).lines[1], contains('\x1b'));
      expect(manager.capture('missing').lines, isEmpty);
    },
  );

  test('create merges caller environment with protected activity values', () {
    final info = manager.create(
      cwd: 'C:/tmp',
      environment: {
        'HOST': '0.0.0.0',
        'TINYRACK_PORT': '4173',
        'TINYRACK_ACTIVITY_TOKEN': 'caller-cannot-override',
      },
    );
    expect(spawnedEnvironments.single, {
      'HOST': '0.0.0.0',
      'TINYRACK_PORT': '4173',
      'TINYRACK_ACTIVITY_TOKEN': 'activity-token',
      'TINYRACK_TERMINAL_ID': info['terminalId'],
      'TINYRACK_TERMINAL_ACTIVITY_URL':
          'http://127.0.0.1:6868/api/terminal-activity',
    });
  });

  test('create inherits the longest registered cwd environment and lets '
      'caller values override it', () {
    manager
      ..registerCwdEnvironment('C:/repo', {
        'TINYRACK_WORKTREE_PORT': '41000',
        'SCOPE': 'root',
      })
      ..registerCwdEnvironment('C:/repo/packages', {
        'TINYRACK_WORKTREE_PORT': '42000',
        'SCOPE': 'package',
      });

    manager.create(
      cwd: 'C:/repo/packages/app',
      environment: {'SCOPE': 'terminal'},
    );

    expect(
      spawnedEnvironments.single,
      containsPair('TINYRACK_WORKTREE_PORT', '42000'),
    );
    expect(spawnedEnvironments.single, containsPair('SCOPE', 'terminal'));
  });

  test('activity contributions retain workspace ownership and timestamps', () {
    final info = manager.create(cwd: 'C:/tmp', workspaceId: 'wks_1');
    final id = info['terminalId']! as String;
    expect(info['workspaceId'], 'wks_1');
    expect(info['activity'], isNull);

    now = 1234;
    expect(manager.setActivity(id, TerminalActivityState.working), isTrue);
    expect(contributionChanges, ['wks_1']);
    expect(manager.list().single['activity'], {
      'state': 'working',
      'changedAt': 1234,
    });
    final contribution = manager.listActivityContributions().single;
    expect(contribution.workspaceId, 'wks_1');
    expect(contribution.cwd, 'C:/tmp');
    expect(contribution.activity?.state, TerminalActivityState.working);
    expect(contribution.activity?.changedAt, 1234);

    // Same derived bucket does not emit a redundant workspace update.
    now = 5678;
    expect(manager.setActivity(id, TerminalActivityState.working), isFalse);
    expect(contributionChanges, ['wks_1']);
    expect(activityChanges, hasLength(1));
    expect(activityChanges.single.terminalId, id);
    expect(activityChanges.single.terminalName, 'Terminal 1');
    expect(activityChanges.single.previous, isNull);
  });

  test('attention clear and contributing exit emit bucket changes', () async {
    final id =
        manager.create(cwd: 'C:/tmp', workspaceId: 'wks_1')['terminalId']!
            as String;
    now = 1;
    manager.setActivity(id, TerminalActivityState.working);
    now = 2;
    manager.setActivity(id, TerminalActivityState.idle);
    expect(
      manager.listActivityContributions().single.activity?.attentionReason,
      TerminalActivityAttentionReason.finished,
    );
    expect(manager.clearAttention(id), isTrue);
    expect(manager.clearAttention(id), isFalse);
    expect(contributionChanges, ['wks_1', 'wks_1', 'wks_1']);

    now = 3;
    manager.setActivity(id, TerminalActivityState.working);
    contributionChanges.clear();
    spawned.single.exitWith(0);
    await pump();
    expect(contributionChanges, ['wks_1']);
  });

  test('subscribe sends snapshot then live output to correct slot', () async {
    final id = create();
    spawned.single.emit('before');
    await pump();

    final slot = manager.subscribe('connA', id);
    await pump();
    final frames = received['connA']!;
    expect(frames, hasLength(1));
    expect(frames[0].opcode, TerminalOpcode.snapshot);
    expect(frames[0].slotId, slot);
    expect(
      frames[0].snapshotState.grid.first
          .take(6)
          .map((cell) => cell.char)
          .join(),
      'before',
    );

    spawned.single.emit('after');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(frames, hasLength(2));
    expect(frames[1].opcode, TerminalOpcode.output);
    expect(frames[1].slotId, slot);
    expect(utf8.decode(frames[1].payload), 'after');
  });

  test('coalesces post-snapshot output on the trailing edge', () async {
    final id = create();
    manager.subscribe('conn', id);
    await pump();
    received['conn']!.clear();

    spawned.single
      ..emit('a')
      ..emit('b')
      ..emit('é');
    await pump();
    expect(received['conn'], isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received['conn']!.map((frame) => utf8.decode(frame.payload)), [
      'abé',
    ]);
  });

  test('live restore replays tracked terminal input modes', () async {
    final id = create();
    spawned.single.emit('\x1b[=3;1u');
    await pump();

    manager.subscribe(
      'conn',
      id,
      restore: const TerminalRestoreOptions(mode: TerminalRestoreMode.live),
    );
    await pump();

    expect(received['conn'], hasLength(1));
    expect(received['conn']!.single.opcode, TerminalOpcode.output);
    expect(utf8.decode(received['conn']!.single.payload), '\x1b[=3;1u');

    spawned.single.emit('\x1b[?u');
    await pump();
    expect(utf8.decode(spawned.single.written.single), '\x1b[?3u');
  });

  test('slow or opaque clients fall back to a catch-up snapshot', () async {
    final id = create();
    manager.subscribe('conn', id);
    await pump();
    received['conn']!.clear();

    spawned.single.emit('x' * (kMaxTerminalOutputFrameBytes + 1));
    await pump();
    await pump();

    expect(received['conn'], hasLength(1));
    expect(received['conn']!.single.opcode, TerminalOpcode.restore);
  });

  test('clients with low buffered output continue streaming', () async {
    bufferedAmount = 0;
    final id = create();
    manager.subscribe('conn', id);
    await pump();
    received['conn']!.clear();

    spawned.single.emit('x' * (kMaxTerminalOutputFrameBytes + 1));
    await pump();

    expect(received['conn'], hasLength(1));
    expect(received['conn']!.single.opcode, TerminalOpcode.output);
  });

  test('input and resize frames route by (connection, slot)', () async {
    final idA = create();
    final idB = create();
    final slotA = manager.subscribe('conn', idA);
    final slotB = manager.subscribe('conn', idB);
    expect(slotA, isNot(slotB));

    manager.handleFrame(
      'conn',
      TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: slotB,
        payload: utf8.encode('hi'),
      ),
    );
    expect(spawned[0].written, isEmpty);
    expect(utf8.decode(spawned[1].written.single), 'hi');

    manager.handleFrame(
      'conn',
      TerminalFrame.resize(slotA, cols: 120, rows: 40),
    );
    expect(spawned[0].resizes, [(120, 40)]);
    expect(spawned[1].resizes, isEmpty);

    // Unknown slot / wrong connection: ignored.
    manager.handleFrame(
      'other',
      TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: slotA,
        payload: utf8.encode('x'),
      ),
    );
    expect(spawned[0].written, isEmpty);
  });

  test('ring buffer truncates capture to the newest bytes', () async {
    final id = create();
    // 1500 bytes against a 1024 limit, in uneven chunks.
    final pty = spawned.single;
    pty.emit('x' * 700);
    pty.emit('y' * 700);
    pty.emit('z' * 100);
    await pump();

    final capture = manager.capture(id);
    expect(capture.lines.single, 'x' * 224 + 'y' * 700 + 'z' * 100);
  });

  test('multi-subscriber fanout with independent slots', () async {
    final id = create();
    final slotA = manager.subscribe('connA', id);
    final slotB = manager.subscribe('connB', id);
    await pump();
    await pump();

    spawned.single.emit('data');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final liveA = received['connA']!.last;
    final liveB = received['connB']!.last;
    expect(liveA.opcode, TerminalOpcode.output);
    expect(liveB.opcode, TerminalOpcode.output);
    expect(liveA.slotId, slotA);
    expect(liveB.slotId, slotB);
    expect(utf8.decode(liveA.payload), 'data');
    expect(utf8.decode(liveB.payload), 'data');
  });

  test('exit broadcasts and cleans up the session', () async {
    final id = create();
    manager.subscribe('conn', id);
    spawned.single.exitWith(7);
    await pump();

    expect(exits, [(id, 7)]);
    expect(streamExits, [('conn', id)]);
    expect(manager.list(), isEmpty);
    expect(() => manager.subscribe('conn', id), throwsStateError);
  });

  test('kill terminates the pty and reports exit', () async {
    final id = create();
    manager.kill(id);
    await pump();
    expect(spawned.single.killed, isTrue);
    expect(exits.single.$1, id);
    expect(manager.list(), isEmpty);
  });

  test(
    'direct input, presence, and killAndWait support managed scripts',
    () async {
      final id = create();
      expect(manager.contains(id), isTrue);
      manager.sendInput(id, 'run\r');
      expect(utf8.decode(spawned.single.written.single), 'run\r');
      expect(await manager.killAndWait(id), 1);
      await pump();
      expect(manager.contains(id), isFalse);
      expect(() => manager.sendInput(id, 'again'), throwsStateError);
    },
  );

  test(
    'connection close unsubscribes everything for that connection',
    () async {
      final id = create();
      manager.subscribe('connA', id);
      manager.subscribe('connB', id);
      manager.onConnectionClosed('connA');

      spawned.single.emit('data');
      await pump();

      // The deferred connA snapshot is cancelled; connB's revision-safe
      // snapshot already includes output produced before snapshot delivery.
      expect(received['connA'], isNull);
      expect(received['connB'], hasLength(1));
      expect(received['connB']!.single.opcode, TerminalOpcode.snapshot);
    },
  );

  test(
    'unsubscribe stops output; resubscribing gets a fresh slot + snapshot',
    () async {
      final id = create();
      final first = manager.subscribe('conn', id);
      manager.unsubscribe('conn', id);

      spawned.single.emit('quiet');
      await pump();
      expect(received['conn'], isNull);

      final second = manager.subscribe('conn', id);
      expect(second, isNot(first));
      await pump();
      final snapshot = received['conn']!.last;
      expect(snapshot.opcode, TerminalOpcode.snapshot);
      expect(
        snapshot.snapshotState.grid.first
            .take(5)
            .map((cell) => cell.char)
            .join(),
        'quiet',
      );
    },
  );

  test('unknown terminal ids throw StateError', () {
    expect(() => manager.kill('nope'), throwsStateError);
    expect(() => manager.subscribe('conn', 'nope'), throwsStateError);
    expect(() => manager.unsubscribe('conn', 'nope'), throwsStateError);
    expect(
      () => manager.setActivity('nope', TerminalActivityState.working),
      throwsStateError,
    );
    expect(() => manager.clearAttention('nope'), throwsStateError);
  });

  test(
    'handleFrame ignores malformed resize and daemon-only opcodes',
    () async {
      final id = create();
      final slot = manager.subscribe('conn', id);
      final pty = spawned.single;

      // Malformed resize payload (< 4 bytes): guarded and ignored.
      manager.handleFrame(
        'conn',
        TerminalFrame(
          opcode: TerminalOpcode.resize,
          slotId: slot,
          payload: Uint8List(2),
        ),
      );
      expect(pty.resizes, isEmpty);

      // Daemon->client-only opcodes arriving from a client are no-ops.
      manager.handleFrame(
        'conn',
        TerminalFrame(
          opcode: TerminalOpcode.output,
          slotId: slot,
          payload: Uint8List(0),
        ),
      );
      manager.handleFrame(
        'conn',
        TerminalFrame(
          opcode: TerminalOpcode.snapshot,
          slotId: slot,
          payload: Uint8List(0),
        ),
      );
      expect(pty.written, isEmpty);
      expect(pty.resizes, isEmpty);
    },
  );

  test(
    'ring buffer capture replaces entirely for an oversized chunk',
    () async {
      final id = create();
      final pty = spawned.single;
      pty.emit('a' * 2000); // exceeds the 1024-byte limit in one shot.
      await pump();

      final capture = manager.capture(id);
      expect(capture.lines.single, 'a' * 1024);
    },
  );

  test('ring buffer drops whole oldest chunks that fit entirely within the '
      'trim excess', () async {
    final id = create();
    final pty = spawned.single;
    pty.emit('a' * 512);
    pty.emit('b' * 512);
    pty.emit('c' * 512); // total 1536 > 1024: the whole 'a' chunk is dropped.
    await pump();

    final capture = manager.capture(id);
    expect(capture.lines.single, 'b' * 512 + 'c' * 512);
  });
}
