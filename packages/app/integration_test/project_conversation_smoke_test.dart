import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstPrompt = 'Complete the deterministic integration journey.';
const _assistantResponse = 'Deterministic integration response.';

final class _IntegrationHostRegistry extends HostRegistryNotifier {
  _IntegrationHostRegistry({required this.serverId, required this.port});

  final String serverId;
  final int port;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      HostProfile(
        serverId: serverId,
        label: 'Integration host',
        connections: [
          DirectTcpHostConnection(
            id: 'direct:127.0.0.1:$port',
            endpoint: '127.0.0.1:$port',
          ),
        ],
        preferredConnectionId: 'direct:127.0.0.1:$port',
        createdAt: '2026-07-30T00:00:00.000Z',
        updatedAt: '2026-07-30T00:00:00.000Z',
      ),
    ],
    activeServerId: serverId,
    loaded: true,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Add Project creates a workspace and renders its first assistant response',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final home = Directory.systemTemp.createTempSync(
        'tinyrack-windows-project-conversation-',
      );
      _ExternalDaemon? stagedDaemon;
      DaemonClient? stagedClient;
      addTearDown(() async {
        await tester.runAsync(() async {
          try {
            stagedClient?.dispose();
          } finally {
            try {
              await stagedDaemon?.stop();
            } finally {
              if (home.existsSync() &&
                  Platform.environment['TINYRACK_KEEP_SMOKE_HOME'] != '1') {
                home.deleteSync(recursive: true);
              }
            }
          }
        });
      });
      final project = Directory('${home.path}${Platform.pathSeparator}project')
        ..createSync();
      File(
        '${project.path}${Platform.pathSeparator}README.md',
      ).writeAsStringSync('# deterministic integration project\n');
      final projectPath = await project.resolveSymbolicLinks();
      final dart = await _resolveDartExecutable();
      final providerFixture = await File(
        _providerFixturePath(),
      ).resolveSymbolicLinks();

      DaemonConfigStore(home: home.path).patch(
        MutableDaemonConfigPatch(
          injectMcpIntoAgents: false,
          providers: {
            for (final provider in const [
              'claude',
              'codex',
              'copilot',
              'opencode',
              'pi',
              'omp',
            ])
              provider: const MutableDaemonProviderConfig(enabled: false),
            'integration-acp': MutableDaemonProviderConfig(
              extra: {
                'extends': 'acp',
                'label': 'Integration fixture',
                'command': [dart, providerFixture],
                'env': {
                  'INTEGRATION_ACP_LOG':
                      '${home.path}${Platform.pathSeparator}acp.log',
                },
                'params': {
                  'supportsMcpServers': true,
                  'clientCapabilities': {
                    'fs': {'readTextFile': true, 'writeTextFile': true},
                    'terminal': true,
                  },
                },
              },
            ),
          },
        ),
      );
      late final DaemonClient client;
      late final String serverId;
      late final int daemonPort;
      await tester.runAsync(() async {
        daemonPort = await _findFreePort();
        stagedDaemon = await _ExternalDaemon.start(
          executable: dart,
          port: daemonPort,
          dataDir: home,
        );
        // Confirm that the child is listening and has completed the daemon
        // hello handshake before wiring the URI into the UI-owned client.
        final hello = await stagedDaemon!.waitForHello();
        client = DaemonClient(uri: Uri.parse('ws://127.0.0.1:$daemonPort'));
        stagedClient = client;
        await _connectClient(client);
        expect(client.serverHello?.daemonVersion, hello.daemonVersion);
        serverId = client.serverInfo!.serverId;
        final providerSnapshot = await client.fetchProvidersSnapshot(
          cwd: projectPath,
        );
        expect(
          providerSnapshot.entries.singleWhere(
            (entry) => entry.provider == 'integration-acp',
          ),
          isA<ProviderSnapshotEntry>()
              .having(
                (entry) => entry.status,
                'catalog status',
                ProviderCatalogStatus.ready,
              )
              .having(
                (entry) => entry.models?.map((model) => model.id),
                'models',
                contains('deterministic-model'),
              ),
        );
      });
      final router = buildAppRouter(initialLocation: '/open-project');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // The smoke owns its port-0 daemon. Keep the desktop lifecycle
            // supervisor from probing or adopting that process while the
            // production project screens are mounted.
            desktopShellProvider.overrideWithValue(false),
            daemonClientProvider.overrideWithValue(client),
            hostRuntimeClientsProvider.overrideWithValue({serverId: client}),
            hostDaemonClientProvider.overrideWith(
              (ref, requestedServerId) =>
                  requestedServerId == serverId ? client : null,
            ),
            hostConnectionStateProvider.overrideWith(
              (ref, requestedServerId) => Stream.value(
                requestedServerId == serverId
                    ? DaemonConnectionState.connected
                    : DaemonConnectionState.disconnected,
              ),
            ),
            hostRegistryProvider.overrideWith(
              () => _IntegrationHostRegistry(
                serverId: serverId,
                port: daemonPort,
              ),
            ),
          ],
          child: FluentApp.router(routerConfig: router),
        ),
      );

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('open-project-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('open-project-submit')));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('add-project-flow-method-directory-search')),
      );
      await tester.tap(
        find.byKey(const ValueKey('add-project-flow-method-directory-search')),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('add-project-flow-input')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('add-project-flow-input')),
        projectPath,
      );
      final projectChoice = find.byKey(
        ValueKey('add-project-flow-path-$projectPath'),
      );
      await _pumpUntil(tester, projectChoice);
      await tester.tap(projectChoice);

      await _pumpUntil(tester, find.byType(NewWorkspaceScreen));
      final promptInput = find.byWidgetPredicate(
        (widget) =>
            widget is TextBox &&
            widget.placeholder == 'What do you want to do? (optional)',
      );
      await _pumpUntil(tester, promptInput);
      final providerSelector = find.byKey(
        const ValueKey('new-workspace-provider-selector'),
      );
      await _pumpUntil(tester, providerSelector);
      expect(
        tester.widget<ComboBox<String>>(providerSelector).value,
        'integration-acp',
      );
      await tester.enterText(promptInput, _firstPrompt);
      final create = find.widgetWithText(FilledButton, 'Create');
      await _pumpUntilCondition(
        tester,
        () =>
            create.evaluate().length == 1 &&
            tester.widget<FilledButton>(create).onPressed != null,
        description: 'the enabled New workspace Create button',
      );
      await tester.tap(create);

      try {
        await _pumpUntil(tester, find.text(_assistantResponse), maxPumps: 400);
      } catch (_) {
        final log = File('${home.path}${Platform.pathSeparator}daemon.log');
        if (log.existsSync()) {
          // Keep the exact daemon-side failure visible in the Windows smoke
          // output; the normal teardown still removes this temp home.
          debugPrint('External daemon log (${home.path}):');
          debugPrint(log.readAsStringSync());
        }
        debugPrint('External daemon stdout/stderr tail:');
        debugPrint(stagedDaemon?.outputTail ?? '<no process output>');
        rethrow;
      }
      // Retained workspace deck entries can keep an offstage copy of the
      // optimistic user message mounted while the active agent tab renders
      // the same message. Presence is the behavior under test here.
      expect(find.text(_firstPrompt), findsWidgets);
      expect(find.text(_assistantResponse), findsOneWidget);
      expect(find.byType(NewWorkspaceScreen), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  int maxPumps = 200,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  fail('Timed out waiting for $description.');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 200,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toSet()
      .join(' | ');
  fail('Timed out waiting for $finder. Visible text: $visibleText');
}

/// Starts the same daemon entrypoint that is shipped/run outside the Flutter
/// process. Keeping this process boundary in the Windows smoke catches lock,
/// config, provider discovery, and websocket lifecycle wiring that an
/// in-process [startDaemonServer] test cannot observe.
final class _ExternalDaemon {
  _ExternalDaemon({
    required this.process,
    required this.port,
    required this.dataDir,
  });

  final Process process;
  final int port;
  final Directory dataDir;
  String _output = '';
  bool _stopped = false;

  String get outputTail => _output;

  static Future<_ExternalDaemon> start({
    required String executable,
    required int port,
    required Directory dataDir,
  }) async {
    final process = await Process.start(
      executable,
      [
        'run',
        'agent_daemon:daemon',
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--data-dir',
        dataDir.path,
        '--no-relay',
        '--no-web-ui',
        '--no-mcp',
      ],
      workingDirectory: _workspaceRoot(),
      runInShell: false,
    );
    final daemon = _ExternalDaemon(
      process: process,
      port: port,
      dataDir: dataDir,
    );
    // Drain both streams so a verbose daemon/provider can never block on a
    // full pipe. Keep a bounded tail for actionable startup failures.
    process.stdout.transform(utf8.decoder).listen(daemon._appendOutput);
    process.stderr.transform(utf8.decoder).listen(daemon._appendOutput);
    return daemon;
  }

  void _appendOutput(String chunk) {
    _output = '$_output$chunk';
    if (_output.length > 8192) {
      _output = _output.substring(_output.length - 8192);
    }
  }

  Future<ServerHello> waitForHello({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final hello = await probeDaemon(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 2),
      );
      if (hello != null) return hello;
      // An exited child cannot become healthy later; surface its captured
      // tail immediately instead of waiting for the full smoke timeout.
      final exited = await _hasExited();
      if (exited != null) {
        throw StateError(
          'external daemon exited with code $exited before hello.\n$_output',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError(
      'external daemon did not answer hello on port $port within $timeout.\n'
      'Output tail:\n$_output',
    );
  }

  Future<int?> _hasExited() async {
    // A completed exitCode future is the only portable way to distinguish a
    // failed spawn from a still-starting child without polling tasklist.
    var completed = false;
    var code = 0;
    unawaited(
      process.exitCode.then((value) {
        completed = true;
        code = value;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    return completed ? code : null;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    // Kill the complete process tree first: `dart run` owns a child Dart VM
    // and leaving it alive would retain the temp data directory/port.
    try {
      await killTree(process.pid, grace: const Duration(seconds: 2));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

Future<int> _findFreePort() async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    // Recheck immediately after releasing the ephemeral reservation. This
    // avoids selecting a port already occupied by a parallel Windows run.
    try {
      final check = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await check.close();
      return port;
    } on SocketException {
      continue;
    }
  }
  throw StateError('Unable to allocate a free loopback TCP port for smoke');
}

Future<void> _connectClient(DaemonClient client) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    await client.connect();
    if (client.currentState == DaemonConnectionState.connected &&
        client.serverInfo != null) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError(
    'UI-owned daemon client did not complete hello: '
    '${client.lastConnectionError}',
  );
}

String _workspaceRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    final pubspec = File(
      '${directory.path}${Platform.pathSeparator}pubspec.yaml',
    );
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('workspace:')) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'Could not locate coding-agent workspace from ${Directory.current.path}',
  );
}

String _providerFixturePath() {
  final candidates = [
    '${Directory.current.path}${Platform.pathSeparator}integration_test'
        '${Platform.pathSeparator}support${Platform.pathSeparator}'
        'deterministic_acp_provider.dart',
    '${Directory.current.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}app${Platform.pathSeparator}'
        'integration_test${Platform.pathSeparator}support'
        '${Platform.pathSeparator}deterministic_acp_provider.dart',
  ];
  return candidates.firstWhere(
    (candidate) => File(candidate).existsSync(),
    orElse: () => throw StateError(
      'Deterministic ACP fixture was not found from ${Directory.current.path}',
    ),
  );
}

Future<String> _resolveDartExecutable() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    final bundled = File(
      '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}dart.exe',
    );
    if (bundled.existsSync()) return bundled.resolveSymbolicLinks();
  }
  final result = await Process.run('where.exe', const ['dart']);
  if (result.exitCode == 0) {
    final candidate = '${result.stdout}'
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .firstOrNull;
    if (candidate != null && File(candidate).existsSync()) {
      return File(candidate).resolveSymbolicLinks();
    }
  }
  throw StateError(
    'Dart executable not found. Run the smoke from a Flutter-enabled shell.',
  );
}
