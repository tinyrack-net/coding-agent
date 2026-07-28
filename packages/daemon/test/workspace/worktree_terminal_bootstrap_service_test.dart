import 'dart:io';

import 'package:agent_daemon/src/workspace/worktree_terminal_bootstrap_service.dart';
import 'package:test/test.dart';

void main() {
  test('loads branded terminal specs and skips malformed entries', () async {
    final temp = Directory.systemTemp.createTempSync('terminal-bootstrap-');
    addTearDown(() => temp.deleteSync(recursive: true));
    File('${temp.path}${Platform.pathSeparator}paseo.json').writeAsStringSync(
      '{"worktree":{"terminals":[{"command":"compatible"}]}}',
    );
    File(
      '${temp.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync(
      '{"worktree":{"terminals":['
      '{"name":" Dev ","command":" npm run dev "},'
      '{"command":"  "},{"name":"bad"},7]}}',
    );

    final specs = await loadWorktreeTerminalSpecs(temp.path);

    expect(specs, hasLength(1));
    expect(specs.single.name, 'Dev');
    expect(specs.single.command, 'npm run dev');
  });

  test('starts all specs and isolates individual terminal failures', () async {
    final created = <String?>[];
    final inputs = <String>[];
    final ready = <String>[];
    var nextId = 0;
    final service = WorktreeTerminalBootstrapService(
      loadSpecs: (_) async => const [
        WorktreeTerminalSpec(name: 'App', command: 'npm run dev'),
        WorktreeTerminalSpec(command: 'dart run tool.dart'),
      ],
      createTerminal:
          ({required cwd, required workspaceId, required name}) async {
            created.add(name);
            if (name == null) throw StateError('shell unavailable');
            return {
              'terminalId': 'term_${nextId++}',
              'name': name,
              'cwd': cwd,
              'workspaceId': workspaceId,
            };
          },
      waitUntilReady: (terminalId) async => ready.add(terminalId),
      sendInput: (terminalId, input) => inputs.add('$terminalId:$input'),
    );

    final results = await service.run(
      workspacePath: '/repo/worktree',
      workspaceId: 'wks_1',
    );

    expect(created, ['App', null]);
    expect(ready, ['term_0']);
    expect(inputs, ['term_0:npm run dev\r']);
    expect(results.first.toJson(), {
      'name': 'App',
      'command': 'npm run dev',
      'status': 'started',
      'terminalId': 'term_0',
      'error': null,
    });
    expect(results.last.status, 'failed');
    expect(results.last.error, contains('shell unavailable'));
  });

  test('invalid config shape fails before creating a terminal', () async {
    final temp = Directory.systemTemp.createTempSync('terminal-config-');
    addTearDown(() => temp.deleteSync(recursive: true));
    File(
      '${temp.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync('{"worktree":{"terminals":"bad"}}');
    final service = WorktreeTerminalBootstrapService(
      createTerminal:
          ({required cwd, required workspaceId, required name}) async =>
              throw StateError('must not create'),
      sendInput: (_, __) {},
    );

    expect(
      () => service.run(workspacePath: temp.path, workspaceId: 'wks_1'),
      throwsFormatException,
    );
  });
}
