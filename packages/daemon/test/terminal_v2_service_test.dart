import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/terminal/pty/pty.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/terminal/terminal_v2_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

final class _FakePty implements Pty {
  _FakePty(this.shell);
  @override
  final String shell;
  final outputController = StreamController<Uint8List>();
  final exit = Completer<int>();
  final writes = <Uint8List>[];
  final resizes = <(int, int)>[];
  @override
  Stream<Uint8List> get output => outputController.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) => writes.add(data);
  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));
  @override
  void kill() {
    if (!exit.isCompleted) exit.complete(0);
    if (!outputController.isClosed) outputController.close();
  }
}

void main() {
  late TerminalManager manager;
  late TerminalV2Service service;
  late List<_FakePty> ptys;
  late List<TerminalFrame> frames;
  late List<Map<String, Object?>> sentJson;
  late Connection connection;

  setUp(() {
    ptys = [];
    frames = [];
    sentJson = [];
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
            final pty = _FakePty(shell ?? 'shell');
            ptys.add(pty);
            return pty;
          },
      sendBinary: (_, bytes) => frames.add(TerminalFrame.decode(bytes)!),
      onExited: (_, __) {},
    );
    service = TerminalV2Service(
      terminals: manager,
      resolveWorkspaceId: (cwd) async => cwd == '/repo' ? 'w1' : null,
    );
    connection = Connection.external(
      frames: const Stream.empty(),
      send: (_) {},
      close: (_, __) {},
      id: 'c1',
      transport: 'direct',
      externalSessionKey: null,
      relayConnectionId: null,
    );
    connection.onJsonSent = sentJson.add;
  });

  tearDown(() {
    service.dispose();
    manager.dispose();
  });

  test(
    'create, list, input, resize, capture, rename, subscribe, and kill',
    () async {
      final created = await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/repo',
        'name': 'Build',
        'command': 'dart',
        'args': ['test'],
        'size': {'rows': 30, 'cols': 100},
        'requestId': 'create',
      });
      final terminal = ((created!['payload'] as Map)['terminal'] as Map)
          .cast<String, Object?>();
      final id = terminal['id']! as String;
      expect(terminal, containsPair('workspaceId', 'w1'));
      expect(terminal['name'], 'Build');
      expect(ptys.single.shell, 'dart');

      final listed = await service.handle(connection, {
        'type': 'list_terminals_request',
        'cwd': '/repo',
        'workspaceId': 'w1',
        'requestId': 'list',
      });
      final payload = (listed!['payload'] as Map).cast<String, Object?>();
      expect(payload['cwd'], '/repo');
      expect((payload['terminals'] as List).single, isNot(contains('cwd')));

      expect(
        await service.handle(connection, {
          'type': 'terminal_input',
          'terminalId': id,
          'message': {'type': 'input', 'data': 'run\r'},
        }),
        isNull,
      );
      await service.handle(connection, {
        'type': 'terminal_input',
        'terminalId': id,
        'message': {'type': 'resize', 'rows': 40, 'cols': 120},
      });
      await service.handle(connection, {
        'type': 'terminal_input',
        'terminalId': id,
        'message': {
          'type': 'mouse',
          'row': 0,
          'col': 0,
          'button': 0,
          'action': 'move',
        },
      });
      expect(utf8.decode(ptys.single.writes.single), 'run\r');
      expect(ptys.single.resizes, [(120, 40)]);

      ptys.single.outputController.add(utf8.encode('one\ntwo\nthree'));
      await Future<void>.delayed(Duration.zero);
      final capture = await service.handle(connection, {
        'type': 'capture_terminal_request',
        'terminalId': id,
        'start': -2,
        'requestId': 'capture',
      });
      expect((capture!['payload'] as Map)['lines'], ['two', 'three']);

      final renamed = await service.handle(connection, {
        'type': 'terminal.rename.request',
        'terminalId': id,
        'title': 'Tests',
        'requestId': 'rename',
      });
      expect((renamed!['payload'] as Map)['success'], isTrue);
      final subscribed = await service.handle(connection, {
        'type': 'subscribe_terminal_request',
        'terminalId': id,
        'restore': {
          'mode': 'live',
          'size': {'rows': 50, 'cols': 140},
        },
        'requestId': 'subscribe',
      });
      expect((subscribed!['payload'] as Map)['slot'], 0);
      expect(frames, isEmpty, reason: 'live restore skips initial snapshots');
      expect(ptys.single.resizes.last, (140, 50));
      expect(
        await service.handle(connection, {
          'type': 'unsubscribe_terminal_request',
          'terminalId': id,
        }),
        isNull,
      );

      final killed = await service.handle(connection, {
        'type': 'kill_terminal_request',
        'terminalId': id,
        'requestId': 'kill',
      });
      expect((killed!['payload'] as Map)['success'], isTrue);
      final second = await service.handle(connection, {
        'type': 'kill_terminal_request',
        'terminalId': id,
        'requestId': 'kill2',
      });
      expect((second!['payload'] as Map)['success'], isFalse);
    },
  );

  test(
    'create and validation failures preserve upstream response semantics',
    () async {
      final agent = await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/repo',
        'agentId': 'a1',
        'requestId': 'agent',
      });
      expect(
        (agent!['payload'] as Map)['error'],
        contains('no longer supported'),
      );
      final missing = await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/missing',
        'requestId': 'missing',
      });
      expect((missing!['payload'] as Map)['error'], 'workspaceId is required');
      final unknownCapture = await service.handle(connection, {
        'type': 'capture_terminal_request',
        'terminalId': 'none',
        'requestId': 'capture',
      });
      expect((unknownCapture!['payload'] as Map)['totalLines'], 0);
      final unknownSub = await service.handle(connection, {
        'type': 'subscribe_terminal_request',
        'terminalId': 'none',
        'requestId': 'sub',
      });
      expect((unknownSub!['payload'] as Map)['error'], 'Terminal not found');
      final emptyTitle = await service.handle(connection, {
        'type': 'terminal.rename.request',
        'terminalId': 'none',
        'title': ' ',
        'requestId': 'rename',
      });
      expect((emptyTitle!['payload'] as Map)['error'], 'Title is required');
      final longTitle = await service.handle(connection, {
        'type': 'terminal.rename.request',
        'terminalId': 'none',
        'title': 'x' * 201,
        'requestId': 'rename2',
      });
      expect((longTitle!['payload'] as Map)['error'], 'Title is too long');
      expect(await service.handle(connection, {'type': 'unknown'}), isNull);
    },
  );

  test(
    'directory subscriptions emit filtered initial and changed snapshots',
    () async {
      expect(
        await service.handle(connection, {
          'type': 'subscribe_terminals_request',
          'cwd': '/repo',
          'workspaceId': 'w1',
        }),
        isNull,
      );
      expect(sentJson, hasLength(1));
      expect(
        ((sentJson.single['message'] as Map)['payload'] as Map)['terminals'],
        isEmpty,
      );

      final created = await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/repo/nested',
        'workspaceId': 'w1',
        'requestId': 'create',
      });
      final terminal = ((created!['payload'] as Map)['terminal'] as Map);
      expect(sentJson, hasLength(2));
      final changed = (sentJson.last['message'] as Map);
      expect(changed['type'], 'terminals_changed');
      final payload = changed['payload'] as Map;
      expect(payload['cwd'], '/repo');
      expect((payload['terminals'] as List).single['id'], terminal['id']);

      await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/outside',
        'workspaceId': 'w1',
        'requestId': 'outside',
      });
      await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/repo/other-workspace',
        'workspaceId': 'w2',
        'requestId': 'other-workspace',
      });
      expect(sentJson, hasLength(3));
      expect(
        (((sentJson.last['message'] as Map)['payload'] as Map)['terminals']
                as List)
            .length,
        1,
        reason: 'the changed event is emitted but workspace filtering remains',
      );

      await service.handle(connection, {
        'type': 'unsubscribe_terminals_request',
        'cwd': '/repo',
        'workspaceId': 'w1',
      });
      await service.handle(connection, {
        'type': 'terminal.rename.request',
        'terminalId': terminal['id'],
        'title': 'Renamed',
        'requestId': 'rename',
      });
      expect(sentJson, hasLength(3));
    },
  );

  test(
    'subscribe restore modes and reflow capability select exact frame form',
    () async {
      final created = await service.handle(connection, {
        'type': 'create_terminal_request',
        'cwd': '/repo',
        'size': {'rows': 2, 'cols': 8},
        'requestId': 'create',
      });
      final id =
          (((created!['payload'] as Map)['terminal'] as Map)['id'] as String);
      ptys.single.outputController.add(
        Uint8List.fromList(utf8.encode('\x1b[1;31mred\x1b[0m')),
      );
      await Future<void>.delayed(Duration.zero);

      final visible = await service.handle(connection, {
        'type': 'subscribe_terminal_request',
        'terminalId': id,
        'restore': {'mode': 'visible-snapshot', 'scrollbackLines': 1},
        'requestId': 'visible',
      });
      expect((visible!['payload'] as Map)['slot'], 0);
      await Future<void>.delayed(Duration.zero);
      expect(frames.single.opcode, TerminalOpcode.restore);
      expect(utf8.decode(frames.single.payload), contains('red'));

      await service.handle(connection, {
        'type': 'unsubscribe_terminal_request',
        'terminalId': id,
      });
      frames.clear();
      connection.clientCapabilities = const {
        'terminal_reflowable_snapshot': true,
      };
      final legacy = await service.handle(connection, {
        'type': 'subscribe_terminal_request',
        'terminalId': id,
        'requestId': 'legacy',
      });
      expect((legacy!['payload'] as Map)['slot'], 1);
      await Future<void>.delayed(Duration.zero);
      expect(frames.single.opcode, TerminalOpcode.snapshot);
      final state = frames.single.snapshotState;
      expect(state.gridWrapped, hasLength(2));
      expect(state.scrollbackWrapped, isEmpty);
      expect(state.grid.first.first.bold, isTrue);
      expect(state.grid.first.first.fg, isNotNull);
    },
  );
}
