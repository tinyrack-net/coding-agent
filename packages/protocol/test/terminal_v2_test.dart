import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('terminal size and info enforce the Paseo boundary shape', () {
    expect(TerminalSize.fromJson({'rows': 24, 'cols': 80}).toJson(), {
      'rows': 24,
      'cols': 80,
    });
    expect(
      () => TerminalSize.fromJson({'rows': 0, 'cols': 80}),
      throwsFormatException,
    );
    final info = PaseoTerminalInfo.fromJson({
      'id': 't1',
      'name': 'Terminal 1',
      'cwd': '/repo',
      'workspaceId': 'w1',
      'title': 'Tests',
      'activity': {'state': 'working', 'changedAt': 1},
    });
    expect(info.toJson(), {
      'id': 't1',
      'name': 'Terminal 1',
      'cwd': '/repo',
      'workspaceId': 'w1',
      'title': 'Tests',
      'activity': {'state': 'working', 'changedAt': 1},
    });
    expect(
      () => PaseoTerminalInfo.fromJson({
        'id': 't1',
        'name': 'n',
        'cwd': '/',
        'activity': false,
      }),
      throwsFormatException,
    );
  });

  test('list and create requests round trip all optional fields', () {
    final list = ListTerminalsRequest.fromJson({
      'type': ListTerminalsRequest.type,
      'cwd': '/repo',
      'workspaceId': 'w1',
      'requestId': 'r1',
    });
    expect(list.toJson(), {
      'type': 'list_terminals_request',
      'cwd': '/repo',
      'workspaceId': 'w1',
      'requestId': 'r1',
    });
    final create = CreateTerminalRequest.fromJson({
      'type': CreateTerminalRequest.type,
      'cwd': '/repo',
      'workspaceId': 'w1',
      'name': 'Build',
      'agentId': 'a1',
      'command': 'dart',
      'args': ['test'],
      'size': {'rows': 40, 'cols': 120},
      'requestId': 'r2',
    });
    expect(create.args, ['test']);
    expect(create.size?.cols, 120);
    expect(create.toJson()['size'], {'rows': 40, 'cols': 120});
    expect(
      () => CreateTerminalRequest.fromJson({
        'type': CreateTerminalRequest.type,
        'cwd': '/',
        'args': [1],
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => CreateTerminalRequest.fromJson({
        'type': CreateTerminalRequest.type,
        'cwd': '/',
        'size': 1,
        'requestId': 'r',
      }),
      throwsFormatException,
    );
  });

  test('kill and capture preserve defaults and signed indices', () {
    expect(
      KillTerminalRequest.fromJson({
        'type': KillTerminalRequest.type,
        'terminalId': 't',
        'requestId': 'r',
      }).toJson(),
      {'type': 'kill_terminal_request', 'terminalId': 't', 'requestId': 'r'},
    );
    final capture = CaptureTerminalRequest.fromJson({
      'type': CaptureTerminalRequest.type,
      'terminalId': 't',
      'start': -5,
      'end': -1,
      'requestId': 'r',
    });
    expect(capture.stripAnsi, isTrue);
    expect(capture.toJson(), {
      'type': 'capture_terminal_request',
      'terminalId': 't',
      'start': -5,
      'end': -1,
      'stripAnsi': true,
      'requestId': 'r',
    });
    expect(
      () => CaptureTerminalRequest.fromJson({
        'type': CaptureTerminalRequest.type,
        'terminalId': 't',
        'stripAnsi': 'yes',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
  });

  test(
    'terminal input union parses input, resize, mouse, and rejects unknown',
    () {
      final messages = <TerminalClientMessage>[
        TerminalClientMessage.fromJson({'type': 'input', 'data': 'x'}),
        TerminalClientMessage.fromJson({
          'type': 'resize',
          'rows': 24,
          'cols': 80,
        }),
        TerminalClientMessage.fromJson({
          'type': 'mouse',
          'row': 1,
          'col': 2,
          'button': 0,
          'action': 'move',
        }),
      ];
      expect(messages.map((value) => value.toJson()).toList(), [
        {'type': 'input', 'data': 'x'},
        {'type': 'resize', 'rows': 24, 'cols': 80},
        {'type': 'mouse', 'row': 1, 'col': 2, 'button': 0, 'action': 'move'},
      ]);
      final request = TerminalInputRequest.fromJson({
        'type': TerminalInputRequest.type,
        'terminalId': 't',
        'message': {'type': 'input', 'data': '\r'},
      });
      expect(request.toJson()['message'], {'type': 'input', 'data': '\r'});
      expect(
        () => TerminalInputRequest.fromJson({
          'type': TerminalInputRequest.type,
          'terminalId': 't',
          'message': false,
        }),
        throwsFormatException,
      );
      expect(
        () => TerminalClientMessage.fromJson({'type': 'unknown'}),
        throwsFormatException,
      );
      expect(
        () => TerminalClientMessage.fromJson({
          'type': 'mouse',
          'row': 0,
          'col': 0,
          'button': 0,
          'action': 'drag',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'open project messages preserve descriptor and degrade unknown code',
    () {
      const request = OpenProjectRequest(cwd: '/repo', requestId: 'r');
      expect(OpenProjectRequest.fromJson(request.toJson()).cwd, '/repo');
      expect(
        () => OpenProjectRequest.fromJson({
          'type': 'wrong',
          'cwd': '/repo',
          'requestId': 'r',
        }),
        throwsFormatException,
      );
      final response = OpenProjectResponse.fromJson({
        'type': OpenProjectResponse.type,
        'payload': {
          'requestId': 'r',
          'workspace': null,
          'error': 'missing',
          'errorCode': 'future_code',
        },
      });
      expect(response.errorCode, isNull);
      expect(response.toJson()['payload'], {
        'requestId': 'r',
        'workspace': null,
        'error': 'missing',
      });
    },
  );
}
