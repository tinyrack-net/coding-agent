import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/terminal/pty/pty.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/workspace/script_health_monitor.dart';
import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:agent_daemon/src/workspace/workspace_git_observer_service.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_daemon/src/workspace/workspace_script_runtime_store.dart';
import 'package:agent_daemon/src/workspace/workspace_scripts_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory workspaceDirectory;
  late WorkspaceRegistries registries;
  late List<_FakePty> ptys;
  late List<Map<String, String>?> environments;
  late TerminalManager terminals;
  late WorkspaceScriptRuntimeStore runtimeStore;
  late List<Map<String, Object?>> broadcasts;
  late WorkspaceScriptsService service;
  late ServiceProxyRouteRegistry serviceProxy;
  late Map<String, ScriptHealthState> health;
  late List<String> healthInvalidations;
  late List<String> logs;
  late _FakeWorkspaceGitObserverBackend branchObserver;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('workspace-scripts-service-');
    workspaceDirectory = Directory(
      '${home.path}${Platform.pathSeparator}workspace',
    )..createSync();
    File(
      '${workspaceDirectory.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync(
      jsonEncode({
        'scripts': {
          'web': {'type': 'service', 'command': 'npm run web', 'port': 4173},
          'check': {'command': 'dart test'},
          'ignored': {'command': '  '},
        },
      }),
    );
    registries = WorkspaceRegistries(dataDir: home.path);
    await registries.initialize();
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace',
        projectId: 'project',
        cwd: workspaceDirectory.path,
        kind: PersistedWorkspaceKind.directory,
        displayName: 'Workspace',
        createdAt: '1',
        updatedAt: '1',
      ),
    );
    ptys = [];
    environments = [];
    terminals = TerminalManager(
      spawn:
          ({
            required String cwd,
            int cols = 80,
            int rows = 24,
            String? shell,
            List<String>? arguments,
            Map<String, String>? environment,
          }) {
            final pty = _FakePty();
            ptys.add(pty);
            environments.add(environment);
            return pty;
          },
      sendBinary: (_, __) {},
      onExited: (_, __) {},
    );
    runtimeStore = WorkspaceScriptRuntimeStore();
    broadcasts = [];
    serviceProxy = ServiceProxyRouteRegistry();
    health = {};
    healthInvalidations = [];
    logs = [];
    branchObserver = _FakeWorkspaceGitObserverBackend();
    service = WorkspaceScriptsService(
      workspaces: registries.workspaces,
      terminals: terminals,
      runtimeStore: runtimeStore,
      broadcast: broadcasts.add,
      serviceProxy: serviceProxy,
      daemonPort: () => 6868,
      daemonListenHost: '0.0.0.0',
      resolveHealth: (hostname) => health[hostname],
      invalidateHealth: healthInvalidations.add,
      log: logs.add,
      branchObserverBackend: branchObserver,
    );
  });

  tearDown(() async {
    service.dispose();
    await terminals.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('lists normalized configured scripts in stable order', () async {
    final scripts = await service.list('workspace');
    expect(scripts.map((value) => value.scriptName), ['check', 'web']);
    expect(scripts.first.type, WorkspaceScriptType.script);
    expect(scripts.first.port, isNull);
    expect(scripts.last.type, WorkspaceScriptType.service);
    expect(scripts.last.port, 4173);
    expect(scripts.last.lifecycle, WorkspaceScriptLifecycle.stopped);
  });

  test(
    'start drives terminal, runtime, status, and management response',
    () async {
      final response = WorkspaceScriptOperationResponse.fromJson(
        (await service.handle(
              Connection.external(
                frames: const Stream.empty(),
                send: (_) {},
                close: (_, __) {},
                id: 'connection',
                transport: 'direct',
                externalSessionKey: null,
                relayConnectionId: null,
              ),
              const WorkspaceScriptStartRequest(
                workspaceId: 'workspace',
                scriptName: 'web',
                requestId: 'start',
              ).toJson(),
            ))
            as Map<String, Object?>,
      );
      expect(response.error, isNull);
      expect(response.script!.lifecycle, WorkspaceScriptLifecycle.running);
      expect(utf8.decode(ptys.single.written.single), 'npm run web\r');
      expect(
        runtimeStore.isRunning(workspaceId: 'workspace', scriptName: 'web'),
        isTrue,
      );
      expect(broadcasts.last['type'], 'script_status_update');

      final duplicate = WorkspaceScriptOperationResponse.fromJson(
        (await service.handle(
              _connection(),
              const WorkspaceScriptStartRequest(
                workspaceId: 'workspace',
                scriptName: 'web',
                requestId: 'duplicate',
              ).toJson(),
            ))
            as Map<String, Object?>,
      );
      expect(duplicate.script, isNull);
      expect(duplicate.error, contains('already running'));
    },
  );

  test(
    'service launch binds port environment, proxy route, health, and cleanup',
    () async {
      final running = await service.launch(
        workspaceId: 'workspace',
        scriptName: 'web',
      );
      expect(running.hostname, 'web--workspace.localhost');
      expect(running.port, 4173);
      expect(running.localProxyUrl, 'http://web--workspace.localhost:6868');
      expect(running.proxyUrl, running.localProxyUrl);
      expect(serviceProxy.findRoute('web--workspace.localhost')?.port, 4173);
      expect(environments.single, containsPair('HOST', '0.0.0.0'));
      expect(environments.single, containsPair('TINYRACK_PORT', '4173'));
      expect(
        environments.single,
        containsPair('TINYRACK_URL', 'http://web--workspace.localhost:6868'),
      );
      expect(
        environments.single,
        containsPair('TINYRACK_SERVICE_WEB_PORT', '4173'),
      );
      expect(healthInvalidations, ['workspace']);

      health[running.hostname] = ScriptHealthState.healthy;
      expect(
        (await service.list(
          'workspace',
        )).firstWhere((script) => script.scriptName == 'web').health,
        WorkspaceScriptHealth.healthy,
      );

      await service.stop(workspaceId: 'workspace', scriptName: 'web');
      expect(serviceProxy.findRoute('web--workspace.localhost'), isNull);
      expect(healthInvalidations, ['workspace', 'workspace']);
    },
  );

  test('plain scripts do not receive service environment or routes', () async {
    final running = await service.launch(
      workspaceId: 'workspace',
      scriptName: 'check',
    );
    expect(running.proxyUrl, isNull);
    expect(environments.single, isNot(contains('TINYRACK_PORT')));
    expect(serviceProxy.listRoutes(), isEmpty);
    expect(healthInvalidations, isEmpty);
  });

  test(
    'service route follows git branch changes and releases its observer',
    () async {
      await service.launch(workspaceId: 'workspace', scriptName: 'web');
      expect(branchObserver.observerCount, 1);
      expect(serviceProxy.findRoute('web--workspace.localhost')?.port, 4173);

      branchObserver.emit(workspaceDirectory.path, 'feature/next');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(serviceProxy.findRoute('web--workspace.localhost'), isNull);
      expect(
        serviceProxy.findRoute('web--feature-next--workspace.localhost')?.port,
        4173,
      );
      expect(
        (await registries.workspaces.get('workspace'))?.branch,
        'feature/next',
      );
      expect(healthInvalidations, ['workspace', 'workspace']);
      expect(
        (await service.list(
          'workspace',
        )).firstWhere((script) => script.scriptName == 'web').hostname,
        'web--feature-next--workspace.localhost',
      );

      await service.stop(workspaceId: 'workspace', scriptName: 'web');
      expect(branchObserver.observerCount, 0);
      expect(branchObserver.unsubscribeCount, 1);
    },
  );

  test('dynamic service planning exposes every service peer', () async {
    final allocator = File(
      '${workspaceDirectory.path}${Platform.pathSeparator}'
      '${Platform.isWindows ? 'port.cmd' : 'port.sh'}',
    );
    allocator.writeAsStringSync(
      Platform.isWindows
          ? '@echo off\r\necho 43124\r\n'
          : '#!/bin/sh\necho 43124\n',
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', allocator.path]);
    }
    File(
      '${workspaceDirectory.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync(
      jsonEncode({
        'worktree': {
          'servicePorts': {'portScript': allocator.path},
        },
        'scripts': {
          'web': {'type': 'service', 'command': 'run-web', 'port': 43123},
          'api': {'type': 'service', 'command': 'run-api'},
        },
      }),
    );

    final running = await service.launch(
      workspaceId: 'workspace',
      scriptName: 'api',
    );
    expect(running.port, 43124);
    expect(environments.single, containsPair('TINYRACK_PORT', '43124'));
    expect(
      environments.single,
      containsPair('TINYRACK_SERVICE_WEB_PORT', '43123'),
    );
    expect(
      environments.single,
      containsPair('TINYRACK_SERVICE_API_PORT', '43124'),
    );
    expect(serviceProxy.findRoute('api--workspace.localhost')?.port, 43124);
  });

  test('script projection uses locale-base natural numeric order', () async {
    File(
      '${workspaceDirectory.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync(
      jsonEncode({
        'scripts': {
          'Task 10': {'command': 'ten'},
          'tásk 2': {'command': 'two-accent'},
          'TASK 2': {'command': 'two-case'},
          'task 1': {'command': 'one'},
        },
      }),
    );

    expect(
      (await service.list('workspace')).map((script) => script.scriptName),
      ['task 1', 'tásk 2', 'TASK 2', 'Task 10'],
    );
  });

  test('invalid config warns and projects no scripts', () async {
    File(
      '${workspaceDirectory.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsStringSync('{invalid');
    expect(await service.list('workspace'), isEmpty);
    expect(logs.single, contains('treating workspace as having no scripts'));
  });

  test('stop waits for exit and returns the stopped projection', () async {
    await service.launch(workspaceId: 'workspace', scriptName: 'check');
    final response = WorkspaceScriptOperationResponse.fromJson(
      (await service.handle(
            _connection(),
            const WorkspaceScriptStopRequest(
              workspaceId: 'workspace',
              scriptName: 'check',
              requestId: 'stop',
            ).toJson(),
          ))
          as Map<String, Object?>,
    );
    expect(response.error, isNull);
    expect(response.script!.lifecycle, WorkspaceScriptLifecycle.stopped);
    expect(response.script!.exitCode, 0);
    expect(ptys.single.killed, isTrue);
  });

  test('legacy failures and list errors preserve frozen envelopes', () async {
    final legacy = StartWorkspaceScriptResponse.fromJson(
      (await service.handle(
            _connection(),
            const StartWorkspaceScriptRequest(
              workspaceId: 'missing',
              scriptName: 'web',
              requestId: 'legacy',
            ).toJson(),
          ))
          as Map<String, Object?>,
    );
    expect(legacy.terminalId, isNull);
    expect(legacy.error, contains('Workspace not found'));

    final list = WorkspaceScriptOperationResponse.fromJson(
      (await service.handle(
            _connection(),
            const WorkspaceScriptListRequest(
              workspaceId: 'missing',
              requestId: 'list',
            ).toJson(),
          ))
          as Map<String, Object?>,
    );
    expect(list.scripts, isEmpty);
    expect(list.error, contains('Workspace not found'));
    expect(await service.handle(_connection(), {'type': 'other'}), isNull);
  });

  test(
    'legacy success and management stop failures preserve payloads',
    () async {
      final legacy = StartWorkspaceScriptResponse.fromJson(
        (await service.handle(
              _connection(),
              const StartWorkspaceScriptRequest(
                workspaceId: 'workspace',
                scriptName: 'web',
                requestId: 'legacy',
              ).toJson(),
            ))
            as Map<String, Object?>,
      );
      expect(legacy.error, isNull);
      expect(legacy.terminalId, isNotEmpty);

      final notRunning = WorkspaceScriptOperationResponse.fromJson(
        (await service.handle(
              _connection(),
              const WorkspaceScriptStopRequest(
                workspaceId: 'workspace',
                scriptName: 'check',
                requestId: 'not-running',
              ).toJson(),
            ))
            as Map<String, Object?>,
      );
      expect(notRunning.script, isNull);
      expect(notRunning.error, contains('not running'));

      await expectLater(
        service.launch(workspaceId: 'workspace', scriptName: 'missing'),
        throwsStateError,
      );
    },
  );

  test('missing terminal and orphan runtime projection match Paseo', () async {
    runtimeStore
      ..set(
        const WorkspaceScriptRuntimeEntry(
          workspaceId: 'workspace',
          scriptName: 'orphan',
          type: WorkspaceScriptType.script,
          lifecycle: WorkspaceScriptLifecycle.running,
          terminalId: 'missing',
          exitCode: null,
        ),
      )
      ..set(
        const WorkspaceScriptRuntimeEntry(
          workspaceId: 'workspace',
          scriptName: 'old',
          type: WorkspaceScriptType.script,
          lifecycle: WorkspaceScriptLifecycle.stopped,
          terminalId: 'old',
          exitCode: 0,
        ),
      );
    final scripts = await service.list('workspace');
    expect(scripts.map((value) => value.scriptName), [
      'check',
      'orphan',
      'web',
    ]);
    await expectLater(
      service.stop(workspaceId: 'workspace', scriptName: 'orphan'),
      throwsStateError,
    );
  });

  test('terminal exits stop only the matching running runtime', () async {
    final script = await service.launch(
      workspaceId: 'workspace',
      scriptName: 'web',
    );
    await service.onTerminalExited(script.terminalId!, 7);
    final runtime = runtimeStore.get(
      workspaceId: 'workspace',
      scriptName: 'web',
    )!;
    expect(runtime.lifecycle, WorkspaceScriptLifecycle.stopped);
    expect(runtime.exitCode, 7);
    final count = broadcasts.length;
    await service.onTerminalExited('other', 1);
    expect(broadcasts, hasLength(count));
  });
}

Connection _connection() => Connection.external(
  frames: const Stream.empty(),
  send: (_) {},
  close: (_, __) {},
  id: 'connection',
  transport: 'direct',
  externalSessionKey: null,
  relayConnectionId: null,
);

final class _FakePty implements Pty {
  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int>();
  final List<Uint8List> written = [];
  bool killed = false;

  @override
  String get shell => 'fake';
  @override
  Stream<Uint8List> get output => _output.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) => written.add(data);
  @override
  void resize(int cols, int rows) {}
  @override
  void kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_output.isClosed) _output.close();
  }
}

final class _FakeWorkspaceGitObserverBackend
    implements WorkspaceGitObserverBackend {
  final Map<String, void Function(WorkspaceGitObserverSnapshot)> _observers =
      {};
  int unsubscribeCount = 0;

  int get observerCount => _observers.length;

  @override
  WorkspaceGitSubscription registerWorkspace(
    String cwd,
    void Function(WorkspaceGitObserverSnapshot snapshot) onSnapshot,
  ) {
    final normalized = Directory(cwd).absolute.path;
    _observers[normalized] = onSnapshot;
    return WorkspaceGitSubscription(
      unsubscribe: () {
        if (_observers.remove(normalized) != null) unsubscribeCount++;
      },
    );
  }

  void emit(String cwd, String? branch) {
    final normalized = Directory(cwd).absolute.path;
    _observers[normalized]!(
      WorkspaceGitObserverSnapshot(currentBranch: branch),
    );
  }
}
