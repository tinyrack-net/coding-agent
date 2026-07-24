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

  setUp(() {
    spawned = [];
    received = {};
    exits = [];
    manager = TerminalManager(
      spawn: ({required String cwd, int cols = 80, int rows = 24, String? shell}) {
        final pty = FakePty();
        spawned.add(pty);
        return pty;
      },
      sendBinary: (connectionId, bytes) {
        final frame = TerminalFrame.decode(bytes);
        expect(frame, isNotNull, reason: 'daemon must emit valid frames');
        (received[connectionId] ??= []).add(frame!);
      },
      onExited: (terminalId, exitCode) => exits.add((terminalId, exitCode)),
      scrollbackLimit: 1024,
    );
  });

  String create() =>
      manager.create(cwd: 'C:/tmp')['terminalId'] as String;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('create returns terminalId, cwd and shell; list reflects it', () {
    final info = manager.create(cwd: 'C:/tmp');
    expect(info['terminalId'], isA<String>());
    expect(info['cwd'], 'C:/tmp');
    expect(info['shell'], 'fake-shell');
    expect(manager.list(), [info]);
  });

  test('subscribe sends snapshot then live output to correct slot', () async {
    final id = create();
    spawned.single.emit('before');
    await pump();

    final slot = manager.subscribe('connA', id);
    final frames = received['connA']!;
    expect(frames, hasLength(1));
    expect(frames[0].opcode, TerminalOpcode.snapshot);
    expect(frames[0].slotId, slot);
    expect(utf8.decode(frames[0].payload), 'before');

    spawned.single.emit('after');
    await pump();
    expect(frames, hasLength(2));
    expect(frames[1].opcode, TerminalOpcode.output);
    expect(frames[1].slotId, slot);
    expect(utf8.decode(frames[1].payload), 'after');
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
        'conn', TerminalFrame.resize(slotA, cols: 120, rows: 40));
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

  test('ring buffer truncates snapshot to the newest bytes', () async {
    final id = create();
    // 1500 bytes against a 1024 limit, in uneven chunks.
    final pty = spawned.single;
    pty.emit('x' * 700);
    pty.emit('y' * 700);
    pty.emit('z' * 100);
    await pump();

    manager.subscribe('conn', id);
    final snapshot = received['conn']!.single.payload;
    expect(snapshot.length, 1024);
    expect(utf8.decode(snapshot), 'x' * 224 + 'y' * 700 + 'z' * 100);
  });

  test('multi-subscriber fanout with independent slots', () async {
    final id = create();
    final slotA = manager.subscribe('connA', id);
    final slotB = manager.subscribe('connB', id);

    spawned.single.emit('data');
    await pump();

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

  test('connection close unsubscribes everything for that connection',
      () async {
    final id = create();
    manager.subscribe('connA', id);
    manager.subscribe('connB', id);
    manager.onConnectionClosed('connA');

    spawned.single.emit('data');
    await pump();

    // connA only ever saw its snapshot; connB got snapshot + live output.
    expect(received['connA'], hasLength(1));
    expect(received['connB'], hasLength(2));
  });

  test('unsubscribe stops output; resubscribing gets a fresh slot + snapshot',
      () async {
    final id = create();
    final first = manager.subscribe('conn', id);
    manager.unsubscribe('conn', id);

    spawned.single.emit('quiet');
    await pump();
    expect(received['conn'], hasLength(1)); // just the original snapshot

    final second = manager.subscribe('conn', id);
    expect(second, isNot(first));
    final snapshot = received['conn']!.last;
    expect(snapshot.opcode, TerminalOpcode.snapshot);
    expect(utf8.decode(snapshot.payload), 'quiet');
  });

  test('unknown terminal ids throw StateError', () {
    expect(() => manager.kill('nope'), throwsStateError);
    expect(() => manager.subscribe('conn', 'nope'), throwsStateError);
    expect(() => manager.unsubscribe('conn', 'nope'), throwsStateError);
  });
}
