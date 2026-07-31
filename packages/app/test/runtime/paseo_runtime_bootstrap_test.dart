// Ports of the upstream test suites for Paseo's cold-start cluster:
// `navigation/host-runtime-bootstrap.test.ts` and
// `runtime/daemon-start-service.test.ts`, plus the edge cases those suites
// leave unpinned (JS truthiness on the blank server id / blank error string,
// the empty-string index pathname, blank ids inside the saved-host list, a
// null host route param, condition callbacks that answer false, concurrent
// start attempts, non-`Error` throws, a store that rejects, and the process
// singleton).
import 'dart:async';

import 'package:coding_agent_app/runtime/paseo_runtime_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// One recorded `upsertConnectionFromListen` call.
final class _RecordedUpsert {
  const _RecordedUpsert({
    required this.listenAddress,
    required this.serverId,
    required this.hostname,
  });

  final String listenAddress;
  final String serverId;
  final String? hostname;

  @override
  bool operator ==(Object other) =>
      other is _RecordedUpsert &&
      other.listenAddress == listenAddress &&
      other.serverId == serverId &&
      other.hostname == hostname;

  @override
  int get hashCode => Object.hash(listenAddress, serverId, hostname);

  @override
  String toString() =>
      '_RecordedUpsert($listenAddress, $serverId, ${hostname ?? 'null'})';
}

/// Records every upsert the service performs, and can be made to fail.
final class _FakeConnectionStore implements DaemonConnectionStore {
  _FakeConnectionStore({this.failure});

  final Object? failure;
  final List<_RecordedUpsert> upserts = [];

  @override
  Future<void> upsertConnectionFromListen({
    required String listenAddress,
    required String serverId,
    required String? hostname,
  }) async {
    if (failure != null) throw failure!;
    upserts.add(
      _RecordedUpsert(
        listenAddress: listenAddress,
        serverId: serverId,
        hostname: hostname,
      ),
    );
  }
}

/// Records that the host registry was booted, optionally failing first.
final class _FakeBootstrapStore implements HostRuntimeBootstrapStore {
  _FakeBootstrapStore({this.events, this.failure});

  final List<String>? events;
  final Object? failure;
  int bootCount = 0;

  @override
  void boot() {
    bootCount += 1;
    events?.add('boot');
    if (failure != null) throw failure!;
  }
}

/// Captures the condition the bootstrap forwards, without doing any work.
final class _FakeBootstrapDaemonStartService
    implements HostRuntimeBootstrapDaemonStartService {
  _FakeBootstrapDaemonStartService({this.events, this.gate});

  final List<String>? events;
  final Completer<DaemonStartResult>? gate;
  final List<DaemonStartCondition> received = [];

  @override
  Future<DaemonStartResult> startIfEnabled({
    required DaemonStartCondition shouldStart,
  }) {
    received.add(shouldStart);
    events?.add('daemon-start-decision');
    return gate?.future ??
        Future<DaemonStartResult>.value(const DaemonStartOk());
  }
}

DesktopDaemonStatus _status({
  String serverId = 'srv_desktop',
  DesktopDaemonState status = DesktopDaemonState.running,
  String? listen = '127.0.0.1:6767',
  String? hostname = 'desktop',
  int? pid = 1234,
  String home = '/home',
  String? version = '0.0.0',
  bool desktopManaged = true,
  String? error,
}) => DesktopDaemonStatus(
  serverId: serverId,
  status: status,
  listen: listen,
  hostname: hostname,
  pid: pid,
  home: home,
  version: version,
  desktopManaged: desktopManaged,
  error: error,
);

DaemonStartService _service({
  required _FakeConnectionStore store,
  required DesktopDaemonLauncher launcher,
}) => DaemonStartService(
  DaemonStartServiceDeps(store: store, startDesktopDaemon: launcher),
);

const _defaultUpsert = _RecordedUpsert(
  listenAddress: '127.0.0.1:6767',
  serverId: 'srv_desktop',
  hostname: 'desktop',
);

// ---------------------------------------------------------------------------
// Startup route input builders
// ---------------------------------------------------------------------------

IndexStartupRouteInput _indexInput({
  String pathname = '/',
  StartupBlocker startupBlocker = const NoStartupBlocker(),
  StartupRegistryStatus hostRegistryStatus = StartupRegistryStatus.ready,
  List<String> serverIds = const [],
  String? anyOnlineHostServerId,
  HostWorkspaceRoute? workspaceSelection,
  WorkspaceSelectionStatus workspaceSelectionStatus =
      WorkspaceSelectionStatus.unknown,
  bool isWorkspaceSelectionLoaded = true,
  bool hasGivenUpWaitingForHost = false,
}) => IndexStartupRouteInput(
  route: IndexStartupRouteTarget(pathname),
  startupBlocker: startupBlocker,
  hostRegistryStatus: hostRegistryStatus,
  serverIds: serverIds,
  anyOnlineHostServerId: anyOnlineHostServerId,
  workspaceSelection: workspaceSelection,
  workspaceSelectionStatus: workspaceSelectionStatus,
  isWorkspaceSelectionLoaded: isWorkspaceSelectionLoaded,
  hasGivenUpWaitingForHost: hasGivenUpWaitingForHost,
);

HostStartupRouteInput _hostInput({
  String? serverId = 'server-saved',
  StartupBlocker startupBlocker = const NoStartupBlocker(),
  StartupRegistryStatus hostRegistryStatus = StartupRegistryStatus.ready,
  List<String> serverIds = const [],
}) => HostStartupRouteInput(
  route: HostStartupRouteTarget(serverId),
  startupBlocker: startupBlocker,
  hostRegistryStatus: hostRegistryStatus,
  serverIds: serverIds,
);

HostWorkspaceRoute _selection(String serverId, String workspaceId) =>
    HostWorkspaceRoute(serverId: serverId, workspaceId: workspaceId);

void main() {
  group('startHostRuntimeBootstrap', () {
    test(
      'boots the host registry and starts the managed-daemon decision as one '
      'operation',
      () {
        final events = <String>[];
        const shouldStartDaemon = FixedDaemonStartCondition(true);
        final store = _FakeBootstrapStore(events: events);
        final daemonStartService = _FakeBootstrapDaemonStartService(
          events: events,
        );

        startHostRuntimeBootstrap(
          store: store,
          daemonStartService: daemonStartService,
          shouldStartDaemon: shouldStartDaemon,
        );

        expect(events, ['boot', 'daemon-start-decision']);
        // Upstream asserts identity (`toBe`): the condition is forwarded, not
        // rebuilt.
        expect(
          identical(daemonStartService.received.single, shouldStartDaemon),
          isTrue,
        );
      },
    );

    test('returns without waiting for the daemon decision to settle', () {
      final gate = Completer<DaemonStartResult>();
      final store = _FakeBootstrapStore();
      final daemonStartService = _FakeBootstrapDaemonStartService(gate: gate);

      startHostRuntimeBootstrap(
        store: store,
        daemonStartService: daemonStartService,
        shouldStartDaemon: ComputedDaemonStartCondition(() async => true),
      );

      expect(store.bootCount, 1);
      expect(daemonStartService.received, hasLength(1));
      expect(gate.isCompleted, isFalse);
      gate.complete(const DaemonStartOk());
    });

    test(
      'does not run the daemon decision when booting the registry throws',
      () {
        final store = _FakeBootstrapStore(
          failure: StateError('registry broke'),
        );
        final daemonStartService = _FakeBootstrapDaemonStartService();

        expect(
          () => startHostRuntimeBootstrap(
            store: store,
            daemonStartService: daemonStartService,
            shouldStartDaemon: const FixedDaemonStartCondition(true),
          ),
          throwsA(isA<StateError>()),
        );
        expect(daemonStartService.received, isEmpty);
      },
    );
  });

  group('startup blocking policy', () {
    StartupBlocker blocker({
      bool isDesktopRuntime = false,
      String? anyOnlineHostServerId,
      bool daemonStartIsRunning = false,
      String? daemonStartError,
    }) => resolveStartupBlocker(
      isDesktopRuntime: isDesktopRuntime,
      anyOnlineHostServerId: anyOnlineHostServerId,
      daemonStartIsRunning: daemonStartIsRunning,
      daemonStartError: daemonStartError,
    );

    test('runs the give-up timer when no startup blocker is active', () {
      final result = blocker();

      expect(result, const NoStartupBlocker());
      expect(resolveStartupNavigationReady(startupBlocker: result), isTrue);
      expect(
        shouldRunStartupGiveUpTimer(
          startupBlocker: result,
          anyOnlineHostServerId: null,
          hasGivenUpWaitingForHost: false,
        ),
        isTrue,
      );
    });

    test('blocks navigation while desktop is starting the managed daemon', () {
      final result = blocker(
        isDesktopRuntime: true,
        daemonStartIsRunning: true,
      );

      expect(result, const ManagedDaemonStartingBlocker());
      expect(resolveStartupNavigationReady(startupBlocker: result), isFalse);
      expect(
        shouldRunStartupGiveUpTimer(
          startupBlocker: result,
          anyOnlineHostServerId: null,
          hasGivenUpWaitingForHost: false,
        ),
        isFalse,
      );
    });

    test('unblocks navigation when any host is online', () {
      final result = blocker(
        isDesktopRuntime: true,
        anyOnlineHostServerId: 'srv_desktop',
        daemonStartIsRunning: true,
      );

      expect(result, const NoStartupBlocker());
      expect(resolveStartupNavigationReady(startupBlocker: result), isTrue);
    });

    test(
      'keeps desktop daemon startup errors on the startup error surface',
      () {
        final result = blocker(
          isDesktopRuntime: true,
          daemonStartError: 'daemon failed to start',
        );

        expect(
          result,
          const ManagedDaemonErrorBlocker('daemon failed to start'),
        );
        expect(resolveStartupNavigationReady(startupBlocker: result), isTrue);
        expect(
          shouldRunStartupGiveUpTimer(
            startupBlocker: result,
            anyOnlineHostServerId: null,
            hasGivenUpWaitingForHost: false,
          ),
          isFalse,
        );
      },
    );

    test('never blocks a non-desktop runtime, whatever the daemon reports', () {
      expect(
        blocker(daemonStartIsRunning: true, daemonStartError: 'boom'),
        const NoStartupBlocker(),
      );
    });

    test('reports the error even while a retry is already running', () {
      expect(
        blocker(
          isDesktopRuntime: true,
          daemonStartIsRunning: true,
          daemonStartError: 'daemon failed to start',
        ),
        const ManagedDaemonErrorBlocker('daemon failed to start'),
      );
    });

    test('treats a blank online host id as no online host', () {
      // JS truthiness: `if (input.anyOnlineHostServerId)` is false for "".
      expect(
        blocker(
          isDesktopRuntime: true,
          anyOnlineHostServerId: '',
          daemonStartIsRunning: true,
        ),
        const ManagedDaemonStartingBlocker(),
      );
    });

    test('treats a blank daemon error as no error', () {
      expect(
        blocker(
          isDesktopRuntime: true,
          daemonStartError: '',
          daemonStartIsRunning: true,
        ),
        const ManagedDaemonStartingBlocker(),
      );
      expect(
        blocker(isDesktopRuntime: true, daemonStartError: ''),
        const NoStartupBlocker(),
      );
    });

    test(
      'stops the give-up timer once a host is online or it already fired',
      () {
        expect(
          shouldRunStartupGiveUpTimer(
            startupBlocker: const NoStartupBlocker(),
            anyOnlineHostServerId: 'srv',
            hasGivenUpWaitingForHost: false,
          ),
          isFalse,
        );
        expect(
          shouldRunStartupGiveUpTimer(
            startupBlocker: const NoStartupBlocker(),
            anyOnlineHostServerId: null,
            hasGivenUpWaitingForHost: true,
          ),
          isFalse,
        );
        // A blank id is not an online host, so the timer keeps running.
        expect(
          shouldRunStartupGiveUpTimer(
            startupBlocker: const NoStartupBlocker(),
            anyOnlineHostServerId: '',
            hasGivenUpWaitingForHost: false,
          ),
          isTrue,
        );
      },
    );
  });

  group('resolveStartupRoute', () {
    test(
      'renders non-index routes instead of making an index startup decision',
      () {
        expect(
          resolveStartupRoute(_indexInput(pathname: '/settings')),
          const RenderStartupRoute(),
        );
      },
    );

    test('keeps startup on the splash while the persisted workspace selection '
        'is loading', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            anyOnlineHostServerId: 'server-1',
            isWorkspaceSelectionLoaded: false,
          ),
        ),
        const SplashStartupRoute(),
      );
    });

    test('keeps startup on the splash while the host registry is loading', () {
      expect(
        resolveStartupRoute(
          _indexInput(hostRegistryStatus: StartupRegistryStatus.loading),
        ),
        const SplashStartupRoute(),
      );
    });

    test('does not treat loading hosts as an empty registry when a workspace '
        'is already restored', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            hostRegistryStatus: StartupRegistryStatus.loading,
            workspaceSelection: _selection('server-1', 'workspace-a'),
            hasGivenUpWaitingForHost: true,
          ),
        ),
        const SplashStartupRoute(),
      );
    });

    test('enters the host boundary for saved workspace restore after the host '
        'registry proves the host exists', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            serverIds: const ['server-1'],
            workspaceSelection: _selection('server-1', 'workspace-a'),
            workspaceSelectionStatus: WorkspaceSelectionStatus.exists,
          ),
        ),
        const RedirectStartupRoute('/h/server-1'),
      );
    });

    test('restores the last workspace host even when a different host is '
        'already online', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            serverIds: const ['server-offline', 'server-online'],
            anyOnlineHostServerId: 'server-online',
            workspaceSelection: _selection('server-offline', 'workspace-a'),
          ),
        ),
        const RedirectStartupRoute('/h/server-offline'),
      );
    });

    test('does not restore a saved workspace after workspace hydration proves '
        'it is missing', () {
      // Still lands on /h/server-1 — but as the saved-host fallback, not as a
      // workspace restore.
      expect(
        resolveStartupRoute(
          _indexInput(
            serverIds: const ['server-1'],
            workspaceSelection: _selection('server-1', 'workspace-a'),
            workspaceSelectionStatus: WorkspaceSelectionStatus.missing,
          ),
        ),
        const RedirectStartupRoute('/h/server-1'),
      );
    });

    test('falls back to a saved host when the restored workspace host is no '
        'longer saved', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            workspaceSelection: _selection('server-saved', 'workspace-a'),
            serverIds: const ['server-next'],
            hasGivenUpWaitingForHost: true,
          ),
        ),
        const RedirectStartupRoute('/h/server-next'),
      );
    });

    test(
      'redirects to the online host when no saved workspace is selected',
      () {
        expect(
          resolveStartupRoute(
            _indexInput(anyOnlineHostServerId: 'srv-desktop'),
          ),
          const RedirectStartupRoute('/h/srv-desktop'),
        );
      },
    );

    test('keeps a known connecting host in app-owned routing instead of '
        'showing welcome', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            serverIds: const ['server-saved'],
            hasGivenUpWaitingForHost: true,
          ),
        ),
        const RedirectStartupRoute('/h/server-saved'),
      );
    });

    test('shows welcome after root startup gives up and no host exists', () {
      expect(
        resolveStartupRoute(_indexInput(hasGivenUpWaitingForHost: true)),
        const RedirectStartupRoute('/welcome'),
      );
    });

    test('keeps host routes mounted while the host registry is loading', () {
      expect(
        resolveStartupRoute(
          _hostInput(hostRegistryStatus: StartupRegistryStatus.loading),
        ),
        const RenderStartupRoute(),
      );
    });

    test('keeps host routes mounted while the managed daemon is starting', () {
      expect(
        resolveStartupRoute(
          _hostInput(startupBlocker: const ManagedDaemonStartingBlocker()),
        ),
        const RenderStartupRoute(),
      );
    });

    test('renders a host route once the route host is known', () {
      expect(
        resolveStartupRoute(_hostInput(serverIds: const ['server-saved'])),
        const RenderStartupRoute(),
      );
    });

    test('sends removed host routes to global project selection instead of '
        'welcome', () {
      expect(
        resolveStartupRoute(
          _hostInput(
            serverId: 'server-removed',
            serverIds: const ['server-next'],
          ),
        ),
        const RedirectStartupRoute('/open-project'),
      );
    });

    test('shows welcome from a host route only after the registry proves no '
        'hosts exist', () {
      expect(
        resolveStartupRoute(_hostInput(serverId: 'server-removed')),
        const RedirectStartupRoute('/welcome'),
      );
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('splashes the index while a managed daemon error blocks startup', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            startupBlocker: const ManagedDaemonErrorBlocker('boom'),
            serverIds: const ['server-1'],
          ),
        ),
        const SplashStartupRoute(),
      );
    });

    test(
      'renders a host route while a managed daemon error blocks startup',
      () {
        expect(
          resolveStartupRoute(
            _hostInput(
              serverId: 'server-removed',
              startupBlocker: const ManagedDaemonErrorBlocker('boom'),
            ),
          ),
          const RenderStartupRoute(),
        );
      },
    );

    test('treats an empty pathname as the index', () {
      expect(
        resolveStartupRoute(
          _indexInput(pathname: '', anyOnlineHostServerId: 'srv-desktop'),
        ),
        const RedirectStartupRoute('/h/srv-desktop'),
      );
    });

    test('renders a nested path before the workspace selection has loaded', () {
      // The pathname check runs first, so a deep route never splashes.
      expect(
        resolveStartupRoute(
          _indexInput(
            pathname: '/h/a/workspace/b',
            isWorkspaceSelectionLoaded: false,
          ),
        ),
        const RenderStartupRoute(),
      );
    });

    test('does not restore a workspace selection whose host id is blank', () {
      expect(
        resolveStartupRoute(
          _indexInput(
            serverIds: const ['', 'server-1'],
            workspaceSelection: _selection('', 'workspace-a'),
            workspaceSelectionStatus: WorkspaceSelectionStatus.exists,
            hasGivenUpWaitingForHost: true,
          ),
        ),
        // The blank id matches neither the registry nor the saved-host
        // fallback (`hosts[0]` is blank), so startup gives up to welcome.
        const RedirectStartupRoute('/welcome'),
      );
    });

    test('percent-encodes the server id in a startup redirect', () {
      expect(
        resolveStartupRoute(_indexInput(anyOnlineHostServerId: 'srv/one')),
        const RedirectStartupRoute('/h/srv%2Fone'),
      );
    });

    test(
      'splashes the index when nothing is online, saved, or given up on',
      () {
        expect(resolveStartupRoute(_indexInput()), const SplashStartupRoute());
      },
    );

    test(
      'sends a host route with no server id to global project selection',
      () {
        expect(
          resolveStartupRoute(
            _hostInput(serverId: null, serverIds: const ['server-next']),
          ),
          const RedirectStartupRoute('/open-project'),
        );
        expect(
          resolveStartupRoute(_hostInput(serverId: null)),
          const RedirectStartupRoute('/welcome'),
        );
      },
    );

    test(
      'sends a host route to welcome when the only saved host id is blank',
      () {
        // Upstream reads `hosts[0]?.serverId` and falls through to welcome when
        // it is falsy, rather than only when the list is empty.
        expect(
          resolveStartupRoute(
            _hostInput(serverId: 'server-removed', serverIds: const ['']),
          ),
          const RedirectStartupRoute('/welcome'),
        );
      },
    );
  });

  group('resolveHostIndexRoute', () {
    test('restores the remembered workspace when the host index opens for the '
        'same host', () {
      expect(
        resolveHostIndexRoute(
          serverId: 'server-saved',
          workspaceSelection: _selection('server-saved', 'workspace-a'),
          workspaceSelectionStatus: WorkspaceSelectionStatus.exists,
        ),
        '/h/server-saved/workspace/workspace-a',
      );
    });

    test('keeps restoring a remembered workspace before the host workspace '
        'list hydrates', () {
      expect(
        resolveHostIndexRoute(
          serverId: 'server-saved',
          workspaceSelection: _selection('server-saved', 'workspace-a'),
          workspaceSelectionStatus: WorkspaceSelectionStatus.unknown,
        ),
        '/h/server-saved/workspace/workspace-a',
      );
    });

    test('opens global project selection when the remembered workspace is '
        'proven missing', () {
      expect(
        resolveHostIndexRoute(
          serverId: 'server-saved',
          workspaceSelection: _selection('server-saved', 'workspace-a'),
          workspaceSelectionStatus: WorkspaceSelectionStatus.missing,
        ),
        '/open-project',
      );
    });

    test('opens global project selection when the remembered workspace belongs '
        'to another host', () {
      expect(
        resolveHostIndexRoute(
          serverId: 'server-saved',
          workspaceSelection: _selection('server-other', 'workspace-a'),
          workspaceSelectionStatus: WorkspaceSelectionStatus.exists,
        ),
        '/open-project',
      );
    });

    test('opens global project selection when no workspace is remembered', () {
      expect(
        resolveHostIndexRoute(
          serverId: 'server-saved',
          workspaceSelection: null,
          workspaceSelectionStatus: WorkspaceSelectionStatus.unknown,
        ),
        '/open-project',
      );
    });
  });

  group('resolveWorkspaceSelectionStatus', () {
    test(
      'an existing workspace is "exists" whether or not hydration finished',
      () {
        expect(
          resolveWorkspaceSelectionStatus(
            hasHydratedWorkspaces: false,
            workspaceExists: true,
          ),
          WorkspaceSelectionStatus.exists,
        );
        expect(
          resolveWorkspaceSelectionStatus(
            hasHydratedWorkspaces: true,
            workspaceExists: true,
          ),
          WorkspaceSelectionStatus.exists,
        );
      },
    );

    test('absence is only "missing" once hydration has proved it', () {
      expect(
        resolveWorkspaceSelectionStatus(
          hasHydratedWorkspaces: false,
          workspaceExists: false,
        ),
        WorkspaceSelectionStatus.unknown,
      );
      expect(
        resolveWorkspaceSelectionStatus(
          hasHydratedWorkspaces: true,
          workspaceExists: false,
        ),
        WorkspaceSelectionStatus.missing,
      );
    });
  });

  group('upsertDesktopDaemonConnection', () {
    test('upserts a valid desktop daemon status', () async {
      final store = _FakeConnectionStore();

      final result = await upsertDesktopDaemonConnection(store, _status());

      expect(result, const DaemonStartOk());
      expect(store.upserts, [_defaultUpsert]);
    });

    test('rejects a missing listen address without upserting', () async {
      final store = _FakeConnectionStore();

      final result = await upsertDesktopDaemonConnection(
        store,
        _status(listen: null),
      );

      expect(
        result,
        const DaemonStartFailure(
          'Desktop daemon did not return a listen address.',
        ),
      );
      expect(store.upserts, isEmpty);
    });

    test('rejects a missing server id without upserting', () async {
      final store = _FakeConnectionStore();

      final result = await upsertDesktopDaemonConnection(
        store,
        _status(serverId: ''),
      );

      expect(
        result,
        const DaemonStartFailure('Desktop daemon did not return a server id.'),
      );
      expect(store.upserts, isEmpty);
    });

    test('rejects an unsupported listen address without upserting', () async {
      final store = _FakeConnectionStore();

      final result = await upsertDesktopDaemonConnection(
        store,
        _status(listen: '???'),
      );

      expect(result.ok, isFalse);
      expect(
        (result as DaemonStartFailure).error,
        contains('unsupported listen address'),
      );
      expect(store.upserts, isEmpty);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test(
      'trims the listen address and the server id before upserting',
      () async {
        final store = _FakeConnectionStore();

        final result = await upsertDesktopDaemonConnection(
          store,
          _status(listen: '  127.0.0.1:6767  ', serverId: '  srv_desktop  '),
        );

        expect(result, const DaemonStartOk());
        expect(store.upserts, [_defaultUpsert]);
      },
    );

    test('treats a whitespace-only listen address as missing', () async {
      final store = _FakeConnectionStore();

      expect(
        await upsertDesktopDaemonConnection(store, _status(listen: '   ')),
        const DaemonStartFailure(
          'Desktop daemon did not return a listen address.',
        ),
      );
      expect(store.upserts, isEmpty);
    });

    test('treats a whitespace-only server id as missing', () async {
      final store = _FakeConnectionStore();

      expect(
        await upsertDesktopDaemonConnection(store, _status(serverId: '   ')),
        const DaemonStartFailure('Desktop daemon did not return a server id.'),
      );
      expect(store.upserts, isEmpty);
    });

    test(
      'accepts socket and pipe listen addresses, and a null hostname',
      () async {
        final store = _FakeConnectionStore();

        expect(
          await upsertDesktopDaemonConnection(
            store,
            _status(listen: 'unix:///tmp/paseo.sock', hostname: null),
          ),
          const DaemonStartOk(),
        );
        expect(
          await upsertDesktopDaemonConnection(
            store,
            _status(listen: r'pipe://\\.\pipe\paseo'),
          ),
          const DaemonStartOk(),
        );
        expect(store.upserts, [
          const _RecordedUpsert(
            listenAddress: 'unix:///tmp/paseo.sock',
            serverId: 'srv_desktop',
            hostname: null,
          ),
          const _RecordedUpsert(
            listenAddress: r'pipe://\\.\pipe\paseo',
            serverId: 'srv_desktop',
            hostname: 'desktop',
          ),
        ]);
      },
    );

    test(
      'rejects a listen address before the server id is even checked',
      () async {
        final store = _FakeConnectionStore();

        // Ordering matters: both are blank, and upstream reports the listen
        // address first.
        expect(
          await upsertDesktopDaemonConnection(
            store,
            _status(listen: null, serverId: ''),
          ),
          const DaemonStartFailure(
            'Desktop daemon did not return a listen address.',
          ),
        );
      },
    );
  });

  group('DaemonStartService', () {
    test('upserts the connection on a successful daemon start', () async {
      final store = _FakeConnectionStore();
      final service = _service(store: store, launcher: () async => _status());

      final result = await service.start();

      expect(result, const DaemonStartOk());
      expect(store.upserts, [_defaultUpsert]);
      expect(service.lastError, isNull);
      expect(service.isRunning, isFalse);
    });

    test('reports lastError after a missing listen address and clears running '
        'state when done', () async {
      final store = _FakeConnectionStore();
      final service = _service(
        store: store,
        launcher: () async => _status(listen: null),
      );

      final result = await service.start();

      expect(
        result,
        const DaemonStartFailure(
          'Desktop daemon did not return a listen address.',
        ),
      );
      expect(
        service.lastError,
        'Desktop daemon did not return a listen address.',
      );
      expect(service.isRunning, isFalse);
      expect(store.upserts, isEmpty);
    });

    test(
      'reports lastError when the daemon does not return a server id',
      () async {
        final store = _FakeConnectionStore();
        final service = _service(
          store: store,
          launcher: () async => _status(serverId: ''),
        );

        final result = await service.start();

        expect(
          result,
          const DaemonStartFailure(
            'Desktop daemon did not return a server id.',
          ),
        );
        expect(service.lastError, 'Desktop daemon did not return a server id.');
        expect(store.upserts, isEmpty);
      },
    );

    test('reports lastError when the listen address is unsupported', () async {
      final store = _FakeConnectionStore();
      final service = _service(
        store: store,
        launcher: () async => _status(listen: '???'),
      );

      final result = await service.start();

      expect(result.ok, isFalse);
      expect(service.lastError, contains('unsupported listen address'));
      expect(store.upserts, isEmpty);
    });

    test('reports lastError when the underlying start call throws', () async {
      final store = _FakeConnectionStore();
      final service = _service(
        store: store,
        launcher: () async => throw StateError('ipc broke'),
      );

      final result = await service.start();

      expect(result, const DaemonStartFailure('ipc broke'));
      expect(service.lastError, 'ipc broke');
    });

    test('clears lastError on retry entry and reports null after subsequent '
        'success', () async {
      final store = _FakeConnectionStore();
      var call = 0;
      final service = _service(
        store: store,
        launcher: () async {
          call += 1;
          if (call == 1) throw StateError('ipc broke');
          return _status();
        },
      );

      final failure = await service.start();
      expect(failure.ok, isFalse);
      expect(service.lastError, 'ipc broke');

      final success = await service.start();
      expect(success, const DaemonStartOk());
      expect(service.lastError, isNull);
    });

    test('notifies subscribers when isRunning toggles between calls', () async {
      final store = _FakeConnectionStore();
      final gate = Completer<DesktopDaemonStatus>();
      final service = _service(store: store, launcher: () => gate.future);

      final runningSnapshots = <bool>[];
      service.subscribe(() => runningSnapshots.add(service.isRunning));

      final startFuture = service.start();
      expect(service.isRunning, isTrue);
      expect(runningSnapshots, [true]);

      gate.complete(_status());
      await startFuture;

      expect(service.isRunning, isFalse);
      expect(runningSnapshots, [true, false]);
    });

    test('stays running while deciding whether the managed daemon should '
        'start', () async {
      final store = _FakeConnectionStore();
      final condition = Completer<bool>();
      var daemonStartCount = 0;
      final service = _service(
        store: store,
        launcher: () async {
          daemonStartCount += 1;
          return _status();
        },
      );

      final startFuture = service.startIfEnabled(
        shouldStart: ComputedDaemonStartCondition(() => condition.future),
      );

      expect(service.isRunning, isTrue);
      expect(daemonStartCount, 0);

      condition.complete(true);
      await startFuture;

      expect(service.isRunning, isFalse);
      expect(daemonStartCount, 1);
    });

    test(
      'finishes without starting the daemon when management is disabled',
      () async {
        final store = _FakeConnectionStore();
        var daemonStartCount = 0;
        final service = _service(
          store: store,
          launcher: () async {
            daemonStartCount += 1;
            return _status();
          },
        );

        final result = await service.startIfEnabled(
          shouldStart: const FixedDaemonStartCondition(false),
        );

        expect(result, const DaemonStartOk());
        expect(service.isRunning, isFalse);
        expect(daemonStartCount, 0);
      },
    );

    test(
      'clears the error and notifies subscribers when retry begins',
      () async {
        final store = _FakeConnectionStore();
        var call = 0;
        final service = _service(
          store: store,
          launcher: () async {
            call += 1;
            if (call == 1) throw StateError('ipc broke');
            return _status();
          },
        );

        await service.start();
        expect(service.lastError, 'ipc broke');

        final errorSnapshots = <String?>[];
        service.subscribe(() => errorSnapshots.add(service.lastError));

        await service.start();
        expect(errorSnapshots.first, isNull);
        expect(service.lastError, isNull);
      },
    );

    test('surfaces settings errors through the daemon startup state', () async {
      final store = _FakeConnectionStore();
      final service = _service(store: store, launcher: () async => _status());

      final result = await service.startIfEnabled(
        shouldStart: ComputedDaemonStartCondition(
          () async => throw StateError('settings file unreadable'),
        ),
      );

      expect(
        result,
        const DaemonStartFailure(
          'Failed to evaluate desktop daemon settings: settings file unreadable',
        ),
      );
      expect(
        service.lastError,
        'Failed to evaluate desktop daemon settings: settings file unreadable',
      );
      expect(service.isRunning, isFalse);
    });

    test('stops notifying after a subscriber unsubscribes', () async {
      final store = _FakeConnectionStore();
      var notifications = 0;
      final service = _service(
        store: store,
        launcher: () async => _status(listen: null),
      );
      final unsubscribe = service.subscribe(() => notifications += 1);

      await service.start();
      final countAfterFirst = notifications;
      expect(countAfterFirst, greaterThan(0));

      unsubscribe();
      await service.start();
      expect(notifications, countAfterFirst);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('keeps running until every concurrent attempt settles', () async {
      final store = _FakeConnectionStore();
      final first = Completer<DesktopDaemonStatus>();
      final second = Completer<DesktopDaemonStatus>();
      var call = 0;
      final service = _service(
        store: store,
        launcher: () {
          call += 1;
          return call == 1 ? first.future : second.future;
        },
      );

      final runningSnapshots = <bool>[];
      service.subscribe(() => runningSnapshots.add(service.isRunning));

      final firstStart = service.start();
      final secondStart = service.start();
      expect(service.isRunning, isTrue);
      // Only the first entry crosses the not-running -> running edge.
      expect(runningSnapshots, [true]);

      first.complete(_status());
      await firstStart;
      expect(service.isRunning, isTrue);
      expect(runningSnapshots, [true]);

      second.complete(_status());
      await secondStart;
      expect(service.isRunning, isFalse);
      expect(runningSnapshots, [true, false]);
      expect(store.upserts, hasLength(2));
    });

    test('does not re-notify when the same failure repeats', () async {
      final store = _FakeConnectionStore();
      final service = _service(
        store: store,
        launcher: () async => throw StateError('ipc broke'),
      );

      await service.start();

      final errorSnapshots = <String?>[];
      service.subscribe(() => errorSnapshots.add(service.lastError));

      await service.start();

      // beginRequest clears the error (null), the identical failure is set
      // again (same message), and endRequest reports the settled state. The
      // repeat itself does not add a notification beyond those.
      expect(errorSnapshots, [null, 'ipc broke', 'ipc broke']);
    });

    test('describes a non-Error throw by its string form', () async {
      final store = _FakeConnectionStore();
      final service = _service(
        store: store,
        launcher: () async => throw 'ipc broke',
      );

      expect(await service.start(), const DaemonStartFailure('ipc broke'));
      expect(service.lastError, 'ipc broke');
    });

    test('reports a store that rejects the upsert', () async {
      final store = _FakeConnectionStore(failure: StateError('registry full'));
      final service = _service(store: store, launcher: () async => _status());

      expect(await service.start(), const DaemonStartFailure('registry full'));
      expect(service.lastError, 'registry full');
      expect(service.isRunning, isFalse);
    });

    test(
      'a computed condition answering false skips the daemon start',
      () async {
        final store = _FakeConnectionStore();
        var daemonStartCount = 0;
        final service = _service(
          store: store,
          launcher: () async {
            daemonStartCount += 1;
            return _status();
          },
        );

        expect(
          await service.startIfEnabled(
            shouldStart: ComputedDaemonStartCondition(() => false),
          ),
          const DaemonStartOk(),
        );
        expect(daemonStartCount, 0);
        expect(service.lastError, isNull);
      },
    );

    test(
      'a synchronously throwing condition is still a settings failure',
      () async {
        final store = _FakeConnectionStore();
        final service = _service(store: store, launcher: () async => _status());

        expect(
          await service.startIfEnabled(
            shouldStart: ComputedDaemonStartCondition(
              () => throw StateError('no settings file'),
            ),
          ),
          const DaemonStartFailure(
            'Failed to evaluate desktop daemon settings: no settings file',
          ),
        );
      },
    );

    test(
      'unsubscribing twice is harmless, and other listeners keep firing',
      () async {
        final store = _FakeConnectionStore();
        final service = _service(store: store, launcher: () async => _status());
        var dropped = 0;
        var kept = 0;
        final unsubscribe = service.subscribe(() => dropped += 1);
        service.subscribe(() => kept += 1);

        unsubscribe();
        unsubscribe();
        await service.start();

        expect(dropped, 0);
        expect(kept, greaterThan(0));
      },
    );

    test(
      'a listener that unsubscribes mid-notification is not called again',
      () async {
        final store = _FakeConnectionStore();
        final service = _service(store: store, launcher: () async => _status());
        var calls = 0;
        late final void Function() unsubscribe;
        unsubscribe = service.subscribe(() {
          calls += 1;
          unsubscribe();
        });

        await service.start();

        expect(calls, 1);
      },
    );
  });

  group('getDaemonStartService', () {
    setUp(resetDaemonStartServiceSingleton);
    tearDown(resetDaemonStartServiceSingleton);

    test('returns the same instance for every caller', () {
      final deps = DaemonStartServiceDeps(
        store: _FakeConnectionStore(),
        startDesktopDaemon: () async => _status(),
      );

      final first = getDaemonStartService(deps);
      final second = getDaemonStartService(deps);

      expect(identical(first, second), isTrue);
    });

    test('ignores the dependencies of every caller after the first', () async {
      final firstStore = _FakeConnectionStore();
      final secondStore = _FakeConnectionStore();

      final service = getDaemonStartService(
        DaemonStartServiceDeps(
          store: firstStore,
          startDesktopDaemon: () async => _status(),
        ),
      );
      getDaemonStartService(
        DaemonStartServiceDeps(
          store: secondStore,
          startDesktopDaemon: () async => _status(serverId: 'srv_other'),
        ),
      );

      await service.start();

      expect(firstStore.upserts, [_defaultUpsert]);
      expect(secondStore.upserts, isEmpty);
    });

    test('builds a fresh instance after the singleton is reset', () {
      final deps = DaemonStartServiceDeps(
        store: _FakeConnectionStore(),
        startDesktopDaemon: () async => _status(),
      );

      final first = getDaemonStartService(deps);
      resetDaemonStartServiceSingleton();
      final second = getDaemonStartService(deps);

      expect(identical(first, second), isFalse);
    });
  });
}
